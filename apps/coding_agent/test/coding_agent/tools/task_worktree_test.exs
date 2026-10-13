defmodule CodingAgent.Tools.Task.WorktreeTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Tools.Task.Worktree

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    git = System.find_executable("git") || raise "Git is required for worktree tests"
    repo = Path.join(tmp_dir, "repository")
    File.mkdir_p!(Path.join(repo, "nested/project"))
    git!(git, repo, ["init", "-q", "-b", "main"])
    git!(git, repo, ["config", "user.name", "Worktree Test"])
    git!(git, repo, ["config", "user.email", "worktree@example.invalid"])
    repo = git!(git, repo, ["rev-parse", "--show-toplevel"])
    File.write!(Path.join(repo, "tracked.txt"), "committed\n")
    File.write!(Path.join(repo, "nested/project/source.ex"), "tracked source\n")
    File.write!(Path.join(repo, ".gitignore"), ".env\n.lemon/\n")
    git!(git, repo, ["add", "."])
    git!(git, repo, ["-c", "core.hooksPath=/dev/null", "commit", "-qm", "Initial tree"])
    %{git: git, repo: repo}
  end

  test "creates a retained branch and checkout from HEAD, without local state", context do
    %{git: git, repo: repo} = context
    File.write!(Path.join(repo, "tracked.txt"), "uncommitted\n")
    File.write!(Path.join(repo, ".env"), "SECRET=private\n")
    File.write!(Path.join(repo, "untracked.txt"), "private\n")
    File.mkdir_p!(Path.join(repo, ".lemon"))
    File.write!(Path.join(repo, ".lemon/config.toml"), "private = true\n")

    assert {:ok, prepared} = Worktree.prepare(repo, "task_123-abc")
    assert prepared.branch == "lemon/task-task_123-abc"
    assert prepared.worktree_path == Path.join(repo, ".git/lemon-task-worktrees/task_123-abc")
    assert prepared.cwd == prepared.worktree_path
    assert Path.type(prepared.cwd) == :absolute
    assert File.read!(Path.join(prepared.cwd, "tracked.txt")) == "committed\n"
    refute File.exists?(Path.join(prepared.cwd, ".env"))
    refute File.exists?(Path.join(prepared.cwd, ".lemon/config.toml"))
    refute File.exists?(Path.join(prepared.cwd, "untracked.txt"))

    assert git!(git, prepared.cwd, ["rev-parse", "HEAD"]) ==
             git!(git, repo, ["rev-parse", "HEAD"])

    assert git!(git, prepared.cwd, ["branch", "--show-current"]) == prepared.branch
    assert File.read!(Path.join(repo, "tracked.txt")) == "uncommitted\n"

    File.write!(Path.join(prepared.cwd, "review.txt"), "keep for parent\n")
    assert {:error, _} = Worktree.prepare(repo, "task_123-abc")
    assert File.read!(Path.join(prepared.cwd, "review.txt")) == "keep for parent\n"
    assert git!(git, repo, ["show-ref", "--verify", "refs/heads/#{prepared.branch}"]) != ""
  end

  test "preserves the source cwd relative to the repository root", %{git: git, repo: repo} do
    cwd = Path.join(repo, "nested/project")
    assert {:ok, prepared} = Worktree.prepare(cwd, "nested-task")
    assert prepared.cwd == Path.join(prepared.worktree_path, "nested/project")
    assert File.read!(Path.join(prepared.cwd, "source.ex")) == "tracked source\n"
    assert git!(git, prepared.cwd, ["rev-parse", "--show-prefix"]) == "nested/project/"
  end

  test "uses the common Git directory when called from another worktree", %{
    git: git,
    repo: repo,
    tmp_dir: tmp_dir
  } do
    source = Path.join(tmp_dir, "source-worktree")
    git!(git, repo, ["worktree", "add", "-b", "source-branch", source])
    File.write!(Path.join(source, "tracked.txt"), "source branch commit\n")
    git!(git, source, ["add", "tracked.txt"])
    git!(git, source, ["-c", "core.hooksPath=/dev/null", "commit", "-qm", "Source branch change"])

    assert {:ok, prepared} = Worktree.prepare(Path.join(source, "nested/project"), "linked-task")
    assert prepared.worktree_path == Path.join(repo, ".git/lemon-task-worktrees/linked-task")
    assert prepared.cwd == Path.join(prepared.worktree_path, "nested/project")

    assert git!(git, prepared.cwd, ["rev-parse", "HEAD"]) ==
             git!(git, source, ["rev-parse", "HEAD"])

    assert File.read!(Path.join(prepared.worktree_path, "tracked.txt")) ==
             "source branch commit\n"
  end

  test "rejects a nonrepository and missing cwd clearly", %{tmp_dir: tmp_dir} do
    # ExUnit's tmp_dir is nested in this checkout; block Git's upward discovery.
    File.write!(Path.join(tmp_dir, ".git"), "not a git directory\n")
    assert {:error, message} = Worktree.prepare(tmp_dir, "nonrepo")
    assert message =~ "not a Git working tree"
    assert {:error, message} = Worktree.prepare(Path.join(tmp_dir, "missing"), "missing")
    assert message =~ "not a Git working tree"
  end

  test "rejects unsafe and nongenerated task IDs before creating resources", %{repo: repo} do
    for id <- [
          "",
          ".",
          "..",
          "../escape",
          "a/../../escape",
          "/absolute",
          "a\\b",
          "-option",
          "a.b",
          "space id",
          "a\n",
          "é",
          String.duplicate("a", 129)
        ] do
      assert {:error, message} = Worktree.prepare(repo, id)
      assert message =~ "Invalid worktree task ID"
    end

    assert {:error, _} = Worktree.prepare(repo, nil)
    refute File.exists?(Path.join(repo, ".git/lemon-task-worktrees"))
  end

  test "preserves a preexisting path and does not create its branch", %{git: git, repo: repo} do
    path = Path.join(repo, ".git/lemon-task-worktrees/existing")
    File.mkdir_p!(path)
    File.write!(Path.join(path, "keep"), "original")

    assert {:error, _} = Worktree.prepare(repo, "existing")
    assert File.read!(Path.join(path, "keep")) == "original"
    refute branch_exists?(git, repo, "lemon/task-existing")
  end

  test "preserves a preexisting branch and removes only its new empty path", %{
    git: git,
    repo: repo
  } do
    branch = "lemon/task-existing-branch"
    git!(git, repo, ["branch", branch])
    original = git!(git, repo, ["rev-parse", branch])

    assert {:error, _} = Worktree.prepare(repo, "existing-branch")
    assert git!(git, repo, ["rev-parse", branch]) == original
    refute File.exists?(Path.join(repo, ".git/lemon-task-worktrees/existing-branch"))
  end

  test "rejects preexisting symlinks without touching their targets", %{
    git: git,
    repo: repo,
    tmp_dir: tmp_dir
  } do
    parent = Path.join(repo, ".git/lemon-task-worktrees")
    File.mkdir_p!(parent)
    target = Path.join(tmp_dir, "private")
    File.mkdir_p!(target)
    File.write!(Path.join(target, "keep"), "original")
    File.ln_s!(target, Path.join(parent, "symlink"))

    assert {:error, _} = Worktree.prepare(repo, "symlink")
    assert File.read!(Path.join(target, "keep")) == "original"
    assert {:ok, ^target} = File.read_link(Path.join(parent, "symlink"))
    refute branch_exists?(git, repo, "lemon/task-symlink")
  end

  test "cleans a failed checkout's resources without removing successful siblings", %{
    git: git,
    repo: repo
  } do
    assert {:ok, retained} = Worktree.prepare(repo, "retained")
    File.write!(Path.join(retained.cwd, "keep"), "review")
    cwd = Path.join(repo, "untracked-directory")
    File.mkdir_p!(cwd)

    assert {:error, message} = Worktree.prepare(cwd, "failed")
    assert message =~ "cwd does not exist in the committed Git tree"
    refute File.exists?(Path.join(repo, ".git/lemon-task-worktrees/failed"))
    refute branch_exists?(git, repo, "lemon/task-failed")
    refute git!(git, repo, ["worktree", "list", "--porcelain"]) =~ "refs/heads/lemon/task-failed"
    assert File.read!(Path.join(retained.cwd, "keep")) == "review"
    assert branch_exists?(git, repo, retained.branch)
  end

  test "cleans its reserved path when the repository has no HEAD", %{git: git, tmp_dir: tmp_dir} do
    repo = Path.join(tmp_dir, "unborn")
    File.mkdir_p!(repo)
    git!(git, repo, ["init", "-q", "-b", "main"])

    assert {:error, _} = Worktree.prepare(repo, "unborn-task")
    refute File.exists?(Path.join(repo, ".git/lemon-task-worktrees/unborn-task"))
    refute branch_exists?(git, repo, "lemon/task-unborn-task")
  end

  defp branch_exists?(git, cwd, branch) do
    {_output, status} =
      System.cmd(git, ["show-ref", "--verify", "--quiet", "refs/heads/#{branch}"],
        cd: cwd,
        stderr_to_stdout: true
      )

    status == 0
  end

  defp git!(git, cwd, args) do
    {output, status} = System.cmd(git, args, cd: cwd, stderr_to_stdout: true)
    assert status == 0, "Git command failed: #{inspect(args)}: #{output}"
    String.trim_trailing(output, "\n")
  end
end
