defmodule LemonSkills.Tools.Goal do
  @moduledoc """
  Session-scoped durable coding goals. `tool/2` requires the canonical router
  `:session_key` and accepts `:agent_id`; `cwd` is the default repository target.
  Dispatch uses the running automation manager, never a tool-owned scheduler.
  """

  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAgent.Workspace.GoalStore
  alias LemonAi.Types.TextContent

  @manager :"Elixir.LemonAutomation.GoalLoopManager"
  @actions ~w(set status start stop pause resume run_once)

  @spec tool(String.t(), keyword()) :: AgentTool.t()
  def tool(cwd, opts \\ []) do
    %AgentTool{
      name: "goal",
      label: "Goal",
      description:
        "Set a durable coding goal in a repository, then start a bounded judge/work loop. run_once starts one asynchronous tick. status shows run IDs, progress and results. stop or pause cancels owned work and disables auto restart; resume only reactivates a paused goal, then start explicitly. Unknown outcomes retain ownership and cannot be retried until reconciled. Work edits the target repository directly, not an isolated worktree.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "action" => %{
            "type" => "string",
            "enum" => @actions,
            "description" =>
              "set defines the goal; status inspects it; start or run_once dispatch bounded work; stop, pause, and resume control its lifecycle."
          },
          "objective" => %{
            "type" => "string",
            "description" => "Concrete coding objective for set."
          },
          "cwd" => %{
            "type" => "string",
            "description" => "Repository for set; defaults to this tool's working directory."
          },
          "max_ticks" => %{
            "type" => "integer",
            "minimum" => 1,
            "maximum" => 20,
            "description" => "Bound on judge/work ticks for start (default 3)."
          },
          "model" => %{
            "type" => "string",
            "description" => "Optional provider:model for start/run_once."
          }
        },
        "required" => ["action"]
      },
      execute: &execute(&1, &2, &3, &4, cwd, opts)
    }
  end

  def execute(_id, params, signal, _on_update, cwd, opts) do
    with false <- signal != nil and LemonAgent.AbortSignal.aborted?(signal),
         {:ok, session_key} <- session_key(opts),
         {:ok, payload} <- dispatch(params["action"], session_key, params, cwd, opts) do
      details = Map.put(payload, :title, "goal #{params["action"]}")

      %AgentToolResult{
        content: [%TextContent{text: Jason.encode!(details, pretty: true)}],
        details: details,
        trust: :untrusted
      }
    else
      true -> {:error, "goal operation cancelled"}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, error_message(reason)}
    end
  end

  defp dispatch("set", session_key, params, cwd, opts) do
    with {:ok, objective} <- required_string(params["objective"], "objective"),
         {:ok, target} <- target_directory(params["cwd"], cwd),
         {:ok, goal} <-
           manager(:set_goal, [session_key, objective, [cwd: target, agent_id: opts[:agent_id]]]) do
      {:ok, %{goal: goal}}
    end
  end

  defp dispatch("status", session_key, _params, _cwd, _opts),
    do: manager(:status, [session_key])

  defp dispatch(action, session_key, params, _cwd, _opts) when action in ["start", "run_once"] do
    max_ticks = if action == "run_once", do: 1, else: Map.get(params, "max_ticks", 3)

    with true <- is_integer(max_ticks) and max_ticks in 1..20,
         {:ok, goal} <- fetch_goal(session_key),
         {:ok, _target} <- target_directory(goal.cwd, nil),
         {:ok, model_opts} <- model_options(params["model"]),
         {:ok, loop} <-
           manager(:start_loop, [session_key, [max_ticks: max_ticks, auto: false] ++ model_opts]) do
      {:ok, %{loop: loop, goal: GoalStore.get(session_key)}}
    else
      false -> {:error, "max_ticks must be 1..20"}
      error -> error
    end
  end

  defp dispatch(action, session_key, _params, _cwd, _opts) when action in ["stop", "pause"] do
    with {:ok, _goal} <- fetch_goal(session_key),
         {:ok, stopped} <- stop(session_key) do
      if action == "pause" do
        with {:ok, goal} <- GoalStore.pause(session_key) do
          {:ok, Map.put(stopped, :goal, goal)}
        end
      else
        {:ok, stopped}
      end
    end
  end

  defp dispatch("resume", session_key, _params, _cwd, _opts) do
    with {:ok, %{running: false}} <- manager(:status, [session_key]),
         {:ok, goal} <- fetch_goal(session_key) do
      if goal.status == "paused" do
        with {:ok, goal} <- GoalStore.resume(session_key), do: {:ok, %{goal: goal}}
      else
        {:error, "only a paused goal can be resumed"}
      end
    else
      {:ok, %{running: true}} -> {:error, :already_running}
      error -> error
    end
  end

  defp dispatch(_action, _session_key, _params, _cwd, _opts),
    do: {:error, "unsupported or missing goal action"}

  defp stop(session_key) do
    case manager(:stop_loop, [session_key, [mode: :hard]]) do
      {:error, :not_running} ->
        with {:ok, _goal} <- GoalStore.configure_loop_auto(session_key, false),
             {:ok, goal} <- GoalStore.record_loop_status(session_key, :stopped) do
          {:ok, %{goal: goal, router_abort: :not_needed}}
        end

      result ->
        result
    end
  end

  defp manager(operation, args) do
    if Code.ensure_loaded?(@manager) and function_exported?(@manager, operation, length(args)) do
      apply(@manager, operation, args)
    else
      {:error, :goal_runtime_unavailable}
    end
  catch
    :exit, {:noproc, _} -> {:error, :goal_runtime_unavailable}
    :exit, _ -> {:error, :outcome_unknown}
  end

  defp fetch_goal(session_key) do
    case GoalStore.get(session_key) do
      goal when map_size(goal) == 0 -> {:error, :not_found}
      goal -> {:ok, goal}
    end
  end

  defp session_key(opts), do: required_string(opts[:session_key], "session_key in tool context")

  defp target_directory(value, cwd) do
    with {:ok, path} <- required_string(value || cwd, "cwd") do
      target = if is_binary(cwd), do: Path.expand(path, cwd), else: Path.expand(path)

      if File.dir?(target),
        do: {:ok, target},
        else: {:error, "cwd must name an existing directory"}
    end
  end

  defp model_options(nil), do: {:ok, []}

  defp model_options(value) do
    with {:ok, model} <- required_string(value, "model"), do: {:ok, [model: model]}
  end

  defp required_string(value, name) when is_binary(value) do
    if String.trim(value) == "", do: {:error, "missing #{name}"}, else: {:ok, String.trim(value)}
  end

  defp required_string(_value, name), do: {:error, "missing #{name}"}

  defp error_message(:already_running),
    do: "goal has active or unresolved work; inspect status before retrying"

  defp error_message(:not_found), do: "no goal set for this session"
  defp error_message(:paused), do: "goal is paused; resume before starting"
  defp error_message(:completed), do: "goal is complete; set a new objective before starting"

  defp error_message(:outcome_unknown),
    do: "goal operation outcome unknown; inspect status, do not retry automatically"

  defp error_message(:goal_runtime_unavailable), do: "goal automation runtime unavailable"
  defp error_message(_reason), do: "goal operation failed"
end
