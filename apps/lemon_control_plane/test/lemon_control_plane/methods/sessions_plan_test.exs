defmodule LemonControlPlane.Methods.SessionsPlanTest do
  use ExUnit.Case, async: false
  alias LemonControlPlane.Methods.{Registry, SessionsPlan}

  defmodule Provider do
    def session_plan(key, cwd, action, opts) do
      send(self(), {:plan, key, cwd, action, opts})
      Process.get(:plan_result, {:ok, %{"mode" => "plan", "path" => nil, "content" => nil}})
    end
  end

  setup do
    original = Application.get_env(:lemon_core, :agent_runtime_provider)
    Application.put_env(:lemon_core, :agent_runtime_provider, Provider)

    on_exit(fn ->
      if original,
        do: Application.put_env(:lemon_core, :agent_runtime_provider, original),
        else: Application.delete_env(:lemon_core, :agent_runtime_provider)
    end)

    :ok
  end

  test "status, enter and exit forward to the native runtime and require write scope" do
    params = %{"sessionKey" => "agent:plan:main", "cwd" => "/repo"}

    for {action, atom} <- [{"status", :status}, {"enter", :enter}, {"exit", :exit}] do
      assert {:ok, %{"sessionKey" => "agent:plan:main", "plan" => %{"mode" => "plan"}}} =
               Registry.dispatch("sessions.plan", Map.put(params, "action", action), %{
                 auth: %{role: :operator, scopes: [:write]}
               })

      assert_receive {:plan, "agent:plan:main", "/repo", ^atom, []}
    end

    assert {:error, _} =
             Registry.dispatch("sessions.plan", Map.put(params, "action", "enter"), %{
               auth: %{role: :operator, scopes: [:read]}
             })

    assert {:error, _} =
             Registry.dispatch("sessions.plan", Map.put(params, "action", "enter"), %{
               auth: %{role: :node, scopes: [:node]}
             })
  end

  test "removed approval actions are invalid and a busy session is a conflict" do
    params = %{"sessionKey" => "agent:plan:main", "cwd" => "/repo"}

    for action <- ["approve", "discard", "code", nil] do
      assert {:error, {:invalid_params, _, _}} =
               SessionsPlan.handle(Map.put(params, "action", action), %{})
    end

    refute_receive {:plan, _, _, _, _}
    Process.put(:plan_result, {:error, :busy})

    assert {:error, {:conflict, _, %{"reason" => "busy"}}} =
             SessionsPlan.handle(Map.put(params, "action", "exit"), %{})
  end
end
