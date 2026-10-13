defmodule LemonControlPlane.ACP do
  @moduledoc """
  Agent Client Protocol JSON-RPC bridge.

  ACP sessions retain model, thinking and approval settings across reconnects.
  Loading replays redacted durable run history; closing releases the active run
  without deleting that history. Session configuration is applied to the next
  prompt through the router boundary. Raw media and client-supplied MCP servers
  are rejected until a session-scoped safe transport contract is available.

  `/compact` invokes native compaction, and `/skill:<key>` asks the agent to
  load the selected workspace skill. Native resume identities survive the chat
  cache TTL. Streaming subscriptions precede run submission; uncertain receipts
  retain their fixed run ID and explicitly forbid automatic retries.
  Permission requests retain the native tool-call identity and bounded target
  preview; approval summaries never persist raw tool arguments. Client calls
  are concurrent so terminal exit waits cannot block output or cancellation.
  """

  alias LemonControlPlane.AgentRuntime

  alias LemonControlPlane.Methods.AgentWait
  alias LemonCore.Store
  alias LemonCore.RunRequest

  @protocol_version 1
  @default_agent_id "default"
  @default_wait_timeout_ms 600_000
  @session_store_table :acp_sessions

  def capabilities do
    %{
      "loadSession" => true,
      "mcpCapabilities" => %{"http" => false, "sse" => false},
      "promptCapabilities" => %{
        "audio" => false,
        "embeddedContext" => false,
        "image" => false
      },
      "sessionCapabilities" => %{
        "fork" => %{},
        "close" => %{},
        "list" => %{},
        "resume" => %{}
      }
    }
  end

  def normalize_client_capabilities(capabilities) when is_map(capabilities) do
    fs = capabilities |> map_get_any(["fs", :fs]) |> ensure_map()

    %{
      terminal: truthy?(map_get_any(capabilities, ["terminal", :terminal])),
      fs: %{
        read_text_file:
          truthy?(
            map_get_any(fs, ["readTextFile", :readTextFile, "read_text_file", :read_text_file])
          ),
        write_text_file:
          truthy?(
            map_get_any(fs, ["writeTextFile", :writeTextFile, "write_text_file", :write_text_file])
          ),
        delete_file:
          truthy?(map_get_any(fs, ["deleteFile", :deleteFile, "delete_file", :delete_file])),
        rename_file:
          truthy?(map_get_any(fs, ["renameFile", :renameFile, "rename_file", :rename_file]))
      }
    }
  end

  def normalize_client_capabilities(_capabilities), do: empty_client_capabilities()

  def handle_jsonrpc(requests, opts \\ [])

  def handle_jsonrpc(requests, opts) when is_list(requests) do
    responses =
      requests
      |> Enum.map(&handle_jsonrpc(&1, opts))
      |> Enum.reject(&(&1 == :noreply))

    {:ok, responses}
  end

  def handle_jsonrpc(%{"jsonrpc" => "2.0", "method" => method} = request, opts) do
    id = Map.get(request, "id")
    params = Map.get(request, "params", %{})

    case dispatch(method, params, opts) do
      {:ok, _result} when is_nil(id) ->
        :noreply

      {:ok, result} ->
        {:ok, response(id, result)}

      {:error, _code, _message} when is_nil(id) ->
        :noreply

      {:error, code, message} ->
        {:ok, error_response(id, code, message)}

      {:error, _code, _message, _data} when is_nil(id) ->
        :noreply

      {:error, code, message, data} ->
        {:ok, put_in(error_response(id, code, message), ["error", "data"], data)}
    end
  end

  def handle_jsonrpc(%{"id" => id}, _opts) do
    {:ok, error_response(id, -32_600, "invalid JSON-RPC request")}
  end

  def handle_jsonrpc(_request, _opts),
    do: {:ok, error_response(nil, -32_600, "invalid JSON-RPC request")}

  def initialize(params) when is_map(params) do
    version = @protocol_version

    client_capabilities =
      params |> Map.get("clientCapabilities") |> normalize_client_capabilities()

    {:ok,
     %{
       "protocolVersion" => version,
       "agentInfo" => %{
         "name" => "Lemon",
         "version" => lemon_version()
       },
       "agentCapabilities" => capabilities(),
       "authMethods" => [
         %{
           "id" => "agent",
           "name" => "Use local Lemon credentials",
           "description" => "Uses provider keys and OAuth already configured with lemon setup."
         }
       ],
       "_meta" => %{
         "lemon" => %{
           "status" => "ready",
           "beamSupervisedRuns" => true,
           "rawMediaPromptSupport" => false,
           "clientCapabilities" => client_capabilities_json(client_capabilities)
         }
       }
     }}
  end

  def initialize(_params), do: {:error, -32_602, "params must be an object"}

  def new_session(params, opts \\ [])

  def new_session(params, opts) when is_map(params) do
    with {:ok, cwd} <- required_cwd(params),
         :ok <- validate_mcp_servers(params) do
      agent_id = lemon_meta_string(params, "agentId", @default_agent_id)
      client_capabilities = client_capabilities(params, opts)
      session_id = "acp_" <> LemonCore.Id.uuid()
      session_key = "agent:#{agent_id}:acp-#{short_hash(session_id)}"
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      session = %{
        cwd: cwd,
        session_key: session_key,
        agent_id: agent_id,
        title: nil,
        updated_at: now,
        last_run_id: nil,
        model: nil,
        thinking: "off",
        mode: "default",
        approval_mode: "ask",
        closed: false,
        client_capabilities: client_capabilities
      }

      put_session(session_id, session)
      bootstrap(session_id, session, opts)
      {:ok, Map.put(session_response(session), "sessionId", session_id)}
    end
  end

  def new_session(_params, _opts), do: {:error, -32_602, "params must be an object"}

  def resume_session(params, opts \\ [])

  def resume_session(params, opts) when is_map(params) do
    with {:ok, session_id} <- required_string(params, "sessionId"),
         {:ok, existing} <- existing_session(session_id),
         {:ok, cwd} <- required_cwd(params),
         :ok <- validate_mcp_servers(params),
         true <- cwd == existing.cwd do
      session =
        existing
        |> Map.put(:closed, false)
        |> Map.put(:client_capabilities, client_capabilities(params, opts, existing))

      put_session(session_id, session)
      if Keyword.get(opts, :replay, false), do: replay_history(session_id, session, opts)
      bootstrap(session_id, session, opts)
      {:ok, session_response(session)}
    else
      false -> {:error, -32_602, "cwd must match the stored session"}
      error -> error
    end
  end

  def resume_session(_params, _opts), do: {:error, -32_602, "params must be an object"}

  def list_sessions(params) when is_map(params) do
    with {:ok, offset} <- parse_cursor(Map.get(params, "cursor")) do
      cwd = Map.get(params, "cwd")

      sessions =
        all_sessions()
        |> Enum.map(fn {session_id, session} -> session_info(session_id, session) end)
        |> Enum.filter(fn session -> is_nil(cwd) or session["cwd"] == cwd end)
        |> Enum.sort_by(&{&1["updatedAt"], &1["sessionId"]}, :desc)

      page = Enum.slice(sessions, offset, 50)
      next = if offset + length(page) < length(sessions), do: to_string(offset + length(page))
      {:ok, reject_nil_values(%{"sessions" => page, "nextCursor" => next})}
    end
  end

  def list_sessions(_params), do: {:error, -32_602, "params must be an object"}

  def close_session(params) when is_map(params) do
    with {:ok, session_id} <- required_string(params, "sessionId"),
         {:ok, session} <- existing_session(session_id),
         :ok <- cancel_last_run(session) do
      put_session(session_id, Map.put(session, :closed, true))
      {:ok, %{}}
    end
  end

  def close_session(_params), do: {:error, -32_602, "params must be an object"}

  def cancel_session(params) when is_map(params) do
    with {:ok, session_id} <- required_string(params, "sessionId"),
         {:ok, session} <- existing_session(session_id) do
      put_session(session_id, Map.put(session, :cancelled_run_id, session.last_run_id))

      case cancel_last_run(session) do
        :ok ->
          {:ok, %{}}

        error ->
          current = get_session(session_id) || session

          put_session(
            session_id,
            Map.put(current, :cancelled_run_id, Map.get(session, :cancelled_run_id))
          )

          error
      end
    end
  end

  def cancel_session(_params), do: {:error, -32_602, "params must be an object"}

  def prompt(params, opts \\ [])

  def prompt(params, opts) when is_map(params) do
    with {:ok, session_id} <- required_string(params, "sessionId") do
      lock = {{__MODULE__, session_id}, self()}

      if :global.set_lock(lock, [node()], 0) do
        try do
          with_prepared_run(session_id, opts, fn run_id, opts ->
            with {:ok, session} <- open_session(session_id),
                 {:ok, blocks} <- required_list(params, "prompt"),
                 {:ok, prompt} <- prompt_text(blocks),
                 {:ok, prompt} <- expand_skill_command(prompt, session) do
              execute_prompt(session_id, session, params, prompt, run_id, opts)
            end
          end)
        after
          :global.del_lock(lock, [node()])
        end
      else
        {:error, -32_000, "session already has an active prompt"}
      end
    end
  end

  def prompt(_params, _opts), do: {:error, -32_602, "params must be an object"}

  defp execute_prompt(session_id, session, _params, "/compact" <> rest, _run_id, opts) do
    if rest == "" or String.starts_with?(rest, " ") do
      compact_opts = [cwd: session.cwd, custom_instructions: String.trim(rest)]

      case AgentRuntime.call(
             :compact_session,
             [session.session_key, compact_opts],
             {:error, :unavailable}
           ) do
        :ok ->
          emit(
            session_id,
            %{
              "sessionUpdate" => "agent_message_chunk",
              "content" => %{"type" => "text", "text" => "Session context compacted."}
            },
            opts
          )

          {:ok, %{"stopReason" => "end_turn"}}

        _ ->
          {:error, -32_000, "session context could not be compacted"}
      end
    else
      {:error, -32_602, "unknown slash command"}
    end
  end

  defp execute_prompt(session_id, session, params, prompt, run_id, opts) do
    with {:ok, result} <- submit_prompt(session_id, session, params, prompt, run_id),
         {:ok, result} <- maybe_wait(result, params, opts) do
      {:ok, prompt_response(result)}
    end
  end

  defp with_prepared_run(session_id, opts, callback) do
    run_id = LemonCore.Id.run_id()

    streaming? =
      Keyword.has_key?(opts, :session_update_callback) or
        Keyword.has_key?(opts, :client_request_callback)

    topic = LemonCore.Bus.run_topic(run_id)

    if streaming? do
      :ok = LemonCore.Bus.subscribe(topic)
      :ok = LemonCore.Bus.subscribe("exec_approvals")
    end

    bridge = if streaming?, do: start_client_bridge(run_id, session_id, opts)

    try do
      callback.(run_id, Keyword.put(opts, :prepared_run_id, run_id))
    after
      if streaming? do
        stop_client_bridge(bridge)
        LemonCore.Bus.unsubscribe(topic)
        LemonCore.Bus.unsubscribe("exec_approvals")
      end
    end
  end

  defp start_client_bridge(run_id, session_id, opts) do
    callback = Keyword.get(opts, :client_request_callback)

    {:ok, bridge} =
      LemonControlPlane.ACP.ClientRequests.start_link(run_id, self(), fn payload ->
        client_exchange(session_id, payload, callback)
      end)

    bridge
  end

  defp stop_client_bridge(bridge) do
    if is_pid(bridge) and Process.alive?(bridge), do: GenServer.stop(bridge, :normal)
  catch
    :exit, _ -> :ok
  end

  defp dispatch(_method, params, _opts) when not is_map(params),
    do: {:error, -32_602, "params must be an object"}

  defp dispatch("initialize", params, _opts), do: initialize(params)
  defp dispatch("session/new", params, opts), do: new_session(params, opts)

  defp dispatch("session/load", params, opts),
    do: resume_session(params, Keyword.put(opts, :replay, true))

  defp dispatch("session/resume", params, opts), do: resume_session(params, opts)
  defp dispatch("session/list", params, _opts), do: list_sessions(params)
  defp dispatch("session/close", params, _opts), do: close_session(params)
  defp dispatch("session/cancel", params, _opts), do: cancel_session(params)
  defp dispatch("session/prompt", params, opts), do: prompt(params, opts)
  defp dispatch("session/fork", params, opts), do: fork_session(params, opts)

  defp dispatch("session/set_mode", params, opts),
    do: set_config(params, "mode", params["modeId"], opts)

  defp dispatch("session/set_model", params, opts),
    do: set_config(params, "model", params["modelId"], opts)

  defp dispatch("session/set_config_option", params, opts),
    do: set_config(params, params["configId"], params["value"], opts)

  defp dispatch("authenticate", %{"methodId" => "agent"}, _opts), do: {:ok, %{}}

  defp dispatch("authenticate", _params, _opts),
    do: {:error, -32_602, "unknown authentication method"}

  defp dispatch(_method, _params, _opts), do: {:error, -32_601, "method not found"}

  defp required_cwd(params) do
    with {:ok, cwd} <- required_string(params, "cwd") do
      if Path.type(cwd) == :absolute,
        do: {:ok, Path.expand(cwd)},
        else: {:error, -32_602, "cwd must be an absolute path"}
    end
  end

  defp validate_mcp_servers(params) do
    case Map.get(params, "mcpServers", []) do
      [] ->
        :ok

      servers when is_list(servers) ->
        {:error, -32_602, "client MCP servers are not supported; configure MCP in Lemon"}

      _ ->
        {:error, -32_602, "mcpServers must be an array"}
    end
  end

  defp parse_cursor(nil), do: {:ok, 0}

  defp parse_cursor(cursor) when is_binary(cursor) do
    case Integer.parse(cursor) do
      {offset, ""} when offset >= 0 -> {:ok, offset}
      _ -> {:error, -32_602, "invalid session cursor"}
    end
  end

  defp parse_cursor(_), do: {:error, -32_602, "invalid session cursor"}

  defp open_session(session_id) do
    with {:ok, session} <- existing_session(session_id) do
      if Map.get(session, :closed, false),
        do: {:error, -32_602, "session is closed; load or resume it first"},
        else: {:ok, session}
    end
  end

  defp session_response(session) do
    %{
      "modes" => %{
        "currentModeId" => Map.get(session, :mode, "default"),
        "availableModes" => [
          %{
            "id" => "default",
            "name" => "Code",
            "description" => "Implement changes with approval controls."
          },
          %{
            "id" => "plan",
            "name" => "Plan",
            "description" => "Read-only tools; no edits or execution."
          }
        ]
      },
      "configOptions" => config_options(session),
      "_meta" => %{
        "lemon" => %{
          "sessionKey" => session.session_key,
          "cwdHash" => short_hash(session.cwd),
          "clientCapabilities" => client_capabilities_json(session_client_capabilities(session))
        }
      }
    }
  end

  defp model_options do
    LemonAi.Models.list_models(discover_openai: false)
    |> Enum.map(fn model ->
      %{
        "value" => "#{model.provider}:#{model.id}",
        "name" => "#{model.name || model.id} (#{model.provider})"
      }
    end)
    |> Enum.uniq_by(& &1["value"])
    |> Enum.sort_by(& &1["value"])
  end

  defp config_options(session) do
    [
      select_option("mode", "Mode", "mode", Map.get(session, :mode, "default"), [
        %{"value" => "default", "name" => "Code"},
        %{"value" => "plan", "name" => "Plan (read only)"}
      ]),
      select_option("model", "Model", "model", Map.get(session, :model) || "default", [
        %{"value" => "default", "name" => "Lemon configured default"} | model_options()
      ]),
      select_option(
        "thinking",
        "Thinking",
        "thought_level",
        Map.get(session, :thinking, "off"),
        Enum.map(
          ~w(off minimal low medium high xhigh),
          &%{"value" => &1, "name" => String.capitalize(&1)}
        )
      ),
      select_option(
        "approval",
        "Tool approvals",
        "other",
        Map.get(session, :approval_mode, "ask"),
        [
          %{"value" => "ask", "name" => "Ask before changes"},
          %{"value" => "never", "name" => "Reject changes"},
          %{"value" => "auto", "name" => "Allow changes"}
        ]
      )
    ]
  end

  defp select_option(id, name, category, current, options) do
    %{
      "id" => id,
      "name" => name,
      "category" => category,
      "type" => "select",
      "currentValue" => current,
      "options" => options
    }
  end

  defp set_config(params, id, value, opts) when is_map(params) do
    with {:ok, session_id} <- required_string(params, "sessionId"),
         {:ok, session} <- open_session(session_id),
         {:ok, key, stored} <- config_value(id, value) do
      session = Map.put(session, key, stored)
      put_session(session_id, session)

      if id == "mode",
        do:
          emit(
            session_id,
            %{"sessionUpdate" => "current_mode_update", "currentModeId" => value},
            opts
          )

      options = config_options(session)

      emit(
        session_id,
        %{"sessionUpdate" => "config_option_update", "configOptions" => options},
        opts
      )

      {:ok, %{"configOptions" => options}}
    end
  end

  defp config_value("mode", value) when value in ["default", "plan"], do: {:ok, :mode, value}

  defp config_value("thinking", value) when value in ~w(off minimal low medium high xhigh),
    do: {:ok, :thinking, value}

  defp config_value("approval", value) when value in ["ask", "never", "auto"],
    do: {:ok, :approval_mode, value}

  defp config_value("model", "default"), do: {:ok, :model, nil}

  defp config_value("model", value) when is_binary(value) do
    if Enum.any?(model_options(), &(&1["value"] == value)),
      do: {:ok, :model, value},
      else: {:error, -32_602, "model is not in the Lemon model registry"}
  end

  defp config_value(_, _), do: {:error, -32_602, "invalid session configuration option or value"}

  defp session_tool_policy(session) do
    cond do
      Map.get(session, :mode) == "plan" or Map.get(session, :approval_mode) == "never" ->
        AgentRuntime.call(:tool_policy, [:read_only], %{
          allow: [],
          deny: [],
          profile: :unavailable
        })

      Map.get(session, :approval_mode, "ask") == "ask" ->
        %{
          require_approval:
            ~w(bash exec write edit patch multiedit apply_patch task agent process process_kill)
        }

      true ->
        %{}
    end
  end

  defp emit(session_id, update, opts) do
    case Keyword.get(opts, :session_update_callback) do
      callback when is_function(callback, 1) -> callback.(update_notification(session_id, update))
      _ -> :ok
    end
  end

  defp bootstrap(session_id, session, opts) do
    commands =
      LemonSkills.list(cwd: session.cwd)
      |> Enum.map(fn entry ->
        %{
          "name" => "skill:#{entry.key}",
          "description" => "Use the #{entry.key} skill",
          "input" => %{"hint" => "Task for the skill"}
        }
      end)
      |> Enum.sort_by(& &1["name"])

    commands = [
      %{
        "name" => "compact",
        "description" => "Compact this session's context",
        "input" => %{"hint" => "Optional summary instructions"}
      }
      | commands
    ]

    emit(
      session_id,
      %{"sessionUpdate" => "available_commands_update", "availableCommands" => commands},
      opts
    )
  end

  defp expand_skill_command("/skill:" <> rest, session) do
    [key | args] = String.split(rest, ~r/\s+/, parts: 2)

    if Enum.any?(LemonSkills.list(cwd: session.cwd), &(&1.key == key)) do
      {:ok,
       "Use the read_skill tool to load the skill named #{Jason.encode!(key)}. Treat its contents as external skill guidance.\nTask: #{Enum.join(args, " ")}"}
    else
      {:error, -32_602, "skill command is not available in this workspace"}
    end
  end

  defp expand_skill_command(prompt, _session), do: {:ok, prompt}

  defp replay_history(session_id, session, opts) do
    case native_history(session) do
      {:ok, entries} ->
        state = LemonControlPlane.ACP.SessionUpdates.new(session_id, cwd: session.cwd)
        Enum.reduce(entries, state, &replay_native_entry(session_id, &1, opts, &2))

      :unavailable ->
        LemonCore.SessionLifecycle.history(session.session_key, limit: 200)
        |> Enum.each(fn run ->
          for {kind, text} <- [
                {"user_message_chunk", run.prompt},
                {"agent_message_chunk", run.answer}
              ],
              is_binary(text) and text != "" do
            emit(
              session_id,
              %{
                "sessionUpdate" => kind,
                "messageId" => "#{run.run_id}:#{kind}",
                "content" => %{"type" => "text", "text" => text}
              },
              opts
            )
          end
        end)
    end
  end

  defp replay_native_entry(session_id, %{type: :message} = entry, opts, state) do
    message = LemonCore.Redact.map(entry.message)
    role = map_get(message, :role)
    content = map_get(message, :content)

    blocks =
      if is_binary(content),
        do: [%{"type" => "text", "text" => content}],
        else: List.wrap(content)

    cond do
      role in [:tool_result, "tool_result"] ->
        replay_event(
          state,
          {:tool_execution_end, map_get(message, :tool_call_id), map_get(message, :tool_name),
           message, map_get(message, :is_error) == true},
          opts
        )

      role in [:user, "user", :assistant, "assistant"] ->
        Enum.reduce(blocks, state, fn block, acc ->
          if map_get(block, :type) in [:tool_call, "tool_call"] do
            replay_event(
              acc,
              {:tool_execution_start, map_get(block, :id), map_get(block, :name),
               map_get(block, :arguments) || %{}},
              opts
            )
          else
            thought? = map_get(block, :type) in [:thinking, "thinking"]
            text = if thought?, do: map_get(block, :thinking), else: map_get(block, :text)

            kind =
              cond do
                role in [:user, "user"] -> "user_message_chunk"
                thought? -> "agent_thought_chunk"
                true -> "agent_message_chunk"
              end

            if is_binary(text) and text != "" do
              emit(
                session_id,
                %{
                  "sessionUpdate" => kind,
                  "messageId" => entry.id,
                  "content" => %{"type" => "text", "text" => text}
                },
                opts
              )
            end

            acc
          end
        end)

      true ->
        state
    end
  end

  defp replay_native_entry(_session_id, _entry, _opts, state), do: state

  defp replay_event(state, event, opts) do
    {updates, state} = LemonControlPlane.ACP.SessionUpdates.map_event(state, event)

    case Keyword.get(opts, :session_update_callback) do
      callback when is_function(callback, 1) -> Enum.each(updates, callback)
      _ -> :ok
    end

    state
  end

  defp native_history(session) do
    case AgentRuntime.call(
           :session_history,
           [session.session_key, session.cwd],
           {:error, :unavailable}
         ) do
      {:ok, entries} when is_list(entries) -> {:ok, entries}
      _ -> :unavailable
    end
  end

  defp fork_session(params, opts) when is_map(params) do
    with {:ok, source_id} <- required_string(params, "sessionId"),
         {:ok, source} <- existing_session(source_id),
         {:ok, cwd} <- required_cwd(params),
         :ok <- validate_mcp_servers(params),
         true <- cwd == source.cwd do
      id = "acp_" <> LemonCore.Id.uuid()
      key = "agent:#{source.agent_id}:acp-#{short_hash(id)}"

      with :ok <- fork_native_session(source, key) do
        session =
          source
          |> Map.merge(%{
            session_key: key,
            last_run_id: nil,
            closed: false,
            updated_at: DateTime.utc_now() |> DateTime.to_iso8601()
          })

        put_session(id, session)
        remember_native_resume(id)
        bootstrap(id, session, opts)
        {:ok, Map.put(session_response(session), "sessionId", id)}
      end
    else
      false -> {:error, -32_602, "cwd must match the stored session"}
      error -> error
    end
  end

  defp fork_native_session(source, destination_key) do
    if is_nil(source.last_run_id) and is_nil(LemonCore.ChatStateStore.get(source.session_key)) do
      :ok
    else
      case AgentRuntime.call(
             :session_fork,
             [source.session_key, source.cwd, destination_key],
             {:error, :unavailable}
           ) do
        :ok -> :ok
        _ -> {:error, -32_000, "could not fork the persisted native session"}
      end
    end
  end

  defp submit_prompt(session_id, session, params, prompt, run_id) do
    queue_only? = lemon_meta(params, "wait") == false
    model = lemon_meta(params, "model") || Map.get(session, :model)
    tool_policy = session_tool_policy(session)
    client_capabilities = session_client_capabilities(session)
    client_fs_capabilities = client_capabilities.fs

    request =
      RunRequest.new(%{
        run_id: run_id,
        origin: :control_plane,
        session_key: session.session_key,
        agent_id: session.agent_id,
        prompt: prompt,
        queue_mode: :collect,
        model: model,
        cwd: session.cwd,
        tool_policy: tool_policy,
        meta: %{
          origin: :acp,
          thinking_level: Map.get(session, :thinking, "off"),
          acp_session_id: session_id,
          acp_wait_requested: not queue_only?,
          acp_resource_link_count: resource_link_count(params["prompt"]),
          acp_client_capabilities: client_capabilities_json(client_capabilities),
          acp_client_terminal: client_capabilities.terminal,
          acp_client_fs_read_text_file: client_fs_capabilities.read_text_file,
          acp_client_fs_write_text_file: client_fs_capabilities.write_text_file,
          acp_client_fs_delete_file: client_fs_capabilities.delete_file,
          acp_client_fs_rename_file: client_fs_capabilities.rename_file
        }
      })

    case submitter().(request) do
      {:ok, run_id} when is_binary(run_id) and byte_size(run_id) > 0 ->
        put_session(session_id, %{
          session
          | updated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
            last_run_id: run_id,
            title: session.title || title_from_prompt(prompt)
        })

        {:ok,
         %{
           run_id: run_id,
           session_id: session_id,
           session_key: session.session_key,
           client_capabilities: client_capabilities,
           status: if(queue_only?, do: "queued", else: "submitted"),
           wait?: not queue_only?
         }}

      {:error, :outcome_unknown} ->
        put_session(session_id, %{session | last_run_id: run_id})

        {:error, -32_000, "run submission outcome is unknown; do not retry automatically",
         %{"runId" => run_id, "retrySafe" => false}}

      {:error, _reason} ->
        {:error, -32_000, "failed to submit Lemon run"}

      _ ->
        {:error, -32_000, "run submission did not return a non-empty run ID"}
    end
  end

  defp maybe_wait(result, params, opts) do
    if Keyword.has_key?(opts, :session_update_callback) or
         Keyword.has_key?(opts, :client_request_callback) do
      wait_with_updates(result, params, opts)
    else
      maybe_wait(result, params)
    end
  end

  defp maybe_wait(%{wait?: false} = result, _params), do: {:ok, result}

  defp maybe_wait(%{run_id: run_id} = result, params) do
    case waiter().(run_id, wait_timeout_ms(params)) do
      {:ok, wait_result} ->
        {:ok,
         result
         |> Map.put(:status, wait_status(wait_result))
         |> Map.put(:wait_result, wait_result)}

      {:error, {:timeout, message, _run_id}} ->
        {:error, -32_001, message}

      {:error, :timeout} ->
        {:error, -32_001, "Run did not complete within timeout"}

      {:error, _reason} ->
        {:error, -32_000, "failed to wait for Lemon run"}
    end
  end

  defp wait_with_updates(%{wait?: false} = result, _params, _opts), do: {:ok, result}

  defp wait_with_updates(%{run_id: run_id} = result, params, opts) do
    topic = LemonCore.Bus.run_topic(run_id)
    prepared? = Keyword.get(opts, :prepared_run_id) == run_id

    unless prepared? do
      :ok = LemonCore.Bus.subscribe(topic)
    end

    bridge = unless prepared?, do: start_client_bridge(run_id, result.session_id, opts)

    session_update_callback = Keyword.get(opts, :session_update_callback)
    client_request_callback = Keyword.get(opts, :client_request_callback)
    session = get_session(result.session_id)

    result =
      Map.put(
        result,
        :mapper_state,
        LemonControlPlane.ACP.SessionUpdates.new(result.session_id,
          cwd: session.cwd,
          context_window: session_context_window(session)
        )
      )

    result =
      Enum.reduce(LemonCore.ExecApprovalStore.list_pending(), result, fn {_id, pending}, acc ->
        maybe_perform_approval_request(acc, %{pending: pending}, client_request_callback)
      end)

    case LemonCore.RunStore.get(run_id) do
      %{summary: %{completed: completed}} when not is_nil(completed) ->
        send(self(), LemonCore.Event.new(:run_completed, %{completed: completed}))

      _ ->
        :ok
    end

    try do
      update_wait_loop(
        result,
        session_update_callback,
        client_request_callback,
        deadline_ms(wait_timeout_ms(params))
      )
    after
      unless prepared? do
        stop_client_bridge(bridge)
        LemonCore.Bus.unsubscribe(topic)
      end
    end
  end

  defp update_wait_loop(result, session_update_callback, client_request_callback, deadline_ms) do
    case remaining_timeout_ms(deadline_ms) do
      0 ->
        {:error, -32_001, "Run did not complete within timeout"}

      timeout_ms ->
        receive do
          %LemonCore.Event{type: :run_completed, payload: payload} = event ->
            result = emit_run_updates(result, event, session_update_callback)
            {:ok, complete_streamed_result(result, payload)}

          {:acp_client_summary, summary} ->
            result = add_client_request_result(result, summary)

            update_wait_loop(
              result,
              session_update_callback,
              client_request_callback,
              deadline_ms
            )

          %LemonCore.Event{type: :approval_requested, payload: payload} ->
            result = maybe_perform_approval_request(result, payload, client_request_callback)

            update_wait_loop(
              result,
              session_update_callback,
              client_request_callback,
              deadline_ms
            )

          %LemonCore.Event{} = event ->
            result = emit_run_updates(result, event, session_update_callback)

            update_wait_loop(
              result,
              session_update_callback,
              client_request_callback,
              deadline_ms
            )

          %{type: :run_completed, payload: payload} = event ->
            result = emit_run_updates(result, event, session_update_callback)
            {:ok, complete_streamed_result(result, payload)}

          %{type: :approval_requested, payload: payload} ->
            result = maybe_perform_approval_request(result, payload, client_request_callback)

            update_wait_loop(
              result,
              session_update_callback,
              client_request_callback,
              deadline_ms
            )

          %{type: _type} = event ->
            result = emit_run_updates(result, event, session_update_callback)

            update_wait_loop(
              result,
              session_update_callback,
              client_request_callback,
              deadline_ms
            )
        after
          timeout_ms ->
            {:error, -32_001, "Run did not complete within timeout"}
        end
    end
  end

  defp deadline_ms(timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    System.monotonic_time(:millisecond) + timeout_ms
  end

  defp deadline_ms(_timeout_ms), do: System.monotonic_time(:millisecond)

  defp remaining_timeout_ms(deadline_ms) do
    max(deadline_ms - System.monotonic_time(:millisecond), 0)
  end

  defp maybe_perform_approval_request(result, payload, callback) do
    pending = payload |> map_get(:pending) |> ensure_map()

    approval_id = map_get(pending, :id) || map_get(pending, :approval_id)

    if map_get(pending, :session_key) == result.session_key and
         map_get(pending, :run_id) == result.run_id and is_binary(approval_id) and
         not is_nil(LemonCore.ExecApprovalStore.get_pending(approval_id)) do
      perform_approval_request(result, pending, callback)
    else
      result
    end
  end

  defp perform_approval_request(result, pending, callback) when is_function(callback, 1) do
    approval_id = map_get(pending, :id) || map_get(pending, :approval_id)

    request =
      client_request("session/request_permission", %{
        "sessionId" => result.session_id,
        "toolCall" => permission_tool_call(result, pending),
        "options" => approval_options()
      })

    summary =
      case safe_client_request(callback, request) do
        {:ok, response} ->
          resolve_approval_from_response(approval_id, response)
          summarize_client_response("session/request_permission", response)

        {:error, _reason} ->
          deny_if_pending(approval_id)

          %{
            "method" => "session/request_permission",
            "status" => "failed",
            "reason" => "client permission request failed"
          }

        response ->
          resolve_approval_from_response(approval_id, response)
          summarize_client_response("session/request_permission", response)
      end

    add_client_request_result(result, summary)
  end

  defp perform_approval_request(result, pending, _callback) do
    approval_id = map_get(pending, :id) || map_get(pending, :approval_id)
    deny_if_pending(approval_id)

    add_client_request_result(result, %{
      "method" => "session/request_permission",
      "status" => "skipped",
      "reason" => "client request callback unavailable"
    })
  end

  # A failed or skipped client prompt denies the pending approval so the
  # gated call cannot run. `{:error, :not_pending}` (already resolved,
  # cancelled, or timed out) leaves nothing to deny, so the outcome is
  # deliberately dropped.
  defp deny_if_pending(approval_id) when is_binary(approval_id) do
    _ = LemonCore.ExecApprovals.resolve(approval_id, :deny)
    :ok
  end

  defp deny_if_pending(_approval_id), do: :ok

  defp permission_tool_call(result, pending) do
    tool = map_get(pending, :tool) || "tool"
    id = map_get(pending, :tool_call_id)

    args =
      case Map.get(result.mapper_state.tools, id) do
        {^tool, args} -> args
        _ -> map_get(pending, :action) |> ensure_map()
      end

    if is_binary(id) and id != "" do
      result.session_id
      |> LemonControlPlane.ACP.SessionUpdates.tool_call(id, tool, args,
        cwd: result.mapper_state.cwd
      )
      |> get_in(["params", "update"])
      |> Map.delete("sessionUpdate")
    else
      %{
        "toolCallId" => id || map_get(pending, :id),
        "title" => "Approve #{tool}",
        "kind" => LemonControlPlane.ACP.SessionUpdates.tool_kind(tool),
        "status" => "pending",
        "content" => approval_content(pending)
      }
    end
  end

  defp approval_content(pending) do
    case map_get(pending, :rationale) do
      rationale when is_binary(rationale) and rationale != "" ->
        [
          %{
            "type" => "content",
            "content" => %{
              "type" => "text",
              "text" => rationale |> LemonCore.Redact.text() |> truncate()
            }
          }
        ]

      _ ->
        nil
    end
  end

  defp approval_options do
    [
      %{"optionId" => "allow-once", "name" => "Allow once", "kind" => "allow_once"},
      %{"optionId" => "allow-session", "name" => "Allow for session", "kind" => "allow_always"},
      %{"optionId" => "reject-once", "name" => "Reject", "kind" => "reject_once"}
    ]
  end

  defp resolve_approval_from_response(approval_id, response) when is_binary(approval_id) do
    outcome = response |> response_result() |> map_get(:outcome) |> ensure_map()

    decision =
      case {Map.get(outcome, "outcome"), Map.get(outcome, "optionId")} do
        {"selected", "allow-once"} -> :approve_once
        {"selected", "allow-session"} -> :approve_session
        _ -> :deny
      end

    # `:not_pending` means the prompt was cancelled or timed out before the
    # client's answer arrived — the record is gone and there is nothing
    # left to resolve, so the outcome is deliberately dropped.
    _ = LemonCore.ExecApprovals.resolve(approval_id, decision)

    :ok
  end

  defp resolve_approval_from_response(_approval_id, _response), do: :ok

  defp safe_client_request(callback, request) do
    callback.(request)
  rescue
    _ -> {:error, :client_request_failed}
  catch
    _, _ -> {:error, :client_request_failed}
  end

  defp client_exchange(_session_id, payload, callback) when not is_function(callback, 1) do
    {%{"error" => %{"message" => "ACP client request callback unavailable"}},
     %{"method" => map_get(payload, :method), "status" => "failed"}}
  end

  defp client_exchange(session_id, payload, callback) when is_map(payload) do
    method = map_get(payload, :method)
    params = payload |> map_get(:params) |> ensure_map()
    request = client_request(method, Map.put(params, "sessionId", session_id))

    {summary, response} =
      case safe_client_request(callback, request) do
        {:ok, response} ->
          {summarize_client_response(method, response), response}

        {:error, _reason} ->
          summary = %{
            "method" => method || "unknown",
            "status" => "failed",
            "reason" => "client request failed"
          }

          {summary, %{"error" => %{"message" => "client request failed"}}}

        response ->
          {summarize_client_response(method, response), response}
      end

    {response, summary}
  end

  defp client_request(method, params) when is_binary(method) do
    %{"jsonrpc" => "2.0", "method" => method, "params" => params}
  end

  defp client_request(_method, params) do
    %{"jsonrpc" => "2.0", "method" => "unknown", "params" => params}
  end

  defp add_client_request_result(result, summary) do
    Map.update(result, :client_requests, [summary], &(&1 ++ [summary]))
  end

  defp summarize_client_response("session/request_permission", response) do
    outcome = response |> response_result() |> map_get(:outcome) |> ensure_map()

    %{
      "method" => "session/request_permission",
      "status" => response_status(response),
      "outcome" => Map.get(outcome, "outcome"),
      "optionId" => Map.get(outcome, "optionId")
    }
    |> reject_nil_values()
  end

  defp summarize_client_response("fs/read_text_file", response) do
    content =
      response
      |> response_result()
      |> map_get(:content)

    %{
      "method" => "fs/read_text_file",
      "status" => response_status(response),
      "contentBytes" => if(is_binary(content), do: byte_size(content)),
      "contentHash" => if(is_binary(content), do: short_hash(content))
    }
    |> reject_nil_values()
  end

  defp summarize_client_response("fs/write_text_file", response) do
    %{"method" => "fs/write_text_file", "status" => response_status(response)}
  end

  defp summarize_client_response("fs/delete_file", response) do
    %{"method" => "fs/delete_file", "status" => response_status(response)}
  end

  defp summarize_client_response("fs/rename_file", response) do
    %{"method" => "fs/rename_file", "status" => response_status(response)}
  end

  defp summarize_client_response(method, response) do
    %{"method" => method || "unknown", "status" => response_status(response)}
  end

  defp response_result(%{"result" => result}), do: result
  defp response_result(%{result: result}), do: result
  defp response_result(result) when is_map(result), do: result
  defp response_result(_result), do: %{}

  defp response_status(%{"error" => _error}), do: "failed"
  defp response_status(%{error: _error}), do: "failed"
  defp response_status(_response), do: "completed"

  defp ensure_map(map) when is_map(map), do: map
  defp ensure_map(_value), do: %{}

  defp reject_nil_values(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp emit_run_updates(result, event, callback) do
    session = get_session(result.session_id) || %{}

    mapper_state =
      if Map.get(session, :cancelled_run_id) == result.run_id do
        {_updates, state} =
          LemonControlPlane.ACP.SessionUpdates.map_event(result.mapper_state, {:cancel_requested})

        state
      else
        result.mapper_state
      end

    {updates, state} = LemonControlPlane.ACP.SessionUpdates.map_event(mapper_state, event)
    if is_function(callback, 1), do: Enum.each(updates, callback)
    Map.put(result, :mapper_state, state)
  end

  defp complete_streamed_result(result, payload) do
    completed =
      case map_get(payload, :completed) do
        nil -> payload
        value -> value
      end

    result
    |> Map.put(:status, wait_status(completed))
    |> Map.put(:usage, map_get(completed, :usage))
    |> Map.put(:wait_result, %{
      "runId" => result.run_id,
      "ok" => completed_ok(completed),
      "answer" => map_get(completed, :answer),
      "error" => map_get(completed, :error)
    })
  end

  defp prompt_response(result) do
    remember_native_resume(result.session_id)

    %{
      "stopReason" => stop_reason(result),
      "usage" => prompt_usage(result[:usage]),
      "_meta" => %{
        "lemon" => %{
          "runId" => result.run_id,
          "sessionId" => result.session_id,
          "sessionKey" => result.session_key,
          "status" => result.status,
          "queued" => result.status == "queued",
          "ok" => wait_ok(result[:wait_result]),
          "answer" => wait_answer(result[:wait_result]),
          "clientCapabilities" =>
            result
            |> Map.get(:client_capabilities)
            |> normalize_client_capabilities()
            |> client_capabilities_json(),
          "clientRequests" => Map.get(result, :client_requests, [])
        }
      }
    }
    |> reject_nil_values()
  end

  defp update_notification(session_id, update) do
    %{
      "jsonrpc" => "2.0",
      "method" => "session/update",
      "params" => %{
        "sessionId" => session_id,
        "update" => update
      }
    }
  end

  defp prompt_text(blocks) do
    blocks
    |> Enum.reduce_while({:ok, []}, fn
      %{"type" => "text", "text" => text}, {:ok, acc} when is_binary(text) ->
        {:cont, {:ok, [text | acc]}}

      %{"type" => "resource_link", "name" => name, "uri" => uri} = block, {:ok, acc}
      when is_binary(name) and is_binary(uri) ->
        {:cont, {:ok, [resource_link_prompt(name, uri, block) | acc]}}

      %{"type" => type}, _acc when type in ["image", "audio", "resource"] ->
        {:halt, {:error, -32_602, "#{type} prompt blocks are not enabled in this preview"}}

      _block, _acc ->
        {:halt, {:error, -32_602, "prompt blocks must be text or resource_link content"}}
    end)
    |> case do
      {:ok, parts} ->
        parts
        |> Enum.reverse()
        |> Enum.join("\n")
        |> case do
          "" -> {:error, -32_602, "prompt must include text or resource_link content"}
          prompt -> {:ok, prompt}
        end

      {:error, code, message} ->
        {:error, code, message}
    end
  end

  defp resource_link_prompt(name, uri, block) do
    details =
      [
        "name=#{name}",
        "uri=#{uri}",
        block["mimeType"] && "mime=#{block["mimeType"]}",
        block["title"] && "title=#{block["title"]}"
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    "[resource link: #{details}]"
  end

  defp required_string(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, -32_602, "#{key} is required"}
    end
  end

  defp required_list(params, key) do
    case Map.get(params, key) do
      value when is_list(value) -> {:ok, value}
      _ -> {:error, -32_602, "#{key} must be an array"}
    end
  end

  defp existing_session(session_id) do
    case get_session(session_id) do
      nil ->
        {:error, -32_602, "session not found"}

      session ->
        restore_native_resume(session)
        {:ok, session}
    end
  end

  defp session_context_window(session) do
    model_id = Map.get(session, :model) || LemonCore.Config.cached().agent.default_model

    Enum.find_value(LemonAi.Models.list_models(discover_openai: false), fn model ->
      if "#{model.provider}:#{model.id}" == model_id, do: model.context_window
    end)
  end

  defp prompt_usage(usage) when is_map(usage) do
    %{
      "inputTokens" => map_get(usage, :input) || 0,
      "outputTokens" => map_get(usage, :output) || 0,
      "totalTokens" => map_get(usage, :total_tokens) || 0,
      "cachedReadTokens" => map_get(usage, :cache_read) || 0,
      "cachedWriteTokens" => map_get(usage, :cache_write) || 0
    }
  end

  defp prompt_usage(_), do: nil

  defp remember_native_resume(session_id) do
    with session when is_map(session) <- get_session(session_id),
         %{last_engine: "lemon", last_resume_token: token} when is_binary(token) <-
           LemonCore.ChatStateStore.get(session.session_key) do
      put_session(session_id, Map.put(session, :native_resume, token))
    else
      _ -> :ok
    end
  end

  defp restore_native_resume(session) do
    if is_nil(LemonCore.ChatStateStore.get(session.session_key)) and
         is_binary(Map.get(session, :native_resume)) do
      LemonCore.ChatStateStore.put(session.session_key, %LemonCore.ChatState{
        last_engine: "lemon",
        last_resume_token: session.native_resume,
        updated_at: System.system_time(:millisecond)
      })
    end

    :ok
  end

  defp get_session(session_id) do
    case Store.get(@session_store_table, session_id) do
      session when is_map(session) -> session
      _ -> nil
    end
  end

  defp put_session(session_id, session) do
    :ok = Store.put(@session_store_table, session_id, session)
  end

  defp all_sessions do
    @session_store_table
    |> Store.list()
    |> Enum.filter(fn {session_id, session} -> is_binary(session_id) and is_map(session) end)
    |> Map.new()
  end

  defp session_info(session_id, session) do
    client_capabilities = session_client_capabilities(session)

    %{
      "sessionId" => session_id,
      "cwd" => session.cwd,
      "title" =>
        if(is_binary(session.title), do: LemonCore.Redact.text(session.title), else: nil),
      "updatedAt" => session.updated_at,
      "_meta" => %{
        "lemon" => %{
          "sessionKey" => session.session_key,
          "lastRunId" => session.last_run_id,
          "clientCapabilities" => client_capabilities_json(client_capabilities)
        }
      }
    }
  end

  defp cancel_last_run(%{last_run_id: run_id}) when is_binary(run_id) and run_id != "" do
    case canceller().(run_id, :acp_cancel) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, :not_found} -> :ok
      _ -> {:error, -32_000, "run cancellation was not acknowledged"}
    end
  end

  defp cancel_last_run(_session), do: :ok

  defp resource_link_count(blocks) when is_list(blocks),
    do: Enum.count(blocks, &(is_map(&1) and &1["type"] == "resource_link"))

  defp resource_link_count(_blocks), do: 0

  defp lemon_meta(params, key) do
    params |> Map.get("_meta") |> ensure_map() |> Map.get("lemon") |> ensure_map() |> Map.get(key)
  end

  defp client_capabilities(params, opts, existing \\ %{}) do
    from_opts = Keyword.get(opts, :client_capabilities)

    from_params =
      Map.get(params, "clientCapabilities") || lemon_meta(params, "clientCapabilities")

    from_existing = map_get_any(existing, [:client_capabilities, "client_capabilities"])

    cond do
      is_map(from_params) -> normalize_client_capabilities(from_params)
      is_map(from_opts) -> normalize_client_capabilities(from_opts)
      is_map(from_existing) -> normalize_client_capabilities(from_existing)
      true -> empty_client_capabilities()
    end
  end

  defp session_client_capabilities(session) do
    session
    |> map_get_any([:client_capabilities, "client_capabilities"])
    |> normalize_client_capabilities()
  end

  defp empty_client_capabilities do
    %{
      terminal: false,
      fs: %{read_text_file: false, write_text_file: false, delete_file: false, rename_file: false}
    }
  end

  defp client_capabilities_json(capabilities) do
    capabilities = normalize_client_capabilities(capabilities)

    %{
      "terminal" => capabilities.terminal,
      "fs" => %{
        "readTextFile" => capabilities.fs.read_text_file,
        "writeTextFile" => capabilities.fs.write_text_file,
        "deleteFile" => capabilities.fs.delete_file,
        "renameFile" => capabilities.fs.rename_file
      }
    }
  end

  defp lemon_meta_string(params, key, default) do
    case lemon_meta(params, key) do
      value when is_binary(value) and value != "" -> value
      _ -> default
    end
  end

  defp wait_timeout_ms(params) do
    case lemon_meta(params, "timeoutMs") do
      value when is_integer(value) and value > 0 -> value
      _ -> @default_wait_timeout_ms
    end
  end

  defp wait_status(%{"ok" => false}), do: "failed"
  defp wait_status(%{ok: false}), do: "failed"
  defp wait_status(_wait_result), do: "completed"

  defp stop_reason(result) do
    session = get_session(result.session_id) || %{}

    cond do
      Map.get(session, :cancelled_run_id) == result.run_id -> "cancelled"
      result.status == "failed" -> "refusal"
      true -> "end_turn"
    end
  end

  defp wait_ok(nil), do: nil
  defp wait_ok(%{"ok" => ok}), do: ok
  defp wait_ok(%{ok: ok}), do: ok
  defp wait_ok(_), do: nil

  defp wait_answer(nil), do: nil
  defp wait_answer(%{"answer" => answer}) when is_binary(answer), do: answer
  defp wait_answer(%{answer: answer}) when is_binary(answer), do: answer
  defp wait_answer(_), do: nil

  defp completed_ok(nil), do: nil
  defp completed_ok(completed), do: map_get(completed, :ok)

  defp map_get(nil, _key), do: nil

  defp map_get(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error when is_atom(key) -> Map.get(map, Atom.to_string(key))
      :error -> nil
    end
  end

  defp map_get_any(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, &Map.get(map, &1))
  end

  defp map_get_any(_map, _keys), do: nil

  defp truthy?(true), do: true
  defp truthy?(_value), do: false

  defp truncate(text, max \\ 240)
  defp truncate(text, max) when is_binary(text) and byte_size(text) <= max, do: text
  defp truncate(text, max) when is_binary(text), do: String.slice(text, 0, max) <> "..."
  defp truncate(value, _max), do: value

  defp title_from_prompt(prompt) do
    prompt
    |> String.split("\n", parts: 2)
    |> List.first()
    |> String.slice(0, 80)
  end

  defp submitter do
    Application.get_env(:lemon_control_plane, :acp_submitter, &LemonRouter.submit/1)
  end

  defp waiter do
    Application.get_env(:lemon_control_plane, :acp_waiter, fn run_id, timeout_ms ->
      AgentWait.handle(%{"runId" => run_id, "timeoutMs" => timeout_ms}, %{})
    end)
  end

  defp canceller do
    Application.get_env(:lemon_control_plane, :acp_canceller, &LemonRouter.abort_run/2)
  end

  defp response(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  defp error_response(id, code, message) do
    %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}
  end

  defp short_hash(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp lemon_version do
    Application.spec(:lemon_control_plane, :vsn)
    |> to_string()
  end
end
