defmodule CodingAgent.Session.PlanningTest do
  use ExUnit.Case, async: false

  alias CodingAgent.{Session, SessionManager, SettingsManager}
  alias CodingAgent.Session.Planning
  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.{AssistantMessage, Model, ModelCost, TextContent, ToolCall}

  setup do
    root = Path.join(System.tmp_dir!(), "lemon-plan-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    on_exit(fn ->
      File.rm_rf!(root)
      File.rm_rf!(SessionManager.get_session_dir(root))
    end)

    %{root: root}
  end

  test "planning refuses writes, persists reviewed artifact, and executes only after approval", %{
    root: root
  } do
    parent = self()
    calls = :counters.new(1, [:atomics])
    target = Path.join(root, "result.txt")

    plan_text =
      "# Verified plan\n1. Write result.txt with EXECUTED.\n2. Read it and verify the exact bytes."

    writer = %AgentTool{
      name: "write",
      label: "Write",
      description: "Write test result",
      parameters: %{"type" => "object", "properties" => %{}},
      execute: fn _, _, _, _ ->
        File.write!(target, "EXECUTED")
        %AgentToolResult{content: [%TextContent{text: "written"}]}
      end
    }

    reader = %AgentTool{
      name: "read",
      label: "Read",
      description: "Read",
      parameters: %{"type" => "object", "properties" => %{}},
      execute: fn _, _, _, _ -> %AgentToolResult{content: [%TextContent{text: "read"}]} end
    }

    stream = fn _model, context, _opts ->
      :counters.add(calls, 1, 1)
      call = :counters.get(calls, 1)
      send(parent, {:provider_context, call, context})

      message =
        if call in [1, 3] do
          response([%ToolCall{id: "write-#{call}", name: "write", arguments: %{}}], :tool_use)
        else
          response(
            [%TextContent{text: if(call == 2, do: plan_text, else: "Executed and verified")}],
            :stop
          )
        end

      {:ok, events(message)}
    end

    opts = [
      cwd: root,
      model: model(),
      stream_fn: stream,
      tools: [reader, writer],
      system_prompt: "Follow the user's request.",
      settings_manager: settings(root)
    ]

    session = start_supervised!({Session, opts})
    Session.subscribe(session)
    assert {:ok, %{"status" => "draft"}} = Session.plan(session, :enter)
    assert :ok = Session.prompt(session, "Write the result, but first plan it.")
    assert_receive {:session_event, _, {:plan_ready, plan}}, 5_000
    assert_receive {:session_event, _, {:agent_end, _}}, 5_000
    assert plan["status"] == "pending"
    assert File.read!(plan["path"]) == plan_text
    refute String.starts_with?(plan["path"], root <> "/")
    refute File.exists?(target)
    assert_receive {:provider_context, 1, context}
    assert Enum.map(context.tools, & &1.name) == ["read"]

    assert Enum.any?(
             Session.get_messages(session),
             &(Map.get(&1, :role) == :tool_result and Map.get(&1, :is_error) == true)
           )

    assert {:error, :revision_mismatch} =
             Session.plan(session, :approve, revision: String.duplicate("0", 64))

    assert {:ok, ^plan} = Session.plan(session, :enter)
    assert {:ok, approved} = Session.plan(session, :approve, revision: plan["revision"])
    assert approved["status"] == "approved"
    assert approved["revision"] == plan["revision"]
    assert :ok = Session.prompt(session, "Execute the approved plan")
    assert_receive {:session_event, _, {:agent_end, _}}, 5_000
    assert_receive {:provider_context, 3, context}
    assert context.system_prompt =~ plan_text
    assert "write" in Enum.map(context.tools, & &1.name)
    assert File.read!(target) == "EXECUTED"

    path = Session.get_state(session).session_file
    stop_supervised!(Session)
    resumed = start_supervised!({Session, Keyword.put(opts, :session_file, path)})
    assert {:ok, ^approved} = Session.plan(resumed)
    assert Session.get_state(resumed).system_prompt =~ plan_text
    assert "write" in Enum.map(Session.get_state(resumed).tools, & &1.name)
    assert {:ok, %{"status" => "none"}} = Session.plan(resumed, :discard)
    refute Session.get_state(resumed).system_prompt =~ plan_text
  end

  test "artifact tampering and branch changes invalidate approval, and forks bind revisions", %{
    root: root
  } do
    session = SessionManager.new(root)
    session = SessionManager.persist(session, Path.join(root, "native.jsonl"))
    {:ok, _, draft} = Planning.transition(session, :enter, [])
    state = %Session{session_manager: draft, event_listeners: [], event_streams: %{}}

    state =
      Planning.after_turn(state, [
        response([%TextContent{text: "# Plan\nModify the checked file."}], :stop)
      ])

    pending = Planning.status(state.session_manager)

    forked = %{
      state.session_manager
      | header: %{state.session_manager.header | id: "independent-fork"}
    }

    refute Planning.status(forked)["revision"] == pending["revision"]

    assert {:error, :revision_mismatch} =
             Planning.transition(forked, :approve, revision: pending["revision"])

    File.write!(pending["path"], "changed after review")

    assert {:error, :plan_artifact_changed} =
             Planning.transition(state.session_manager, :approve, revision: pending["revision"])

    assert {:error, :plan_not_pending} =
             Planning.transition(draft, :approve, revision: pending["revision"])
  end

  test "entering before the first run creates one durable native planning session", %{root: root} do
    key = "agent:plan-test-#{System.unique_integer([:positive])}:main"
    on_exit(fn -> LemonCore.SessionLifecycle.delete(key) end)

    assert {:ok, %{"status" => "none"}} =
             CodingAgent.ControlPlaneProvider.session_plan(key, root, :status, [])

    assert {:ok, draft} = CodingAgent.ControlPlaneProvider.session_plan(key, root, :enter, [])
    first = LemonCore.ChatStateStore.get(key).last_resume_token
    assert {:ok, ^draft} = CodingAgent.ControlPlaneProvider.session_plan(key, root, :enter, [])
    assert LemonCore.ChatStateStore.get(key).last_resume_token == first
    assert {:ok, ^draft} = CodingAgent.ControlPlaneProvider.session_plan(key, root, :status, [])
    assert LemonCore.SessionLifecycle.get(key).run_count == 0
  end

  test "explicit creation is idempotent, nameable and contains no fabricated plan or messages", %{
    root: root
  } do
    key = "agent:create-test-#{System.unique_integer([:positive])}:main"
    on_exit(fn -> LemonCore.SessionLifecycle.delete(key) end)

    assert {:error, :not_found} =
             LemonCore.SessionLifecycle.patch(key, %{title: "Before first turn"})

    results =
      1..4
      |> Task.async_stream(fn _ -> CodingAgent.ControlPlaneProvider.session_create(key, root) end)
      |> Enum.map(fn {:ok, {:ok, receipt}} -> receipt end)

    assert Enum.count(results, & &1["created"]) == 1
    assert [id] = results |> Enum.map(& &1["sessionId"]) |> Enum.uniq()
    assert LemonCore.ChatStateStore.get(key).last_resume_token == id

    assert {:ok, native} =
             SessionManager.load_from_file(SessionManager.session_file_path(root, id))

    assert SessionManager.entries(native) == []
    assert Planning.status(native)["status"] == "none"
    assert {:ok, named} = LemonCore.SessionLifecycle.patch(key, %{title: "Before first turn"})
    assert named.title == "Before first turn"
    assert named.run_count == 0

    assert {:ok, %{"created" => false, "sessionId" => ^id}} =
             CodingAgent.ControlPlaneProvider.session_create(key, root)

    assert LemonCore.SessionLifecycle.get(key).title == "Before first turn"
    assert {:error, _} = CodingAgent.ControlPlaneProvider.session_create(key, root <> "-wrong")
    assert LemonCore.ChatStateStore.get(key).last_resume_token == id
  end

  test "explicit creation refuses legacy identities and existing non-native indexes", %{
    root: root
  } do
    assert {:error, :invalid_session_key} =
             CodingAgent.ControlPlaneProvider.session_create("unknown-legacy", root)

    key = "agent:existing-test-#{System.unique_integer([:positive])}:main"
    on_exit(fn -> LemonCore.SessionLifecycle.delete(key) end)

    :ok =
      LemonCore.RunStore.create_session_index(
        key,
        LemonCore.SessionKey.agent_id(key),
        :control_plane
      )

    assert {:error, :unsupported_session} =
             CodingAgent.ControlPlaneProvider.session_create(key, root)

    assert LemonCore.ChatStateStore.get(key) == nil
  end

  defp settings(root), do: %{SettingsManager.load(root) | compaction_enabled: false}

  defp model,
    do: %Model{
      id: "plan-test",
      name: "Plan Test",
      api: :mock,
      provider: :mock_provider,
      base_url: "https://invalid.test",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{},
      context_window: 128_000,
      max_tokens: 4096
    }

  defp response(content, reason),
    do: %AssistantMessage{
      content: content,
      api: :mock,
      provider: :mock_provider,
      model: "plan-test",
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
