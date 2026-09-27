defmodule CodingAgent.ContextGuardrailsImagesTest do
  use ExUnit.Case, async: true

  alias CodingAgent.ContextGuardrails
  alias LemonAi.Types.{ImageContent, TextContent, ToolResultMessage}

  defp image(tag), do: %ImageContent{data: Base.encode64("png-#{tag}"), mime_type: "image/png"}

  defp tool_result(id, images) do
    %ToolResultMessage{
      role: :tool_result,
      tool_call_id: id,
      tool_name: "read",
      content: [%TextContent{type: :text, text: "result #{id}"} | images],
      timestamp: 0
    }
  end

  defp kept_images(messages) do
    Enum.flat_map(messages, fn %ToolResultMessage{content: content} ->
      for %ImageContent{data: data} <- content, do: Base.decode64!(data)
    end)
  end

  test "keeps the three most recent tool-result images by default" do
    messages = [
      tool_result("a", [image(1), image(2)]),
      tool_result("b", [image(3)]),
      tool_result("c", [image(4), image(5)])
    ]

    assert {:ok, guarded} = ContextGuardrails.transform(messages, nil, %{spill_dir: nil})

    assert kept_images(guarded) == ["png-3", "png-4", "png-5"]

    [first | _] = guarded

    assert Enum.count(first.content, fn
             %TextContent{text: text} -> text =~ "[tool_result image spilled]"
             _ -> false
           end) == 2
  end

  test "a budget of zero spills every image" do
    messages = [tool_result("a", [image(1)])]

    assert {:ok, guarded} =
             ContextGuardrails.transform(messages, nil, %{
               max_tool_result_images: 0,
               spill_dir: nil
             })

    assert kept_images(guarded) == []
  end
end
