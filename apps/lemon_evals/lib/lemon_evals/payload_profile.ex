defmodule LemonEvals.PayloadProfile do
  @moduledoc """
  Opt-in, in-memory Codex request/usage profiler for a dedicated live-eval daemon.

  Install after boot with `install!/2`. The offline Python worker requires
  tiktoken and writes only counts, tool names, and hashes to an owner-only JSONL
  file. Raw request bodies never enter artifacts. Normal runtime execution is
  unchanged unless the operator explicitly installs this development adapter.
  """
  use GenServer

  def install!(path, opts \\ []) do
    python = Keyword.get(opts, :python, System.find_executable("python3"))
    {:ok, pid} = GenServer.start_link(__MODULE__, {Path.expand(path), python}, name: __MODULE__)
    Application.put_env(:lemon_gateway, :executor, LemonEvals.PayloadProfile.Executor)
    pid
  end

  def record(event, run_id, data, metadata) do
    metadata = Map.take(metadata, [:provider, :model, :session_id]) |> Map.put(:run_id, run_id)
    GenServer.cast(__MODULE__, {:record, event, data, metadata})
  end

  @impl true
  def init({path, python}) when is_binary(python) do
    script = Path.join(:code.priv_dir(:lemon_evals), "payload_profile.py")

    port =
      Port.open({:spawn_executable, python}, [
        :binary,
        :use_stdio,
        :exit_status,
        {:line, 1_048_576},
        {:args, [script, path]}
      ])

    receive do
      {^port, {:data, {:eol, line}}} ->
        case Jason.decode(line) do
          {:ok, %{"event" => "ready"}} -> {:ok, %{port: port}}
          _ -> {:stop, :profiling_worker_unavailable}
        end

      {^port, {:exit_status, _}} ->
        {:stop, :profiling_worker_unavailable}
    after
      30_000 ->
        Port.close(port)
        {:stop, :profiling_worker_timeout}
    end
  end

  @impl true
  def handle_cast({:record, event, data, metadata}, state) do
    true =
      Port.command(
        state.port,
        Jason.encode!(%{event: event, data: data, metadata: metadata}) <> "\n"
      )

    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    case Jason.decode(line) do
      {:ok, %{"event" => "recorded"}} -> {:noreply, state}
      _ -> {:stop, :profiling_worker_failed, state}
    end
  end

  def handle_info({port, {:exit_status, _}}, %{port: port} = state),
    do: {:stop, :profiling_worker_failed, state}

  @impl true
  def format_status(status) do
    status |> Map.put(:message, :redacted) |> Map.put(:reason, :redacted) |> Map.put(:log, [])
  end
end

defmodule LemonEvals.PayloadProfile.Executor do
  @moduledoc false
  @behaviour LemonGateway.Executor
  alias LemonAi.Types.StreamOptions

  @impl true
  def start_run(request, opts, sink) do
    base = Keyword.get(opts, :stream_options) || %StreamOptions{}

    callbacks = %{
      base
      | on_payload: fn body, metadata ->
          if is_function(base.on_payload, 2), do: base.on_payload.(body, metadata)
          LemonEvals.PayloadProfile.record(:payload, request.run_id, body, metadata)
        end,
        on_usage: fn usage, metadata ->
          if is_function(base.on_usage, 2), do: base.on_usage.(usage, metadata)
          LemonEvals.PayloadProfile.record(:usage, request.run_id, usage, metadata)
        end
    }

    CodingAgent.Executor.start_run(request, Keyword.put(opts, :stream_options, callbacks), sink)
  end

  @impl true
  defdelegate cancel(context), to: CodingAgent.Executor
  @impl true
  defdelegate steer(context, text), to: CodingAgent.Executor
  @impl true
  defdelegate redirect(context, text), to: CodingAgent.Executor
end
