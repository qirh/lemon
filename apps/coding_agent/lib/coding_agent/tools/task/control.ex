defmodule CodingAgent.Tools.Task.Control do
  @moduledoc """
  Invocation-bound control of native task workers. Tracks the owning parent,
  cancellation signal and live child session without publishing process handles.
  Worker and parent death cancel descendants and terminalize abandoned work.
  """
  use GenServer

  alias CodingAgent.{Session, TaskStore}
  alias LemonAgent.AbortSignal

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def owner(opts) do
    {Keyword.get(opts, :parent_session) || Keyword.get(opts, :session_key) ||
       Keyword.get(opts, :session_pid), Keyword.get(opts, :agent_id)}
  end

  def authorize(task_id, opts) do
    case TaskStore.get(task_id) do
      {:ok, record, _} ->
        if Map.get(record, :owner, {nil, nil}) == owner(opts),
          do: :ok,
          else: {:error, "Unknown task_id: #{task_id}"}

      _ ->
        {:error, "Unknown task_id: #{task_id}"}
    end
  end

  def register(task_id, signal, parent_signal, parent, on_failure) do
    GenServer.call(__MODULE__, {:register, task_id, signal, parent_signal, parent, on_failure})
  end

  def attach_worker(task_id), do: GenServer.call(__MODULE__, {:worker, task_id, self()})

  def attach_session(task_id, session),
    do: GenServer.call(__MODULE__, {:session, task_id, session})

  def complete(task_id), do: GenServer.call(__MODULE__, {:complete, task_id})
  def cancel_parent(parent), do: GenServer.cast(__MODULE__, {:cancel_parent, parent})

  def command(task_id, action, text, opts) do
    with :ok <- authorize(task_id, opts) do
      GenServer.call(__MODULE__, {:command, task_id, action, text})
    end
  end

  @impl true
  def init(_opts) do
    Process.send_after(self(), :check_signals, 50)
    {:ok, %{}}
  end

  @impl true
  def handle_call({:register, id, signal, parent_signal, parent, on_failure}, _from, state) do
    entry = %{
      signal: signal,
      parent_signal: parent_signal,
      parent: parent,
      parent_ref: if(is_pid(parent) and Process.alive?(parent), do: Process.monitor(parent)),
      worker: nil,
      worker_ref: nil,
      session: nil,
      messages: [],
      cancelled: false,
      on_failure: on_failure
    }

    {:reply, :ok, Map.put(state, id, entry)}
  end

  def handle_call({:worker, id, worker}, _from, state) do
    case state[id] do
      nil ->
        {:reply, {:error, "Task aborted"}, state}

      entry ->
        entry = %{entry | worker: worker, worker_ref: Process.monitor(worker)}
        {:reply, :ok, Map.put(state, id, entry)}
    end
  end

  def handle_call({:session, id, session}, _from, state) do
    case state[id] do
      nil ->
        Session.abort(session)
        {:reply, {:error, "Task aborted"}, state}

      entry ->
        if entry.cancelled, do: Session.abort(session)
        Enum.each(Enum.reverse(entry.messages), &Session.steer(session, &1))
        {:reply, :ok, Map.put(state, id, %{entry | session: session, messages: []})}
    end
  end

  def handle_call({:complete, id}, _from, state) do
    {:reply, :ok, remove(state, id)}
  end

  def handle_call({:command, id, action, text}, _from, state) do
    case state[id] do
      nil ->
        {:reply, {:error, "Task is no longer running"}, state}

      entry when action == "cancel" ->
        {:reply, :ok, Map.put(state, id, cancel(id, entry))}

      %{cancelled: true} ->
        {:reply, {:error, "Task is being cancelled"}, state}

      entry ->
        entry =
          if is_pid(entry.session) do
            Session.steer(entry.session, text)
            entry
          else
            %{entry | messages: [text | entry.messages]}
          end

        {:reply, :ok, Map.put(state, id, entry)}
    end
  end

  @impl true
  def handle_cast({:cancel_parent, parent}, state) do
    {:noreply,
     Map.new(state, fn {id, entry} ->
       {id, if(entry.parent == parent, do: cancel(id, entry), else: entry)}
     end)}
  end

  @impl true
  def handle_info(:check_signals, state) do
    state =
      Map.new(state, fn {id, entry} ->
        {id, if(AbortSignal.aborted?(entry.parent_signal), do: cancel(id, entry), else: entry)}
      end)

    Process.send_after(self(), :check_signals, 50)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    state =
      Enum.reduce(state, state, fn {id, entry}, acc ->
        cond do
          entry.parent_ref == ref ->
            Map.put(acc, id, cancel(id, entry))

          entry.worker_ref == ref ->
            stop_child(entry)

            failure =
              if entry.cancelled,
                do: "Task aborted",
                else: "Task worker exited: #{inspect(reason)}"

            entry.on_failure.(failure)
            remove(acc, id)

          true ->
            acc
        end
      end)

    {:noreply, state}
  end

  def handle_info({:force_cancel, id}, state) do
    case state[id] do
      %{cancelled: true} = entry ->
        stop_child(entry)
        if is_pid(entry.worker), do: Process.exit(entry.worker, :kill)
        entry.on_failure.("Task aborted")
        {:noreply, remove(state, id)}

      _ ->
        {:noreply, state}
    end
  end

  defp cancel(_id, %{cancelled: true} = entry), do: entry

  defp cancel(id, entry) do
    AbortSignal.abort(entry.signal)
    if is_pid(entry.session), do: Session.abort(entry.session)
    Process.send_after(self(), {:force_cancel, id}, 2_000)
    %{entry | cancelled: true}
  end

  defp stop_child(%{session: session}) when is_pid(session) do
    Session.abort(session)
    # Also cancel any descendants before stopping their parent session.
    cancel_parent(session)
    CodingAgent.SessionSupervisor.stop_session(session)
  catch
    :exit, _ -> :ok
  end

  defp stop_child(_), do: :ok

  defp remove(state, id) do
    case Map.pop(state, id) do
      {nil, state} ->
        state

      {entry, state} ->
        for ref <- [entry.parent_ref, entry.worker_ref],
            is_reference(ref),
            do: Process.demonitor(ref, [:flush])

        AbortSignal.clear(entry.signal)
        state
    end
  end
end
