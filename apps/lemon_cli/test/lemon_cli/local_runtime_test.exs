defmodule LemonCli.LocalRuntimeTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias LemonCli.LocalRuntime

  setup do
    dir =
      Path.join(System.tmp_dir!(), "lemon_local_runtime_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    %{dir: dir, record: Path.join(dir, "launcher-args")}
  end

  defp launcher!(dir, record, exit_status) do
    path = Path.join(dir, "lemon")

    File.write!(path, """
    #!/bin/sh
    printf '%s\\n' "$@" > '#{record}'
    echo "launcher progress"
    exit #{exit_status}
    """)

    File.chmod!(path, 0o755)
    path
  end

  test "without a launcher nothing is started" do
    assert LocalRuntime.ensure_running(launcher: nil, healthy?: fn -> flunk("probed") end) == :ok
  end

  test "a healthy runtime is reused without invoking the launcher", %{dir: dir, record: record} do
    launcher = launcher!(dir, record, 0)

    assert LocalRuntime.ensure_running(launcher: launcher, healthy?: fn -> true end) == :ok
    refute File.exists?(record)
  end

  test "an unhealthy runtime is started through `launcher daemon` with progress on stderr",
       %{dir: dir, record: record} do
    launcher = launcher!(dir, record, 0)

    stderr =
      capture_io(:stderr, fn ->
        stdout =
          capture_io(fn ->
            assert LocalRuntime.ensure_running(launcher: launcher, healthy?: fn -> false end) ==
                     :ok
          end)

        assert stdout == ""
      end)

    assert File.read!(record) == "daemon\n"
    assert stderr =~ "runtime not running; starting it"
    assert stderr =~ "launcher progress"
  end

  test "a failing launcher is reported", %{dir: dir, record: record} do
    launcher = launcher!(dir, record, 3)

    capture_io(:stderr, fn ->
      assert {:error, message} =
               LocalRuntime.ensure_running(launcher: launcher, healthy?: fn -> false end)

      assert message =~ "status 3"
    end)
  end
end
