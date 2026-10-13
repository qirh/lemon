defmodule CodingAgent.ControlPlaneProviderTest do
  @moduledoc """
  The provider deliberately carries no `@behaviour` attribute, so that this app
  keeps no compile-time reference to the reference runtime. These tests are what
  replaces that compile-time check.

  `lemon_control_plane` is not a dependency of this app, so the contract and
  boot-registration checks below only run where the control plane happens to be
  on the code path (a release or a full-umbrella boot). In an app-dir run
  (`cd apps/coding_agent && mix test`) they are compiled out; the adapter-shape
  tests always run.
  """

  use ExUnit.Case, async: false

  alias CodingAgent.ControlPlaneProvider

  @behaviour_module LemonControlPlane.AgentRuntime.Provider
  @control_plane_loaded Code.ensure_loaded?(@behaviour_module)

  if @control_plane_loaded do
    test "implements every callback the control plane declares" do
      expected = @behaviour_module.behaviour_info(:callbacks) |> Enum.sort()

      missing =
        Enum.reject(expected, fn {fun, arity} ->
          function_exported?(ControlPlaneProvider, fun, arity)
        end)

      assert missing == [],
             "provider is missing: #{inspect(missing)} — a typo here degrades the method to its fallback silently"
    end

    describe "boot registration" do
      setup do
        original = Application.get_env(:lemon_control_plane, :agent_runtime_provider)

        on_exit(fn ->
          if is_nil(original) do
            Application.delete_env(:lemon_control_plane, :agent_runtime_provider)
          else
            Application.put_env(:lemon_control_plane, :agent_runtime_provider, original)
          end
        end)

        :ok
      end

      test "the running application has registered this provider" do
        assert LemonControlPlane.AgentRuntime.provider() == ControlPlaneProvider
        assert LemonControlPlane.AgentRuntime.available?()
      end
    end
  end

  describe "adapters return the shapes the control plane expects" do
    @tag :tmp_dir
    test "resolves reviewer instructions with enforced read-only policy", %{tmp_dir: cwd} do
      agents = Path.join(cwd, ".lemon/agents")
      File.mkdir_p!(agents)

      File.write!(Path.join(agents, "reviewer.md"), """
      ---
      description: Local review policy
      model: openai-codex:gpt-5.5
      read_only: false
      tools: [read, write, bash]
      ---
      Check the exact proposed changes before approval.
      """)

      assert {:ok, persona} = ControlPlaneProvider.resolve_subagent(cwd, "reviewer")
      assert persona.prompt =~ "Check the exact proposed changes"
      assert persona.model == "openai-codex:gpt-5.5"
      assert persona.tool_policy.allow == ["read"]
      refute Map.has_key?(persona, :source)

      assert {:error, :persona_unavailable} =
               ControlPlaneProvider.resolve_subagent(cwd, "../reviewer")
    end

    test "list_tasks returns id/record pairs" do
      assert is_list(ControlPlaneProvider.list_tasks())
    end

    test "compact_session reports a missing session rather than raising" do
      assert ControlPlaneProvider.compact_session(
               "no-such-session-#{System.unique_integer()}",
               []
             ) ==
               {:error, :session_not_found}
    end

    test "todo_progress carries the actionable count for the control plane to rename" do
      progress = ControlPlaneProvider.todo_progress("no-such-session-#{System.unique_integer()}")
      assert progress.actionable_count == 0
    end

    test "wasm_sidecar_running? is a boolean" do
      assert is_boolean(ControlPlaneProvider.wasm_sidecar_running?())
    end

    test "extension_dirs returns global then project" do
      dirs = ControlPlaneProvider.extension_dirs("/tmp/some-project")

      assert length(dirs) == 2
      assert Enum.all?(dirs, &is_binary/1)
    end
  end

  describe "durable native session adapters" do
    setup do
      cwd = Path.join(System.tmp_dir!(), "provider-session-#{System.unique_integer([:positive])}")
      File.mkdir_p!(cwd)
      source_key = "source-#{LemonCore.Id.uuid()}"
      destination_key = "fork-#{LemonCore.Id.uuid()}"

      session =
        CodingAgent.SessionManager.new(cwd)
        |> CodingAgent.SessionManager.append_entry(
          CodingAgent.SessionManager.SessionEntry.model_change("openai-codex", "gpt-5.5")
        )
        |> CodingAgent.SessionManager.append_message(%{
          "role" => "user",
          "content" => "Decision: append-only JSONL"
        })
        |> CodingAgent.SessionManager.append_message(%{
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => "Remembered"}]
        })
        |> CodingAgent.SessionManager.append_message(%{
          "role" => "user",
          "content" => "TODO: blue widgets"
        })

      path = CodingAgent.Session.Presentation.session_file_path(session.header.id, cwd)
      :ok = CodingAgent.SessionManager.save_to_file(path, session)

      :ok =
        LemonCore.ChatStateStore.put(source_key, %LemonCore.ChatState{
          last_engine: "lemon",
          last_resume_token: session.header.id
        })

      on_exit(fn ->
        LemonCore.ChatStateStore.delete(source_key)
        LemonCore.ChatStateStore.delete(destination_key)
        File.rm_rf!(CodingAgent.Config.sessions_dir(cwd))
        File.rm_rf!(cwd)
      end)

      %{cwd: cwd, source: source_key, destination: destination_key, session: session, path: path}
    end

    test "fork creates a distinct resume token and replays independent history", context do
      assert :ok =
               ControlPlaneProvider.session_fork(context.source, context.cwd, context.destination)

      child = LemonCore.ChatStateStore.get(context.destination)
      assert child.last_engine == "lemon"
      refute child.last_resume_token == context.session.header.id

      assert {:ok, entries} =
               ControlPlaneProvider.session_history(context.destination, context.cwd)

      assert entries == CodingAgent.SessionManager.get_branch(context.session)

      assert {:error, :destination_exists} =
               ControlPlaneProvider.session_fork(context.source, context.cwd, context.destination)
    end

    test "manual compaction works after the native session process has stopped", context do
      assert :ok =
               ControlPlaneProvider.compact_session(context.source,
                 cwd: context.cwd,
                 summary: "Decision: append-only JSONL",
                 keep_recent_tokens: 5
               )

      assert {:ok, session} = CodingAgent.SessionManager.load_from_file(context.path)
      assert Enum.any?(CodingAgent.SessionManager.get_branch(session), &(&1.type == :compaction))
    end
  end
end
