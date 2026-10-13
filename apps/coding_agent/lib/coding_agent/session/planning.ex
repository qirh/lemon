defmodule CodingAgent.Session.Planning do
  @moduledoc """
  Branch-aware planning state. The native journal is authoritative; Markdown
  artifacts are immutable review copies, never writes into the working tree.
  Only an explicit user operation can approve a reviewed revision.
  """

  alias CodingAgent.SessionManager
  alias CodingAgent.SessionManager.SessionEntry
  alias CodingAgent.Session.Notifier
  alias LemonAi.Types.AssistantMessage

  @entry_type "lemon.plan"
  @max_bytes 32_768

  def context_boundary?(%SessionEntry{type: :custom, custom_type: @entry_type}), do: true
  def context_boundary?(_), do: false

  def empty do
    %{"mode" => "code", "status" => "none", "revision" => nil, "path" => nil, "content" => nil}
  end

  def status(session) do
    plan = stored(session)

    if is_binary(plan["revision"]) do
      Map.put(plan, "revision", digest([session.header.id, "\0", plan["revision"]]))
    else
      plan
    end
  end

  defp stored(%{by_id: entries, leaf_id: leaf}), do: stored_entry(entries, leaf)
  defp stored(_), do: empty()

  defp stored_entry(_entries, nil), do: empty()

  defp stored_entry(entries, id) do
    case Map.get(entries, id) do
      %SessionEntry{type: :custom, custom_type: @entry_type, data: data} when is_map(data) -> data
      %SessionEntry{parent_id: parent} -> stored_entry(entries, parent)
      _ -> empty()
    end
  end

  def transition(session, :status, _opts), do: {:ok, status(session), session}

  def transition(session, :enter, _opts) do
    case stored(session) do
      %{"mode" => "plan"} ->
        {:ok, status(session), session}

      old ->
        append(session, %{
          empty()
          | "mode" => "plan",
            "status" => "draft",
            "content" => old["content"]
        })
    end
  end

  def transition(session, :discard, _opts), do: append(session, empty())

  def transition(session, :approve, opts) do
    plan = stored(session)

    cond do
      plan["status"] != "pending" ->
        {:error, :plan_not_pending}

      Keyword.get(opts, :revision) != status(session)["revision"] ->
        {:error, :revision_mismatch}

      true ->
        expected = plan["content"]

        case File.read(plan["path"]) do
          {:ok, ^expected} ->
            append(session, %{plan | "mode" => "code", "status" => "approved"})

          _ ->
            {:error, :plan_artifact_changed}
        end
    end
  end

  def transition(_session, _action, _opts), do: {:error, :invalid_plan_action}

  defp append(session, plan) do
    session = SessionManager.append_entry(session, SessionEntry.custom(@entry_type, plan))
    {:ok, status(session), session}
  end

  def tools(tools, session) do
    if stored(session)["mode"] == "plan" do
      policy = CodingAgent.ToolPolicy.from_profile(:read_only)
      Enum.filter(tools, &CodingAgent.ToolPolicy.allowed?(policy, &1.name))
    else
      tools
    end
  end

  def system_prompt(base, session) do
    plan = stored(session)

    case plan do
      %{"mode" => "plan"} ->
        base <>
          "\n\n" <>
          """
          ## Read-only planning phase
          Research the user's request using only the available read-only tools. Do not
          modify files, run commands, delegate execution, or claim implementation is done.
          Produce a self-contained Markdown execution plan as your final response (at most
          32 KiB). Include the goal, exact files/symbols to change, ordered concrete steps,
          decisions and constraints, and verification commands with expected outcomes.
          Ground paths and behavior in files you actually read; label unresolved assumptions.
          Your final response is saved automatically as a durable review artifact outside
          the working tree. It is NOT approval. Wait for the user's explicit plan approval
          before execution; ordinary follow-up prompts remain read-only.
          """ <> reference_plan(plan)

      %{"status" => "approved", "content" => content, "path" => path} ->
        base <>
          "\n\n## User-approved execution plan\n" <>
          "The user explicitly approved this plan. Execute it when requested, preserving its " <>
          "constraints and verifying actual outcomes. New user instructions take precedence.\n" <>
          "Durable review copy: #{path}\n\n#{content}"

      _ ->
        base
    end
  end

  defp reference_plan(%{"content" => content}) when is_binary(content) and content != "",
    do: "\nPrevious plan, for revision/reference (not approval):\n" <> content

  defp reference_plan(_), do: ""

  def refresh(state) do
    tools = tools(state.base_tools || state.tools || [], state.session_manager)

    prompt =
      system_prompt(state.base_system_prompt || state.system_prompt || "", state.session_manager)

    if tools != state.tools, do: :ok = LemonAgent.Agent.set_tools(state.agent, tools)

    if prompt != state.system_prompt,
      do: :ok = LemonAgent.Agent.set_system_prompt(state.agent, prompt)

    %{state | tools: tools, system_prompt: prompt}
  end

  def after_turn(state, messages) do
    if stored(Map.get(state, :session_manager))["mode"] == "plan" do
      case List.last(messages) do
        %AssistantMessage{stop_reason: :stop} = message ->
          text = message |> LemonAi.get_text() |> String.trim()
          capture(state, text)

        _ ->
          state
      end
    else
      state
    end
  end

  defp capture(state, ""), do: state

  defp capture(state, text) when byte_size(text) > @max_bytes do
    Notifier.broadcast_event(state, {:plan_error, :plan_too_large})
    state
  end

  defp capture(state, text) do
    session = state.session_manager
    old = stored(session)

    if old["status"] == "pending" and old["content"] == text do
      state
    else
      revision = digest([session.header.id, "\0", session.leaf_id || "", "\0", text])

      directory =
        Path.join([
          SessionManager.get_session_dir(session.header.cwd),
          "plans",
          digest(session.header.id)
        ])

      path = Path.join(directory, revision <> ".md")

      with :ok <- File.mkdir_p(directory),
           :ok <- File.chmod(directory, 0o700),
           :ok <- write_artifact(path, text) do
        plan = %{
          "mode" => "plan",
          "status" => "pending",
          "revision" => revision,
          "path" => path,
          "content" => text
        }

        {:ok, public, session} = append(session, plan)
        state = %{state | session_manager: session}
        Notifier.broadcast_event(state, {:plan_ready, public})
        state
      else
        {:error, _} ->
          Notifier.broadcast_event(state, {:plan_error, :artifact_write_failed})
          state
      end
    end
  end

  defp write_artifact(path, text) do
    temporary = path <> "." <> LemonCore.Id.uuid() <> ".tmp"

    try do
      with :ok <- File.write(temporary, text, [:exclusive, :sync]),
           :ok <- File.chmod(temporary, 0o600),
           :ok <- File.rename(temporary, path),
           do: :ok
    after
      File.rm(temporary)
    end
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
