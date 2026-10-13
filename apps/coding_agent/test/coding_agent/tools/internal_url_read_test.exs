defmodule CodingAgent.Tools.InternalUrlReadTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Tools.{Bash, Read}
  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.TextContent

  @moduletag :tmp_dir

  test "skill references load locally even when the client owns workspace reads", %{tmp_dir: cwd} do
    key = "uri-read-#{System.unique_integer([:positive])}"
    root = Path.join([cwd, ".claude", "skills", key])
    File.mkdir_p!(Path.join(root, "references"))

    File.write!(
      Path.join(root, "SKILL.md"),
      "---\nname: URI read\ndescription: Read a local skill bundle\n---\nbody\n"
    )

    File.write!(Path.join([root, "references", "check.txt"]), "first\nreceipt\nlast\n")
    LemonSkills.refresh(cwd: cwd)

    opts = [acp_client_fs_read_text_file: true]

    assert %AgentToolResult{content: [%TextContent{text: body}], trust: :untrusted} =
             Read.execute("skill", %{"path" => "skill://#{key}"}, nil, nil, cwd, opts)

    assert body =~ "body"

    assert %AgentToolResult{content: [%TextContent{text: excerpt}], details: details} =
             Read.execute(
               "reference",
               %{"path" => "skill://#{key}/references/check.txt", "offset" => 2, "limit" => 1},
               nil,
               nil,
               cwd,
               opts
             )

    assert excerpt =~ "receipt"
    refute excerpt =~ "first"
    assert details.start_line == 2
  end

  test "foreground shell spills are fetched by handle and remain session scoped", %{tmp_dir: cwd} do
    opts = [
      session_id: "uri-shell",
      context_guardrails: %{spill_dir: Path.join(cwd, "spill")},
      acp_client_fs_read_text_file: true
    ]

    result =
      Bash.execute(
        "shell",
        %{
          "command" =>
            "i=1; while [ $i -le 6000 ]; do printf 'receipt-line-%s abcdefghijklmnopqrstuvwxyz\\n' \"$i\"; i=$((i+1)); done"
        },
        nil,
        nil,
        cwd,
        opts
      )

    assert %AgentToolResult{is_error: false, details: details} = result
    assert details.truncated
    assert details.artifact_uri =~ "artifact://"
    on_exit(fn -> File.rm(details.full_output_path) end)

    assert %AgentToolResult{content: [%TextContent{text: text}], trust: :untrusted} =
             Read.execute(
               "fetch",
               %{"path" => details.artifact_uri, "offset" => 3000, "limit" => 1},
               nil,
               nil,
               cwd,
               opts
             )

    assert text =~ "receipt-line-3000 abcdefghijklmnopqrstuvwxyz"
    refute text =~ "receipt-line-3001"

    assert {:error, _} =
             Read.execute("foreign", %{"path" => details.artifact_uri}, nil, nil, cwd,
               session_id: "another-session"
             )
  end
end
