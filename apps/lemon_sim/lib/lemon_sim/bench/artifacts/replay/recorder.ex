defmodule LemonSim.Bench.Artifacts.Replay.Recorder do
  @moduledoc """
  Collects the input batches (and the events they appended) of a live run so
  its bundle can be replay-verified.

  Runners either call `record/3` after each ingest, or wrap
  `Runner.run_until_terminal/3` callbacks with `wrap_opts/2`. Recording is a
  no-op when the recorder is `nil`.
  """

  use Agent

  alias LemonSim.Bench.Artifacts.Replay
  alias LemonSim.Kernel.State
  alias LemonSim.LLM.Usage

  @doc """
  Starts a recorder.

  Options: `:config` (the domain's replay `config.json` map) and `:batches`
  (already-recorded input batches, e.g. when resuming from a checkpoint).
  """
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    Agent.start_link(fn ->
      %{
        config: Keyword.get(opts, :config),
        batches: Enum.reverse(Keyword.get(opts, :batches, [])),
        observed: [],
        before_recent: []
      }
    end)
  end

  @spec stop(pid() | nil) :: :ok
  def stop(nil), do: :ok

  def stop(recorder) when is_pid(recorder) do
    if Process.alive?(recorder), do: Agent.stop(recorder)
    :ok
  end

  @doc "Records one applied input batch and the events it appended."
  @spec record(pid() | nil, list(), list()) :: :ok
  def record(nil, _inputs, _appended), do: :ok

  def record(recorder, inputs, appended) when is_pid(recorder) do
    Agent.update(recorder, fn recording ->
      %{
        recording
        | batches: [inputs | recording.batches],
          observed: Enum.reverse(appended, recording.observed)
      }
    end)
  end

  @doc "Returns `%{config:, batches:, observed:}` in recording order."
  @spec recording(pid()) :: %{config: map() | nil, batches: list(), observed: list()}
  def recording(recorder) when is_pid(recorder) do
    Agent.get(recorder, fn recording ->
      %{
        config: recording.config,
        batches: Enum.reverse(recording.batches),
        observed: Enum.reverse(recording.observed)
      }
    end)
  end

  @doc """
  Wraps `:on_before_step`/`:on_after_step` so every `Runner.step/3` batch is
  recorded. The wrapped callbacks' return values are passed through; an
  `:on_after_step` that replaces the state breaks replay, so replay-verified
  games must keep those callbacks notify-only.
  """
  @spec wrap_opts(keyword(), pid() | nil) :: keyword()
  def wrap_opts(opts, nil), do: opts

  def wrap_opts(opts, recorder) when is_pid(recorder) do
    before_step = Keyword.get(opts, :on_before_step)
    after_step = Keyword.get(opts, :on_after_step)

    opts
    |> Keyword.put(:on_before_step, fn turn, %State{} = state ->
      Agent.update(recorder, &%{&1 | before_recent: state.recent_events})
      if is_function(before_step, 2), do: before_step.(turn, state), else: :ok
    end)
    |> Keyword.put(:on_after_step, fn turn, result ->
      record_step(recorder, result)
      if is_function(after_step, 2), do: after_step.(turn, result), else: :ok
    end)
  end

  @doc """
  Runs `run_fun` and, when `opts[:artifact_dir]` is set, records it and writes
  a replay-verifiable bundle with `writer` (`fn state, events, actions, opts`).

  `run_fun` receives the run opts (with `:replay_recorder` and
  `:usage_collector` added when recording) and returns the runner result.
  """
  @spec with_bundle(State.t(), keyword(), map(), function(), (keyword() -> term())) :: term()
  def with_bundle(%State{} = initial_state, opts, config, writer, run_fun)
      when is_list(opts) and is_map(config) and is_function(writer, 4) and
             is_function(run_fun, 1) do
    if is_binary(Keyword.get(opts, :artifact_dir)) do
      {:ok, recorder} = start_link(config: config)
      {usage_collector, owns_usage?} = usage_collector(initial_state.sim_id, opts)

      try do
        run_opts =
          opts
          |> Keyword.put(:replay_recorder, recorder)
          |> Keyword.put(:usage_collector, usage_collector)

        case run_fun.(run_opts) do
          {:ok, result} ->
            final_state = final_state(result)
            recording = recording(recorder)

            {:ok, _paths} =
              writer.(
                final_state,
                recording.observed,
                [],
                Keyword.put(run_opts, :replay, recording)
              )

            {:ok, result}

          other ->
            other
        end
      after
        stop(recorder)
        if owns_usage?, do: stop_agent(usage_collector)
      end
    else
      run_fun.(opts)
    end
  end

  defp record_step(recorder, %{state: %State{} = next_state} = result) do
    inputs = Map.get(result, :events, [])

    Agent.update(recorder, fn recording ->
      appended = Replay.appended_events(recording.before_recent, next_state.recent_events)

      %{
        recording
        | batches: [inputs | recording.batches],
          observed: Enum.reverse(appended, recording.observed),
          before_recent: next_state.recent_events
      }
    end)
  end

  defp record_step(_recorder, _result), do: :ok

  defp final_state(%State{} = state), do: state
  defp final_state(%{state: %State{} = state}), do: state

  defp usage_collector(sim_id, opts) do
    case Keyword.get(opts, :usage_collector) do
      collector when is_pid(collector) ->
        {collector, false}

      _ ->
        {:ok, collector} = Usage.start_link(sim_id)
        {collector, true}
    end
  end

  defp stop_agent(pid) do
    if Process.alive?(pid), do: Agent.stop(pid)
    :ok
  end
end
