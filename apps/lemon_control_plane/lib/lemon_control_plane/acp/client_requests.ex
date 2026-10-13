defmodule LemonControlPlane.ACP.ClientRequests do
  @moduledoc """
  Run-scoped concurrent ACP client calls.

  Terminal exit waits must not block output polling, kill requests, or unrelated
  file operations. The bridge owns request workers and terminates them with the
  prompt owner; responses are correlated by the core client bridge reference.
  """
  use GenServer

  def start_link(run_id, owner, exchange) do
    GenServer.start_link(__MODULE__, {run_id, owner, exchange})
  end

  @impl true
  def init({run_id, owner, exchange}) do
    Process.flag(:trap_exit, true)

    with :ok <- LemonCore.ACPClientBridge.register(run_id) do
      {:ok, %{owner: owner, owner_ref: Process.monitor(owner), exchange: exchange, pending: %{}}}
    else
      error -> {:stop, error}
    end
  end

  @impl true
  def handle_info({:acp_client_request, payload}, state) do
    bridge = self()
    id = make_ref()
    exchange = state.exchange

    {pid, monitor} =
      spawn_monitor(fn -> send(bridge, {:client_result, id, exchange.(payload)}) end)

    pending = Map.put(state.pending, id, %{pid: pid, monitor: monitor, payload: payload})
    {:noreply, %{state | pending: pending}}
  end

  def handle_info({:client_result, id, {response, summary}}, state) do
    case Map.pop(state.pending, id) do
      {nil, _} ->
        {:noreply, state}

      {request, pending} ->
        Process.demonitor(request.monitor, [:flush])
        send(state.owner, {:acp_client_summary, summary})
        reply(request.payload, response)
        {:noreply, %{state | pending: pending}}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state),
    do: {:stop, :normal, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Enum.find(state.pending, fn {_id, request} -> request.monitor == ref end) do
      nil ->
        {:noreply, state}

      {id, request} ->
        reply(request.payload, failure())
        {:noreply, %{state | pending: Map.delete(state.pending, id)}}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.pending, fn {_id, request} ->
      reply(request.payload, failure())
      Process.exit(request.pid, :kill)
    end)

    :ok
  end

  defp reply(%{reply_to: pid, ref: ref}, response) when is_pid(pid),
    do: send(pid, {:acp_client_response, ref, response})

  defp reply(_, _), do: :ok
  defp failure, do: %{"error" => %{"code" => -32_000, "message" => "ACP client request ended"}}
end
