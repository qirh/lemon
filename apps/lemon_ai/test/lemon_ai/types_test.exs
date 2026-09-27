defmodule LemonAi.TypesTest do
  @moduledoc """
  Tests for context message accumulation and ordering.
  """
  use ExUnit.Case, async: true

  alias LemonAi.Types.{AssistantMessage, Context, TextContent, ToolResultMessage, UserMessage}

  describe "Context.add_user_message/2" do
    test "appends user message to context" do
      ctx = Context.new() |> Context.add_user_message("Hello")
      assert length(ctx.messages) == 1
      assert %UserMessage{content: "Hello"} = hd(ctx.messages)
    end

    test "preserves existing messages (in chronological order)" do
      ctx =
        Context.new()
        |> Context.add_user_message("First")
        |> Context.add_user_message("Second")

      messages = Context.get_messages_chronological(ctx)
      assert length(messages) == 2
      assert %UserMessage{content: "First"} = Enum.at(messages, 0)
      assert %UserMessage{content: "Second"} = Enum.at(messages, 1)
    end

    test "sets timestamp" do
      ctx = Context.new() |> Context.add_user_message("Hello")
      msg = hd(ctx.messages)
      assert msg.timestamp > 0
    end
  end

  describe "Context.add_assistant_message/2" do
    test "appends assistant message to context" do
      assistant = %AssistantMessage{content: [%TextContent{text: "I can help"}]}

      ctx = Context.new() |> Context.add_assistant_message(assistant)
      assert length(ctx.messages) == 1
      assert %AssistantMessage{} = hd(ctx.messages)
    end
  end

  describe "Context.add_tool_result/2" do
    test "appends tool result to context" do
      result = %ToolResultMessage{
        tool_call_id: "tc1",
        tool_name: "read",
        content: [%TextContent{text: "file contents"}]
      }

      ctx = Context.new() |> Context.add_tool_result(result)
      assert length(ctx.messages) == 1
      assert %ToolResultMessage{tool_call_id: "tc1"} = hd(ctx.messages)
    end
  end
end
