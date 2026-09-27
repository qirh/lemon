defmodule CodingAgent.ContextGuardrailsThinkingTest do
  use ExUnit.Case, async: true

  alias CodingAgent.ContextGuardrails
  alias LemonAi.Types.{AssistantMessage, TextContent, ThinkingContent}

  defp guard(blocks, max_thinking_bytes) do
    message = %AssistantMessage{role: :assistant, content: blocks, stop_reason: :stop}

    {:ok, [%AssistantMessage{content: content}]} =
      ContextGuardrails.transform([message], nil, %{max_thinking_bytes: max_thinking_bytes})

    content
  end

  test "an oversized signed thinking block is dropped, never truncated under its signature" do
    signed = %ThinkingContent{
      type: :thinking,
      thinking: String.duplicate("a", 200),
      thinking_signature: "sig"
    }

    text = %TextContent{type: :text, text: "answer"}

    assert guard([signed, text], 100) == [text]
  end

  test "an oversized unsigned thinking block is truncated" do
    unsigned = %ThinkingContent{type: :thinking, thinking: String.duplicate("a", 200)}

    assert [%ThinkingContent{thinking: truncated, thinking_signature: nil}] =
             guard([unsigned], 100)

    assert truncated =~ "TRUNCATED"
  end

  test "signed thinking within the limit is kept intact" do
    signed = %ThinkingContent{type: :thinking, thinking: "short", thinking_signature: "sig"}

    assert guard([signed], 100) == [signed]
  end
end
