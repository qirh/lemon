defmodule LemonSim.Examples.StockMarket.GameLog do
  @moduledoc false

  use LemonSim.Examples.GameLog

  def log_step(log, step, world, events \\ [])
  def log_step(nil, _step, _world, _events), do: :ok

  def log_step(log, step, world, events) do
    SharedGameLog.log_step(log, step, world, events, %{
      round: MapHelpers.get_key(world, :round),
      active_actor: MapHelpers.get_key(world, :active_actor_id),
      phase: MapHelpers.get_key(world, :phase)
    })
  end

  def log_game_over(nil, _step, _world), do: :ok

  def log_game_over(log, step, world) do
    SharedGameLog.log_terminal(log, "game_over", step, world, %{
      winner: MapHelpers.get_key(world, :winner)
    })
  end
end
