defmodule LemonSkills.Tools.Kanban do
  @moduledoc """
  Durable kanban board tool backed by LemonAgent.Workspace.KanbanStore.

  Wired into CodingAgent.ToolRegistry's builtin tool list. No external service or credentials are
  required; boards and tasks persist in the workspace KanbanStore.

  `board_create` optionally accepts `coding_workflow`: an explicit opt-in map
  for isolated coding, review of the exact diff, and a local branch commit before
  completion. Omission or `false` preserves coding-only behavior. Publishing is
  disabled unless an explicit `publish` map selects `branch` or `pull_request`.
  Workflow settings are validated by the optional automation service and stored
  unchanged as JSON-safe string-key settings under board metadata `codingWorkflow`;
  arbitrary metadata, force-push, and command options are not accepted.
  """

  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent
  alias LemonAgent.Workspace.KanbanStore

  @actions ~w(board_list board_create board_get task_list task_get task_create task_update task_comment dispatch_start dispatch_stop dispatch_status)

  @doc """
  Returns the `LemonAgent.Types.AgentTool.t()` definition for the `"kanban"`
  tool, wired to `execute/6`.

  `cwd` is the project directory; it is the fallback `:kanban_workspace` for
  `board_create` when neither the `"workspace"` param nor the
  `:kanban_workspace` opt is set. The `opts` keyword is read for two keys:
  `:kanban_workspace` (board workspace for `board_create`) and `:agent_id`
  (owner for `board_create` and author for `task_comment` when the
  `"owner"`/`"author"` params are absent).
  """
  @spec tool(String.t(), keyword()) :: AgentTool.t()
  def tool(cwd, opts \\ []) do
    %AgentTool{
      name: "kanban",
      description:
        "Manage durable Lemon kanban boards and coding tasks. Create a board in a repository, add tasks, then dispatch_start to execute them in isolated worktrees. Inspect task_get for progress/results; dispatch_stop cancels workers. Move a failed task back to the first column to explicitly retry.",
      label: "Kanban",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "action" => %{
            "type" => "string",
            "enum" => @actions,
            "description" => "Kanban operation to run."
          },
          "board_id" => %{"type" => "string", "description" => "Board id for board/task actions."},
          "task_id" => %{"type" => "string", "description" => "Task id for task actions."},
          "name" => %{"type" => "string", "description" => "Board name for board_create."},
          "title" => %{"type" => "string", "description" => "Task title."},
          "description" => %{"type" => "string", "description" => "Task description."},
          "body" => %{"type" => "string", "description" => "Comment body for task_comment."},
          "status" => %{"type" => "string", "description" => "Board or task status filter/value."},
          "priority" => %{"type" => "string", "description" => "Task priority."},
          "assignee" => %{
            "type" => "string",
            "description" => "Task assignee or assignee filter."
          },
          "worker_profile" => %{"type" => "string", "description" => "Worker profile for a task."},
          "session_key" => %{"type" => "string", "description" => "Session key linked to a task."},
          "run_id" => %{"type" => "string", "description" => "Router run id linked to a task."},
          "owner" => %{"type" => "string", "description" => "Board owner or owner filter."},
          "workspace" => %{"type" => "string", "description" => "Board workspace path."},
          "author" => %{"type" => "string", "description" => "Comment author."},
          "coding_workflow" => coding_workflow_schema(),
          "max_concurrency" => %{
            "type" => "integer",
            "minimum" => 1,
            "maximum" => 8,
            "description" => "Parallel coding workers for dispatch_start (default 1)."
          },
          "model" => %{
            "type" => "string",
            "description" => "Optional provider:model for workers."
          },
          "columns" => %{
            "type" => "array",
            "description" => "Board columns for board_create.",
            "items" => %{"type" => "string"}
          },
          "depends_on" => %{
            "type" => "array",
            "description" => "Task ids that must complete before this task is available.",
            "items" => %{"type" => "string"}
          },
          "include_tasks" => %{
            "type" => "boolean",
            "description" => "Whether board_get includes tasks. Defaults to true."
          },
          "limit" => %{
            "type" => "integer",
            "minimum" => 1,
            "description" => "Maximum rows to return."
          }
        },
        "required" => ["action"]
      },
      execute: &execute(&1, &2, &3, &4, cwd, opts)
    }
  end

  @doc """
  Tool callback invoked by the agent loop with, in order: `tool_call_id`,
  `params` map, `signal`, `on_update` callback, `cwd`, and `opts`.

  Reads the required `"action"` param to dispatch to `board_list`,
  `board_create`, `board_get`, `task_list`, `task_get`, `task_create`,
  `task_update`, or `task_comment`. Per action: `board_list` reads `"status"`,
  `"owner"`, `"workspace"`, `"limit"`; `board_create` requires `"name"` and
  reads `"workspace"`, `"owner"`, `"columns"`, `"coding_workflow"`; `board_get` requires
  `"board_id"` and reads `"include_tasks"` (defaults to `true`) and `"limit"`
  (defaults to `100`); `task_list` requires `"board_id"` and reads `"status"`,
  `"assignee"`, `"limit"`; `task_get` requires `"task_id"`; `task_create`
  requires `"board_id"` and `"title"` and reads `"description"`, `"status"`,
  `"priority"`, `"assignee"`, `"worker_profile"`, `"session_key"`, `"run_id"`,
  `"depends_on"`; `task_update` requires `"task_id"` and reads the same
  optional fields; `task_comment` requires `"task_id"` and `"body"` and reads
  `"author"`.

  `dispatch_start`, `dispatch_stop`, and `dispatch_status` require `"board_id"`
  and operate on the long-running automation dispatcher. Start accepts
  `"max_concurrency"` (1–8) and an optional worker `"model"`. No scheduler is
  started by this tool when the automation runtime is unavailable.
  Supplied `"coding_workflow"` settings also require the automation service and
  are validated before board creation. Only explicit caller settings are stored;
  publishing settings are never inferred from the repository or coding output.

  On success returns a `%LemonAgent.Types.AgentToolResult{}` whose `content`
  is the pretty-printed JSON encoding of the details and whose `details` map
  holds the payload (board/task data) plus a `:title` summary string. Failures
  — a missing or unsupported `"action"`, a missing required param, a missing
  board/task, or a `KanbanStore` error — return `{:error, message}` with a
  string message (see `required_string/2`, `fetch_board/1`, `format_error/1`).
  """
  @spec execute(String.t(), map(), reference() | nil, function() | nil, String.t(), keyword()) ::
          AgentToolResult.t() | {:error, term()}
  def execute(_tool_call_id, params, _signal, _on_update, cwd, opts) do
    case Map.get(params, "action") do
      "board_list" -> board_list(params)
      "board_create" -> board_create(params, cwd, opts)
      "board_get" -> board_get(params)
      "task_list" -> task_list(params)
      "task_get" -> task_get(params)
      "task_create" -> task_create(params)
      "task_update" -> task_update(params)
      "task_comment" -> task_comment(params, opts)
      "dispatch_start" -> dispatch(:start_board, params)
      "dispatch_stop" -> dispatch(:stop_board, params)
      "dispatch_status" -> dispatch(:status, params)
      nil -> {:error, "missing required parameter: action"}
      action -> {:error, "unsupported kanban action: #{inspect(action)}"}
    end
  end

  defp coding_workflow_schema do
    %{
      "description" =>
        "board_create only. Explicit opt-in to isolated coding, exact-diff review, and a local branch commit before done. Omit or set false for coding-only behavior. Never publishes unless publish explicitly selects a mode.",
      "anyOf" => [
        %{"type" => "boolean", "enum" => [false]},
        %{
          "type" => "object",
          "additionalProperties" => false,
          "properties" => %{
            "reviewModel" => %{
              "type" => "string",
              "minLength" => 1,
              "description" => "Optional nonempty reviewer model (provider:model)."
            },
            "publish" => %{
              "description" =>
                "Omit or set false to keep commits local with no network publishing. Supply a mode only when publishing is explicitly authorized.",
              "anyOf" => [
                %{"type" => "boolean", "enum" => [false]},
                %{
                  "type" => "object",
                  "additionalProperties" => false,
                  "properties" => %{
                    "mode" => %{
                      "type" => "string",
                      "enum" => ["branch", "pull_request"],
                      "description" =>
                        "branch pushes the task branch; pull_request also opens a PR and records its link."
                    },
                    "remote" => %{
                      "type" => "string",
                      "minLength" => 1,
                      "description" => "Explicit Git remote name, such as origin."
                    },
                    "repository" => %{
                      "type" => "string",
                      "minLength" => 1,
                      "description" => "Required for pull_request: repository as owner/repo."
                    },
                    "base" => %{
                      "type" => "string",
                      "minLength" => 1,
                      "description" => "Required for pull_request: target branch, such as main."
                    },
                    "draft" => %{
                      "type" => "boolean",
                      "default" => true,
                      "description" => "Create pull requests as drafts by default."
                    }
                  },
                  "required" => ["mode", "remote"]
                }
              ]
            }
          }
        }
      ]
    }
  end

  defp dispatch(operation, params) do
    module = :"Elixir.LemonAutomation.KanbanDispatcher"
    concurrency = Map.get(params, "max_concurrency", 1)

    with {:ok, board_id} <- required_string(params, "board_id"),
         true <- is_integer(concurrency) and concurrency in 1..8,
         true <- Code.ensure_loaded?(module) and function_exported?(module, operation, 2) do
      opts =
        if operation == :start_board do
          [max_concurrency: concurrency, worker_opts: put_opt([], :model, params["model"])]
        else
          []
        end

      case apply(module, operation, [board_id, opts]) do
        {:ok, dispatch} -> result("kanban dispatch #{board_id}", %{dispatch: dispatch})
        {:error, reason} -> {:error, format_error(reason)}
      end
    else
      false -> {:error, "kanban dispatcher unavailable or max_concurrency must be 1..8"}
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, _ -> {:error, "kanban dispatcher unavailable"}
  end

  defp board_list(params) do
    opts =
      []
      |> put_opt(:status, params["status"])
      |> put_opt(:owner, params["owner"])
      |> put_opt(:workspace, params["workspace"])
      |> put_opt(:limit, params["limit"])

    result("kanban boards", %{boards: KanbanStore.list_boards(opts)})
  end

  defp board_create(params, cwd, opts) do
    with {:ok, name} <- required_string(params, "name"),
         {:ok, meta} <- coding_workflow_meta(params) do
      create_opts =
        []
        |> put_opt(:workspace, params["workspace"] || Keyword.get(opts, :kanban_workspace) || cwd)
        |> put_opt(:owner, params["owner"] || Keyword.get(opts, :agent_id))
        |> put_opt(:columns, params["columns"])
        |> put_opt(:meta, meta)

      case KanbanStore.create_board(name, create_opts) do
        {:ok, board} -> result("created kanban board #{board.id}", %{board: board})
        {:error, reason} -> {:error, format_error(reason)}
      end
    end
  end

  defp coding_workflow_meta(params) do
    case Map.fetch(params, "coding_workflow") do
      :error ->
        {:ok, nil}

      {:ok, settings} ->
        module = :"Elixir.LemonAutomation.KanbanGitWorkflow"

        cond do
          not (Code.ensure_loaded?(module) and function_exported?(module, :normalize, 1)) ->
            {:error, "kanban coding workflow unavailable"}

          not (is_map(settings) or settings == false) ->
            {:error, "coding_workflow must be an object or false"}

          is_map(settings) and not string_key_settings?(settings) ->
            {:error, "coding_workflow settings must use string keys"}

          true ->
            case apply(module, :normalize, [settings]) do
              {:ok, _runtime_config} -> {:ok, %{"codingWorkflow" => settings}}
              {:error, reason} -> {:error, format_error(reason)}
            end
        end
    end
  end

  defp string_key_settings?(settings) do
    Enum.all?(settings, fn {key, value} ->
      is_binary(key) and (not is_map(value) or string_key_settings?(value))
    end)
  end

  defp board_get(params) do
    with {:ok, board_id} <- required_string(params, "board_id"),
         {:ok, board} <- fetch_board(board_id) do
      payload = %{board: board}

      payload =
        if Map.get(params, "include_tasks", true) do
          Map.put(
            payload,
            :tasks,
            KanbanStore.list_tasks(board.id, limit: params["limit"] || 100)
          )
        else
          payload
        end

      result("kanban board #{board.id}", payload)
    end
  end

  defp task_list(params) do
    with {:ok, board_id} <- required_string(params, "board_id") do
      opts =
        []
        |> put_opt(:status, params["status"])
        |> put_opt(:assignee, params["assignee"])
        |> put_opt(:limit, params["limit"])

      result("kanban tasks", %{tasks: KanbanStore.list_tasks(board_id, opts)})
    end
  end

  defp task_get(params) do
    with {:ok, task_id} <- required_string(params, "task_id"),
         {:ok, task} <- fetch_task(task_id) do
      result("kanban task #{task.id}", %{task: task})
    end
  end

  defp task_create(params) do
    with {:ok, board_id} <- required_string(params, "board_id"),
         {:ok, title} <- required_string(params, "title") do
      opts =
        []
        |> put_opt(:description, params["description"])
        |> put_opt(:status, params["status"])
        |> put_opt(:priority, params["priority"])
        |> put_opt(:assignee, params["assignee"])
        |> put_opt(:worker_profile, params["worker_profile"])
        |> put_opt(:session_key, params["session_key"])
        |> put_opt(:run_id, params["run_id"])
        |> put_opt(:depends_on, params["depends_on"])

      case KanbanStore.create_task(board_id, title, opts) do
        {:ok, task} -> result("created kanban task #{task.id}", %{task: task})
        {:error, reason} -> {:error, format_error(reason)}
      end
    end
  end

  defp task_update(params) do
    with {:ok, task_id} <- required_string(params, "task_id") do
      attrs =
        %{}
        |> put_attr(:title, params["title"])
        |> put_attr(:description, params["description"])
        |> put_attr(:status, params["status"])
        |> put_attr(:priority, params["priority"])
        |> put_attr(:assignee, params["assignee"])
        |> put_attr(:worker_profile, params["worker_profile"])
        |> put_attr(:session_key, params["session_key"])
        |> put_attr(:run_id, params["run_id"])
        |> put_attr(:depends_on, params["depends_on"])

      case KanbanStore.update_task(task_id, attrs) do
        {:ok, task} -> result("updated kanban task #{task.id}", %{task: task})
        {:error, reason} -> {:error, format_error(reason)}
      end
    end
  end

  defp task_comment(params, opts) do
    with {:ok, task_id} <- required_string(params, "task_id"),
         {:ok, body} <- required_string(params, "body") do
      comment_opts =
        []
        |> put_opt(:author, params["author"] || Keyword.get(opts, :agent_id))

      case KanbanStore.add_comment(task_id, body, comment_opts) do
        {:ok, task} -> result("commented on kanban task #{task.id}", %{task: task})
        {:error, reason} -> {:error, format_error(reason)}
      end
    end
  end

  defp fetch_board(board_id) do
    case KanbanStore.get_board(board_id) do
      %{} = board when map_size(board) == 0 -> {:error, "board not found: #{board_id}"}
      board -> {:ok, board}
    end
  end

  defp fetch_task(task_id) do
    case KanbanStore.get_task(task_id) do
      %{} = task when map_size(task) == 0 -> {:error, "task not found: #{task_id}"}
      task -> {:ok, task}
    end
  end

  defp required_string(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: {:error, "#{key} is required"}, else: {:ok, value}

      _ ->
        {:error, "#{key} is required"}
    end
  end

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, _key, ""), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp put_attr(attrs, _key, nil), do: attrs
  defp put_attr(attrs, _key, ""), do: attrs
  defp put_attr(attrs, key, value), do: Map.put(attrs, key, value)

  defp result(title, details) do
    %AgentToolResult{
      content: [%TextContent{type: :text, text: Jason.encode!(details, pretty: true)}],
      details: Map.put(details, :title, title)
    }
  end

  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error(reason), do: inspect(reason)
end
