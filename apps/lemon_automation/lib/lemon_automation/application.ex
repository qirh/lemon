defmodule LemonAutomation.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        {Task.Supervisor, name: LemonAutomation.TaskSupervisor},
        LemonAutomation.CronManager
      ] ++
        daily_brief_sync() ++
        [
          LemonAutomation.GoalContinuationManager,
          LemonAutomation.GoalLoopManager,
          LemonAutomation.KanbanDispatcher,
          LemonAutomation.SkillCuratorManager,
          LemonAutomation.SynthesisRunnerManager
        ]

    opts = [strategy: :one_for_one, name: LemonAutomation.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Reconcile the opt-in `[automation] daily_brief` job once CronManager is up.
  defp daily_brief_sync do
    if Application.get_env(:lemon_automation, :daily_brief_sync, true) do
      [
        Supervisor.child_spec(
          {Task, &LemonAutomation.Heartbeat.sync_daily_brief/0},
          id: :daily_brief_sync
        )
      ]
    else
      []
    end
  end
end
