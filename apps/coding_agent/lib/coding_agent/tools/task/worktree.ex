defmodule CodingAgent.Tools.Task.Worktree do
  @moduledoc """
  Prepares a tracked-files-only Git worktree for a native child task.

  The caller supplies a generated task ID containing only ASCII letters, digits,
  underscores and hyphens, beginning with a letter or digit (at most 128 bytes).
  Worktrees live in the repository's common Git directory under
  `lemon-task-worktrees/<task_id>` on branch `lemon/task-<task_id>`.

  Successful worktrees and branches are retained for review or cherry-picking.
  Existing paths and branches are never reused or removed. Uncommitted files,
  local configuration and credentials are not copied from the source checkout.
  """

  @type prepared :: %{cwd: String.t(), worktree_path: String.t(), branch: String.t()}

  @spec prepare(String.t(), String.t()) :: {:ok, prepared()} | {:error, String.t()}
  def prepare(cwd, task_id) when is_binary(cwd) and is_binary(task_id) do
    with :ok <- validate_id(task_id),
         {:ok, git} <- git_executable(),
         {:ok, root} <- repository_root(git, cwd),
         {:ok, prefix} <- run_git(git, cwd, ["rev-parse", "--show-prefix"]),
         {:ok, common} <-
           run_git(git, root, ["rev-parse", "--path-format=absolute", "--git-common-dir"]),
         parent = Path.join(common, "lemon-task-worktrees"),
         :ok <- prepare_parent(parent) do
      create(git, root, prefix, parent, task_id)
    end
  end

  def prepare(_, _), do: {:error, "Worktree cwd and task ID must be strings"}

  defp validate_id(task_id) do
    if byte_size(task_id) in 1..128 and
         Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_-]*\z/, task_id) do
      :ok
    else
      {:error,
       "Invalid worktree task ID: use 1-128 letters, digits, underscores or hyphens, starting with a letter or digit"}
    end
  end

  defp git_executable do
    case System.find_executable("git") do
      nil -> {:error, "Git executable is required to prepare a task worktree"}
      git -> {:ok, git}
    end
  end

  defp repository_root(git, cwd) do
    case run_git(git, cwd, ["rev-parse", "--show-toplevel"]) do
      {:ok, root} -> {:ok, root}
      {:error, _} -> {:error, "Cannot prepare task worktree: cwd is not a Git working tree"}
    end
  end

  defp prepare_parent(parent) do
    case File.mkdir(parent) do
      :ok ->
        :ok

      {:error, :eexist} ->
        case File.lstat(parent) do
          {:ok, %{type: :directory}} -> :ok
          _ -> {:error, "Task worktree parent is not a directory"}
        end

      {:error, _} ->
        {:error, "Cannot create task worktree parent directory"}
    end
  end

  defp create(git, root, prefix, parent, task_id) do
    path = Path.join(parent, task_id)
    branch = "lemon/task-#{task_id}"

    # Reserve the path atomically before creating a branch. In particular, an
    # existing empty directory or dangling symlink must not become ours to clean.
    case File.mkdir(path) do
      :ok ->
        case run_git(git, root, ["branch", branch, "HEAD"]) do
          {:ok, _} ->
            checkout(git, root, prefix, path, branch)

          {:error, reason} ->
            File.rmdir(path)
            {:error, reason}
        end

      {:error, :eexist} ->
        {:error, "Task worktree path already exists"}

      {:error, _} ->
        {:error, "Cannot reserve task worktree path"}
    end
  end

  defp checkout(git, root, prefix, path, branch) do
    case run_git(git, root, ["worktree", "add", "--", path, branch]) do
      {:ok, _} ->
        child_cwd = Path.expand(prefix, path)

        if File.dir?(child_cwd) do
          {:ok, %{cwd: child_cwd, worktree_path: path, branch: branch}}
        else
          cleanup(git, root, path, branch, "Task cwd does not exist in the committed Git tree")
        end

      {:error, reason} ->
        cleanup(git, root, path, branch, reason)
    end
  end

  defp cleanup(git, root, path, branch, reason) do
    # Git cleans its registration on a failed add. If add succeeded but the
    # requested subdirectory is absent, remove that registration explicitly.
    run_git(git, root, ["worktree", "remove", "--force", "--", path])
    path_result = File.rm_rf(path)
    branch_result = run_git(git, root, ["branch", "-D", "--", branch])

    case {path_result, branch_result} do
      {{:ok, _}, {:ok, _}} -> {:error, reason}
      _ -> {:error, reason <> "; could not fully clean the task's new worktree resources"}
    end
  end

  defp run_git(git, cwd, args) do
    # Do not run repository checkout hooks that might copy local state into the
    # child. Git itself populates the checkout solely from the committed tree.
    options = ["-c", "core.hooksPath=/dev/null", "-c", "submodule.recurse=false"]

    case System.cmd(git, options ++ args, cd: cwd, stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, String.trim_trailing(output, "\n")}

      {_output, _status} ->
        {:error,
         "Git #{Enum.take(args, 2) |> Enum.join(" ")} failed while preparing task worktree"}
    end
  rescue
    _ in [ErlangError, ArgumentError] ->
      {:error, "Could not execute Git while preparing task worktree"}
  end
end
