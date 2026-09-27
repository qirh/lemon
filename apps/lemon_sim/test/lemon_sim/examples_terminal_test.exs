defmodule LemonSim.ExamplesTerminalTest do
  use ExUnit.Case, async: true

  alias LemonSim.Examples
  alias LemonSim.Examples.{Poker, TicTacToe, VendingBench, Werewolf}
  alias LemonSim.Kernel.State

  test "each scenario's own terminal statuses end its run" do
    for {scenario, status} <- [
          {TicTacToe, "won"},
          {TicTacToe, "draw"},
          {VendingBench, "complete"},
          {VendingBench, "bankrupt"},
          {Werewolf, "game_over"},
          {Poker, "game_over"}
        ] do
      assert status in scenario.terminal_statuses()
      assert Examples.terminal?(State.new(sim_id: "t", world: %{status: status}))
    end
  end

  test "in-progress, missing, and lifecycle-only statuses are not terminal" do
    for world <- [%{status: "in_progress"}, %{}, %{status: "running"}, %{status: nil}] do
      refute Examples.terminal?(world)
    end

    refute Examples.terminal?(nil)
  end

  test "string-keyed worlds restored from JSON are recognized" do
    assert Examples.terminal?(%{"status" => "bankrupt"})
    assert Examples.terminal?(%{"status" => "won"})
    refute Examples.terminal?(%{"status" => "in_progress"})
  end

  test "a fresh scenario world is not terminal" do
    refute Examples.terminal?(TicTacToe.initial_state())
    refute Examples.terminal?(Werewolf.initial_state(seed: 1))
    refute Examples.terminal?(Poker.initial_state(seed: 1))
    refute Examples.terminal?(VendingBench.initial_state(sim_id: "vb_terminal_fresh"))
  end
end
