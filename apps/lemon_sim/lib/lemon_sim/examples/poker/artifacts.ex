defmodule LemonSim.Examples.Poker.Artifacts do
  @moduledoc """
  Writes replay-verifiable `lemon_sim.run.v1` bundles for poker runs.

  `config.json` records the seating, stacks, blinds, hand limit, and base
  seed that `Poker.initial_state/1` needs; every hand's deck derives from the
  base seed, so re-folding `inputs.jsonl` reproduces the run.
  """

  @behaviour LemonSim.Bench.Artifacts.Replay

  alias LemonCore.MapHelpers
  alias LemonSim.Bench.Artifacts.Bundle
  alias LemonSim.Bench.Artifacts.Replay
  alias LemonSim.Examples.Poker
  alias LemonSim.Examples.Poker.{Performance, Updater}
  alias LemonSim.Kernel.State

  @default_artifact_root "apps/lemon_sim/priv/game_logs/poker"
  @sim_version "1.0.0"

  @spec default_artifact_dir(String.t()) :: String.t()
  def default_artifact_dir(sim_id), do: Path.join(@default_artifact_root, sim_id)

  @spec write_run_artifacts(State.t(), list(), list(), keyword()) :: {:ok, map()}
  def write_run_artifacts(%State{} = state, events, actions, opts) do
    artifact_dir = Keyword.get(opts, :artifact_dir) || default_artifact_dir(state.sim_id)

    Bundle.write_scorecard_bundle(
      replay_finalize(state),
      events,
      actions,
      Keyword.merge(opts,
        artifact_dir: artifact_dir,
        scenario_id: "poker",
        version: @sim_version,
        ruleset_hash: ruleset_hash()
      )
    )
  end

  @doc "Builds the replay `config.json` map for a run that started from `state`."
  @spec replay_config(State.t()) :: map()
  def replay_config(%State{} = state) do
    world = state.world
    table = MapHelpers.get_key(world, :table)

    player_ids =
      world
      |> MapHelpers.get_key(:players)
      |> Enum.sort_by(fn {_player_id, player} -> MapHelpers.get_key(player, :seat) end)
      |> Enum.map(fn {player_id, _player} -> player_id end)

    %{
      "schema_version" => "lemon_sim.config.v1",
      "sim_id" => state.sim_id,
      "seed" => MapHelpers.get_key(world, :base_seed),
      "player_ids" => player_ids,
      "max_seats" => table.max_seats,
      "starting_stack" => MapHelpers.get_key(world, :starting_stack),
      "max_hands" => MapHelpers.get_key(world, :max_hands),
      "small_blind" => MapHelpers.get_key(world, :small_blind),
      "big_blind" => MapHelpers.get_key(world, :big_blind),
      "blind_schedule" => MapHelpers.get_key(world, :blind_schedule) || []
    }
  end

  @impl Replay
  def replay_updater, do: Updater

  @impl Replay
  def replay_initial_state(
        %{"sim_id" => sim_id, "seed" => seed, "player_ids" => [_ | _] = player_ids} = config,
        _final_world
      )
      when is_binary(sim_id) and is_integer(seed) do
    opts =
      [
        max_seats: config["max_seats"],
        starting_stack: config["starting_stack"],
        max_hands: config["max_hands"],
        small_blind: config["small_blind"],
        big_blind: config["big_blind"],
        blind_schedule: config["blind_schedule"]
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Keyword.merge(sim_id: sim_id, seed: seed, player_ids: player_ids)

    {:ok, Poker.initial_state(opts)}
  end

  def replay_initial_state(_config, _final_world), do: {:error, :invalid_replay_config}

  @doc "Attaches the objective performance summary every poker bundle records."
  @impl Replay
  def replay_finalize(%State{} = state) do
    %{state | world: Map.put(state.world, :performance, Performance.summarize(state.world))}
  end

  defp ruleset_hash do
    [
      "apps/lemon_sim/lib/lemon_sim/examples/poker.ex",
      "apps/lemon_sim/lib/lemon_sim/examples/poker/action_space.ex",
      "apps/lemon_sim/lib/lemon_sim/examples/poker/performance.ex",
      "apps/lemon_sim/lib/lemon_sim/examples/poker/updater.ex"
    ]
    |> Enum.map(fn path -> File.read!(path) end)
    |> Enum.join("\n")
    |> Bundle.sha256()
  rescue
    _ -> nil
  end
end
