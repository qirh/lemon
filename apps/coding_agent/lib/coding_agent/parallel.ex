defmodule CodingAgent.Parallel do
  @moduledoc """
  Concurrency control utilities for task execution.

  Provides a semaphore-based approach for limiting the number of concurrently
  running tasks, and a `map_with_concurrency_limit` helper for executing a
  batch of work items with bounded parallelism.
  """

  defmodule Semaphore do
    @moduledoc """
    A counting semaphore implemented as a GenServer.

    Limits the number of concurrent operations. Callers block on `acquire/1`
    until a slot becomes available, then must call `release/1` when done.

    Slots belong to the acquiring process and are reclaimed when it exits.
    Each acquisition consumes a slot, including repeated acquisitions by the
    same caller; acquiring again when all slots are held blocks until another
    caller releases a slot. Each successful acquisition needs its own release.
    """

    use GenServer

    @type t :: GenServer.server()

    @spec start_link(pos_integer()) :: GenServer.on_start()
    def start_link(max_concurrency) when is_integer(max_concurrency) and max_concurrency > 0 do
      GenServer.start_link(__MODULE__, max_concurrency)
    end

    @spec start_link(keyword()) :: GenServer.on_start()
    def start_link(opts) when is_list(opts) do
      max = Keyword.fetch!(opts, :max)
      name = Keyword.get(opts, :name)

      if name do
        GenServer.start_link(__MODULE__, max, name: name)
      else
        GenServer.start_link(__MODULE__, max)
      end
    end

    @doc """
    Acquire a semaphore slot. Blocks until a slot is available.
    """
    @spec acquire(t()) :: :ok
    def acquire(semaphore) do
      GenServer.call(semaphore, :acquire, :infinity)
    end

    @doc """
    Release one slot held by the calling process, allowing a waiter to proceed.
    Releases from processes that hold no slots are ignored.
    """
    @spec release(t()) :: :ok
    def release(semaphore) do
      GenServer.cast(semaphore, {:release, self()})
    end

    @doc """
    Returns the current number of available slots.
    """
    @spec available(t()) :: non_neg_integer()
    def available(semaphore) do
      GenServer.call(semaphore, :available)
    end

    # -- Server callbacks --

    @impl true
    def init(max) do
      {:ok, %{max: max, current: 0, waiters: :queue.new(), holders: %{}, monitors: %{}}}
    end

    @impl true
    def handle_call(:acquire, {pid, _tag} = from, state) do
      ref = Process.monitor(pid)

      if state.current < state.max do
        {:reply, :ok, grant(state, pid, ref)}
      else
        state = %{
          state
          | waiters: :queue.in(ref, state.waiters),
            monitors: Map.put(state.monitors, ref, {:waiter, from})
        }

        {:noreply, state}
      end
    end

    def handle_call(:available, _from, state) do
      {:reply, max(state.max - state.current, 0), state}
    end

    @impl true
    def handle_cast({:release, pid}, state) do
      case Map.get(state.holders, pid, []) do
        [ref | _rest] ->
          Process.demonitor(ref, [:flush])
          {:noreply, state |> remove_holder(pid, ref) |> drain_waiters()}

        [] ->
          {:noreply, state}
      end
    end

    @impl true
    def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
      case Map.get(state.monitors, ref) do
        {:holder, ^pid} ->
          {:noreply, state |> remove_holder(pid, ref) |> drain_waiters()}

        {:waiter, _from} ->
          {:noreply, %{state | monitors: Map.delete(state.monitors, ref)}}

        nil ->
          {:noreply, state}
      end
    end

    defp grant(state, pid, ref) do
      %{
        state
        | current: state.current + 1,
          holders: Map.update(state.holders, pid, [ref], &[ref | &1]),
          monitors: Map.put(state.monitors, ref, {:holder, pid})
      }
    end

    defp remove_holder(state, pid, ref) do
      holders =
        case List.delete(Map.fetch!(state.holders, pid), ref) do
          [] -> Map.delete(state.holders, pid)
          refs -> Map.put(state.holders, pid, refs)
        end

      %{
        state
        | current: state.current - 1,
          holders: holders,
          monitors: Map.delete(state.monitors, ref)
      }
    end

    defp drain_waiters(%{current: current, max: max} = state) when current >= max,
      do: state

    defp drain_waiters(state) do
      case :queue.out(state.waiters) do
        {{:value, ref}, rest} ->
          state = %{state | waiters: rest}

          case Map.get(state.monitors, ref) do
            {:waiter, {pid, _tag} = from} ->
              if Process.alive?(pid) do
                state = grant(state, pid, ref)
                GenServer.reply(from, :ok)
                drain_waiters(state)
              else
                Process.demonitor(ref, [:flush])
                drain_waiters(%{state | monitors: Map.delete(state.monitors, ref)})
              end

            nil ->
              drain_waiters(state)
          end

        {:empty, _} ->
          state
      end
    end
  end

  @doc """
  Maps over `items` with at most `max_concurrency` items executing `fun`
  concurrently.

  Returns a list of results in the same order as the input items.

  ## Options

  - `:timeout` - per-task timeout in milliseconds (default: `:infinity`)
  - `:task_supervisor` - optional `Task.Supervisor` name/pid to use

  ## Examples

      iex> CodingAgent.Parallel.map_with_concurrency_limit([1, 2, 3], 2, &(&1 * 2))
      [2, 4, 6]
  """
  @spec map_with_concurrency_limit(
          Enumerable.t(),
          pos_integer(),
          (term() -> term()),
          keyword()
        ) :: [term()]
  def map_with_concurrency_limit(items, max_concurrency, fun, opts \\ [])
      when is_integer(max_concurrency) and max_concurrency > 0 do
    timeout = Keyword.get(opts, :timeout, :infinity)
    task_supervisor = Keyword.get(opts, :task_supervisor)

    {:ok, semaphore} = Semaphore.start_link(max_concurrency)

    try do
      tasks =
        Enum.map(items, fn item ->
          start_task(task_supervisor, fn ->
            Semaphore.acquire(semaphore)

            try do
              fun.(item)
            after
              Semaphore.release(semaphore)
            end
          end)
        end)

      Task.await_many(tasks, timeout)
    after
      GenServer.stop(semaphore)
    end
  end

  defp start_task(nil, fun), do: Task.async(fun)

  defp start_task(supervisor, fun) do
    Task.Supervisor.async(supervisor, fun)
  end

  @doc """
  Returns the default max concurrency based on the number of schedulers.
  """
  @spec default_max_concurrency() :: pos_integer()
  def default_max_concurrency do
    System.schedulers_online()
  end
end
