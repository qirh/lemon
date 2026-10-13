defmodule LemonCli.PrintCommandTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  test "piped empty input returns a usage error without starting a run" do
    capture_io([input: "\n"], fn ->
      error =
        capture_io(:stderr, fn ->
          assert LemonCli.CLI.run(["-p", "--output", "stream-json"]) == 2
        end)

      assert error =~ "prompt argument or stdin is required"
    end)
  end

  test "print aliases reject incompatible resume selectors" do
    error =
      capture_io(:stderr, fn ->
        assert LemonCli.CLI.run([
                 "--print",
                 "hello",
                 "--continue",
                 "--session",
                 "agent:default:main"
               ]) == 2
      end)

    assert error =~ "Choose --continue or --session"
  end

  test "invalid output does not silently execute a prompt" do
    error =
      capture_io(:stderr, fn ->
        assert LemonCli.CLI.run(["run", "hello", "--output", "yaml"]) == 2
      end)

    assert error =~ "Invalid run options"
  end
end
