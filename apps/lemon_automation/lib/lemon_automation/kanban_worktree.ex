defmodule LemonAutomation.KanbanWorktree do
  @moduledoc """
  Creates task-owned isolated Git worktrees. Reuse requires exact checkout,
  common repository, registered path and branch identity; `.git` alone is not
  evidence of ownership. Commands use the workflow's bounded supervised runner.
  """

  alias LemonAutomation.KanbanGitWorkflow

  @type context :: %{
          cwd: binary() | nil,
          worktree: map() | nil
        }

  @spec prepare(map(), map() | nil, keyword()) :: {:ok, context()} | {:error, term()}
  def prepare(task, board, opts \\ []) do
    mode = Keyword.get(opts, :worktree_mode, :auto)
    workspace = Keyword.get(opts, :cwd) || board_workspace(board)

    cond do
      mode in [false, :off, "off"] ->
        {:ok, %{cwd: workspace, worktree: nil}}

      not is_binary(workspace) or workspace == "" ->
        {:ok, %{cwd: workspace, worktree: nil}}

      true ->
        maybe_prepare(task, workspace, mode, opts)
    end
  end

  defp maybe_prepare(task, workspace, mode, opts) do
    case git_root(workspace) do
      {:ok, repo} ->
        path = Keyword.get(opts, :worktree_path) || path_for(repo, task)
        branch = Keyword.get(opts, :worktree_branch) || branch_for(task)

        with :ok <- ensure_worktree(repo, path, branch) do
          {:ok,
           %{
             cwd: path,
             worktree: %{
               root: repo,
               path: path,
               branch: branch,
               mode: :git_worktree
             }
           }}
        end

      {:error, reason} when mode in [:auto, "auto"] ->
        {:ok, %{cwd: workspace, worktree: nil, skipped: reason}}

      {:error, reason} ->
        {:error, {:worktree_unavailable, reason}}
    end
  end

  defp ensure_worktree(repo, path, branch) do
    cond do
      File.exists?(path) ->
        KanbanGitWorkflow.validate_context(repo, path, branch)

      not safe_destination?(path) ->
        {:error, :invalid_worktree}

      true ->
        with :ok <- File.mkdir_p(Path.dirname(path)),
             :ok <- add_worktree(repo, path, branch) do
          KanbanGitWorkflow.validate_context(repo, path, branch)
        end
    end
  end

  defp add_worktree(repo, path, branch) do
    args =
      if branch_exists?(repo, branch) do
        ["worktree", "add", path, branch]
      else
        ["worktree", "add", "-b", branch, path, "HEAD"]
      end

    case git(repo, args) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:git_worktree_add_failed, reason}}
    end
  end

  defp branch_exists?(repo, branch) do
    case git(repo, ["rev-parse", "--verify", "--quiet", "refs/heads/#{branch}"]) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  defp git_root(workspace) do
    with {:ok, root} <- git(workspace, ["rev-parse", "--show-toplevel"]),
         true <- KanbanGitWorkflow.clean_path?(root) do
      {:ok, root}
    else
      false -> {:error, :invalid_worktree}
      {:error, _} = error -> error
    end
  end

  defp git(repo, args) do
    case KanbanGitWorkflow.git(repo, args) do
      {:ok, output} -> {:ok, String.trim(output)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp safe_destination?(path) when is_binary(path) do
    path == Path.expand(path) and safe_parent?(Path.dirname(path)) and
      match?({:error, :enoent}, File.lstat(path))
  end

  defp safe_destination?(_), do: false

  defp safe_parent?(path) do
    case File.lstat(path) do
      {:error, :enoent} -> safe_parent?(Path.dirname(path))
      {:ok, %{type: :directory}} -> KanbanGitWorkflow.clean_path?(path)
      _ -> false
    end
  end

  @doc false
  def path_for(repo, task) do
    Path.join([repo, ".worktrees", "kanban-#{slug(task_id(task))}"])
  end

  @doc false
  def branch_for(task) do
    "lemon-kanban/#{slug(task_id(task))}"
  end

  defp task_id(%{id: id}) when is_binary(id), do: id
  defp task_id(%{"id" => id}) when is_binary(id), do: id
  defp task_id(_), do: "task"

  defp board_workspace(%{workspace: workspace}), do: workspace
  defp board_workspace(%{"workspace" => workspace}), do: workspace
  defp board_workspace(_), do: nil

  defp slug(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9._-]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "task"
      slug -> String.slice(slug, 0, 80)
    end
  end
end
