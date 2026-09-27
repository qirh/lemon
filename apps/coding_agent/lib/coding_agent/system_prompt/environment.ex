defmodule CodingAgent.SystemPrompt.Environment do
  @moduledoc """
  The environment block of the system prompt: working directory, platform,
  shell, git branch and status, and today's date.

  The block is captured once when a session starts and reused for every prompt
  refresh after that. Provider prompt caches are keyed on the exact prompt
  bytes, so a block that re-read `git status` or the clock on every turn would
  invalidate the cached prefix whenever a file changed. The git status is
  therefore labelled as a snapshot, the same contract Claude Code uses.

  `CodingAgent.Session.PromptComposer` appends the rendered block after every
  other prompt section, so the most volatile text sits at the very end of the
  prompt.
  """

  @git_timeout_ms 2_000
  @max_status_lines 20

  @type capture_opt :: {:date, Date.t()} | {:shell, String.t() | nil}

  @doc """
  Capture and render the environment block for `cwd`.

  Options:

    * `:date` - the date to report (default: today, UTC)
    * `:shell` - the shell the `bash` tool runs (default:
      `CodingAgent.BashExecutor.get_shell_config/0`)
  """
  @spec capture(String.t(), [capture_opt()]) :: String.t()
  def capture(cwd, opts \\ []) when is_binary(cwd) do
    date = Keyword.get(opts, :date) || Date.utc_today()
    shell = Keyword.get(opts, :shell) || default_shell()

    [
      "## Environment",
      "Working directory: #{cwd}",
      "Platform: #{platform()}",
      "Shell: #{shell}"
    ]
    |> Kernel.++(git_lines(cwd))
    |> Kernel.++(["Today's date: #{Date.to_iso8601(date)}"])
    |> Enum.join("\n")
  end

  defp default_shell do
    {shell, _args} = CodingAgent.BashExecutor.get_shell_config()
    shell
  end

  defp platform do
    os =
      case :os.type() do
        {:unix, name} -> Atom.to_string(name)
        {:win32, _} -> "windows"
      end

    "#{os} (#{:erlang.system_info(:system_architecture)})"
  end

  defp git_lines(cwd) do
    case git_status(cwd) do
      {:ok, [branch_line | changes]} ->
        ["Git repository: yes (#{branch_summary(branch_line)})" | status_lines(changes)]

      _ ->
        ["Git repository: no"]
    end
  end

  # `## main...origin/main [ahead 1]` -> `branch: main...origin/main [ahead 1]`
  defp branch_summary("## " <> branch), do: "branch: #{branch}"
  defp branch_summary(_other), do: "branch: unknown"

  defp status_lines([]), do: ["Git status at session start: clean"]

  defp status_lines(changes) do
    shown = Enum.take(changes, @max_status_lines)
    hidden = length(changes) - length(shown)

    header =
      "Git status at session start (a snapshot; it does not update during the session):"

    more = if hidden > 0, do: ["... and #{hidden} more"], else: []

    [header | shown] ++ more
  end

  # `GIT_OPTIONAL_LOCKS=0` keeps the status call from taking the index lock, so
  # it never races a git command the user is running. A slow repository (or a
  # hung network mount) costs at most @git_timeout_ms of session start.
  defp git_status(cwd) do
    with git when is_binary(git) <- System.find_executable("git"),
         true <- File.dir?(cwd) do
      task =
        Task.async(fn ->
          System.cmd(git, ["-C", cwd, "status", "--porcelain=v1", "--branch"],
            env: [{"GIT_OPTIONAL_LOCKS", "0"}],
            stderr_to_stdout: true
          )
        end)

      case Task.yield(task, @git_timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, {output, 0}} ->
          {:ok, output |> String.split("\n", trim: true)}

        _ ->
          :error
      end
    else
      _ -> :error
    end
  end
end
