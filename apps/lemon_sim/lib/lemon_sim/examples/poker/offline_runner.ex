defmodule LemonSim.Examples.Poker.OfflineRunner do
  @moduledoc """
  Keyless poker self-play driven by a deterministic heuristic decider.

  Every seat plays the `"heuristic"` strategy: it rates its holding (pocket
  pairs and high cards preflop, made-hand category postflop), raises the
  minimum with strong hands, calls cheap bets with playable ones, and
  otherwise checks or folds. Occasional mixed decisions draw from a decider
  RNG seeded from `:seed`, so the same seed replays the same game.
  """

  alias LemonCore.MapHelpers
  alias LemonSim.Bench.Artifacts.Replay
  alias LemonSim.Examples.Poker
  alias LemonSim.Examples.Poker.{ActionSpace, Artifacts, Updater}
  alias LemonSim.Examples.Poker.Engine.{Card, HandRank, Table}
  alias LemonSim.Kernel.{State, Store}

  @default_max_turns 2_000
  @setup_opts [:player_count, :player_ids, :starting_stack, :max_hands, :small_blind, :big_blind]
  @tool_opts [include_note_tool?: false, include_say_tool?: false]

  @spec run_strategy(String.t() | atom(), keyword()) ::
          {:ok, %{state: State.t(), artifacts: map(), steps: non_neg_integer()}}
          | {:error, term()}
  def run_strategy(strategy, opts \\ [])

  def run_strategy(strategy, opts) when strategy in ["heuristic", :heuristic] do
    seed = Keyword.get(opts, :seed, 1)
    sim_id = Keyword.get(opts, :sim_id, "poker_heuristic_#{seed}")

    state =
      opts
      |> Keyword.take(@setup_opts)
      |> Keyword.merge(sim_id: sim_id, seed: seed)
      |> Poker.initial_state()

    config = Artifacts.replay_config(state)
    rng = :rand.seed_s(:exsss, {seed, seed + 11, seed + 29})

    max_turns =
      Keyword.get(opts, :driver_max_turns, Keyword.get(opts, :max_turns, @default_max_turns))

    IO.puts("Starting Poker offline heuristic self-play (seed #{seed})")

    with {:ok, final_state, batches, events} <- run_loop(state, rng, max_turns, 0, [], []),
         final_state = Artifacts.replay_finalize(final_state),
         :ok <- maybe_persist(final_state, opts),
         {:ok, artifacts} <-
           Artifacts.write_run_artifacts(
             final_state,
             events,
             [],
             Keyword.put(opts, :replay, %{config: config, batches: batches})
           ) do
      IO.puts(
        "Completed #{MapHelpers.get_key(final_state.world, :completed_hands)} hands in " <>
          "#{length(batches)} actions; winners: " <>
          Enum.join(MapHelpers.get_key(final_state.world, :winner_ids) || [], ", ")
      )

      {:ok, %{state: final_state, artifacts: artifacts, steps: length(batches)}}
    end
  end

  def run_strategy(strategy, _opts), do: {:error, {:unknown_offline_strategy, strategy}}

  # `batches` and `events` accumulate reversed.
  defp run_loop(state, rng, max_turns, turn, batches, events) do
    cond do
      MapHelpers.get_key(state.world, :status) == "game_over" ->
        {:ok, state, Enum.reverse(batches), Enum.reverse(events)}

      turn >= max_turns ->
        {:error, {:offline_turn_limit_exceeded, max_turns}}

      true ->
        with {:ok, event, next_rng} <- decide(state, rng),
             input = %{event | ts_ms: turn},
             {:ok, next_state, appended} <- Replay.apply_batch(state, [input], Updater) do
          run_loop(
            next_state,
            next_rng,
            max_turns,
            turn + 1,
            [[input] | batches],
            Enum.reverse(appended, events)
          )
        end
    end
  end

  defp decide(%State{} = state, rng) do
    table = MapHelpers.get_key(state.world, :table)

    with {:ok, legal} <- Table.legal_actions(table),
         {:ok, tools} <- ActionSpace.tools(state, @tool_opts) do
      player = Map.fetch!(table.hand.players, legal.seat)
      strength = hand_strength(player.hole_cards, table.hand.board || [])
      {roll, rng} = :rand.uniform_s(100, rng)
      {name, params} = choose_action(legal, strength, roll, table.big_blind)

      with %{} = tool <- Enum.find(tools, &(&1.name == name)),
           {:ok, %{details: %{"event" => event}}} <-
             tool.execute.("offline-heuristic", params, nil, nil) do
        {:ok, event, rng}
      else
        _ -> {:error, {:heuristic_action_failed, name}}
      end
    end
  end

  # strength: 0 weak, 1 playable, 2 good, 3 strong
  defp choose_action(legal, strength, roll, big_blind) do
    cond do
      strength >= 3 and is_map(legal.raise) ->
        {"raise_to", %{"total" => legal.raise.min}}

      strength >= 3 and is_map(legal.bet) ->
        {"bet_to", %{"total" => legal.bet.min}}

      strength == 2 and is_map(legal.bet) and roll <= 50 ->
        {"bet_to", %{"total" => legal.bet.min}}

      :check in legal.options ->
        {"check", %{}}

      strength >= 2 and :call in legal.options ->
        {"call", %{}}

      strength == 1 and :call in legal.options and legal.to_call <= big_blind * 3 ->
        {"call", %{}}

      strength == 0 and :call in legal.options and legal.to_call <= big_blind and roll <= 15 ->
        {"call", %{}}

      true ->
        {"fold", %{}}
    end
  end

  defp hand_strength(hole_cards, board) when length(hole_cards) + length(board) >= 5 do
    case HandRank.evaluate(hole_cards ++ board) do
      {:ok, %HandRank{category_value: category}} when category >= 3 -> 3
      {:ok, %HandRank{category_value: 2}} -> 2
      {:ok, %HandRank{category_value: 1}} -> 1
      _ -> 0
    end
  end

  defp hand_strength([first, second], _board) do
    high = max(Card.rank_value(first), Card.rank_value(second))
    low = min(Card.rank_value(first), Card.rank_value(second))

    cond do
      high == low and high >= 10 -> 3
      high == low -> 2
      low >= 11 -> 2
      high == 14 or (first.suit == second.suit and high - low == 1) -> 1
      low >= 9 -> 1
      true -> 0
    end
  end

  defp hand_strength(_hole_cards, _board), do: 0

  defp maybe_persist(state, opts) do
    if Keyword.get(opts, :persist?, false) do
      _ = Store.put_state(state)
    end

    :ok
  end
end
