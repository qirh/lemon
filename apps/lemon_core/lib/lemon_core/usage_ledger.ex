defmodule LemonCore.UsageLedger do
  @moduledoc """
  Records every finalized run's token usage and cost into `LemonCore.UsageStore`.

  Wired as a `LemonCore.Store` finalize-run hook (see `config/config.exs`):

      finalize_run_hooks: [{LemonCore.UsageLedger, :handle_finalize_run}]

  The hook runs inside the store process, so it only casts to this server, which
  serializes the read-modify-write of the daily record and the `:current`
  summary. Delivery is at least once; a bounded set of recently recorded run IDs
  keeps a retried finalization from counting twice.

  Each UTC day's record (key `"YYYY-MM-DD"`) keeps the historical shape read by
  `usage.cost` and `LemonCore.UsageDiagnostics` (`total_cost`, provider-keyed
  `breakdown`/`requests`/`tokens`) plus:

    * `models` — `"provider:model"` → `%{provider, model, cost, requests, input, output}`
    * `sessions` — session key → `%{cost, requests, input, output, last_at_ms}`,
      bounded to 100 per day; runs beyond that are counted in
      `sessions_omitted`.

  The `:current` summary carries its `date` and restarts each UTC day, so it is
  "today" for `usage.status`. Only counts, costs, provider/model identifiers and
  session keys are stored — never prompts, answers or credentials.
  """

  use GenServer

  alias LemonCore.UsageStore

  @max_sessions_per_day 100
  @recent_run_ids 1_000
  @max_label_bytes 128

  @input_keys [:input_tokens, :input, :prompt_tokens]
  @output_keys [:output_tokens, :output, :completion_tokens]
  @cache_read_keys [:cache_read_input_tokens, :cached_input_tokens, :cache_read]
  @cache_write_keys [:cache_creation_input_tokens, :cache_write_input_tokens, :cache_write]

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  `LemonCore.Store` finalize-run hook. Never blocks or raises in the store.
  """
  @spec handle_finalize_run(map()) :: :ok
  def handle_finalize_run(event), do: handle_finalize_run(__MODULE__, event)

  @spec handle_finalize_run(GenServer.server(), map()) :: :ok
  def handle_finalize_run(server, %{run_id: run_id, summary: summary} = event)
      when is_map(summary) do
    case entry(run_id, Map.get(event, :session_key), summary) do
      nil -> :ok
      entry -> GenServer.cast(server, {:record, entry})
    end

    :ok
  catch
    :exit, _ -> :ok
  end

  def handle_finalize_run(_server, _event), do: :ok

  @doc """
  Records one run synchronously (tests and callers outside the store hook).
  `entry` is the map produced from a finalized run summary: `:run_id`,
  `:session_key`, `:provider`, `:model`, `:input`, `:output`, `:cost`.
  """
  @spec record(GenServer.server(), map()) :: :ok
  def record(server \\ __MODULE__, entry) when is_map(entry),
    do: GenServer.call(server, {:record, entry})

  @doc """
  Builds a usage entry from a finalized run summary, or `nil` when the run
  reported no usage at all.
  """
  @spec entry(term(), term(), map()) :: map() | nil
  def entry(run_id, session_key, summary) when is_map(summary) do
    completed = field(summary, :completed) || %{}
    usage = completed |> field(:usage) |> plain_map()
    meta = summary |> field(:meta) |> plain_map()

    input = first_integer(usage, @input_keys)
    output = first_integer(usage, @output_keys)

    cache =
      (first_integer(usage, @cache_read_keys) || 0) +
        (first_integer(usage, @cache_write_keys) || 0)

    cost = cost(usage)

    if Enum.all?([input, output, cost], &is_nil/1) do
      nil
    else
      {provider, model} = provider_model(meta)

      %{
        run_id: run_id,
        session_key: label(session_key || field(summary, :session_key)),
        provider: provider,
        model: model,
        input: (input || 0) + if(cache_inclusive?(usage), do: 0, else: cache),
        output: output || 0,
        cost: cost || 0.0
      }
    end
  rescue
    _ -> nil
  end

  def entry(_run_id, _session_key, _summary), do: nil

  # -- GenServer ---------------------------------------------------------------

  @impl true
  def init(_opts), do: {:ok, %{recent: MapSet.new(), order: :queue.new()}}

  @impl true
  def handle_cast({:record, entry}, state), do: {:noreply, do_record(entry, state)}

  @impl true
  def handle_call({:record, entry}, _from, state), do: {:reply, :ok, do_record(entry, state)}

  defp do_record(%{run_id: run_id} = entry, state) when not is_nil(run_id) do
    if MapSet.member?(state.recent, run_id) do
      state
    else
      safe_write(entry)
      remember(state, run_id)
    end
  end

  defp do_record(entry, state) do
    safe_write(entry)
    state
  end

  defp remember(state, run_id) do
    recent = MapSet.put(state.recent, run_id)
    order = :queue.in(run_id, state.order)

    if MapSet.size(recent) > @recent_run_ids do
      {{:value, oldest}, order} = :queue.out(order)
      %{state | recent: MapSet.delete(recent, oldest), order: order}
    else
      %{state | recent: recent, order: order}
    end
  end

  defp safe_write(entry) do
    today = Date.utc_today() |> Date.to_iso8601()
    now_ms = System.system_time(:millisecond)

    record = UsageStore.get_record(today) || %{date: today}
    UsageStore.put_record(today, add_to_record(record, entry, today, now_ms))

    summary =
      case UsageStore.get_summary(:current) do
        %{date: ^today} = summary -> summary
        _ -> %{date: today}
      end

    UsageStore.put_summary(:current, add_to_summary(summary, entry))
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  @doc false
  def add_to_record(record, entry, date, now_ms) do
    provider = entry.provider
    record = Map.put(record, :date, date)

    record
    |> Map.put(:total_cost, number(record[:total_cost]) + entry.cost)
    |> Map.put(:breakdown, bump(record[:breakdown], provider, entry.cost))
    |> Map.put(:requests, bump(record[:requests], provider, 1))
    |> Map.put(:tokens, bump_tokens(record[:tokens], provider, entry))
    |> Map.put(:models, bump_model(record[:models], entry))
    |> add_session(entry, now_ms)
  end

  defp add_to_summary(summary, entry) do
    totals = summary[:total_tokens] || %{}

    summary
    |> Map.put(:total_cost, number(summary[:total_cost]) + entry.cost)
    |> Map.put(:total_requests, integer(summary[:total_requests]) + 1)
    |> Map.put(:total_tokens, %{
      input: integer(totals[:input]) + entry.input,
      output: integer(totals[:output]) + entry.output
    })
    |> Map.put(:breakdown, bump(summary[:breakdown], entry.provider, entry.cost))
    |> Map.put(:requests, bump(summary[:requests], entry.provider, 1))
    |> Map.put(:tokens, bump_tokens(summary[:tokens], entry.provider, entry))
  end

  defp add_session(record, %{session_key: nil}, _now_ms), do: record

  defp add_session(record, entry, now_ms) do
    sessions = record[:sessions] || %{}
    key = entry.session_key

    cond do
      Map.has_key?(sessions, key) or map_size(sessions) < @max_sessions_per_day ->
        current = Map.get(sessions, key, %{cost: 0.0, requests: 0, input: 0, output: 0})

        Map.put(
          record,
          :sessions,
          Map.put(sessions, key, %{
            cost: number(current[:cost]) + entry.cost,
            requests: integer(current[:requests]) + 1,
            input: integer(current[:input]) + entry.input,
            output: integer(current[:output]) + entry.output,
            last_at_ms: now_ms
          })
        )

      true ->
        Map.put(record, :sessions_omitted, integer(record[:sessions_omitted]) + 1)
    end
  end

  defp bump(map, key, amount) do
    map = map || %{}
    Map.put(map, key, (Map.get(map, key) || 0) + amount)
  end

  defp bump_tokens(map, provider, entry) do
    map = map || %{}
    current = Map.get(map, provider) || %{}

    Map.put(map, provider, %{
      input: integer(current[:input] || current["input"]) + entry.input,
      output: integer(current[:output] || current["output"]) + entry.output
    })
  end

  defp bump_model(map, entry) do
    map = map || %{}
    key = "#{entry.provider}:#{entry.model}"
    current = Map.get(map, key) || %{}

    Map.put(map, key, %{
      provider: entry.provider,
      model: entry.model,
      cost: number(current[:cost]) + entry.cost,
      requests: integer(current[:requests]) + 1,
      input: integer(current[:input]) + entry.input,
      output: integer(current[:output]) + entry.output
    })
  end

  # -- Extraction ----------------------------------------------------------------

  defp provider_model(meta) do
    model = label(field(meta, :model))
    provider = label(field(meta, :provider))

    case {provider, model && String.split(model, ":", parts: 2)} do
      {_, nil} -> {provider || "unknown", "unknown"}
      {nil, [p, m]} when p != "" and m != "" -> {p, m}
      {provider, [p, m]} when p == provider and m != "" -> {provider, m}
      {provider, _} -> {provider || "unknown", model}
    end
  end

  defp label(value) when is_atom(value) and not is_nil(value) and not is_boolean(value),
    do: label(Atom.to_string(value))

  defp label(value) when is_binary(value) do
    value = String.trim(value)

    if value == "" or not String.valid?(value),
      do: nil,
      else: binary_part(value, 0, min(byte_size(value), @max_label_bytes))
  end

  defp label(_), do: nil

  defp cost(usage) do
    case field(usage, :cost) do
      %{} = cost -> to_float(field(plain_map(cost), :total))
      cost -> to_float(cost)
    end
  end

  # `:prompt_tokens` already includes cached input in the APIs that report it.
  defp cache_inclusive?(usage) do
    is_nil(first_integer(usage, [:input_tokens, :input])) and
      is_integer(first_integer(usage, [:prompt_tokens]))
  end

  defp first_integer(usage, keys) do
    Enum.find_value(keys, fn key ->
      case field(usage, key) do
        value when is_integer(value) and value >= 0 -> value
        _ -> nil
      end
    end)
  end

  defp plain_map(%{__struct__: _} = struct), do: Map.from_struct(struct)
  defp plain_map(map) when is_map(map), do: map
  defp plain_map(_), do: %{}

  defp field(map, key) when is_map(map) do
    case Map.get(map, key) do
      nil -> Map.get(map, Atom.to_string(key))
      value -> value
    end
  end

  defp field(_map, _key), do: nil

  defp to_float(value) when is_number(value) and value >= 0, do: value * 1.0
  defp to_float(_), do: nil

  defp number(value) when is_number(value), do: value * 1.0
  defp number(_), do: 0.0

  defp integer(value) when is_integer(value), do: value
  defp integer(_), do: 0
end
