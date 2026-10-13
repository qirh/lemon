defmodule CodingAgent.ArtifactsTest do
  use ExUnit.Case, async: false

  alias CodingAgent.{Artifacts, Config}

  setup do
    root = Path.join(System.tmp_dir!(), "artifacts_test_#{System.unique_integer([:positive])}")
    cwd = Path.join(root, "workspace")
    File.mkdir_p!(cwd)

    original_agent_dir = System.get_env("LEMON_AGENT_DIR")
    System.put_env("LEMON_AGENT_DIR", Path.join(root, "agent"))

    on_exit(fn ->
      if original_agent_dir do
        System.put_env("LEMON_AGENT_DIR", original_agent_dir)
      else
        System.delete_env("LEMON_AGENT_DIR")
      end

      File.rm_rf!(root)
    end)

    output = Path.join(root, "bash-output.txt")
    File.write!(output, "complete output\nsecond line\n")

    %{root: root, cwd: cwd, output: output, opts: [session_id: "session-a"]}
  end

  test "persists stable handles across processes without copying external output", context do
    %{cwd: cwd, output: output, opts: opts} = context
    original_stat = File.stat!(output)
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        send(parent, {:registered, Artifacts.register(output, cwd, opts)})
      end)

    assert_receive {:registered, {:ok, handle}}
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
    assert handle =~ ~r/\Aartifact:\/\/[0-9a-f]{64}\z/
    assert {:ok, ^handle} = Artifacts.register(output, cwd, opts)

    resolution = Task.async(fn -> Artifacts.resolve(handle, cwd, opts) end)
    assert {:ok, ^output} = Task.await(resolution)

    assert {:ok, directory} = Artifacts.spill_dir(cwd, opts)
    assert directory == Config.spill_dir(cwd, "session-a")
    refute String.starts_with?(output, directory <> "/")

    "artifact://" <> id = handle
    assert File.ls!(directory) == [".artifacts"]
    assert File.ls!(Path.join(directory, ".artifacts")) == [id <> ".json"]
    metadata = File.read!(Path.join([directory, ".artifacts", id <> ".json"]))
    assert %{"version" => 1, "path" => ^output} = Jason.decode!(metadata)
    assert byte_size(metadata) < 1024
    assert File.stat!(output) == original_stat
    assert File.read!(output) == "complete output\nsecond line\n"
  end

  test "resolves relative output paths against cwd", %{cwd: cwd, opts: opts} do
    output = Path.join(cwd, "relative.txt")
    File.write!(output, "output")
    assert {:ok, handle} = Artifacts.register("./relative.txt", cwd, opts)
    assert {:ok, ^handle} = Artifacts.register(output, cwd, opts)
    assert {:ok, ^output} = Artifacts.resolve(handle, cwd, opts)
  end

  test "does not resolve another session's or workspace's index", context do
    %{cwd: cwd, output: output, opts: opts} = context
    assert {:ok, handle} = Artifacts.register(output, cwd, opts)

    assert {:error, "Artifact is not registered in the current session"} =
             Artifacts.resolve(handle, cwd, session_id: "session-b")

    assert {:error, "Artifact is not registered in the current session"} =
             Artifacts.resolve(handle, Path.join(cwd, "other-workspace"), opts)

    assert {:ok, ^handle} = Artifacts.register(output, cwd, session_id: "session-b")
    assert {:ok, ^output} = Artifacts.resolve(handle, cwd, session_id: "session-b")
  end

  test "reports missing and deleted outputs without recreating them", context do
    %{cwd: cwd, output: output, opts: opts} = context
    assert {:ok, handle} = Artifacts.register(output, cwd, opts)
    File.rm!(output)

    assert {:error, "Artifact output file is missing or has been deleted"} =
             Artifacts.resolve(handle, cwd, opts)

    assert {:error, "Artifact output file is missing or has been deleted"} =
             Artifacts.register(output, cwd, opts)

    refute File.exists?(output)
    assert {:error, "Artifact output is not a regular file"} = Artifacts.register(cwd, cwd, opts)
  end

  test "rejects malformed handles including traversal, suffixes and controls", context do
    %{cwd: cwd, output: output, opts: opts} = context
    assert {:ok, handle} = Artifacts.register(output, cwd, opts)

    malformed = [
      nil,
      "",
      output,
      "artifact://",
      "artifact://../output",
      "artifact://" <> String.duplicate("A", 64),
      "artifact://" <> String.duplicate("g", 64),
      handle <> "/../output",
      handle <> "%2foutput",
      handle <> ":1-2",
      handle <> "?path=output",
      handle <> "#fragment",
      handle <> "\n",
      handle <> <<0>>,
      "artifact://" <> <<255>>
    ]

    for uri <- malformed do
      assert {:error, message} = Artifacts.resolve(uri, cwd, opts)
      assert message =~ "Malformed artifact handle"
    end
  end

  test "honors map and keyword guardrail spill directory overrides", context do
    %{cwd: cwd, output: output} = context
    directory = Path.join(cwd, "custom-spill")

    for guardrails <- [%{spill_dir: "custom-spill"}, [spill_dir: "custom-spill"]] do
      opts = [session_id: "custom-session", context_guardrails: guardrails]
      assert {:ok, ^directory} = Artifacts.spill_dir(cwd, opts)
      assert {:ok, handle} = Artifacts.register(output, cwd, opts)
      assert {:ok, ^output} = Artifacts.resolve(handle, cwd, opts)

      assert {:error, "Artifact is not registered in the current session"} =
               Artifacts.resolve(handle, cwd, session_id: "custom-session")
    end

    assert {:ok, ^directory} =
             Artifacts.spill_dir(cwd, %{
               session_id: "custom-session",
               context_guardrails: %{spill_dir: directory}
             })
  end

  test "guardrails can register an existing spill directly", %{cwd: cwd, opts: opts} do
    assert {:ok, directory} = Artifacts.spill_dir(cwd, opts)
    File.mkdir_p!(directory)
    output = Path.join(directory, "tool-result.txt")
    File.write!(output, "guardrail output")

    assert {:ok, handle} = Artifacts.register_in_dir(output, directory)
    assert {:ok, ^handle} = Artifacts.register_in_dir("tool-result.txt", directory)
    assert {:ok, ^output} = Artifacts.resolve(handle, cwd, opts)
  end

  test "requires session context even with an explicit spill override", context do
    %{cwd: cwd, output: output, root: root} = context
    handle = "artifact://" <> String.duplicate("0", 64)
    directory = Path.join(root, "must-not-create")

    for session_id <- [nil, "", " \t ", 123] do
      opts = [session_id: session_id, context_guardrails: %{spill_dir: directory}]
      assert {:error, message} = Artifacts.spill_dir(cwd, opts)
      assert message =~ "session_id"
      assert {:error, ^message} = Artifacts.register(output, cwd, opts)
      assert {:error, ^message} = Artifacts.resolve(handle, cwd, opts)
    end

    assert {:error, message} = Artifacts.register(output, cwd, [])
    assert message =~ "session_id"
    refute File.exists?(directory)
  end

  test "does not return a handle when the index cannot be persisted", context do
    %{cwd: cwd, output: output, opts: opts} = context
    assert {:ok, directory} = Artifacts.spill_dir(cwd, opts)
    File.mkdir_p!(directory)
    File.write!(Path.join(directory, ".artifacts"), "not a directory")
    original = File.read!(output)

    assert {:error, message} = Artifacts.register(output, cwd, opts)
    assert message =~ "Cannot persist artifact index"
    assert File.read!(output) == original
  end

  test "rejects corrupt and mismatched index metadata", context do
    %{cwd: cwd, output: output, opts: opts} = context
    assert {:ok, "artifact://" <> id = handle} = Artifacts.register(output, cwd, opts)
    assert {:ok, directory} = Artifacts.spill_dir(cwd, opts)
    index_path = Path.join([directory, ".artifacts", id <> ".json"])

    for contents <- [
          "not JSON",
          Jason.encode!(%{version: 1, path: "relative.txt"}),
          Jason.encode!(%{version: 1, path: cwd}),
          Jason.encode!(%{version: 1, path: output <> "\n"}),
          Jason.encode!(%{version: 2, path: output})
        ] do
      File.write!(index_path, contents)

      assert {:error, "Artifact index entry is invalid"} =
               Artifacts.resolve(handle, cwd, opts)
    end
  end
end
