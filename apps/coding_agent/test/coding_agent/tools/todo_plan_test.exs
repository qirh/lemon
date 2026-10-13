defmodule CodingAgent.Tools.TodoPlanTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Checkpoint
  alias CodingAgent.Tools.{Todo, TodoRead, TodoStore, TodoWrite}
  alias LemonAgent.Types.AgentToolResult

  setup do
    session_id = "todo-plan-#{System.unique_integer([:positive])}"
    on_exit(fn -> TodoStore.delete(session_id) end)
    {:ok, session_id: session_id}
  end

  defp write(session_id, todos) do
    TodoWrite.execute("write", %{"todos" => todos}, nil, nil, session_id)
  end

  test "nullable optional fields work through constrained provider schemas", %{
    session_id: session_id
  } do
    first =
      write(session_id, [
        %{"content" => "Inspect", "id" => nil},
        %{"content" => "Verify", "id" => nil}
      ])

    assert %AgentToolResult{} = first
    ids = Enum.map(first.details.todos, & &1["id"])
    assert length(Enum.uniq(ids)) == 2
    assert Enum.all?(ids, &is_binary/1)

    for action <- ["read", "progress", "actionable"] do
      assert %AgentToolResult{details: %{todos: todos}} =
               Todo.execute("getter", %{"action" => action, "todos" => nil}, nil, nil, session_id)

      assert Enum.map(todos, & &1["id"]) == ids
    end
  end

  test "getters reject status-update payloads instead of silently ignoring them", %{
    session_id: session_id
  } do
    assert %AgentToolResult{} = write(session_id, [%{"content" => "Verify behavior"}])
    original = TodoStore.get(session_id)
    completed = Enum.map(original, &Map.put(&1, "status", "completed"))

    for action <- ["read", "progress", "actionable"] do
      assert {:error, _} =
               Todo.execute(
                 "getter",
                 %{"action" => action, "todos" => completed},
                 nil,
                 nil,
                 session_id
               )

      assert TodoStore.get(session_id) == original
    end

    assert %AgentToolResult{} =
             Todo.execute(
               "update",
               %{"action" => "write", "todos" => completed},
               nil,
               nil,
               session_id
             )

    assert %AgentToolResult{details: %{completed: 1}} =
             Todo.execute("counts", %{"action" => "progress"}, nil, nil, session_id)
  end

  test "same-content updates retain generated ids across reorder and status changes", %{
    session_id: session_id
  } do
    first = write(session_id, [%{"content" => "Inspect"}, %{"content" => "Fix"}])
    [inspect_todo, fix_todo] = first.details.todos

    updated =
      write(session_id, [
        %{"content" => "Fix", "status" => "in_progress", "priority" => "high"},
        %{"content" => "Inspect", "status" => "completed"}
      ])

    assert Enum.map(updated.details.todos, & &1["id"]) == [fix_todo["id"], inspect_todo["id"]]

    assert updated.details.plan.entries == [
             %{content: "Fix", status: "in_progress", priority: "high"},
             %{content: "Inspect", status: "completed", priority: "medium"}
           ]

    assert TodoStore.get(session_id) == updated.details.todos
  end

  test "omitting an id reuses a previously explicit id", %{session_id: session_id} do
    write(session_id, [%{"id" => "existing", "content" => "Task"}])
    updated = write(session_id, [%{"content" => "Task", "status" => "completed"}])
    assert hd(updated.details.todos)["id"] == "existing"
  end

  test "explicit ids preserve task identity when content changes", %{session_id: session_id} do
    first = write(session_id, [%{"content" => "Old description"}])
    id = hd(first.details.todos)["id"]
    updated = write(session_id, [%{"id" => id, "content" => "New description"}])
    assert hd(updated.details.todos)["id"] == id

    assert updated.details.plan.entries == [
             %{content: "New description", status: "pending", priority: "medium"}
           ]
  end

  test "duplicate content receives distinct stable ids", %{session_id: session_id} do
    entries = [%{"content" => "Repeat"}, %{"content" => "Repeat"}, %{"content" => "Repeat"}]
    first = write(session_id, entries)
    ids = Enum.map(first.details.todos, & &1["id"])
    assert length(Enum.uniq(ids)) == 3
    second = write(session_id, entries)
    assert Enum.map(second.details.todos, & &1["id"]) == ids
  end

  test "explicit ids are reserved regardless of entry order", %{session_id: session_id} do
    first = write(session_id, [%{"content" => "Repeat"}, %{"content" => "Repeat"}])
    [first_id, second_id] = Enum.map(first.details.todos, & &1["id"])

    updated =
      write(session_id, [
        %{"content" => "Repeat"},
        %{"id" => first_id, "content" => "Renamed"}
      ])

    assert Enum.map(updated.details.todos, & &1["id"]) == [second_id, first_id]
  end

  test "generated ids cannot collide with supplied ids", %{session_id: session_id} do
    first = write(session_id, [%{"content" => "Task"}])
    generated_id = hd(first.details.todos)["id"]
    TodoStore.delete(session_id)

    updated =
      write(session_id, [
        %{"content" => "Task"},
        %{"id" => generated_id, "content" => "Other task"}
      ])

    ids = Enum.map(updated.details.todos, & &1["id"])
    assert Enum.uniq(ids) == ids
    assert List.last(ids) == generated_id
  end

  test "invalid explicit values and duplicate ids never mutate state", %{session_id: session_id} do
    original = write(session_id, [%{"content" => "Keep"}]).details.todos

    for {field, value, message} <- [
          {"status", "blocked", "Todo 1 status must be pending, in_progress, or completed"},
          {"status", nil, "Todo 1 status must be pending, in_progress, or completed"},
          {"priority", nil, "Todo 1 priority must be high, medium, or low"},
          {"id", nil, "Todo 1 id must be a non-empty string"}
        ] do
      assert {:error, ^message} =
               write(session_id, [Map.put(%{"content" => "Invalid"}, field, value)])

      assert TodoStore.get(session_id) == original
    end

    assert {:error, "todo ids must be unique"} =
             write(session_id, [
               %{"id" => "duplicate", "content" => "One"},
               %{"id" => "duplicate", "content" => "Two"}
             ])

    assert TodoStore.get(session_id) == original
  end

  test "standalone read normalizes atom-keyed store entries without dropping metadata", %{
    session_id: session_id
  } do
    todos = [
      %{id: "done", content: "Done", status: :completed, priority: :high, dependencies: []},
      %{
        id: "blocked",
        content: "Wait",
        status: :blocked,
        priority: :low,
        dependencies: ["missing"]
      }
    ]

    TodoStore.put(session_id, todos)

    result = TodoRead.execute("read", %{}, nil, nil, session_id)
    assert %AgentToolResult{} = result

    assert result.details.todos == [
             %{
               "id" => "done",
               "content" => "Done",
               "status" => "completed",
               "priority" => "high",
               "dependencies" => []
             },
             %{
               "id" => "blocked",
               "content" => "Wait",
               "status" => "blocked",
               "priority" => "low",
               "dependencies" => ["missing"]
             }
           ]

    assert result.details.plan.entries == [
             %{content: "Done", status: "completed", priority: "high"},
             %{content: "Wait", status: "pending", priority: "low"}
           ]

    assert Jason.decode!(hd(result.content).text) == result.details.todos
    assert TodoStore.get(session_id) == todos
  end

  test "plans remain session isolated", %{session_id: session_id} do
    other_session = session_id <> "-other"
    on_exit(fn -> TodoStore.delete(other_session) end)
    first = write(session_id, [%{"content" => "First session"}])
    second = write(other_session, [%{"content" => "Second session"}])

    assert TodoRead.execute("read", %{}, nil, nil, session_id).details.plan == first.details.plan

    assert TodoRead.execute("read", %{}, nil, nil, other_session).details.plan ==
             second.details.plan

    assert Todo.execute("read", %{"action" => "read"}, nil, nil, session_id <> "-new").details.plan ==
             %{entries: []}
  end

  test "checkpoint resume preserves normalized plan and stable ids", %{session_id: session_id} do
    on_exit(fn -> Checkpoint.delete_all(session_id) end)

    original =
      write(session_id, [
        %{"content" => "Inspect", "status" => "completed"},
        %{"content" => "Fix", "status" => "in_progress", "priority" => "high"}
      ])

    assert {:ok, checkpoint} = Checkpoint.create(session_id)
    TodoStore.delete(session_id)
    assert {:ok, _resumed} = Checkpoint.resume(checkpoint.id)
    read = TodoRead.execute("read", %{}, nil, nil, session_id)
    assert read.details == original.details

    updated =
      write(session_id, [
        %{"content" => "Inspect", "status" => "completed"},
        %{"content" => "Fix", "status" => "completed", "priority" => "high"}
      ])

    assert Enum.map(updated.details.todos, & &1["id"]) ==
             Enum.map(original.details.todos, & &1["id"])

    assert Enum.all?(updated.details.plan.entries, &(&1.status == "completed"))
  end
end
