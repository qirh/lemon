defmodule LemonSim.Examples.SeededDeterminismTest do
  @moduledoc """
  Kept arenas must be a pure function of their seed and event sequence: other
  consumers of the process-global `:rand` state must not change the outcome.
  """

  use ExUnit.Case, async: true

  alias LemonSim.Examples.{Poker, Werewolf}
  alias LemonSim.Examples.Poker.Engine.Table
  alias LemonSim.Kernel.{Rng, Runner, State}

  @max_steps 600

  describe "werewolf" do
    test "same seed yields the same final world despite interleaved :rand use" do
      :rand.seed(:exsss, {1, 2, 3})
      first = play_werewolf(4_242)

      :rand.seed(:exsss, {97, 98, 99})
      second = play_werewolf(4_242)

      assert state_hash(first) == state_hash(second)

      # The run must actually exercise updater randomness (evidence, wandering,
      # village events, items), not just the seeded setup.
      assert first.world.rng_state != Werewolf.initial_world(player_count: 6, seed: 4_242).rng_state
    end

    test "the seed, not the process RNG, decides the world" do
      :rand.seed(:exsss, {5, 5, 5})
      first = Werewolf.initial_world(player_count: 6, seed: 11)
      :rand.seed(:exsss, {5, 5, 5})
      other = Werewolf.initial_world(player_count: 6, seed: 12)

      assert first.seed == 11
      assert first.rng_state != other.rng_state
      assert Werewolf.initial_world(player_count: 6, seed: 11) == first
    end

    test "worlds without an rng_state are rejected instead of falling back to :rand" do
      assert_raise ArgumentError, ~r/rng_state/, fn -> Rng.fetch!(%{players: %{}}) end
    end
  end

  describe "poker" do
    test "same seed yields the same final world despite interleaved :rand use" do
      :rand.seed(:exsss, {1, 2, 3})
      first = play_poker(31)

      :rand.seed(:exsss, {97, 98, 99})
      second = play_poker(31)

      assert first.world.completed_hands == 4
      assert state_hash(first) == state_hash(second)
      refute state_hash(first) == state_hash(play_poker(32))
    end

    test "a hand cannot start without a seed or an explicit deck" do
      {:ok, table} = Table.seat_player(Table.new("unseeded"), 1, "player_1", 1_000)
      {:ok, table} = Table.seat_player(table, 2, "player_2", 1_000)

      assert {:error, :missing_seed} = Table.start_hand(table)
    end
  end

  defp play_werewolf(seed) do
    [player_count: 6, seed: seed, sim_id: "ww-determinism", generate_lore?: false]
    |> Werewolf.initial_state()
    |> drive_werewolf(0)
  end

  defp drive_werewolf(%State{} = state, steps) do
    if state.world.status != "in_progress" or steps >= @max_steps do
      state
    else
      _ = :rand.uniform()
      {:ok, events} = Werewolf.ActionSpace.fallback_events(state, :determinism_test)

      {:ok, next_state, _signal} =
        Runner.ingest_events(state, events, Werewolf.Updater, halt_on_decide?: false)

      drive_werewolf(next_state, steps + 1)
    end
  end

  defp play_poker(seed) do
    [player_count: 4, max_hands: 4, seed: seed, sim_id: "pkr-determinism"]
    |> Poker.initial_state()
    |> drive_poker(0)
  end

  defp drive_poker(%State{} = state, steps) do
    if state.world.status != "in_progress" or steps >= @max_steps do
      state
    else
      _ = :rand.uniform()
      table = state.world.table
      {:ok, legal} = Table.legal_actions(table)
      player = table.hand.players[legal.seat]

      action =
        cond do
          :call in legal.options -> "call"
          :check in legal.options -> "check"
          true -> "fold"
        end

      event = %{
        "kind" => "poker_action",
        "payload" => %{"player_id" => player.player_id, "seat" => player.seat, "action" => action}
      }

      {:ok, next_state, _signal} = Poker.Updater.apply_event(state, event, [])
      drive_poker(next_state, steps + 1)
    end
  end

  defp state_hash(%State{} = state) do
    :crypto.hash(:sha256, :erlang.term_to_binary({state.version, state.world}))
  end
end
