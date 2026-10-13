defmodule LemonControlPlane.Methods.SessionsFork do
  @moduledoc "Forks a native session and registers its independent durable child."
  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.AgentRuntime
  alias LemonControlPlane.Methods.NativeSessions
  alias LemonCore.{SessionKey, SessionLifecycle}

  @impl true
  def name, do: "sessions.fork"

  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(params, _ctx) do
    with {:ok, source, cwd} <- NativeSessions.target(params),
         {:ok, agent_id} <- SessionLifecycle.fork_agent_id(source) do
      destination =
        SessionKey.channel_peer(%{
          agent_id: agent_id,
          channel_id: "fork",
          account_id: "local",
          peer_kind: :unknown,
          peer_id: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
        })

      with {:ok, _} <- NativeSessions.string(%{"sessionKey" => destination}, "sessionKey", 1024) do
        case AgentRuntime.call(
               :session_fork,
               [source, cwd, destination],
               {:error, :outcome_unknown}
             ) do
          :ok ->
            case SessionLifecycle.register_fork(source, destination) do
              :ok -> {:ok, %{"sessionKey" => destination, "sourceSessionKey" => source}}
              {:error, _} -> uncertain(destination, source)
            end

          {:error, :outcome_unknown} ->
            uncertain(destination, source)

          {:error, reason} ->
            NativeSessions.failure(reason)

          _ ->
            uncertain(destination, source)
        end
      end
    else
      {:error, {_, _, _}} = error -> error
      {:error, reason} -> NativeSessions.failure(reason)
    end
  end

  defp uncertain(destination, source) do
    {:error,
     {:unavailable, "Fork outcome requires reconciliation; do not retry automatically",
      %{"sessionKey" => destination, "sourceSessionKey" => source, "retrySafe" => false}}}
  end
end
