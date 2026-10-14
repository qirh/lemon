defmodule Mix.Tasks.Lemon.CheckDuplicateTestsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Lemon.CheckDuplicateTests

  @moduletag :tmp_dir

  test "local helper names collide only when their enclosing module is the same", %{tmp_dir: root} do
    write_test(root, "first", "defmodule FirstTest do\n  defmodule FakeCron do\n  end\nend")
    write_test(root, "second", "defmodule SecondTest do\n  defmodule FakeCron do\n  end\nend")

    capture_io(fn -> CheckDuplicateTests.run(["--root", root]) end)

    write_test(root, "collision", "defmodule SecondTest.FakeCron do\nend")

    assert_raise Mix.Error, ~r/SecondTest\.FakeCron/, fn ->
      CheckDuplicateTests.run(["--root", root])
    end
  end

  test "absolute Elixir names do not inherit their enclosing module", %{tmp_dir: root} do
    write_test(
      root,
      "nested",
      "defmodule ParentTest do\n  defmodule Elixir.SharedWorker do\n  end\nend"
    )

    write_test(root, "absolute", "defmodule SharedWorker do\nend")

    assert_raise Mix.Error, ~r/SharedWorker/, fn ->
      CheckDuplicateTests.run(["--root", root])
    end
  end

  defp write_test(root, name, source) do
    path = Path.join([root, "apps", "sample", "test", name <> "_test.exs"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, source)
  end
end
