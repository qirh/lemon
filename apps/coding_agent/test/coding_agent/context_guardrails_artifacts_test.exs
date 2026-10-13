defmodule CodingAgent.ContextGuardrailsArtifactsTest do
  use ExUnit.Case, async: true

  alias CodingAgent.{Artifacts, ContextGuardrails}
  alias LemonAi.Types.{ImageContent, TextContent, ToolResultMessage}

  @moduletag :tmp_dir

  test "spilled image handles resolve to original bytes", %{tmp_dir: root} do
    bytes = "original image bytes"

    message = %ToolResultMessage{
      tool_call_id: "image",
      tool_name: "read",
      content: [%ImageContent{data: Base.encode64(bytes), mime_type: "image/png"}]
    }

    assert {:ok, [result]} =
             ContextGuardrails.transform([message], nil, %{
               max_tool_result_images: 0,
               spill_dir: root
             })

    [%TextContent{text: text}] = result.content
    [uri] = Regex.run(~r/artifact_uri=(artifact:\/\/[a-f0-9]+)/, text, capture: :all_but_first)
    opts = [session_id: "image", context_guardrails: %{spill_dir: root}]
    assert {:ok, path} = Artifacts.resolve(uri, root, opts)
    assert File.read!(path) == bytes
  end

  test "relative session spill overrides are readable from the same session", %{tmp_dir: root} do
    overrides = %{spill_dir: ".spill", max_tool_result_bytes: 100}

    guardrails =
      CodingAgent.Session.State.build_context_guardrail_opts(root, "relative", overrides)

    original = String.duplicate("output\n", 500)

    message = %ToolResultMessage{
      tool_call_id: "relative",
      tool_name: "bash",
      content: [%TextContent{text: original}]
    }

    assert {:ok, [result]} = ContextGuardrails.transform([message], nil, guardrails)
    [%TextContent{text: text}] = result.content
    [uri] = Regex.run(~r/artifact_uri=(artifact:\/\/[a-f0-9]+)/, text, capture: :all_but_first)
    opts = [session_id: "relative", context_guardrails: overrides]
    assert {:ok, path} = Artifacts.resolve(uri, root, opts)
    assert String.starts_with?(path, Path.join(root, ".spill") <> "/")
    assert File.read!(path) == original
  end

  test "reuses the full-output handle instead of spilling a truncated shell preview", %{
    tmp_dir: root
  } do
    output = Path.join(root, "shell.txt")
    original = String.duplicate("full output\n", 500)
    File.write!(output, original)
    directory = Path.join(root, "spill")
    opts = [session_id: "shell", context_guardrails: %{spill_dir: directory}]

    tool_result = %LemonAgent.Types.AgentToolResult{
      content: [%TextContent{text: String.duplicate("tail preview\n", 100)}],
      details: %{full_output_path: output, truncated: true},
      trust: :untrusted
    }

    attached = Artifacts.attach(tool_result, root, opts)
    uri = attached.details.artifact_uri

    message = %ToolResultMessage{
      tool_call_id: "shell",
      tool_name: "bash",
      content: attached.content,
      details: attached.details
    }

    assert {:ok, [result]} =
             ContextGuardrails.transform([message], nil, %{
               spill_dir: directory,
               max_tool_result_bytes: 100
             })

    [%TextContent{text: text}] = result.content
    assert text =~ "artifact_uri=#{uri}"
    assert {:ok, ^output} = Artifacts.resolve(uri, root, opts)
    assert File.read!(output) == original
    assert File.ls!(directory) == [".artifacts"]
    assert attached.trust == :untrusted
  end

  test "failed spills never advertise an unreadable path or handle", %{tmp_dir: root} do
    blocked = Path.join(root, "not-a-directory")
    File.write!(blocked, "file")

    message = %ToolResultMessage{
      tool_call_id: "large",
      tool_name: "bash",
      content: [%TextContent{text: String.duplicate("output\n", 500)}]
    }

    assert {:ok, [result]} =
             ContextGuardrails.transform([message], nil, %{
               max_tool_result_bytes: 100,
               spill_dir: blocked
             })

    [%TextContent{text: text}] = result.content
    assert text =~ "[tool_result truncated]"
    refute text =~ "artifact_uri="
    refute text =~ "spill_path="
  end
end
