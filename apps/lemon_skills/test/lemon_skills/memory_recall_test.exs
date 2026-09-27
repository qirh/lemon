defmodule LemonSkills.MemoryRecallTest do
  use ExUnit.Case, async: false

  alias LemonMemory.{Document, Store}
  alias LemonSkills.MemoryRecall

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    store = :"memory_recall_test_store_#{System.unique_integer([:positive])}"

    start_supervised!(
      Supervisor.child_spec({Store, name: store, path: Path.join(tmp_dir, "store")}, id: store)
    )

    doc =
      Document.new(
        session_key: "agent:assistant:telegram:1",
        agent_id: "assistant",
        prompt_summary: "My sister Priya's birthday is on March 14th.",
        answer_summary: "Noted: Priya's birthday is March 14th."
      )

    :ok = Store.put_sync(store, doc)

    cwd = Path.join(tmp_dir, "project")
    File.mkdir_p!(cwd)

    request = %{
      cwd: cwd,
      session_scope: :main,
      session_key: "agent:assistant:tui:2",
      agent_id: "assistant",
      query: "Any gift ideas for Priya's birthday?"
    }

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

  test "anything that is not a request map is skipped" do
    assert MemoryRecall.contribute(:not_a_request) == :skip
  end
end
