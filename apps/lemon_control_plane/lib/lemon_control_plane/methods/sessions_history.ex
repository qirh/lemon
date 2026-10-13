defmodule LemonControlPlane.Methods.SessionsHistory do
  @moduledoc "Read bounded redacted durable run history from the daemon's session lifecycle."
  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Methods.NativeSessions
  alias LemonCore.SessionLifecycle

  @impl true
  def name, do: "sessions.history"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    params = params || %{}

    with {:ok, key} <- NativeSessions.string(params, "sessionKey", 1024),
         {:ok, limit} <- NativeSessions.integer(params, "limit", 50, 1, 200) do
      case SessionLifecycle.get(key) do
        nil ->
          {:error, {:not_found, "Session not found", nil}}

        session ->
          {:ok,
           %{
             "session" => session,
             "history" => SessionLifecycle.history(key, limit: limit, redact: true)
           }}
      end
    end
  rescue
    _ -> {:error, {:unavailable, "Session history is unavailable", nil}}
  catch
    :exit, _ -> {:error, {:unavailable, "Session history is unavailable", nil}}
  end
end
