defmodule LemonEvals.HarnessTest do
  use ExUnit.Case, async: false

  alias LemonEvals.Harness

  test "eval harness passes all baseline checks" do
    report = Harness.run(cwd: File.cwd!(), iterations: 10)

    assert report.summary.failed == 0
  end
end
