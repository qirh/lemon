defmodule LemonSimUi.Demo.WerewolfHeuristic do
  @moduledoc """
  Keyless, deterministic Werewolf seat policy behind `mix lemon.sim.demo`
  (`SimManager.start_sim(:werewolf, offline_strategy: "heuristic")`).

  Each turn it asks `LemonSim.Examples.Werewolf.ActionSpace` for the active
  actor's legal tools, draws one tool and each required enum parameter from a
  threaded `:rand` `:exsss` state seeded from the world seed, fills required
  free-text parameters with short canned lines, and builds the authoritative
  event through `ActionSpace.execute_action/4`, the same validation path that
  hosted seats and the SimManager decision fallback use. The only strategy on
  top of uniform legal play: nobody abstains or targets themselves while
  another target is legal, and werewolves never target a fellow wolf when a
  non-wolf target is legal.

  The same game (seed, player count) always plays out identically: the
  decision is a pure function of the world and the threaded RNG state.
  """

  alias LemonCore.MapHelpers
  alias LemonSim.Examples.Werewolf.ActionSpace
  alias LemonSim.Kernel.{Event, State}

  @type rng :: :rand.state()

  @statements [
    "I want every vote explained today; quiet players worry me more than loud ones.",
    "My read is still forming, but last night's kill points away from the talkative seats.",
    "If I had to vote right now I would follow the strongest accusation on the table.",
    "Someone here keeps agreeing with everyone. That is who I want to hear from next.",
    "I trust the players who named a suspect early. Hedging this late looks like cover."
  ]

  @messages [
    "Let's compare notes: who has been dodging direct questions?",
    "I'll follow your lead tonight if you tell me who you trust.",
    "Keep your head down today; we can't afford to split the table.",
    "Watch who changes their vote at the last second. That's our tell."
  ]

  @reasons [
    "keeps deflecting instead of giving a read.",
    "pushed a vote and then went quiet when questioned.",
    "has defended every player who later looked suspicious."
  ]

  @doc """
  Builds the decision RNG for a game seed. A run resumed after
  `turns_completed` turns reseeds deterministically from the same seed.
  """
  @spec seed_rng(integer(), non_neg_integer()) :: rng()
  def seed_rng(seed, turns_completed \\ 0)
      when is_integer(seed) and is_integer(turns_completed) and turns_completed >= 0 do
    :rand.seed_s(:exsss, {seed, seed + 7, seed + 13 + turns_completed})
  end

  @doc """
  Chooses one legal action for the world's active actor and returns the
  resulting event with the advanced RNG state.
  """
  @spec decide(State.t(), rng()) :: {:ok, Event.t(), rng()} | {:error, term()}
  def decide(%State{} = state, rng) do
    actor_id = MapHelpers.get_key(state.world, :active_actor_id)

    with true <- is_binary(actor_id) || {:error, :no_active_actor},
         {:ok, tools} <- legal_tools(state),
         {tool, rng} = pick(tools, rng),
         {:ok, params, rng} <- build_params(tool.parameters, state, actor_id, rng),
         {:ok, event} <- ActionSpace.execute_action(state, actor_id, tool.name, params) do
      {:ok, event, rng}
    end
  end

  defp legal_tools(state) do
    case ActionSpace.tools(state, []) do
      {:ok, [_ | _] = tools} -> {:ok, tools}
      {:ok, []} -> {:error, :no_legal_action}
      {:error, _reason} = error -> error
    end
  end

  defp build_params(schema, state, actor_id, rng) do
    properties = Map.get(schema, "properties", %{})
    required = Map.get(schema, "required", [])

    {enum_keys, text_keys} =
      Enum.split_with(required, &is_list(get_in(properties, [&1, "enum"])))

    with {:ok, params, rng} <- pick_enum_values(enum_keys, properties, state, actor_id, rng) do
      {params, rng} =
        Enum.reduce(text_keys, {params, rng}, fn key, {acc, rng} ->
          {line, rng} = text_for(key, acc, rng)
          {Map.put(acc, key, line), rng}
        end)

      {:ok, params, rng}
    end
  end

  defp pick_enum_values(keys, properties, state, actor_id, rng) do
    Enum.reduce_while(keys, {:ok, %{}, rng}, fn key, {:ok, acc, rng} ->
      case properties |> get_in([key, "enum"]) |> preferred_options(state, actor_id) do
        [] ->
          {:halt, {:error, {:no_legal_value, key}}}

        options ->
          {value, rng} = pick(options, rng)
          {:cont, {:ok, Map.put(acc, key, value), rng}}
      end
    end)
  end

  defp preferred_options(options, state, actor_id) do
    players = MapHelpers.get_key(state.world, :players) || %{}
    wolf? = role(players, actor_id) == "werewolf"

    preferred =
      Enum.reject(options, fn option ->
        option == "skip" or option == actor_id or
          (wolf? and role(players, option) == "werewolf")
      end)

    if preferred == [], do: options, else: preferred
  end

  defp role(players, player_id) do
    players
    |> Map.get(player_id, %{})
    |> MapHelpers.get_key(:role)
    |> to_string()
  end

  defp text_for("reason", params, rng) do
    {reason, rng} = pick(@reasons, rng)
    {"#{Map.get(params, "target_id", "That player")} #{reason}", rng}
  end

  defp text_for("message", _params, rng), do: pick(@messages, rng)
  defp text_for(_key, _params, rng), do: pick(@statements, rng)

  defp pick(list, rng) do
    {index, rng} = :rand.uniform_s(length(list), rng)
    {Enum.at(list, index - 1), rng}
  end
end
