defmodule LemonControlPlane.Methods.SessionsPlanTest do
  use ExUnit.Case, async: false
  alias LemonControlPlane.Methods.{Registry, SessionsPlan}

  defmodule Provider do
    def session_plan(key, cwd, action, opts) do
      send(self(), {:plan, key, cwd, action, opts})
      Process.get(:plan_result, {:ok, %{"mode" => "plan", "status" => "draft"}})
    end
  end

  setup do
    original = Application.get_env(:lemon_control_plane, :agent_runtime_provider)
    Application.put_env(:lemon_control_plane, :agent_runtime_provider, Provider)

    on_exit(fn ->
      if original,
        do: Application.put_env(:lemon_control_plane, :agent_runtime_provider, original),
        else: Application.delete_env(:lemon_control_plane, :agent_runtime_provider)
    end)

    :ok
  end

  test "explicit approval forwards exactly the reviewed revision and requires write scope" do
    revision = String.duplicate("a", 64)

    params = %{
      "sessionKey" => "agent:plan:main",
      "cwd" => "/repo",
      "action" => "approve",
      "revision" => revision
    }

    Process.put(
      :plan_result,
      {:ok, %{"mode" => "code", "status" => "approved", "revision" => revision}}
    )

    assert {:ok, %{"sessionKey" => "agent:plan:main", "plan" => plan}} =
             Registry.dispatch("sessions.plan", params, %{
               auth: %{role: :operator, scopes: [:write]}
             })

    assert plan["revision"] == revision
    assert_receive {:plan, "agent:plan:main", "/repo", :approve, [revision: ^revision]}

    assert {:error, _} =
             Registry.dispatch("sessions.plan", params, %{
               auth: %{role: :operator, scopes: [:read]}
             })

    assert {:error, _} =
             Registry.dispatch("sessions.plan", params, %{auth: %{role: :node, scopes: [:node]}})
  end

  test "invalid approval and stale revisions cannot be silently treated as code mode" do
    params = %{"sessionKey" => "agent:plan:main", "cwd" => "/repo", "action" => "approve"}
    assert {:error, {:invalid_params, _, _}} = SessionsPlan.handle(params, %{})
    refute_receive {:plan, _, _, _, _}

    for reason <- [:revision_mismatch, :plan_artifact_changed, :plan_not_pending] do
      Process.put(:plan_result, {:error, reason})

      assert {:error, {:conflict, _, %{"reason" => actual}}} =
               SessionsPlan.handle(Map.put(params, "revision", String.duplicate("f", 64)), %{})

      assert actual == Atom.to_string(reason)
    end

    assert {:error, {:invalid_params, _, _}} =
             SessionsPlan.handle(Map.put(params, "action", "code"), %{})
  end
end
