defmodule LemonSim.Examples.Courtroom.GameLog do
  @moduledoc false

  use LemonSim.Examples.GameLog

  def log_step(log, step, world, events \\ [])
  def log_step(nil, _step, _world, _events), do: :ok

  def log_step(log, step, world, events) do
    SharedGameLog.log_step(log, step, world, events, %{
      phase: MapHelpers.get_key(world, :phase),
      active_actor: MapHelpers.get_key(world, :active_actor_id)
    })
  end

  def log_verdict(nil, _step, _world), do: :ok

  def log_verdict(log, step, world) do
    SharedGameLog.log_terminal(log, "verdict", step, world, %{
      outcome: MapHelpers.get_key(world, :outcome),
      winner: MapHelpers.get_key(world, :winner),
      verdict_votes: MapHelpers.get_key(world, :verdict_votes)
    })
  end
end
