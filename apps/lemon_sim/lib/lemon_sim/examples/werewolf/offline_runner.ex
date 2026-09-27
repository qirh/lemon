defmodule LemonSim.Examples.Werewolf.OfflineRunner do
  @moduledoc """
  Keyless Werewolf self-play driven by a deterministic heuristic decider.

  Every seat is played by the `"heuristic"` strategy: wolves kill whoever has
  been accusing their pack, the seer investigates unchecked players and
  accuses confirmed wolves, the doctor protects a random living player, and
  the village votes the most-accused player. Choices the heuristic leaves open
  are drawn from a decider RNG seeded from `:seed`, so the same seed always
  produces the same game and the same bundle bytes (given a seed-deterministic
  `Werewolf.initial_state/1` and updater).
  """

  import LemonSim.Examples.Helpers, only: [get: 2, get: 3]

  alias LemonSim.Bench.Artifacts.Replay
  alias LemonSim.Examples.Werewolf
  alias LemonSim.Examples.Werewolf.{ActionSpace, Artifacts, Roles, Updater}
  alias LemonSim.Kernel.{State, Store}

  @default_max_turns 1_000
  @setup_opts [:player_count, :player_ids, :balanced_roles?]
  # Tools the heuristic prefers, in order, when several are offered. Item
  # tools are never used.
  @tool_preference ~w(
    choose_victim
    investigate_player
    protect_player
    wolf_chat
    request_meeting
    meeting_message
    cast_vote
    make_last_words
    make_statement
    sleep
  )

  @spec run_strategy(String.t() | atom(), keyword()) ::
          {:ok, %{state: State.t(), artifacts: map(), steps: non_neg_integer()}}
          | {:error, term()}
  def run_strategy(strategy, opts \\ [])

  def run_strategy(strategy, opts) when strategy in ["heuristic", :heuristic] do
    seed = Keyword.get(opts, :seed, 1)
    sim_id = Keyword.get(opts, :sim_id, "werewolf_heuristic_#{seed}")

    initial_opts =
      opts
      |> Keyword.take(@setup_opts)
      |> Keyword.merge(sim_id: sim_id, seed: seed, generate_lore?: false)

    state = Werewolf.initial_state(initial_opts)
    config = Artifacts.replay_config(state, initial_opts)
    rng = :rand.seed_s(:exsss, {seed, seed + 7, seed + 13})

    max_turns =
      Keyword.get(opts, :driver_max_turns, Keyword.get(opts, :max_turns, @default_max_turns))

    IO.puts("Starting Werewolf offline heuristic self-play (seed #{seed})")

    with {:ok, final_state, batches, events} <- run_loop(state, rng, max_turns, 0, [], []),
         :ok <- maybe_persist(final_state, opts),
         {:ok, artifacts} <-
           Artifacts.write_run_artifacts(
             final_state,
             events,
             [],
             Keyword.put(opts, :replay, %{config: config, batches: batches})
           ) do
      IO.puts(
        "Winner: #{get(final_state.world, :winner)} after #{length(batches)} actions " <>
          "(day #{get(final_state.world, :day_number)})"
      )

      {:ok, %{state: final_state, artifacts: artifacts, steps: length(batches)}}
    end
  end

  def run_strategy(strategy, _opts), do: {:error, {:unknown_offline_strategy, strategy}}

  # `batches` and `events` accumulate reversed.
  defp run_loop(state, rng, max_turns, turn, batches, events) do
    cond do
      get(state.world, :status) == "game_over" ->
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

  @doc """
  Picks the heuristic action for the active seat and returns the input event
  to feed `Werewolf.Updater`, plus the advanced decider RNG
  (an `:rand.seed_s/2` state).
  """
  @spec decide(State.t(), :rand.state()) ::
          {:ok, LemonSim.Kernel.Event.t(), :rand.state()} | {:error, term()}
  def decide(%State{} = state, rng) do
    world = state.world
    actor_id = get(world, :active_actor_id)

    with {:ok, tools} <- ActionSpace.tools(state, []),
         %{} = tool <- choose_tool(tools, world, actor_id) do
      {params, rng} = params_for(tool, world, actor_id, rng)

      case ActionSpace.execute_action(state, actor_id, tool.name, params) do
        {:ok, event} -> {:ok, event, rng}
        {:error, reason} -> {:error, {:heuristic_action_failed, tool.name, reason}}
      end
    else
      nil -> {:error, {:no_available_actions, actor_id, get(world, :phase)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp choose_tool(tools, world, actor_id) do
    by_name = Map.new(tools, &{&1.name, &1})

    if Map.has_key?(by_name, "make_accusation") and known_wolf(world, actor_id, nil) != nil do
      Map.fetch!(by_name, "make_accusation")
    else
      Enum.find_value(@tool_preference, &Map.get(by_name, &1))
    end
  end

  defp params_for(tool, world, actor_id, rng) do
    properties = Map.get(tool.parameters, "properties", %{})

    tool.parameters
    |> Map.get("required", [])
    |> Enum.reduce({%{}, rng}, fn key, {params, rng} ->
      {value, rng} =
        case get_in(properties, [key, "enum"]) do
          [_ | _] = options ->
            pick_option(tool.name, key, Enum.sort(options), world, actor_id, rng)

          _ ->
            {text_for(tool.name, key, world, actor_id), rng}
        end

      {Map.put(params, key, value), rng}
    end)
  end

  defp pick_option("choose_victim", "victim_id", options, world, _actor_id, rng),
    do: pick_top(options, &wolf_threat(world, &1), rng)

  defp pick_option("investigate_player", "target_id", options, world, _actor_id, rng) do
    checked = world |> get(:seer_history, []) |> Enum.map(&get(&1, :target))

    case options -- checked do
      [] -> pick_random(options, rng)
      unchecked -> pick_random(unchecked, rng)
    end
  end

  defp pick_option(tool, "target_id", options, world, actor_id, rng)
       when tool in ["cast_vote", "make_accusation"] do
    case known_wolf(world, actor_id, options) do
      nil -> pick_top(options, &suspicion(world, actor_id, &1), rng)
      wolf -> {wolf, rng}
    end
  end

  defp pick_option(_tool, _key, options, _world, _actor_id, rng), do: pick_random(options, rng)

  defp text_for("wolf_chat", _key, world, _actor_id) do
    target =
      world
      |> get(:players, %{})
      |> Roles.living_players()
      |> Enum.reject(fn {_id, player} -> get(player, :role) == "werewolf" end)
      |> Enum.map(fn {id, _player} -> id end)
      |> Enum.sort()
      |> Enum.max_by(&wolf_threat(world, &1), fn -> nil end)

    if target,
      do: "#{target} is the biggest threat to us. Let's take them out tonight.",
      else: "Let's keep our heads down and pick a quiet target."
  end

  defp text_for("make_accusation", "reason", world, actor_id) do
    case known_wolf(world, actor_id, nil) do
      nil -> "Their votes and statements do not add up."
      wolf -> "I investigated #{wolf} at night: they are a werewolf."
    end
  end

  defp text_for("make_statement", _key, world, actor_id) do
    case current_suspect(world, actor_id) do
      nil -> "I have no strong read yet; I'll vote with the strongest case on the table."
      suspect -> "My read is #{suspect}. I'm voting #{suspect} unless someone clears them."
    end
  end

  defp text_for("meeting_message", _key, world, actor_id) do
    case current_suspect(world, actor_id) do
      nil -> "Who do you trust least right now?"
      suspect -> "I'm suspicious of #{suspect}. What is your read?"
    end
  end

  defp text_for("make_last_words", _key, _world, _actor_id),
    do: "Trust the votes, not the speeches. Good luck."

  defp text_for(_tool, _key, _world, _actor_id), do: "No further comment."

  # A werewolf the actor confirmed as seer that is still alive and, when
  # `options` is given, a legal choice.
  defp known_wolf(world, actor_id, options) do
    players = get(world, :players, %{})

    if role_of(players, actor_id) == "seer" do
      world
      |> get(:seer_history, [])
      |> Enum.filter(&(get(&1, :role) == "werewolf"))
      |> Enum.map(&get(&1, :target))
      |> Enum.filter(&alive?(players, &1))
      |> Enum.filter(&(is_nil(options) or &1 in options))
      |> Enum.sort()
      |> List.first()
    end
  end

  defp current_suspect(world, actor_id) do
    candidates =
      world
      |> get(:players, %{})
      |> Roles.living_players()
      |> Enum.map(fn {id, _player} -> id end)
      |> Enum.reject(&(&1 == actor_id))
      |> Enum.sort()

    case known_wolf(world, actor_id, candidates) do
      nil ->
        best = Enum.max_by(candidates, &suspicion(world, actor_id, &1), fn -> nil end)
        if best && suspicion(world, actor_id, best) > 0, do: best

      wolf ->
        wolf
    end
  end

  # How strongly the public discussion points at `target`: accusations count
  # double, statements naming them count once. Wolves never pile onto their
  # own pack.
  defp suspicion(world, actor_id, target) do
    players = get(world, :players, %{})

    if role_of(players, actor_id) == "werewolf" and role_of(players, target) == "werewolf" do
      -1
    else
      world
      |> get(:discussion_transcript, [])
      |> Enum.reduce(0, fn entry, score ->
        cond do
          get(entry, :player) == target -> score
          get(entry, :target) == target -> score + 2
          String.contains?(to_string(get(entry, :statement, "")), target) -> score + 1
          true -> score
        end
      end)
    end
  end

  # How dangerous a villager is to the pack: accusations aimed at werewolves.
  defp wolf_threat(world, player_id) do
    players = get(world, :players, %{})

    world
    |> get(:discussion_transcript, [])
    |> Enum.count(fn entry ->
      get(entry, :player) == player_id and role_of(players, get(entry, :target)) == "werewolf"
    end)
  end

  defp pick_top(options, score_fun, rng) do
    best_score = options |> Enum.map(score_fun) |> Enum.max()
    options |> Enum.filter(&(score_fun.(&1) == best_score)) |> pick_random(rng)
  end

  defp pick_random(options, rng) do
    {index, rng} = :rand.uniform_s(length(options), rng)
    {Enum.at(options, index - 1), rng}
  end

  defp role_of(players, player_id) do
    case Map.get(players, player_id) do
      nil -> nil
      player -> get(player, :role)
    end
  end

  defp alive?(players, player_id) do
    case Map.get(players, player_id) do
      nil -> false
      player -> get(player, :status, "alive") == "alive"
    end
  end

  defp maybe_persist(state, opts) do
    if Keyword.get(opts, :persist?, false) do
      _ = Store.put_state(state)
    end

    :ok
  end
end
