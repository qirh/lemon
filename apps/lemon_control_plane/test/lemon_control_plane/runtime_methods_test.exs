defmodule LemonControlPlane.RuntimeMethodsTest do
  use ExUnit.Case, async: false

  setup do
    original = Application.get_env(:lemon_core, :agent_runtime_provider)
    Application.delete_env(:lemon_core, :agent_runtime_provider)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:lemon_core, :agent_runtime_provider)
      else
        Application.put_env(:lemon_core, :agent_runtime_provider, original)
      end
    end)

    :ok
  end

  describe "methods without an agent runtime" do
    test "tasks.active.list answers with an empty list, not an error" do
      assert {:ok, payload} = LemonControlPlane.Methods.TasksActiveList.handle(%{}, %{})
      assert payload["tasks"] == []
    end

    test "tasks.recent.list answers with an empty list" do
      assert {:ok, payload} = LemonControlPlane.Methods.TasksRecentList.handle(%{}, %{})
      assert payload["tasks"] == []
    end

    test "sessions.compact reports the runtime as unavailable, in the pre-existing shape" do
      assert {:error, {:internal_error, "Failed to compact session", reason}} =
               LemonControlPlane.Methods.SessionsCompact.handle(
                 %{"sessionKey" => "agent:main:x"},
                 %{}
               )

      assert reason == :session_registry_not_available
    end
  end
end
