defmodule LemonControlPlane.ACP.Connection do
  @moduledoc """
  Duplex ACP transport inside the existing runtime.

  Each connection owns its request workers and client-request correlations.
  Disconnect cancels active turns but retains durable sessions for later resume.
  """
  @behaviour WebSock

  alias LemonControlPlane.ACP

  @impl true
  def init(_opts) do
    {:ok, %{workers: %{}, clients: %{}, capabilities: nil}}
  end

  @impl true
  def handle_in({encoded, [opcode: :text]}, state) do
    case Jason.decode(encoded) do
      {:ok, %{"id" => id} = response}
      when not is_map_key(response, "method") and
             (is_map_key(response, "result") or is_map_key(response, "error")) ->
        case Map.pop(state.clients, id) do
          {nil, _clients} ->
            {:ok, state}

          {{pid, ref, _session}, clients} ->
            send(pid, {:acp_client_response, ref, {:ok, response}})
            {:ok, %{state | clients: clients}}
        end

      {:ok, %{"method" => "$/cancel_request", "params" => %{"requestId" => id}}} ->
        session =
          Enum.find_value(state.workers, fn {_ref, worker} ->
            if worker.id == id and worker.method == "session/prompt", do: worker.session
          end)

        {:ok, cancel_session(state, session)}

      {:ok, request} ->
        state = remember_capabilities(state, request)
        state = maybe_cancel_clients(state, request)
        {:ok, start_request(state, request)}

      {:error, _reason} ->
        {:push, {:text, Jason.encode!(error(nil, -32_700, "parse error"))}, state}
    end
  end

  def handle_in(_frame, state), do: {:ok, state}

  @impl true
  def handle_info({:acp_output, message}, state) do
    {:push, {:text, Jason.encode!(message)}, state}
  end

  def handle_info({:acp_client_request, pid, ref, request, session}, state) do
    id = "lemon_req_#{System.unique_integer([:positive])}"
    clients = Map.put(state.clients, id, {pid, ref, session})
    {:push, {:text, Jason.encode!(Map.put(request, "id", id))}, %{state | clients: clients}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.workers, ref) do
      {nil, _workers} ->
        {:ok, state}

      {worker, workers} ->
        state = %{state | workers: workers}

        if reason != :normal and not is_nil(worker.id) do
          {:push, {:text, Jason.encode!(error(worker.id, -32_603, "ACP request failed"))}, state}
        else
          {:ok, state}
        end
    end
  end

  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def terminate(_reason, state) do
    state.workers
    |> Map.values()
    |> Enum.filter(&(&1.method == "session/prompt"))
    |> Enum.each(fn worker -> cancel_turn(worker.session) end)

    Enum.each(state.clients, fn {_id, {pid, ref, _session}} ->
      send(pid, {:acp_client_response, ref, {:error, :cancelled}})
    end)

    Enum.each(state.workers, fn {_ref, worker} -> Process.exit(worker.pid, :shutdown) end)
    :ok
  end

  defp start_request(state, request) do
    owner = self()
    capabilities = state.capabilities
    method = if is_map(request), do: request["method"]
    params = if is_map(request), do: request["params"] || %{}, else: %{}
    session = if is_map(params), do: params["sessionId"]
    buffered? = method in ["session/new", "session/resume", "session/fork"]

    {pid, ref} =
      spawn_monitor(fn ->
        Process.put(:acp_bootstrap, [])

        opts = [
          client_capabilities: capabilities,
          session_update_callback: fn message ->
            if buffered? do
              Process.put(:acp_bootstrap, [message | Process.get(:acp_bootstrap)])
            else
              send(owner, {:acp_output, message})
            end
          end,
          client_request_callback: fn message ->
            correlation = make_ref()
            send(owner, {:acp_client_request, self(), correlation, message, session})

            receive do
              {:acp_client_response, ^correlation, result} -> result
            after
              60_000 -> {:error, :timeout}
            end
          end
        ]

        case ACP.handle_jsonrpc(request, opts) do
          {:ok, :noreply} -> :ok
          :noreply -> :ok
          {:ok, response} -> send(owner, {:acp_output, response})
        end

        Process.get(:acp_bootstrap)
        |> Enum.reverse()
        |> Enum.each(&send(owner, {:acp_output, &1}))
      end)

    worker = %{
      pid: pid,
      id: if(is_map(request), do: request["id"]),
      method: method,
      session: session
    }

    %{state | workers: Map.put(state.workers, ref, worker)}
  end

  defp remember_capabilities(state, %{"method" => "initialize", "params" => params})
       when is_map(params) do
    %{state | capabilities: ACP.normalize_client_capabilities(params["clientCapabilities"])}
  end

  defp remember_capabilities(state, _request), do: state

  defp maybe_cancel_clients(state, %{
         "method" => "session/cancel",
         "params" => %{"sessionId" => session}
       }),
       do: release_clients(state, session)

  defp maybe_cancel_clients(state, _request), do: state

  defp cancel_session(state, nil), do: state

  defp cancel_session(state, session) do
    cancel_turn(session)
    release_clients(state, session)
  end

  defp cancel_turn(nil), do: :ok

  defp cancel_turn(session) do
    ACP.handle_jsonrpc(%{
      "jsonrpc" => "2.0",
      "method" => "session/cancel",
      "params" => %{"sessionId" => session}
    })
  end

  defp release_clients(state, session) do
    {cancelled, retained} =
      Enum.split_with(state.clients, fn {_id, {_pid, _ref, sid}} -> sid == session end)

    Enum.each(cancelled, fn {_id, {pid, ref, _sid}} ->
      send(pid, {:acp_client_response, ref, {:error, :cancelled}})
    end)

    %{state | clients: Map.new(retained)}
  end

  defp error(id, code, message),
    do: %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}
end
