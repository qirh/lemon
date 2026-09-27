defmodule LemonSimUi.HostedGame.Replay do
  @moduledoc """
  Verifies a hosted Werewolf room export by re-folding its recorded commands
  from the room seed with `LemonSim.Bench.Artifacts.Replay.fold/4`, checking
  every command's recorded state hash and the final state hash.
  """

  alias LemonSim.Bench.Artifacts.Replay, as: BenchReplay
  alias LemonSim.Examples.Werewolf
  alias LemonSim.Examples.Werewolf.RulesConfig
  alias LemonSim.Kernel.{Event, State}

  def verify(export) when is_map(export) do
    config = value(export, :config, %{})
    seats = value(export, :seats, %{})
    seed = value(config, :seed)
    player_ids = value(export, :player_ids, Map.keys(seats)) |> Enum.sort()

    initial_opts = [
      sim_id: "hosted_replay_verification",
      seed: seed,
      player_count: value(config, :player_count),
      generate_lore?: false
    ]

    initial_opts =
      if value(export, :match_number, 1) > 1 do
        Keyword.put(initial_opts, :player_ids, player_ids)
      else
        initial_opts
      end

    state = Werewolf.initial_state(initial_opts)

    if MapSet.new(Map.keys(state.world.players)) != MapSet.new(player_ids) do
      raise ArgumentError, "replay player IDs do not match the seeded game"
    end

    state =
      put_in(
        state.world[:rules],
        config
        |> value(:rules_preset)
        |> RulesConfig.for_preset()
        |> Map.put(:turn_timeout_seconds, value(config, :turn_timeout_seconds))
      )

    commands = export |> value(:replay, []) |> Enum.filter(&(value(&1, :kind) == "command"))
    expected_hashes = Enum.map(commands, &(&1 |> value(:data, %{}) |> value(:state_hash)))

    after_batch = fn index, next_state ->
      if state_hash(next_state) == Enum.at(expected_hashes, index),
        do: :ok,
        else: {:error, :command_state_hash_mismatch}
    end

    batches = Enum.map(commands, &command_events/1)

    case BenchReplay.fold(state, batches, Werewolf.Updater, after_batch: after_batch) do
      {:ok, final_state, _observed} ->
        if state_hash(final_state) == value(export, :final_state_hash) do
          {:ok, %{commands: value(export, :command_seq, 0), state_hash: state_hash(final_state)}}
        else
          {:error, :final_state_hash_mismatch}
        end

      {:error, {:replay_batch_rejected, _index, reason}} ->
        {:error, {:replay_event_rejected, reason}}

      {:error, _reason} = error ->
        error
    end
  rescue
    _ -> {:error, :invalid_replay}
  end

  def verify(_export), do: {:error, :invalid_replay}

  def state_hash(%State{} = state) do
    world = state.world |> Map.delete(:journals) |> Map.delete("journals")

    :crypto.hash(:sha256, :erlang.term_to_binary({state.version, world}))
    |> Base.url_encode64(padding: false)
  end

  defp command_events(entry) do
    entry
    |> value(:data, %{})
    |> value(:events, [])
    |> Enum.map(fn event -> Event.new(value(event, :kind), value(event, :payload, %{})) end)
  end

  defp value(map, key, default \\ nil) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end
end
