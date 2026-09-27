defmodule LemonAutomation.CronMemoryTest do
  use ExUnit.Case, async: true

  alias LemonAutomation.CronMemory

  @header "# Cron Memory: nightly\n\n- Job ID: cron_1\n- Agent ID: default\n"

  test "small files are left alone" do
    content = memory([{1, "completed"}])
    assert CronMemory.compact_if_needed(content) == content
  end

  test "compaction keeps the header and recent whole runs and summarizes older runs" do
    runs = for i <- 1..40, do: {i, if(rem(i, 7) == 0, do: "failed", else: "completed")}
    compacted = CronMemory.compact_if_needed(memory(runs))

    assert String.length(compacted) <= 24_000
    assert String.starts_with?(compacted, "# Cron Memory: nightly")

    # The newest run survives intact, with its full result block.
    assert compacted =~ "## Run run_40\n"
    assert compacted =~ "result line one for 40\n" <> String.duplicate("x", 900) <> "\n```"

    # The oldest run is reduced to one structured line.
    refute compacted =~ "## Run run_1\n"
    assert compacted =~ "- run run_1 · 2026-09-01T09:00:00Z · completed · result line one for 1"

    [_, summarized, pairs] = Regex.run(~r/runs_summarized: (\d+) \(([^)]*)\)/, compacted)
    kept = length(Regex.scan(~r/^## Run /m, compacted))
    assert String.to_integer(summarized) + kept == 40
    assert pairs =~ "failed: "
  end

  test "repeated compaction carries counts forward and bounds the summary" do
    first = CronMemory.compact_if_needed(memory(for i <- 1..40, do: {i, "completed"}))
    second = CronMemory.compact_if_needed(append(first, for(i <- 41..80, do: {i, "timeout"})))

    [_, summarized] = Regex.run(~r/runs_summarized: (\d+)/, second)
    kept = length(Regex.scan(~r/^## Run /m, second))

    assert String.to_integer(summarized) + kept == 80
    assert length(Regex.scan(~r/^- run /m, second)) == 40
    assert length(Regex.scan(~r/^## Earlier Runs/m, second)) == 1
    assert String.length(second) <= 24_000
  end

  defp memory(runs), do: append(@header, runs)

  defp append(content, runs) do
    Enum.reduce(runs, content, fn {i, status}, acc -> acc <> "\n\n" <> entry(i, status) end)
  end

  defp entry(i, status) do
    day = (i - 1) |> rem(28) |> Kernel.+(1) |> Integer.to_string() |> String.pad_leading(2, "0")

    """
    ## Run run_#{i}

    - started_at: 2026-09-#{day}T09:00:00Z
    - status: #{status}
    - triggered_by: schedule
    - session_key: agent:default:main
    - router_run_id: r#{i}

    ### Prompt

    ```text
    check things
    ```

    ### Result

    ```text
    result line one for #{i}
    #{String.duplicate("x", 900)}
    ```
    """
  end
end
