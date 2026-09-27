defmodule CodingAgent.Session.MessageSerializationSignatureTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Session.MessageSerialization
  alias LemonAi.Types.{AssistantMessage, TextContent, ThinkingContent, ToolCall, Usage}

  # Persisted entries go through JSON, so the round trip does too.
  defp round_trip(message) do
    message
    |> MessageSerialization.serialize_message()
    |> Jason.encode!()
    |> Jason.decode!()
    |> MessageSerialization.deserialize_message()
  end

  defp assistant(content) do
    %AssistantMessage{
      role: :assistant,
      content: content,
      api: "anthropic_messages",
      provider: "anthropic",
      model: "claude-opus-4-6",
      usage: %Usage{},
      stop_reason: :tool_use,
      timestamp: 1
    }
  end

  test "Anthropic thinking signatures survive save and resume" do
    thinking = %ThinkingContent{
      type: :thinking,
      thinking: "I should read the file first.",
      thinking_signature: "EqQBCkgIARABGAIiQL-signed"
    }

    tool_call = %ToolCall{
      type: :tool_call,
      id: "toolu_1",
      name: "read",
      arguments: %{"path" => "lib/app.ex"}
    }

    restored = round_trip(assistant([thinking, tool_call]))

    assert [%ThinkingContent{} = restored_thinking, %ToolCall{} = restored_call] =
             restored.content

    assert restored_thinking == thinking
    assert restored_call == tool_call
  end

  test "OpenAI Responses reasoning items and message ids survive save and resume" do
    reasoning_item =
      Jason.encode!(%{
        "type" => "reasoning",
        "id" => "rs_123",
        "encrypted_content" => "gAAAA-opaque",
        "summary" => []
      })

    content = [
      %ThinkingContent{type: :thinking, thinking: "", thinking_signature: reasoning_item},
      %TextContent{type: :text, text: "Done.", text_signature: "msg_456"}
    ]

    assert round_trip(assistant(content)).content == content
  end

  test "Gemini thought signatures on tool calls survive save and resume" do
    tool_call = %ToolCall{
      type: :tool_call,
      id: "call_1",
      name: "bash",
      arguments: %{"command" => "mix test"},
      thought_signature: "CiQB-gemini-signature"
    }

    assert [^tool_call] = round_trip(assistant([tool_call])).content
  end

  test "unsigned blocks keep the historical serialized shape" do
    serialized =
      MessageSerialization.serialize_message(
        assistant([
          %ThinkingContent{type: :thinking, thinking: "plain"},
          %TextContent{type: :text, text: "hi"}
        ])
      )

    assert serialized["content"] == [
             %{"type" => "thinking", "thinking" => "plain"},
             %{"type" => "text", "text" => "hi"}
           ]
  end
end
