defmodule LemonAutomation.RunNotifications do
  @moduledoc """
  Binds automation runs to their supervision channel before submission and hands
  terminal facts to channels. Channels owns rendering, durable delivery and
  platform authorization; automation never calls an adapter or builds buttons.
  """
  alias LemonAutomation.CronDelivery
  alias LemonAgent.Workspace.{GoalStore, KanbanStore}
  require Logger

  def bind_cron(job, params), do: bind(CronDelivery.target(job, job.session_key), params)

  def bind_goal(goal, params) do
    bind(target(goal.meta, goal.session_key), params)
  end

  def bind_kanban(task, params) do
    board = KanbanStore.get_board(task.board_id)
    session = get_in(board, [:meta, "notificationSessionKey"]) || task.session_key
    bind(target(board[:meta] || %{}, session), params)
  end

  def cron_finished(job, run, summary) do
    route = CronDelivery.target(job, (job && job.session_key) || get_in(run.meta, [:session_key]))
    invocation_session = run.meta[:router_session_key] || run.meta["router_session_key"]

    route =
      if is_binary(invocation_session),
        do: bound_target(run.run_id, invocation_session, route),
        else: route

    notice = %{
      kind: :cron,
      id: run.job_id,
      run_id: run.run_id || run.id,
      status: terminal_status(run.status),
      title: (job && job.name) || run.meta[:job_name] || "Scheduled task",
      summary: summary
    }

    deliver(route, notice)
  end

  def kanban_finished(task, lease_id) do
    board = KanbanStore.get_board(task.board_id)
    checkpoint = task.meta["codingWorkflow"] || %{}

    session =
      if checkpoint["reviewRunId"] == task.run_id,
        do: checkpoint["reviewSessionKey"] || task.session_key,
        else: task.session_key

    fallback =
      target(board[:meta] || %{}, get_in(board, [:meta, "notificationSessionKey"]) || session)

    route = bound_target(task.run_id, session, fallback)

    status =
      if task.status == "done",
        do: :completed,
        else:
          if(get_in(task.meta, ["lastFailure", "reason"]) == "cancelled",
            do: :cancelled,
            else: :failed
          )

    notice = %{
      kind: :kanban,
      id: task.id,
      run_id: task.run_id || "lease_#{lease_id}",
      status: status,
      title: task.title,
      summary:
        get_in(task.meta, ["kanbanRun", "output"]) || get_in(task.meta, ["lastFailure", "reason"]),
      commit_sha: checkpoint["commitSha"],
      pr_url: checkpoint["prUrl"]
    }

    deliver(route, notice)
  end

  def goal_finished(session_key, loop_status) do
    goal = GoalStore.get(session_key)
    loop = get_in(goal, [:meta, "goalLoop"]) || %{}
    run_id = loop["lastRunId"]

    status =
      cond do
        goal[:status] == "completed" -> :completed
        loop_status == :stopped -> :cancelled
        goal[:status] == "paused" or loop_status in [:error, :limit_reached] -> :failed
        true -> nil
      end

    if status && is_binary(run_id) do
      # Judges execute under their own deterministic child session.
      session =
        if loop["lastRunKind"] == "judge", do: session_key <> ":goal_judge", else: session_key

      route = bound_target(run_id, session, target(goal.meta, session_key))

      summary =
        get_in(goal.meta, ["lastResult", "output"]) || get_in(loop, ["lastVerdict", "reason"]) ||
          loop["lastError"] ||
          if(status == :failed,
            do: "Goal paused or bounded loop ended before completion.",
            else: nil
          )

      deliver(route, %{
        kind: :goal,
        id: goal.id,
        run_id: run_id,
        status: status,
        title: "Coding goal",
        summary: summary
      })
    else
      :ok
    end
  end

  defp target(meta, session_key),
    do: CronDelivery.target_for(meta["deliverTo"] || meta[:deliver_to], session_key)

  defp bind(:none, _params), do: :ok

  defp bind({:ok, target}, params),
    do: service(:bind_run, [params.run_id, params.session_key, target])

  defp bound_target(nil, _session, fallback), do: fallback

  defp bound_target(run_id, session, fallback) do
    case service(:target_for_run, [run_id, session]) do
      :none -> fallback
      result -> result
    end
  end

  defp deliver(:none, _notice), do: :ok

  defp deliver({:ok, target}, notice) do
    result = service(:notify, [target, notice])

    if result != :ok,
      do:
        Logger.warning(
          "Automation channel notice admission failed kind=#{notice.kind} status=#{notice.status}"
        )

    result
  end

  defp deliver({:error, _} = error, _notice), do: error

  defp service(function, args) do
    module = Module.concat([LemonChannels, Supervision])

    if Code.ensure_loaded?(module) and function_exported?(module, function, length(args)),
      do: apply(module, function, args),
      else: {:error, :channels_unavailable}
  rescue
    _ -> {:error, :channels_unavailable}
  catch
    :exit, _ -> {:error, :outcome_unknown}
  end

  defp terminal_status(:completed), do: :completed
  defp terminal_status(status) when status in [:aborted, :cancelled], do: :cancelled
  defp terminal_status(_), do: :failed
end
