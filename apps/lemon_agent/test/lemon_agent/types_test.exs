defmodule LemonAgent.TypesTest do
  use ExUnit.Case, async: true

  alias LemonAgent.Types.{AgentTool, ToolSchemaSnapshot}

  describe "ToolSchemaSnapshot" do
    test "captures tool names and stable fingerprint inputs" do
      tools = [
        %AgentTool{name: "read", description: "Read", parameters: %{"type" => "object"}},
        %AgentTool{name: "write", description: "Write", parameters: %{"type" => "object"}}
      ]

      snapshot = ToolSchemaSnapshot.new(tools)

      assert snapshot.tools == tools
      assert snapshot.tool_names == ["read", "write"]
      assert snapshot.id =~ ~r/^tool_schema_[a-f0-9]{16}_[a-z0-9]+$/
      assert byte_size(snapshot.fingerprint) == 16
      assert is_integer(snapshot.created_at_ms)
    end
  end
end
