defmodule CodingAgent.Session.ContextUsageSessionTest do
  use ExUnit.Case, async: false

  alias CodingAgent.{ControlPlaneProvider, Session, SessionManager, SettingsManager}
  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.{AssistantMessage, Model, ModelCost, TextContent, ToolCall, Usage}

  setup do
    root = Path.join(System.tmp_dir!(), "lemon-context-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "AGENTS.md"), "Project rules for the context test.")
    key = "agent:context-test-#{System.unique_integer([:positive])}:main"

    on_exit(fn ->
      LemonCore.SessionLifecycle.delete(key)
      File.rm_rf!(root)
      File.rm_rf!(SessionManager.get_session_dir(root))
    end)

    %{root: root, key: key}
  end

  test "live and durable reads report the same server accounting", %{root: root, key: key} do
    calls = :counters.new(1, [:atomics])

    reader = %AgentTool{
      name: "read",
      label: "Read",
      description: "Read a file",
      parameters: %{"type" => "object", "properties" => %{"path" => %{"type" => "string"}}},
      execute: fn _, _, _, _ ->
        %AgentToolResult{content: [%TextContent{text: String.duplicate("line of file\n", 300)}]}
      end
    }

    stream = fn _model, _context, _opts ->
      :counters.add(calls, 1, 1)

      message =
        case :counters.get(calls, 1) do
          1 ->
            response(
              [%ToolCall{id: "r1", name: "read", arguments: %{"path" => "a.txt"}}],
              :tool_use,
              %Usage{input: 3_000, output: 20}
            )

          _ ->
            response([%TextContent{text: "The file has 300 lines."}], :stop, %Usage{
              input: 4_000,
              output: 30,
              cache_read: 1_000
            })
        end

      {:ok, events(message)}
    end

    session =
      start_supervised!(
        {Session,
         [
           cwd: root,
           model: model(),
           stream_fn: stream,
           tools: [reader],
           session_key: key,
           register: true,
           settings_manager: %{SettingsManager.load(root) | compaction_enabled: false}
         ]}
      )

    Session.subscribe(session)
    assert :ok = Session.prompt(session, "How many lines does a.txt have?")
    assert_receive {:session_event, _, {:agent_end, _}}, 5_000

    assert {:ok, live} = ControlPlaneProvider.session_context_usage(key, root)
    assert live.live
    assert live.overhead == :live
    assert live.source == "usage"
    assert live.used_tokens == 5_030
    assert Enum.sum(Enum.map(live.categories, & &1.tokens)) == 5_030
    assert live.window == 128_000
    assert live.percent_used == 3.9
    assert category(live, :tool_definitions).items == 1
    assert category(live, :tool_results).tokens > 0
    assert category(live, :context_files).tokens > 0
    assert Enum.any?(live.top, &(&1.label == "read result #3"))

    # Sessions stop between turns: the save records the overhead profile.
    header_id = Session.get_state(session).session_manager.header.id
    assert :ok = Session.save(session)
    stop_supervised!(Session)

    LemonCore.ChatStateStore.put(key, %LemonCore.ChatState{
      last_engine: "lemon",
      last_resume_token: header_id,
      updated_at: System.system_time(:millisecond)
    })

    on_exit(fn -> LemonCore.Store.delete(:session_context_overhead, header_id) end)

    assert {:ok, durable} = ControlPlaneProvider.session_context_usage(key, root)
    refute durable.live
    assert durable.overhead == :snapshot
    assert durable.used_tokens == live.used_tokens
    # The mock model is not registered, so its window is honestly unknown.
    assert durable.window == nil
    assert durable.percent_used == nil
    assert Enum.sum(Enum.map(durable.categories, & &1.tokens)) == durable.used_tokens

    # The recorded profile itemises the same prompt sections and tools; scaled
    # tokens differ only through the durable message estimate.
    for id <- [:system_prompt, :tool_definitions, :skills, :context_files] do
      assert category(durable, id).items == category(live, id).items
    end

    assert category(durable, :context_files).tokens > 0

    assert {:error, :session_not_found} =
             ControlPlaneProvider.session_context_usage("agent:unknown:main", root)
  end

  defp category(report, id), do: Enum.find(report.categories, &(&1.id == id))

  defp model,
    do: %Model{
      id: "context-test",
      name: "Context Test",
      api: :mock,
      provider: :mock_provider,
      base_url: "https://invalid.test",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{},
      context_window: 128_000,
      max_tokens: 4096
    }

  defp response(content, reason, usage),
    do: %AssistantMessage{
      content: content,
      api: :mock,
      provider: :mock_provider,
      model: "context-test",
      usage: usage,
      stop_reason: reason,
      timestamp: System.system_time(:millisecond)
    }

  defp events(message) do
    {:ok, stream} = LemonAi.EventStream.start_link()

    Task.start(fn ->
      LemonAi.EventStream.push(stream, {:start, message})
      LemonAi.EventStream.push(stream, {:done, message.stop_reason, message})
      LemonAi.EventStream.complete(stream, message)
    end)

    stream
  end
end
