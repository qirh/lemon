defmodule LemonCli.McpCommandTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  alias LemonCli.{CLI, CommandRegistry}
  alias LemonSkills.McpConfig

  @moduletag :tmp_dir

  test "source and release share management help and completion" do
    assert {:ok, entry} = CommandRegistry.fetch("mcp")

    for launcher <- [:source, :release] do
      assert CommandRegistry.available?(entry, launcher)
      assert Enum.any?(CommandRegistry.completion_commands(launcher), &(&1.name == "mcp"))
    end

    output = capture_io(fn -> assert CLI.run(["mcp", "--help"]) == 0 end)
    assert output =~ "--tool-approval"
    assert output =~ "--replace"
  end

  test "stdio args after separator stay literal and list never prints secrets", %{tmp_dir: root} do
    secret = "sensitive-credential"

    output =
      capture_io(fn ->
        assert CLI.run([
                 "mcp",
                 "add",
                 "local",
                 "--cwd",
                 root,
                 "--stdio",
                 "server",
                 "--env",
                 "TOKEN=" <> secret,
                 "--tool-approval",
                 "read=never",
                 "--",
                 "--help",
                 secret
               ]) == 0
      end)

    refute output =~ secret
    assert {:ok, entry} = McpConfig.fetch("local", cwd: root)
    assert entry["args"] == ["--help", secret]
    assert entry["approval"] == "always"
    assert entry["tool_approvals"] == %{"read" => "never"}
    output = capture_io(fn -> assert CLI.run(["mcp", "list", "--cwd", root, "--json"]) == 0 end)
    assert Jason.decode!(output)["servers"] |> length() == 1
    refute output =~ secret
    refute output =~ "TOKEN"
  end

  test "HTTP add and exact removal use operation and usage exit codes", %{tmp_dir: root} do
    capture_io(fn ->
      assert CLI.run([
               "mcp",
               "add",
               "remote",
               "--cwd",
               root,
               "--http",
               "https://example.test/mcp",
               "--header",
               "Authorization=private",
               "--approval",
               "never"
             ]) == 0
    end)

    capture_io(:stderr, fn ->
      assert CLI.run(["mcp", "add", "remote", "--cwd", root, "--stdio", "server"]) == 1
      assert CLI.run(["mcp", "remove", "rem", "--cwd", root]) == 1
      assert CLI.run(["mcp", "test", "absent", "--cwd", root]) == 1
    end)

    capture_io(fn -> assert CLI.run(["mcp", "remove", "remote", "--cwd", root]) == 0 end)

    for args <- [
          [],
          ["unknown"],
          ["add", "x"],
          ["add", "x", "--http", "bad"],
          ["add", "x", "--stdio", "server", "--approval", "bad"],
          ["add", "x", "--http", "https://example.test", "--env", "A=B"],
          ["list", "--replace"],
          ["remove"],
          ["list", "--", "x"]
        ] do
      capture_io(:stderr, fn -> assert CLI.run(["mcp" | args]) == 2 end)
    end
  end

  @tag timeout: 30_000
  test "test connects to a real stdio server without calling its tools", %{tmp_dir: root} do
    script = Path.join(root, "server.exs")
    marker = Path.join(root, "tool-called")

    File.write!(script, ~S'''
    IO.stream(:stdio, :line)
    |> Enum.each(fn line ->
      request = :json.decode(String.trim(line))
      result = case request["method"] do
        "initialize" -> %{"protocolVersion" => "2024-11-05", "capabilities" => %{"tools" => %{}}, "serverInfo" => %{"name" => "fixture", "version" => "1"}}
        "tools/list" -> %{"tools" => [%{"name" => "echo", "description" => "Echo", "inputSchema" => %{"type" => "object"}}]}
        "tools/call" -> File.write!(System.fetch_env!("CALL_MARKER"), "called"); %{"content" => []}
        _ -> nil
      end
      if request["id"] && result do
        IO.puts(:json.encode(%{"jsonrpc" => "2.0", "id" => request["id"], "result" => result}) |> IO.iodata_to_binary())
      end
    end)
    ''')

    executable = System.find_executable("elixir")
    assert is_binary(executable)

    capture_io(fn ->
      assert CLI.run([
               "mcp",
               "add",
               "fixture",
               "--cwd",
               root,
               "--stdio",
               executable,
               "--env",
               "CALL_MARKER=" <> marker,
               "--env",
               "ERL_FLAGS=+S 2:2",
               "--",
               script
             ]) == 0
    end)

    output =
      capture_io(fn ->
        assert CLI.run(["mcp", "test", "fixture", "--cwd", root, "--json"]) == 0
      end)

    assert Jason.decode!(output) == %{"status" => "connected", "tool_count" => 1}
    refute File.exists?(marker)
  end
end
