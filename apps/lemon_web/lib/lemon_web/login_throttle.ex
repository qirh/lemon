defmodule LemonWeb.LoginThrottle do
  @moduledoc """
  Bounded per-peer throttle for failed operator logins.

  After `@max_failures` failed attempts inside `@window_ms`, further attempts
  from the same peer address are refused until the window ends. Successful
  logins clear the peer's record. The table holds at most `@max_peers` entries;
  when full, expired entries are swept and the oldest are dropped.
  """

  use GenServer

  @table __MODULE__
  @max_failures 5
  @window_ms 60_000
  @max_peers 1_024

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Returns `:ok` or `{:error, :throttled, retry_after_seconds}`."
  @spec check(term()) :: :ok | {:error, :throttled, pos_integer()}
  def check(peer) do
    now = now_ms()

    case :ets.lookup(@table, peer) do
      [{^peer, count, started}] when count >= @max_failures and now - started < @window_ms ->
        {:error, :throttled, max(div(@window_ms - (now - started), 1000), 1)}

      _ ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  @doc "Records one failed attempt from `peer`."
  @spec record_failure(term()) :: :ok
  def record_failure(peer), do: GenServer.call(__MODULE__, {:failure, peer})

  @doc "Clears `peer` after a successful login."
  @spec clear(term()) :: :ok
  def clear(peer) do
    :ets.delete(@table, peer)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:failure, peer}, _from, state) do
    now = now_ms()

    case :ets.lookup(@table, peer) do
      [{^peer, count, started}] when now - started < @window_ms ->
        :ets.insert(@table, {peer, count + 1, started})

      _ ->
        bound_table(now)
        :ets.insert(@table, {peer, 1, now})
    end

    {:reply, :ok, state}
  end

  defp bound_table(now) do
    if :ets.info(@table, :size) >= @max_peers do
      :ets.select_delete(@table, [
        {{:_, :_, :"$1"}, [{:<, :"$1", now - @window_ms}], [true]}
      ])

      if :ets.info(@table, :size) >= @max_peers do
        @table
        |> :ets.tab2list()
        |> Enum.sort_by(fn {_peer, _count, started} -> started end)
        |> Enum.take(div(@max_peers, 4))
        |> Enum.each(fn {peer, _, _} -> :ets.delete(@table, peer) end)
      end
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
