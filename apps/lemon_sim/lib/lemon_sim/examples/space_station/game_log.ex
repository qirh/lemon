defmodule LemonSim.Examples.SpaceStation.GameLog do
  @moduledoc false

  use LemonSim.Examples.GameLog

  def log_step(log, step, world, events \\ [])
  def log_step(nil, _step, _world, _events), do: :ok

  def log_step(log, step, world, events) do
    SharedGameLog.log_step(log, step, world, events, %{
      round: MapHelpers.get_key(world, :round),
      active_actor: MapHelpers.get_key(world, :active_actor_id),
      phase: MapHelpers.get_key(world, :phase),
      alert_level: compute_alert_level(world)
    })
  end

  def log_game_over(nil, _step, _world), do: :ok

  def log_game_over(log, step, world) do
    SharedGameLog.log_terminal(log, "game_over", step, world, %{
      winner: MapHelpers.get_key(world, :winner),
      round: MapHelpers.get_key(world, :round),
      phase: MapHelpers.get_key(world, :phase),
      alert_level: compute_alert_level(world)
    })
  end

  defp compute_alert_level(world) do
    systems = MapHelpers.get_key(world, :systems) || %{}

    min_health =
      systems
      |> Map.values()
      |> Enum.map(fn
        %{health: health} -> health
        %{"health" => health} -> health
        _system -> 100
      end)
      |> Enum.min(fn -> 100 end)

    cond do
      min_health <= 20 -> "critical"
      min_health <= 50 -> "warning"
      true -> "normal"
    end
  end
end
