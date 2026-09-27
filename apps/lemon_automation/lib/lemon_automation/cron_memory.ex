defmodule LemonAutomation.CronMemory do
  @moduledoc """
  Per-job markdown memory that carries context across cron runs.

  Each run appends a `## Run <id>` entry. When the file outgrows 24,000
  characters it is compacted deterministically (no model call):
  the header and the most recent whole run entries are kept, and every older
  entry is reduced to one line - start time, status, and the first line of its
  result - under `## Earlier Runs`. Earlier summaries carry forward, with a
  bounded number of lines and cumulative status counts.
  """

  alias LemonAutomation.{CronJob, CronRun}

  @default_memory_dir ".lemon/cron_memory"
  @max_prompt_chars 8_000
  @max_file_chars 24_000
  @recent_entries_chars 14_000
  @max_header_chars 2_000
  @max_summary_lines 40
  @summary_line_chars 160
  @max_result_chars 2_000
  @summary_heading "## Earlier Runs"

  @spec memory_file(CronJob.t()) :: binary()
  def memory_file(%CronJob{} = job) do
    configured =
      normalize_string(job.memory_file) ||
        normalize_string(map_get(job.meta, :memory_file)) ||
        normalize_string(map_get(job.meta, :memoryFile))

    case configured do
      nil ->
        default_memory_file(job.id)

      path ->
        expand_path(path)
    end
  end

  @spec read_for_prompt(CronJob.t()) :: {binary(), binary() | nil}
  def read_for_prompt(%CronJob{} = job) do
    path = memory_file(job)

    text =
      case File.read(path) do
        {:ok, content} -> prompt_slice(content)
        {:error, _} -> nil
      end

    {path, text}
  end

  @spec build_prompt(binary(), binary(), binary() | nil) :: binary()
  def build_prompt(prompt, memory_file, memory_text)
      when is_binary(prompt) and is_binary(memory_file) do
    memory_block =
      case normalize_string(memory_text) do
        nil -> "_No previous memory yet._"
        text -> text
      end

    """
    You are running a scheduled cron task.
    This run uses an isolated forked session so scheduled work stays separate from the originating conversation.

    Persistent memory file: #{memory_file}
    Use the memory notes below as prior run history for continuity across runs.
    Update durable findings in that memory file through the normal file tools when the task produces reusable state.

    Delivery: your final answer is sent to the user's chat (the originating chat, or their paired chat when the job was created elsewhere). Write it for the user and keep it concise.

    Scheduling guardrail: do not create, update, remove, or recursively schedule cron jobs from this run unless the task explicitly asks you to manage schedules.

    Tooling guardrail: use only the tools needed for this scheduled task. Prefer reading memory and completing the requested work over broad exploration.

    ## Memory Context
    #{memory_block}

    ## Task
    #{prompt}
    """
  end

  @spec append_run(
          CronJob.t(),
          CronRun.t(),
          binary(),
          {:ok, binary()} | {:error, binary()} | :timeout
        ) ::
          :ok
  def append_run(%CronJob{} = job, %CronRun{} = run, session_key, result)
      when is_binary(session_key) do
    path = memory_file(job)
    existing = load_existing(path, job)
    entry = render_entry(job, run, session_key, result)
    updated = compact_if_needed(existing <> "\n\n" <> entry)

    with :ok <- ensure_parent_dir(path),
         :ok <- File.write(path, updated) do
      :ok
    else
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  def append_run(_job, _run, _session_key, _result), do: :ok

  defp load_existing(path, %CronJob{} = job) do
    case File.read(path) do
      {:ok, content} when is_binary(content) and content != "" ->
        content

      _ ->
        """
        # Cron Memory: #{job.name}

        - Job ID: #{job.id}
        - Agent ID: #{job.agent_id}
        - Base Session Key: #{job.session_key}
        - Memory file created at: #{DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()}
        """
    end
  end

  defp render_entry(%CronJob{} = job, %CronRun{} = run, session_key, result) do
    status =
      case result do
        {:ok, _} -> "completed"
        {:error, _} -> "failed"
        :timeout -> "timeout"
      end

    result_text =
      case result do
        {:ok, output} -> output
        {:error, error} -> error
        :timeout -> "Run timed out waiting for completion."
      end
      |> normalize_string()
      |> case do
        nil -> "(empty)"
        text -> String.slice(text, 0, @max_result_chars)
      end

    started_at =
      run.started_at_ms
      |> case do
        nil ->
          DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

        ms ->
          DateTime.from_unix!(ms, :millisecond)
          |> DateTime.truncate(:second)
          |> DateTime.to_iso8601()
      end

    """
    ## Run #{run.id}

    - started_at: #{started_at}
    - status: #{status}
    - triggered_by: #{run.triggered_by}
    - session_key: #{session_key}
    - router_run_id: #{run.run_id || "(unknown)"}

    ### Prompt

    ```text
    #{String.slice(job.prompt || "", 0, 1_200)}
    ```

    ### Result

    ```text
    #{result_text}
    ```
    """
  end

  @doc false
  @spec compact_if_needed(binary()) :: binary()
  def compact_if_needed(content) when is_binary(content) do
    if String.length(content) <= @max_file_chars do
      content
    else
      compact(content)
    end
  end

  defp compact(content) do
    {header, previous_summary, entries} = split_sections(content)
    {kept, dropped} = keep_recent_entries(entries)
    {prior_counts, prior_lines} = parse_summary(previous_summary)

    counts = Enum.reduce(dropped, prior_counts, &count_status(entry_field(&1, "status"), &2))
    lines = Enum.take(prior_lines ++ Enum.map(dropped, &summary_line/1), -@max_summary_lines)

    compacted_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    summary =
      Enum.join(
        [
          @summary_heading,
          "",
          "- compacted_at: #{compacted_at}",
          "- runs_summarized: #{format_counts(counts)}"
          | lines
        ],
        "\n"
      )

    [String.slice(header, 0, @max_header_chars), summary | kept]
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
    |> Kernel.<>("\n")
  end

  # Header = everything before the first summary/run heading.
  defp split_sections(content) do
    [header | rest] = String.split(content, ~r/^(?=## (?:Run |Earlier Runs))/m)

    {summaries, entries} =
      Enum.split_with(rest, &String.starts_with?(&1, @summary_heading))

    {header, Enum.join(summaries, "\n"), entries}
  end

  # Keep whole recent entries within the budget; always keep the newest one.
  defp keep_recent_entries(entries) do
    {kept, _size} =
      entries
      |> Enum.reverse()
      |> Enum.reduce_while({[], 0}, fn entry, {kept, size} ->
        entry_size = String.length(entry)

        cond do
          kept == [] ->
            {:cont, {[String.slice(entry, 0, @recent_entries_chars)], entry_size}}

          size + entry_size <= @recent_entries_chars ->
            {:cont, {[entry | kept], size + entry_size}}

          true ->
            {:halt, {kept, size}}
        end
      end)

    {kept, Enum.take(entries, length(entries) - length(kept))}
  end

  defp parse_summary(summary) do
    counts =
      case Regex.run(~r/runs_summarized: \d+ \(([^)]*)\)/, summary) do
        [_, pairs] ->
          ~r/(\w+): (\d+)/
          |> Regex.scan(pairs)
          |> Map.new(fn [_, status, n] -> {status, String.to_integer(n)} end)

        _ ->
          %{}
      end

    lines =
      summary
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "- run "))

    {counts, lines}
  end

  defp summary_line(entry) do
    id =
      case Regex.run(~r/^## Run (\S+)/, entry) do
        [_, id] -> id
        _ -> "?"
      end

    result =
      case Regex.run(~r/### Result\s*```text\n(.*?)\n/s, entry) do
        [_, first_line] -> String.trim(first_line)
        _ -> ""
      end

    ("- run #{id} · #{entry_field(entry, "started_at") || "?"} · " <>
       "#{entry_field(entry, "status") || "unknown"} · #{result}")
    |> String.slice(0, @summary_line_chars)
  end

  defp entry_field(entry, field) do
    case Regex.run(~r/^- #{field}: (.+)$/m, entry) do
      [_, value] -> String.trim(value)
      _ -> nil
    end
  end

  defp count_status(status, counts), do: Map.update(counts, status || "unknown", 1, &(&1 + 1))

  defp format_counts(counts) do
    total = counts |> Map.values() |> Enum.sum()

    pairs =
      counts
      |> Enum.sort()
      |> Enum.map_join(", ", fn {status, n} -> "#{status}: #{n}" end)

    "#{total} (#{pairs})"
  end

  defp prompt_slice(content) when is_binary(content) do
    if String.length(content) <= @max_prompt_chars do
      content
    else
      tail = String.slice(content, -@max_prompt_chars, @max_prompt_chars)

      """
      [Memory truncated to latest #{@max_prompt_chars} chars]
      #{tail}
      """
    end
  end

  defp ensure_parent_dir(path) do
    path
    |> Path.dirname()
    |> File.mkdir_p()
  end

  defp default_memory_file(job_id) when is_binary(job_id) do
    root =
      case System.user_home() do
        home when is_binary(home) and home != "" -> Path.join(home, @default_memory_dir)
        _ -> Path.expand(@default_memory_dir)
      end

    Path.join(root, "#{job_id}.md")
  end

  defp expand_path(path) when is_binary(path) do
    if Path.type(path) == :absolute do
      path
    else
      Path.expand(path)
    end
  end

  defp normalize_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_string(_), do: nil

  defp map_get(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_get(_map, _key), do: nil
end
