defmodule CodingAgentTest do
  use ExUnit.Case, async: true

  describe "load_settings/1" do
    test "returns SettingsManager struct" do
      settings = CodingAgent.load_settings("/tmp")
      assert %CodingAgent.SettingsManager{} = settings
    end

    test "has default compaction settings" do
      settings = CodingAgent.load_settings("/tmp")
      assert settings.compaction_enabled == true
      assert settings.reserve_tokens == 16_384
    end
  end
end
