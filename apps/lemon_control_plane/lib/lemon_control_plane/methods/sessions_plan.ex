defmodule LemonControlPlane.Methods.SessionsPlan do
  @moduledoc """
  Explicit user planning operations over the native session journal. Approval
  binds the reviewed revision; selecting code mode alone is never approval.
  """
  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.AgentRuntime
  alias LemonControlPlane.Methods.NativeSessions

  @actions %{"status" => :status, "enter" => :enter, "approve" => :approve, "discard" => :discard}
  @impl true
  def name, do: "sessions.plan"
  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(params, _ctx) do
    with {:ok, key, cwd} <- NativeSessions.target(params),
         {:ok, action} <- action(params),
         {:ok, opts} <- options(params, action) do
      case AgentRuntime.call(:session_plan, [key, cwd, action, opts], {:error, :unavailable}) do
        {:ok, plan} when is_map(plan) -> {:ok, %{"sessionKey" => key, "plan" => plan}}
        {:error, reason} -> failure(reason)
        _ -> failure(:unavailable)
      end
    end
  rescue
    _ -> failure(:unavailable)
  catch
    :exit, _ -> failure(:unavailable)
  end

  defp action(params) do
    case Map.fetch(@actions, params["action"]) do
      {:ok, action} -> {:ok, action}
      :error -> NativeSessions.invalid("action must be status, enter, approve, or discard")
    end
  end

  defp options(params, :approve) do
    with {:ok, revision} <- NativeSessions.string(params, "revision", 64) do
      if Regex.match?(~r/\A[0-9a-f]{64}\z/, revision),
        do: {:ok, [revision: revision]},
        else: NativeSessions.invalid("revision must be the exact reviewed plan revision")
    end
  end

  defp options(_params, _action), do: {:ok, []}

  defp failure(reason)
       when reason in [:plan_not_pending, :revision_mismatch, :plan_artifact_changed] do
    {:error,
     {:conflict, "Review the current pending plan before approving",
      %{"reason" => Atom.to_string(reason)}}}
  end

  defp failure(reason), do: NativeSessions.failure(reason)
end
