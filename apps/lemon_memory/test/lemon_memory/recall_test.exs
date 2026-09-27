defmodule LemonMemory.RecallTest do
  use ExUnit.Case, async: false

  alias LemonCore.Config.Features
  alias LemonMemory.{Document, Ingest, Recall, Store}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    store = :"recall_test_store_#{System.unique_integer([:positive])}"
    ingest = :"recall_test_ingest_#{System.unique_integer([:positive])}"
    agent_id = "recall_agent_#{System.unique_integer([:positive])}"

    start_supervised!(
      Supervisor.child_spec({Store, name: store, path: Path.join(tmp_dir, "store")}, id: store)
    )

    start_supervised!(
      Supervisor.child_spec(
        {Ingest,
         name: ingest,
         memory_store: store,
         config_loader: fn ->
           %{features: %Features{session_search: :"default-on", routing_feedback: :off}}
         end},
        id: ingest
      )
    )

    %{store: store, ingest: ingest, agent_id: agent_id}
  end

  defp put(store, agent_id, prompt, answer) do
    doc =
      Document.new(
        session_key: "agent:#{agent_id}:main",
        agent_id: agent_id,
        prompt_summary: prompt,
        answer_summary: answer
      )

    :ok = Store.put_sync(store, doc)
    doc
  end

  test "a fact from run N is in the recall block for run N+1", %{
    store: store,
    ingest: ingest,
    agent_id: agent_id
  } do
    # Run N finishes and goes through the real ingest path.
    :ok =
      Ingest.handle_finalize_run(ingest, %{
        run_id: "run-n",
        record: %{events: [], started_at: System.system_time(:millisecond)},
        summary: %{
          session_key: "agent:#{agent_id}:telegram:1",
          agent_id: agent_id,
          prompt: "Remember that my sister Priya's birthday is on March 14th.",
          completed: %{ok: true, answer: "Got it: Priya's birthday is March 14th."}
        }
      })

    assert eventually(fn ->
             Store.search(store, "priya", scope: :agent, scope_key: agent_id) != []
           end)

    # Run N+1, a different session, asks without naming a tool.
    assert {:ok, block} =
             Recall.block("What should I get Priya for her birthday?",
               agent_id: agent_id,
               store: store
             )

    assert block =~ "March 14th"
  end

  test "only this agent's conversations are recalled", %{store: store, agent_id: agent_id} do
    put(store, "someone_else", "Priya's birthday is March 14th.", "Noted.")

    assert Recall.block("When is Priya's birthday?", agent_id: agent_id, store: store) == :skip
  end

  test "skips trivial messages without searching", %{store: store, agent_id: agent_id} do
    put(store, agent_id, "ok thanks", "You're welcome.")

    for message <- ["ok", "thanks!", "continue", "yes please", nil] do
      assert Recall.block(message, agent_id: agent_id, store: store) == :skip
    end
  end

  test "a paraphrase sharing one meaningful keyword is recalled", %{
    store: store,
    agent_id: agent_id
  } do
    put(store, agent_id, "Our deployment uses canary releases.", "Roll back with Helm.")

    assert {:ok, block} =
             Recall.block("Explain the deployment strategy",
               agent_id: agent_id,
               store: store
             )

    assert block =~ "canary releases"
  end

  test "the block is bounded", %{store: store, agent_id: agent_id} do
    long = String.duplicate("kubernetes cluster upgrade notes ", 60)

    for _ <- 1..6, do: put(store, agent_id, long, long)

    opts = [agent_id: agent_id, store: store, limit: 5]
    assert {:ok, block} = Recall.block("kubernetes cluster upgrade", opts)

    assert byte_size(Recall.title()) + byte_size(block) <= 2_048

    # Every included conversation is complete: a user line and an assistant line.
    users = length(Regex.scan(~r/^\[[^\]]+\] User: /m, block))
    assistants = length(Regex.scan(~r/^Assistant: /m, block))
    assert users >= 1 and users == assistants
  end

  test "USER.md and three hits share a hard UTF-8 byte budget", %{
    store: store,
    agent_id: agent_id,
    tmp_dir: tmp_dir
  } do
    File.write!(Path.join(tmp_dir, "USER.md"), String.duplicate("Prefers café gifts. ", 200))

    for index <- 1..5 do
      put(store, agent_id, "birthday gift #{index}", String.duplicate("café ", 300))
    end

    assert {:ok, block} =
             Recall.block("birthday gifts",
               agent_id: agent_id,
               store: store,
               workspace_dir: tmp_dir
             )

    assert String.valid?(block)
    assert block =~ "USER.md: Prefers café gifts."
    assert byte_size(Recall.title()) + byte_size(block) <= 2_048
    assert length(Regex.scan(~r/^Assistant: /m, block)) == 3
  end

  defp eventually(fun, attempts \\ 50)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end
end
