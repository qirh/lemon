defmodule LemonSim.Bench.Artifacts.Replay do
  @moduledoc """
  Event-refold replay verification for `lemon_sim.run.v1` bundles.

  A replay-capable bundle records every batch of input events it fed to the
  domain updater in `inputs.jsonl` (one `{"events": [...]}` object per
  ingest call, with the exact `ts_ms`/`meta` that were applied). Verification
  rebuilds the initial state from `config.json` (seed and setup options),
  re-folds each batch through the domain updater, and requires that:

    * the events the updater appended reproduce `events.jsonl` line for line
    * the refolded final world equals `final_world.json`

  so `final_world.json` (and therefore the recomputed scorecard) provably
  follows from the seed and the recorded inputs. Domains opt in by
  implementing this module's callbacks and being listed in `@domains`;
  bundles of those domains without `inputs.jsonl`/`config.json` fail
  verification.
  """

  alias LemonSim.Bench.Artifacts.Bundle
  alias LemonSim.Kernel.{Event, Runner, State}

  @doc "Updater module that folds input events for this domain."
  @callback replay_updater() :: module()

  @doc """
  Rebuilds the pre-run state from the bundle's decoded `config.json`.

  `final_world` is the decoded `final_world.json`; domains may only read
  run-identity fields from it that the updater never changes (e.g. model
  labels), never gameplay state.
  """
  @callback replay_initial_state(config :: map(), final_world :: map()) ::
              {:ok, State.t()} | {:error, term()}

  @doc "Post-fold transformation the bundle writer applied before writing `final_world.json`."
  @callback replay_finalize(State.t()) :: State.t()

  @inputs_file "inputs.jsonl"
  @config_file "config.json"

  @domains %{
    "vending_bench" => LemonSim.Examples.VendingBench.Artifacts,
    "werewolf" => LemonSim.Examples.Werewolf.Artifacts,
    "poker" => LemonSim.Examples.Poker.Artifacts
  }

  @doc "Sim ids whose bundles must pass replay verification."
  @spec supported_domains() :: [String.t()]
  def supported_domains, do: @domains |> Map.keys() |> Enum.sort()

  @spec supported?(String.t()) :: boolean()
  def supported?(sim_id) when is_binary(sim_id), do: Map.has_key?(@domains, sim_id)
  def supported?(_sim_id), do: false

  @doc "Bundle files a replay-capable domain must hash."
  @spec required_files() :: [String.t()]
  def required_files, do: [@config_file, @inputs_file]

  @doc """
  Applies one input batch the way `Runner.step/3` does and returns the events
  the updater appended to `recent_events`.
  """
  @spec apply_batch(State.t(), [Event.t() | map()], module()) ::
          {:ok, State.t(), [Event.t()]} | {:error, term()}
  def apply_batch(%State{} = state, events, updater) when is_list(events) and is_atom(updater) do
    case Runner.ingest_events(state, events, updater, halt_on_decide?: false) do
      {:ok, next_state, _signal} ->
        {:ok, next_state, appended_events(state.recent_events, next_state.recent_events)}

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Returns the suffix of `after_recent` that was appended after `before_recent`
  inside the bounded recent-event window.
  """
  @spec appended_events([Event.t()], [Event.t()]) :: [Event.t()]
  def appended_events(before_recent, after_recent) do
    max_overlap = min(length(before_recent), length(after_recent))

    overlap =
      max_overlap..0//-1
      |> Enum.find(0, fn count ->
        Enum.take(before_recent, -count) == Enum.take(after_recent, count)
      end)

    Enum.drop(after_recent, overlap)
  end

  @doc """
  Folds input batches through `updater`, returning the final state and the
  concatenated appended-event stream.

  `:after_batch` (`fn index, state -> :ok | {:error, reason}`) may reject a
  batch result, e.g. to compare per-command state hashes.
  """
  @spec fold(State.t(), [[Event.t() | map()]], module(), keyword()) ::
          {:ok, State.t(), [Event.t()]} | {:error, term()}
  def fold(%State{} = state, batches, updater, opts \\ []) when is_list(batches) do
    after_batch = Keyword.get(opts, :after_batch, fn _index, _state -> :ok end)

    batches
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, state, []}, fn {events, index}, {:ok, acc_state, observed} ->
      case apply_batch(acc_state, events, updater) do
        {:ok, next_state, appended} ->
          case after_batch.(index, next_state) do
            :ok -> {:cont, {:ok, next_state, Enum.reverse(appended, observed)}}
            {:error, _reason} = error -> {:halt, error}
          end

        {:error, reason} ->
          {:halt, {:error, {:replay_batch_rejected, index, reason}}}
      end
    end)
    |> case do
      {:ok, final_state, observed} -> {:ok, final_state, Enum.reverse(observed)}
      {:error, _reason} = error -> error
    end
  end

  @doc "Encodes input batches as `inputs.jsonl` content."
  @spec inputs_jsonl([[Event.t() | map()]]) :: String.t()
  def inputs_jsonl(batches) when is_list(batches) do
    Enum.map_join(batches, fn events ->
      encoded = Enum.map(events, &(&1 |> Event.new() |> Bundle.jsonable()))
      Jason.encode!(%{"events" => encoded}) <> "\n"
    end)
  end

  @doc "Decodes `inputs.jsonl` content into input batches of `Event` structs."
  @spec decode_inputs(String.t()) :: {:ok, [[Event.t()]]} | {:error, term()}
  def decode_inputs(body) when is_binary(body) do
    body
    |> String.split("\n", trim: true)
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {line, line_no}, {:ok, acc} ->
      case Jason.decode(line) do
        {:ok, %{"events" => events}} when is_list(events) ->
          if Enum.all?(events, &valid_event_map?/1) do
            {:cont, {:ok, [Enum.map(events, &Event.new/1) | acc]}}
          else
            {:halt, {:error, {:invalid_replay_input, line_no}}}
          end

        _ ->
          {:halt, {:error, {:invalid_replay_input, line_no}}}
      end
    end)
    |> case do
      {:ok, batches} -> {:ok, Enum.reverse(batches)}
      error -> error
    end
  end

  @doc """
  Reads the replay recording a bundle writer was handed: either an explicit
  `replay: %{config: map | nil, batches: [...]}` map or a live
  `replay_recorder:` pid. Returns `nil` when the run was not recorded.
  """
  @spec recording_from_opts(keyword()) :: map() | nil
  def recording_from_opts(opts) when is_list(opts) do
    case {Keyword.get(opts, :replay), Keyword.get(opts, :replay_recorder)} do
      {%{batches: batches} = recording, _recorder} when is_list(batches) -> recording
      {_replay, recorder} when is_pid(recorder) -> __MODULE__.Recorder.recording(recorder)
      _ -> nil
    end
  end

  @doc """
  Replays a bundle when its domain declares replay support.

  Returns `{:ok, :unsupported}` for domains without replay support and
  `{:ok, %{batches: n, events: m}}` after a successful refold.
  """
  @spec verify_bundle(String.t(), map()) :: {:ok, :unsupported | map()} | {:error, term()}
  def verify_bundle(artifact_dir, %{"sim" => %{"id" => sim_id}} = manifest)
      when is_binary(artifact_dir) do
    case Map.fetch(@domains, sim_id) do
      :error -> {:ok, :unsupported}
      {:ok, domain} -> replay_domain(artifact_dir, manifest, domain)
    end
  end

  def verify_bundle(_artifact_dir, _manifest), do: {:ok, :unsupported}

  defp replay_domain(artifact_dir, manifest, domain) do
    with {:ok, config} <- read_json(artifact_dir, @config_file),
         {:ok, final_world} <- read_json(artifact_dir, "final_world.json"),
         {:ok, inputs_body} <- read_file(artifact_dir, @inputs_file),
         {:ok, batches} <- decode_inputs(inputs_body),
         {:ok, recorded_events} <- read_jsonl(artifact_dir, "events.jsonl"),
         :ok <- verify_seed(manifest, config),
         {:ok, %State{} = initial_state} <- domain.replay_initial_state(config, final_world),
         {:ok, final_state, observed} <- fold(initial_state, batches, domain.replay_updater()),
         final_state <- domain.replay_finalize(final_state),
         :ok <- compare_events(observed, recorded_events),
         :ok <- compare_world(final_state.world, final_world) do
      {:ok, %{batches: length(batches), events: length(observed)}}
    end
  rescue
    error -> {:error, {:replay_crashed, Exception.message(error)}}
  end

  defp verify_seed(%{"sim" => %{"seed" => seed}}, config) when not is_nil(seed) do
    if Map.get(config, "seed") == seed,
      do: :ok,
      else: {:error, {:replay_mismatch, :seed}}
  end

  defp verify_seed(_manifest, _config), do: :ok

  defp compare_events(observed, recorded) do
    replayed =
      observed
      |> Bundle.jsonl()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    mismatch =
      replayed
      |> Enum.zip(recorded)
      |> Enum.with_index(1)
      |> Enum.find(fn {{replayed_event, recorded_event}, _line} ->
        replayed_event != recorded_event
      end)

    cond do
      mismatch != nil ->
        {_pair, line} = mismatch
        {:error, {:replay_mismatch, {:events_jsonl_line, line}}}

      length(replayed) != length(recorded) ->
        {:error, {:replay_mismatch, {:event_count, length(recorded), length(replayed)}}}

      true ->
        :ok
    end
  end

  defp compare_world(world, recorded_world) do
    replayed_world = world |> Bundle.jsonable() |> Jason.encode!() |> Jason.decode!()

    if replayed_world == recorded_world do
      :ok
    else
      key =
        (Map.keys(replayed_world) ++ Map.keys(recorded_world))
        |> Enum.uniq()
        |> Enum.sort()
        |> Enum.find(&(Map.get(replayed_world, &1) != Map.get(recorded_world, &1)))

      {:error, {:replay_mismatch, {:final_world, key}}}
    end
  end

  defp valid_event_map?(%{"kind" => kind, "payload" => payload})
       when is_binary(kind) and is_map(payload),
       do: true

  defp valid_event_map?(_event), do: false

  defp read_file(artifact_dir, file) do
    case File.read(Path.join(artifact_dir, file)) do
      {:ok, body} -> {:ok, body}
      {:error, reason} -> {:error, {:missing_replay_file, file, reason}}
    end
  end

  defp read_json(artifact_dir, file) do
    with {:ok, body} <- read_file(artifact_dir, file) do
      case Jason.decode(body) do
        {:ok, %{} = json} -> {:ok, json}
        _ -> {:error, {:invalid_replay_file, file}}
      end
    end
  end

  defp read_jsonl(artifact_dir, file) do
    with {:ok, body} <- read_file(artifact_dir, file) do
      body
      |> String.split("\n", trim: true)
      |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
        case Jason.decode(line) do
          {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
          {:error, _reason} -> {:halt, {:error, {:invalid_replay_file, file}}}
        end
      end)
      |> case do
        {:ok, entries} -> {:ok, Enum.reverse(entries)}
        error -> error
      end
    end
  end
end
