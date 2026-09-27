defmodule LemonControlPlane.Methods.EventTypeValidationTest do
  use ExUnit.Case, async: true

  alias LemonControlPlane.Methods.ConfigGet

  @admin_ctx %{conn_id: "test-conn", auth: %{role: :operator}}

  describe "ConfigGet key validation" do
    test "allowed_config_keys returns a list" do
      keys = ConfigGet.allowed_config_keys()

      assert is_list(keys)
      assert keys != []
    end

    test "returns nil for arbitrary keys not in allowed list" do
      # This tests that arbitrary strings don't create atoms
      params = %{"key" => "arbitrary_config_key_#{:rand.uniform(1_000_000)}"}

      {:ok, response} = ConfigGet.handle(params, @admin_ctx)

      # Should return nil for unknown keys, not crash or create atoms
      assert response["key"] == params["key"]
      assert response["value"] == nil
    end

    test "returns values for allowed config keys" do
      params = %{"key" => "logLevel"}

      {:ok, response} = ConfigGet.handle(params, @admin_ctx)

      assert response["key"] == "logLevel"
      # Value may be nil if not configured, but should not error
    end

    test "returns all config without key parameter" do
      params = %{}

      {:ok, response} = ConfigGet.handle(params, @admin_ctx)

      assert is_map(response)
      # Response may be empty if no config is set, but should always be a map
    end

    test "includes standard config keys" do
      keys = ConfigGet.allowed_config_keys()

      assert "logLevel" in keys
      assert "env" in keys
    end
  end
end
