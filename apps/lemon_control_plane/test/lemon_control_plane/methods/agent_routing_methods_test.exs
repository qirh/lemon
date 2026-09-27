defmodule LemonControlPlane.Methods.AgentRoutingMethodsTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.{Agent, AgentDirectoryList, AgentsList}

  alias LemonCore.{SessionKey, Store}

  defmodule UnavailableSessionCoordinator do
    @moduledoc false
    def list_active_sessions, do: {:error, :unavailable}
  end

  setup do
    {:ok, _apps} = Application.ensure_all_started(:lemon_router)
    :ok
  end

  test "agent submission rejects legacy engine selectors with migration guidance" do
    methods = [
      {Agent, %{"prompt" => "do native work"}}
    ]

    legacy_fields = ~w(
      engine
      engine_id
      engineId
      default_engine
      defaultEngine
      engine_preference
      enginePreference
      preferred_engine
      preferredEngine
    )

    for {method, base_params} <- methods, field <- legacy_fields do
      params = Map.put(base_params, field, "codex")

      assert {:error, {:invalid_params, message, %{fields: [^field]}}} =
               method.handle(params, %{})

      assert message =~ "Top-level engine selection is no longer supported"
      assert message =~ "remove #{field}"
      assert message =~ "Lemon now runs natively; use model to choose a model"
    end
  end

  test "agent.directory.list returns filtered agent/session entries" do
    token = System.unique_integer([:positive, :monotonic])
    agent_id = "cp_directory_#{token}"

    session_key =
      SessionKey.channel_peer(%{
        agent_id: agent_id,
        channel_id: "telegram",
        account_id: "default",
        peer_kind: :dm,
        peer_id: "9988"
      })

    :ok =
      Store.put(:sessions_index, session_key, %{
        session_key: session_key,
        agent_id: agent_id,
        origin: :channel,
        run_count: 1,
        created_at_ms: 1_000,
        updated_at_ms: 2_000
      })

    on_exit(fn ->
      Store.delete(:sessions_index, session_key)
    end)

    assert {:ok, result} =
             AgentDirectoryList.handle(
               %{"agentId" => agent_id, "includeSessions" => true, "limit" => 10},
               %{}
             )

    assert Enum.any?(result["agents"], &(&1["agentId"] == agent_id))
    assert Enum.any?(result["sessions"], &(&1["sessionKey"] == session_key))
    assert result["summary"]["includeSessions"] == true
    assert result["summary"]["agentCount"] >= 1
    assert result["summary"]["sessionCount"] >= 1
    assert result["summary"]["routeSessionCount"] >= 1
    assert result["includesMessageBodies"] == false
    assert result["includesSecretValues"] == false
    assert result["includesCredentials"] == false

    assert {:ok, no_sessions} =
             AgentDirectoryList.handle(
               %{"agentId" => agent_id, "includeSessions" => false},
               %{}
             )

    assert no_sessions["sessions"] == []
    assert no_sessions["summary"]["includeSessions"] == false

    assert {:ok, agents_list} = AgentsList.handle(%{"agentId" => agent_id}, %{})
    assert Enum.any?(agents_list["agents"], &(&1["agentId"] == agent_id and &1["id"] == agent_id))
    assert agents_list["totalAgents"] >= 1
    assert agents_list["summary"]["agentCount"] >= 1
    assert agents_list["includesMessageBodies"] == false
  end

  test "directory method returns a bounded unavailable error when routing state is down" do
    previous = Application.get_env(:lemon_router, :session_coordinator)
    Application.put_env(:lemon_router, :session_coordinator, UnavailableSessionCoordinator)

    try do
      assert {:error, {:unavailable, "Agent directory is unavailable", nil}} =
               AgentDirectoryList.handle(%{}, %{})
    after
      case previous do
        nil -> Application.delete_env(:lemon_router, :session_coordinator)
        module -> Application.put_env(:lemon_router, :session_coordinator, module)
      end
    end
  end
end
