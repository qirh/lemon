defmodule LemonControlPlane.Methods.SessionsPlan do
  @moduledoc """
  Inspect, enter or exit native plan mode. Leaving plan mode never approves a
  plan: approval is the user's answer to the agent's `propose_plan` request.
  """
  @behaviour LemonControlPlane.Method

  alias LemonCore.AgentRuntime
  alias LemonControlPlane.Methods.NativeSessions

  @actions %{"status" => :status, "enter" => :enter, "exit" => :exit}
  @impl true
  def name, do: "sessions.plan"
  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(params, _ctx) do
    with {:ok, key, cwd} <- NativeSessions.target(params),
         {:ok, action} <- action(params) do
      case AgentRuntime.call(:session_plan, [key, cwd, action, []], {:error, :unavailable}) do
        {:ok, plan} when is_map(plan) -> {:ok, %{"sessionKey" => key, "plan" => plan}}
        {:error, reason} -> NativeSessions.failure(reason)
        _ -> NativeSessions.failure(:unavailable)
      end
    end
  rescue
    _ -> NativeSessions.failure(:unavailable)
  catch
    :exit, _ -> NativeSessions.failure(:unavailable)
  end

  defp action(params) do
    case Map.fetch(@actions, params["action"]) do
      {:ok, action} -> {:ok, action}
      :error -> NativeSessions.invalid("action must be status, enter, or exit")
    end
  end
end
