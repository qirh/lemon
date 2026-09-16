defmodule LemonSim.Examples.Poker.GameLog do
  @moduledoc false

  use LemonSim.Examples.GameLog

  def log_step(log, step, world, events \\ [])
  def log_step(nil, _step, _world, _events), do: :ok

  def log_step(log, step, world, events) do
    SharedGameLog.log_step(log, step, world, events, %{
      status: MapHelpers.get_key(world, :status),
      current_actor_id: MapHelpers.get_key(world, :current_actor_id),
      completed_hands: MapHelpers.get_key(world, :completed_hands)
    })
  end

  def log_game_over(nil, _step, _world), do: :ok

  def log_game_over(log, step, world) do
    SharedGameLog.log_terminal(log, "game_over", step, world, %{
      winner: MapHelpers.get_key(world, :winner)
    })
  end
end
