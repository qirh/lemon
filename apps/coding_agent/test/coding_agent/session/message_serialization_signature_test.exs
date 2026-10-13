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

  test "durable session resume preserves cache accounting and every cost component" do
    usage = %Usage{
      input: 123,
      output: 45,
      cache_read: 678,
      cache_write: 90,
      cache_write_long: 40,
      total_tokens: 936,
      cost: %LemonAi.Types.Cost{
        input: 0.01,
        output: 0.02,
        cache_read: 0.03,
        cache_write: 0.04,
        total: 0.1
      }
    }

    message = %{assistant([%TextContent{text: "answer"}]) | usage: usage}
    dir = Path.join(System.tmp_dir!(), "usage-resume-#{System.unique_integer([:positive])}")
    path = Path.join(dir, "session.jsonl")
    on_exit(fn -> File.rm_rf!(dir) end)

    session =
      CodingAgent.SessionManager.new(dir)
      |> CodingAgent.SessionManager.append_message(
        MessageSerialization.serialize_message(message)
      )

    assert :ok = CodingAgent.SessionManager.save_to_file(path, session)
    assert {:ok, loaded} = CodingAgent.SessionManager.load_from_file(path)
    assert [restored] = CodingAgent.Session.Persistence.restore_messages_from_session(loaded)
    assert restored.usage == usage
    assert MessageSerialization.deserialize_usage(Map.from_struct(usage)) == usage
  end
end
