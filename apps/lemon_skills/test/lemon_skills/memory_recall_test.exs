defmodule LemonSkills.MemoryRecallTest do
  use ExUnit.Case, async: false

  alias LemonMemory.{Document, Project, Store}
  alias LemonSkills.MemoryRecall

  defmodule ExternalProvider do
    @behaviour LemonMemory.Provider

    @impl true
    def put(_doc, _opts) do
      send(:persistent_term.get(__MODULE__), :external_memory_provider_called)
      :ok
    end

    @impl true
    def search(_query, _opts) do
      send(:persistent_term.get(__MODULE__), :external_memory_provider_called)
      []
    end
  end

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    store = :"memory_recall_test_store_#{System.unique_integer([:positive])}"

    start_supervised!(
      Supervisor.child_spec({Store, name: store, path: Path.join(tmp_dir, "store")}, id: store)
    )

    cwd = Path.join(tmp_dir, "project")
    home = Path.join(tmp_dir, "home")
    File.mkdir_p!(Path.join(cwd, ".git"))
    File.mkdir_p!(home)

    request = %{
      cwd: cwd,
      workspace_dir: home,
      session_scope: :main,
      session_key: "agent:assistant:tui:2",
      agent_id: "assistant",
      query: "Any gift ideas for Priya's birthday?"
    }

    {:ok, scope} = Project.scope(request)

    doc =
      Document.new(
        session_key: "agent:assistant:telegram:1",
        agent_id: "assistant",
        workspace_key: cwd,
        prompt_summary: "My sister Priya's birthday is on March 14th.",
        answer_summary: "Noted: Priya's birthday is March 14th.",
        meta: %{"home_digest" => scope.home_digest}
      )

    :ok = Store.put_sync(store, doc)

    %{store: store, request: request, cwd: cwd}
  end

  test "contributes a bounded volatile block for the user message", %{
    store: store,
    request: request
  } do
    assert {:ok, section} = MemoryRecall.contribute(request, store: store, auto_recall: true)

    assert section.title == "Relevant memory"
    assert section.placement == :user_message
    assert section.body =~ "March 14th"
    assert byte_size(section.title) + byte_size(section.body) <= 2_048
  end

  test "falls back to the agent in the session key", %{store: store, request: request} do
    request = Map.delete(request, :agent_id)

    assert {:ok, _section} = MemoryRecall.contribute(request, store: store, auto_recall: true)
  end

  test "skips subagent sessions", %{store: store, request: request} do
    request = %{request | session_scope: :subagent}

    assert MemoryRecall.contribute(request, store: store, auto_recall: true) == :skip
  end

  test "[memory] auto_recall = false turns the block off", %{
    store: store,
    request: request,
    cwd: cwd
  } do
    config = Path.join([cwd, ".lemon", "config.toml"])
    File.mkdir_p!(Path.dirname(config))
    File.write!(config, "[memory]\nauto_recall = false\n")

    assert MemoryRecall.contribute(request, store: store) == :skip

    File.write!(config, "[memory]\nauto_recall = true\n")
    LemonCore.Config.reload(cwd)

    assert {:ok, _section} = MemoryRecall.contribute(request, store: store)
  end

  test "profile facts come only from the supplied workspace", %{
    store: store,
    request: request,
    cwd: cwd
  } do
    profile = Path.join(cwd, "profile")
    other_profile = Path.join(cwd, "other-profile")
    File.mkdir_p!(profile)
    File.mkdir_p!(other_profile)
    File.write!(Path.join(profile, "USER.md"), "Prefers birthday gifts made of wood.")
    File.write!(Path.join(other_profile, "USER.md"), "Private other-profile fact.")

    assert {:ok, section} =
             MemoryRecall.contribute(Map.put(request, :workspace_dir, profile),
               store: store,
               auto_recall: true
             )

    assert section.body =~ "Prefers birthday gifts made of wood."
    refute section.body =~ "Private other-profile fact."

    assert MemoryRecall.contribute(Map.put(request, :workspace_dir, profile),
             store: store,
             auto_recall: false
           ) == :skip
  end

  test "automatic recall stays local instead of invoking network or model-backed providers", %{
    store: store,
    request: request
  } do
    assert {:ok, _} = Project.remember(request, "Build with mix release.", nil, store: store)
    id = "automatic-recall-local-only-test"
    :persistent_term.put(ExternalProvider, self())

    on_exit(fn ->
      LemonMemory.Providers.unregister_provider(id)
      :persistent_term.erase(ExternalProvider)
    end)

    assert :ok =
             LemonMemory.Providers.register_provider(
               id: id,
               module: ExternalProvider,
               enabled: true,
               scopes: [:agent, :workspace, :session]
             )

    assert {:ok, section} = MemoryRecall.contribute(request, store: store, auto_recall: true)
    assert section.body =~ "Build with mix release."
    refute_received :external_memory_provider_called
  end

  test "project defaults help unrelated opening queries and stay bounded with history and personal notes",
       %{
         store: store,
         request: request
       } do
    fact = "Use mix release for production builds."
    assert {:ok, _} = Project.remember(request, fact, nil, store: store)

    for n <- 1..7 do
      assert {:ok, _} =
               Project.remember(
                 request,
                 "Convention #{n}: " <> String.duplicate("Use explicit module names. ", 8),
                 nil,
                 store: store
               )
    end

    File.write!(
      Path.join(request.workspace_dir, "USER.md"),
      String.duplicate("Prefers concise output. ", 30)
    )

    nested = Path.join(request.cwd, "apps/example")
    File.mkdir_p!(nested)

    assert {:ok, section} =
             MemoryRecall.contribute(%{request | cwd: nested}, store: store, auto_recall: true)

    assert section.body =~ fact
    assert String.valid?(section.body)
    assert byte_size(section.title) + byte_size(section.body) + 6 <= 2_048
    assert section.placement == :user_message
  end

  test "project facts never cross repository, profile, agent, or subagent scope", %{
    store: store,
    request: request
  } do
    fact = "Use mix release for production builds."
    assert {:ok, _} = Project.remember(request, fact, nil, store: store)
    request = %{request | query: "Implement feature flags"}

    for other <- [
          %{request | cwd: request.cwd <> "-other"},
          %{request | workspace_dir: request.workspace_dir <> "-other"},
          %{request | agent_id: "other"},
          %{request | session_scope: :subagent},
          Map.delete(request, :session_scope)
        ] do
      assert MemoryRecall.contribute(other, store: store, auto_recall: true) == :skip
    end

    assert {:ok, section} = MemoryRecall.contribute(request, store: store, auto_recall: true)
    assert section.body =~ fact
  end

  test "automatic history is isolated by profile and agent and excludes unscoped legacy documents",
       %{
         store: store,
         request: request
       } do
    {:ok, scope} = Project.scope(request)

    for {agent, home, answer} <- [
          {"assistant", "foreign-home", "Foreign profile private detail"},
          {"other", scope.home_digest, "Foreign agent private detail"},
          {"assistant", nil, "Unscoped legacy private detail"}
        ] do
      :ok =
        Store.put_sync(
          store,
          Document.new(
            session_key: "agent:#{agent}:test:1",
            agent_id: agent,
            workspace_key: request.cwd,
            prompt_summary: "Priya birthday",
            answer_summary: answer,
            meta: %{"home_digest" => home}
          )
        )
    end

    assert {:ok, section} = MemoryRecall.contribute(request, store: store, auto_recall: true)
    assert section.body =~ "March 14th"
    refute section.body =~ "Foreign profile"
    refute section.body =~ "Foreign agent"
    refute section.body =~ "Unscoped legacy"
  end

  test "trivial prompts still skip even when project facts exist", %{
    store: store,
    request: request
  } do
    assert {:ok, _} = Project.remember(request, "Build with mix release.", nil, store: store)

    for query <- ["ok", "thanks", "continue", ""] do
      assert MemoryRecall.contribute(%{request | query: query}, store: store, auto_recall: true) ==
               :skip
    end
  end

  test "disabled durable memory gates history, personal notes, and project defaults", %{
    store: store,
    request: request
  } do
    assert {:ok, _} = Project.remember(request, "Build with mix release.", nil, store: store)
    File.write!(Path.join(request.workspace_dir, "USER.md"), "Prefers concise output.")
    config = Path.join([request.cwd, ".lemon", "config.toml"])
    File.mkdir_p!(Path.dirname(config))
    File.write!(config, "[features]\nsession_search = \"off\"\n[memory]\nauto_recall = true\n")
    LemonCore.Config.reload(request.cwd)

    assert MemoryRecall.contribute(request, store: store) == :skip
    assert MemoryRecall.contribute(request, store: store, auto_recall: true) == :skip
  end

  test "anything that is not a request map is skipped" do
    assert MemoryRecall.contribute(:not_a_request) == :skip
  end
end
