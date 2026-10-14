defmodule LemonSkills.Tools.KanbanTest do
  use ExUnit.Case, async: false

  alias LemonAgent.Types.AgentToolResult
  alias LemonSkills.Tools.Kanban
  alias LemonAgent.Workspace.KanbanStore

  setup do
    on_exit(fn ->
      KanbanStore.list_boards(limit: 100)
      |> Enum.each(fn board -> KanbanStore.clear_board(board.id) end)
    end)

    :ok
  end

  test "returns the kanban tool definition" do
    tool = Kanban.tool("/tmp/lemon-kanban-tool")

    assert tool.name == "kanban"
    assert "board_create" in tool.parameters["properties"]["action"]["enum"]
    assert "task_comment" in tool.parameters["properties"]["action"]["enum"]
    refute Map.has_key?(tool.parameters["properties"], "meta")

    workflow = tool.parameters["properties"]["coding_workflow"]
    assert [disabled, settings] = workflow["anyOf"]
    assert disabled == %{"type" => "boolean", "enum" => [false]}
    assert settings["type"] == "object"
    assert settings["additionalProperties"] == false
    assert settings["properties"]["reviewModel"]["type"] == "string"

    assert [_, publish] = settings["properties"]["publish"]["anyOf"]
    assert publish["type"] == "object"
    assert publish["additionalProperties"] == false
    assert publish["properties"]["mode"]["enum"] == ["branch", "pull_request"]
    assert publish["properties"]["draft"]["default"] == true
  end

  test "creates and lists boards with current cwd as default workspace" do
    assert %AgentToolResult{details: %{board: board}} =
             Kanban.execute(
               "call",
               %{"action" => "board_create", "name" => "Launch board"},
               nil,
               nil,
               "/tmp/lemon-kanban-tool",
               agent_id: "agent_1"
             )

    assert board.name == "Launch board"
    assert board.workspace == "/tmp/lemon-kanban-tool"
    assert board.owner == "agent_1"
    refute Map.has_key?(board.meta, "codingWorkflow")

    assert %AgentToolResult{details: %{boards: boards}} =
             Kanban.execute("call", %{"action" => "board_list"}, nil, nil, "/tmp", [])

    assert Enum.any?(boards, &(&1.id == board.id))
  end

  test "board supervision preserves origin and validates explicit destination before mutation" do
    tool =
      Kanban.tool(System.tmp_dir!(),
        session_key: "agent:operator:telegram:work:group:-100:thread:77"
      )

    assert %AgentToolResult{details: %{board: board}} =
             tool.execute.(
               "call",
               %{"action" => "board_create", "name" => "Remote", "deliver_to" => " NONE "},
               nil,
               nil
             )

    assert board.meta["deliverTo"] == "none"

    assert board.meta["notificationSessionKey"] ==
             "agent:operator:telegram:work:group:-100:thread:77"

    assert {:error, _} =
             tool.execute.(
               "call",
               %{"action" => "board_create", "name" => "Rejected", "deliver_to" => "wrong"},
               nil,
               nil
             )

    refute Enum.any?(KanbanStore.list_boards(), &(&1.name == "Rejected"))
  end

  test "creates reviewed local boards without inventing publishing settings" do
    for settings <- [%{}, %{"reviewModel" => "test:reviewer", "publish" => false}] do
      assert %AgentToolResult{details: %{board: board}} =
               Kanban.execute(
                 "call",
                 %{
                   "action" => "board_create",
                   "name" => "Reviewed local board",
                   "coding_workflow" => settings
                 },
                 nil,
                 nil,
                 "/tmp/lemon-kanban-tool",
                 []
               )

      assert board.meta == %{"codingWorkflow" => settings}
      assert KanbanStore.get_board(board.id).meta == board.meta
      assert Jason.decode!(Jason.encode!(board.meta)) == board.meta
    end
  end

  test "preserves explicit coding-only workflow opt-out" do
    assert %AgentToolResult{details: %{board: board}} =
             Kanban.execute(
               "call",
               %{
                 "action" => "board_create",
                 "name" => "Coding-only board",
                 "coding_workflow" => false
               },
               nil,
               nil,
               "/tmp/lemon-kanban-tool",
               []
             )

    assert board.meta == %{"codingWorkflow" => false}
  end

  test "accepts explicit branch and pull request publishing settings unchanged" do
    for publish <- [
          %{"mode" => "branch", "remote" => "origin"},
          %{
            "mode" => "pull_request",
            "remote" => "origin",
            "repository" => "owner/repo",
            "base" => "main"
          },
          %{
            "mode" => "pull_request",
            "remote" => "origin",
            "repository" => "owner/repo",
            "base" => "main",
            "draft" => false
          }
        ] do
      settings = %{"reviewModel" => "test:reviewer", "publish" => publish}

      assert %AgentToolResult{details: %{board: board}} =
               Kanban.execute(
                 "call",
                 %{
                   "action" => "board_create",
                   "name" => "Explicit publish board",
                   "coding_workflow" => settings
                 },
                 nil,
                 nil,
                 "/tmp/lemon-kanban-tool",
                 []
               )

      assert board.meta == %{"codingWorkflow" => settings}
      assert KanbanStore.get_board(board.id).meta == board.meta
      assert Jason.decode!(Jason.encode!(board.meta)) == board.meta
    end
  end

  test "rejects malformed workflow settings before creating a board" do
    workspace = "/tmp/lemon-kanban-invalid-#{System.unique_integer([:positive])}"

    invalid_settings = [
      nil,
      true,
      [],
      "enabled",
      %{"unknown" => true},
      %{reviewModel: "test:reviewer"},
      %{"reviewModel" => ""},
      %{"reviewModel" => "   "},
      %{"reviewModel" => 1},
      %{"publish" => true},
      %{"publish" => %{}},
      %{"publish" => %{"mode" => "unknown", "remote" => "origin"}},
      %{"publish" => %{"mode" => "branch", "remote" => "origin", "force" => true}},
      %{"publish" => %{"mode" => "branch", "remote" => "origin", "command" => "git push"}},
      %{"publish" => %{mode: "branch", remote: "origin"}},
      %{"publish" => %{"mode" => "pull_request", "remote" => "origin"}},
      %{
        "publish" => %{
          "mode" => "pull_request",
          "remote" => "origin",
          "repository" => "owner/repo"
        }
      },
      %{
        "publish" => %{
          "mode" => "pull_request",
          "remote" => "origin",
          "base" => "main"
        }
      },
      %{
        "publish" => %{
          "mode" => "pull_request",
          "remote" => "origin",
          "repository" => "owner/repo",
          "base" => "main",
          "draft" => "true"
        }
      }
    ]

    for settings <- invalid_settings do
      assert {:error, reason} =
               Kanban.execute(
                 "call",
                 %{
                   "action" => "board_create",
                   "name" => "Invalid workflow board",
                   "coding_workflow" => settings
                 },
                 nil,
                 nil,
                 workspace,
                 []
               )

      assert is_binary(reason)
      assert KanbanStore.list_boards(workspace: workspace) == []
    end
  end

  test "creates, updates, gets, and comments on tasks" do
    assert %AgentToolResult{details: %{board: board}} =
             Kanban.execute(
               "call",
               %{
                 "action" => "board_create",
                 "name" => "Task board",
                 "columns" => ["todo", "done"]
               },
               nil,
               nil,
               "/tmp",
               []
             )

    assert %AgentToolResult{details: %{task: task}} =
             Kanban.execute(
               "call",
               %{
                 "action" => "task_create",
                 "board_id" => board.id,
                 "title" => "Implement tool",
                 "description" => "Expose kanban to agents",
                 "assignee" => "agent_1"
               },
               nil,
               nil,
               "/tmp",
               []
             )

    assert task.status == "todo"
    assert task.assignee == "agent_1"

    assert %AgentToolResult{details: %{task: updated}} =
             Kanban.execute(
               "call",
               %{"action" => "task_update", "task_id" => task.id, "status" => "done"},
               nil,
               nil,
               "/tmp",
               []
             )

    assert updated.status == "done"

    assert %AgentToolResult{details: %{task: commented}} =
             Kanban.execute(
               "call",
               %{
                 "action" => "task_comment",
                 "task_id" => task.id,
                 "body" => "Ready",
                 "author" => "me"
               },
               nil,
               nil,
               "/tmp",
               []
             )

    assert [%{"body" => "Ready", "author" => "me"}] = commented.comments

    assert %AgentToolResult{details: %{task: fetched}} =
             Kanban.execute(
               "call",
               %{"action" => "task_get", "task_id" => task.id},
               nil,
               nil,
               "/tmp",
               []
             )

    assert fetched.id == task.id
  end

  test "returns clear errors for missing identifiers" do
    assert {:error, "board_id is required"} =
             Kanban.execute(
               "call",
               %{"action" => "task_list"},
               nil,
               nil,
               "/tmp",
               []
             )

    assert {:error, "unsupported kanban action: \"wat\""} =
             Kanban.execute("call", %{"action" => "wat"}, nil, nil, "/tmp", [])
  end
end
