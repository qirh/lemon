defmodule LemonMCP.Transport.StdioTest do
  use ExUnit.Case, async: true

  alias LemonMCP.Transport.Stdio

  test "subprocess exit terminates the transport so clients observe disconnect" do
    port = make_ref()
    state = %{port: port, buffer: ""}
    assert {:stop, :normal, %{port: nil}} = Stdio.handle_info({port, {:exit_status, 0}}, state)
  end

  test "rejects an unterminated protocol frame larger than eight MiB" do
    port = make_ref()
    state = %{port: port, buffer: String.duplicate("x", 8 * 1024 * 1024)}
    assert {:stop, :message_too_large, ^state} = Stdio.handle_info({port, {:data, "x"}}, state)
  end

  test "rejects empty command strings" do
    assert {:error, {:invalid_command, "command cannot be empty"}} =
             GenServer.start(Stdio, command: "")
  end

  test "rejects unknown executables without raising" do
    assert {:error, {:invalid_command, message}} =
             GenServer.start(Stdio, command: "definitely-not-a-real-executable")

    assert message =~ "Executable not found"
  end
end
