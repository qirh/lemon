defmodule CodingAgent.Tools.Task do
  @moduledoc """
  Task tool for the coding agent.

  Spawns a new CodingAgent session to run a focused subtask and returns the
  final assistant response.
  """

  alias LemonAgent.AbortSignal
  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias CodingAgent.Tools.Task.{Control, Execution, Messaging, Params, Result, Wait}

  @doc """
  Returns the Task tool definition.
  """
  @spec tool(cwd :: String.t(), opts :: keyword()) :: AgentTool.t()
  def tool(cwd, opts \\ []) do
    description = Params.build_description(cwd)
    agent_enum = Params.build_agent_enum(cwd)

    %AgentTool{
      name: "task",
      description: description,
      label: "Run Task",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "action" => %{
            "type" => "string",
            "description" =>
              "Run tasks, poll/join/get results, message/steer a child, or cancel it",
            "enum" => ["run", "poll", "join", "wait", "get", "message", "steer", "cancel"]
          },
          "name" => %{
            "type" => "string",
            "description" =>
              "Optional unique live task name for agent:// messaging; 1-64 ASCII letters, digits, underscores or hyphens, starting with a letter"
          },
          "to" => %{
            "type" => "string",
            "description" =>
              "Message target: agent://<task-id-or-name>, agent://parent, or agent://all"
          },
          "description" => %{
            "type" => "string",
            "description" => "Short (3-5 words) description of the task"
          },
          "prompt" => %{
            "type" => "string",
            "description" => "The task for the agent to perform"
          },
          "message" => %{
            "type" => "string",
            "description" =>
              "Instruction delivered to the child at its next safe steering boundary"
          },
          "worktree" => %{
            "type" => "boolean",
            "description" =>
              "Create an isolated git worktree from HEAD; retain it and its branch for review"
          },
          "task_id" => %{
            "type" => "string",
            "description" => "Task id to poll (when action=poll) or get (when action=get)"
          },
          "task_ids" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Task ids to join (when action=join)"
          },
          "mode" => %{
            "type" => "string",
            "enum" => ["wait_all", "wait_any"],
            "description" => "Join mode for action=join (default: wait_all)"
          },
          "model" => %{
            "type" => "string",
            "description" => "Optional model override for the native task session"
          },
          "thinking_level" => %{
            "type" => "string",
            "description" => "Optional thinking level override for the native task session"
          },
          "agent" => %{
            "type" => "string",
            "description" =>
              "Named agent persona: scout (read-only discovery), reviewer (read-only review), task-executor, or a local .lemon/agents/*.md definition"
          },
          "output_schema" => %{
            "type" => ["object", "boolean"],
            "description" =>
              "JSON Schema for the child's final JSON response. Invalid output fails the task; validated data is returned as structured_output."
          },
          "async" => %{
            "type" => "boolean",
            "description" =>
              "When true (recommended), run in background and return task_id immediately. Use async=true by default to keep user conversations responsive. Only use async=false for simple tasks that complete instantly."
          },
          "auto_followup" => %{
            "type" => "boolean",
            "description" =>
              "When true (default), async task completion is automatically posted back into this session."
          },
          "cwd" => %{
            "type" => "string",
            "description" => "Optional working directory override for this task run"
          },
          "tool_policy" => %{
            "type" => "object",
            "description" => "Optional tool policy override for the task session"
          },
          "meta" => %{
            "type" => "object",
            "description" =>
              "Optional metadata map attached to task lifecycle and async followup routing"
          },
          "session_key" => %{
            "type" => "string",
            "description" =>
              "Optional parent session key override used for async followup routing and lifecycle metadata"
          },
          "agent_id" => %{
            "type" => "string",
            "description" =>
              "Optional parent agent id override used for async followup routing and lifecycle metadata"
          },
          "queue_mode" => %{
            "type" => "string",
            "enum" => Params.valid_queue_modes(),
            "description" =>
              "Queue mode for async followup routing via router fallback (default: followup)"
          }
        },
        "required" => []
      },
      execute: &execute(&1, &2, &3, &4, cwd, opts)
    }
    |> Params.maybe_add_enum(agent_enum)
    |> add_batch_schema()
  end

  @doc """
  Execute the task tool.
  """
  @spec execute(
          tool_call_id :: String.t(),
          params :: map(),
          signal :: reference() | nil,
          on_update :: (AgentToolResult.t() -> :ok) | nil,
          cwd :: String.t(),
          opts :: keyword()
        ) :: AgentToolResult.t() | {:error, term()}
  def execute(tool_call_id, params, signal, on_update, cwd, opts) do
    if AbortSignal.aborted?(signal) do
      {:error, "Operation aborted"}
    else
      case Params.normalize_action(Map.get(params, "action")) do
        "wait" ->
          Wait.execute(params, signal, opts)

        action when action in ["message", "steer"] ->
          Messaging.send(params["to"] || params["task_id"], params["message"], opts)

        action when action in ["poll", "join", "get", "cancel"] ->
          with :ok <- authorize_action(action, params, opts) do
            case action do
              "poll" -> Result.do_poll(params)
              "join" -> Result.do_join(params, signal)
              "get" -> Result.do_get(params)
              "cancel" -> cancel_child(params, opts)
            end
          end

        "run" ->
          if Map.has_key?(params, "tasks"),
            do: run_batch(tool_call_id, params, signal, on_update, cwd, opts),
            else: do_execute(tool_call_id, params, signal, on_update, cwd, opts)

        _ ->
          {:error, "Unknown task action"}
      end
    end
  end

  defp do_execute(tool_call_id, params, signal, on_update, cwd, opts) do
    with {:ok, validated} <- Params.validate_run_params(params, cwd),
         :ok <- Params.check_budget_and_policy(validated, opts) do
      Execution.run(tool_call_id, validated, signal, on_update, cwd, opts)
    end
  end

  defp add_batch_schema(tool) do
    child_properties =
      Map.take(tool.parameters["properties"], [
        "description",
        "name",
        "prompt",
        "agent",
        "output_schema",
        "model",
        "thinking_level",
        "cwd",
        "worktree",
        "tool_policy"
      ])

    tasks = %{
      "type" => "array",
      "minItems" => 1,
      "maxItems" => 32,
      "description" =>
        "Independent children launched together. Common top-level options are inherited. Use action=join with returned task_ids to aggregate.",
      "items" => %{"type" => "object", "properties" => child_properties, "required" => ["prompt"]}
    }

    %{tool | parameters: put_in(tool.parameters, ["properties", "tasks"], tasks)}
  end

  defp authorize_action(action, params, opts) do
    ids =
      if action == "join",
        do: Map.get(params, "task_ids") || Map.get(params, "task_id"),
        else: Map.get(params, "task_id")

    ids = if is_binary(ids), do: [ids], else: ids

    if is_list(ids) and ids != [] and Enum.all?(ids, &is_binary/1) do
      Enum.reduce_while(ids, :ok, fn id, :ok ->
        case Control.authorize(id, opts) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    else
      # Let the action's existing validator explain malformed IDs.
      :ok
    end
  end

  defp cancel_child(params, opts) do
    case Map.get(params, "task_id") do
      id when is_binary(id) ->
        with :ok <- Control.command(id, "cancel", nil, opts) do
          %AgentToolResult{
            content: [%LemonAi.Types.TextContent{text: "Cancellation requested: #{id}"}],
            details: %{task_id: id, status: "cancelling"}
          }
        end

      _ ->
        {:error, "task_id is required"}
    end
  end

  defp run_batch(tool_call_id, params, signal, on_update, cwd, opts) do
    tasks = params["tasks"]

    if is_list(tasks) and length(tasks) in 1..32 and Enum.all?(tasks, &is_map/1) do
      defaults = Map.drop(params, ["tasks", "action"])

      validated =
        Enum.map(tasks, fn task ->
          child = Map.merge(defaults, task) |> Map.put("async", true)

          child =
            if params["async"] == false, do: Map.put(child, "auto_followup", false), else: child

          Params.validate_run_params(child, cwd)
        end)

      with nil <- Enum.find(validated, &match?({:error, _}, &1)),
           :ok <- unique_task_names(validated) do
        results =
          Enum.map(validated, fn {:ok, child} ->
            with :ok <- Params.check_budget_and_policy(child, opts) do
              Execution.run(tool_call_id, child, signal, on_update, cwd, opts)
            end
          end)

        receipts =
          Enum.map(results, fn
            %AgentToolResult{details: details} -> details
            {:error, reason} -> %{status: "error", error: reason}
          end)

        task_ids = for %{task_id: id} <- receipts, do: id

        if params["async"] == false and task_ids != [] do
          case Result.do_join(%{"task_ids" => task_ids}, signal) do
            %AgentToolResult{} = result ->
              %{result | details: Map.put(result.details, :launches, receipts)}

            error ->
              error
          end
        else
          %AgentToolResult{
            content: [%LemonAi.Types.TextContent{text: Jason.encode!(%{tasks: receipts})}],
            details: %{tasks: receipts, task_ids: task_ids, status: "queued"}
          }
        end
      else
        {:error, _} = error -> error
      end
    else
      {:error, "tasks must contain 1 to 32 task objects"}
    end
  end

  defp unique_task_names(validated) do
    names = for {:ok, %{name: name}} <- validated, not is_nil(name), do: name

    if length(names) == length(Enum.uniq(names)),
      do: :ok,
      else: {:error, "Task names must be unique within a batch"}
  end
end
