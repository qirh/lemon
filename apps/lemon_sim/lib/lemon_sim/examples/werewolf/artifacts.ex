defmodule LemonSim.Examples.Werewolf.Artifacts do
  @moduledoc """
  Writes replay-verifiable `lemon_sim.run.v1` bundles for Werewolf runs.

  `config.json` records the seed and seating options `initial_state/1` needs
  to rebuild the pre-game world; run-identity overlays (per-seat model labels
  and any LLM-generated character profiles) are recorded explicitly because
  they are not derived from the seed.
  """

  @behaviour LemonSim.Bench.Artifacts.Replay

  import LemonSim.Examples.Helpers, only: [get: 2, get: 3]

  alias LemonSim.Bench.Artifacts.Bundle
  alias LemonSim.Bench.Artifacts.Replay
  alias LemonSim.Examples.Werewolf
  alias LemonSim.Examples.Werewolf.Updater
  alias LemonSim.Kernel.State

  @default_artifact_root "apps/lemon_sim/priv/game_logs/werewolf"
  @sim_version "1.0.0"
  @ruleset_files [
    "apps/lemon_sim/lib/lemon_sim/examples/werewolf.ex",
    "apps/lemon_sim/lib/lemon_sim/examples/werewolf/action_space.ex",
    "apps/lemon_sim/lib/lemon_sim/examples/werewolf/performance.ex",
    "apps/lemon_sim/lib/lemon_sim/examples/werewolf/roles.ex",
    "apps/lemon_sim/lib/lemon_sim/examples/werewolf/rules_config.ex",
    "apps/lemon_sim/lib/lemon_sim/examples/werewolf/updater.ex"
  ]

  @spec write_run_artifacts(State.t(), list(), list(), keyword()) :: {:ok, map()}
  def write_run_artifacts(%State{} = state, events, actions, opts) do
    artifact_dir =
      Keyword.get(opts, :artifact_dir) || Path.join(@default_artifact_root, state.sim_id)

    Bundle.write_scorecard_bundle(
      state,
      events,
      actions,
      Keyword.merge(opts,
        artifact_dir: artifact_dir,
        scenario_id: "werewolf",
        version: @sim_version,
        ruleset_hash: ruleset_hash()
      )
    )
  end

  @doc """
  Builds the replay `config.json` map for a run that started from `state`
  (after per-seat models were attached) with `initial_opts`.
  """
  @spec replay_config(State.t(), keyword()) :: map()
  def replay_config(%State{} = state, initial_opts) when is_list(initial_opts) do
    players = get(state.world, :players, %{})

    seat_models =
      players
      |> Enum.flat_map(fn {player_id, player} ->
        case get(player, :model) do
          nil -> []
          model -> [{player_id, model}]
        end
      end)
      |> Map.new()

    %{
      "schema_version" => "lemon_sim.config.v1",
      "sim_id" => state.sim_id,
      "seed" => get(state.world, :seed),
      "player_count" => map_size(players),
      "player_ids" => Keyword.get(initial_opts, :player_ids),
      "balanced_roles" => Keyword.get(initial_opts, :balanced_roles?, false) == true,
      "seat_models" => seat_models,
      "character_profiles" => get(state.world, :character_profiles, %{})
    }
  end

  @impl Replay
  def replay_updater, do: Updater

  @impl Replay
  def replay_initial_state(
        %{"sim_id" => sim_id, "seed" => seed, "player_count" => player_count} = config,
        _final_world
      )
      when is_binary(sim_id) and is_integer(seed) and is_integer(player_count) do
    opts =
      [
        sim_id: sim_id,
        seed: seed,
        player_count: player_count,
        balanced_roles?: Map.get(config, "balanced_roles") == true,
        generate_lore?: false
      ]
      |> maybe_put_player_ids(Map.get(config, "player_ids"))

    state = Werewolf.initial_state(opts)
    seat_models = Map.get(config, "seat_models") || %{}

    players =
      Map.new(get(state.world, :players, %{}), fn {player_id, player} ->
        case Map.get(seat_models, player_id) do
          nil -> {player_id, player}
          model -> {player_id, Map.put(player, :model, model)}
        end
      end)

    world =
      state.world
      |> Map.put(:players, players)
      |> Map.put(:character_profiles, Map.get(config, "character_profiles") || %{})

    {:ok, %{state | world: world}}
  end

  def replay_initial_state(_config, _final_world), do: {:error, :invalid_replay_config}

  @impl Replay
  def replay_finalize(state), do: state

  defp maybe_put_player_ids(opts, player_ids) when is_list(player_ids),
    do: Keyword.put(opts, :player_ids, player_ids)

  defp maybe_put_player_ids(opts, _player_ids), do: opts

  defp ruleset_hash do
    @ruleset_files
    |> Enum.map(&File.read!/1)
    |> Enum.join("\n")
    |> Bundle.sha256()
  rescue
    _ -> nil
  end
end
