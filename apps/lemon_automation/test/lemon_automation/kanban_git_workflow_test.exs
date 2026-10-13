defmodule LemonAutomation.KanbanGitWorkflowTest do
  use ExUnit.Case, async: false

  alias LemonAutomation.{KanbanGitWorkflow, KanbanWorktree}

  setup do
    if Process.whereis(LemonAutomation.TaskSupervisor) == nil do
      start_supervised!({Task.Supervisor, name: LemonAutomation.TaskSupervisor})
    end

    directory = Path.join(System.tmp_dir!(), "kanban-git-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    git!(directory, ["init", "-b", "main"])
    # Git supplies the physical path (macOS temporary directories can be aliases).
    root = git!(directory, ["rev-parse", "--show-toplevel"])
    git!(root, ["config", "user.name", "Kanban Test"])
    git!(root, ["config", "user.email", "kanban@example.invalid"])
    File.write!(Path.join(root, "file.txt"), "initial\n")
    File.write!(Path.join(root, ".gitignore"), ".worktrees/\nignored.txt\n")
    git!(root, ["add", "."])
    git!(root, ["commit", "-m", "initial"])
    task = %{id: "review-test"}
    assert {:ok, workspace} = KanbanWorktree.prepare(task, %{workspace: root})
    assert {:ok, config} = KanbanGitWorkflow.normalize(%{})
    assert {:ok, checkpoint} = KanbanGitWorkflow.prepare(workspace, task, config)
    %{root: root, workspace: workspace, task: task, checkpoint: checkpoint, config: config}
  end

  test "normalization is explicit and rejects unsafe or unknown input" do
    assert {:ok, nil} = KanbanGitWorkflow.normalize(nil)
    assert {:ok, nil} = KanbanGitWorkflow.normalize(false)
    assert {:ok, %{review_model: nil, publish: nil}} = KanbanGitWorkflow.normalize(%{})
    assert {:error, :invalid_workflow} = KanbanGitWorkflow.normalize(true)
    assert {:error, :unknown_workflow_key} = KanbanGitWorkflow.normalize(%{"push" => true})
    assert {:error, :invalid_review_model} = KanbanGitWorkflow.normalize(%{"reviewModel" => " "})

    assert {:error, :duplicate_workflow_key} =
             KanbanGitWorkflow.normalize(%{"publish" => false, publish: false})

    for publish <- [
          true,
          %{"mode" => "branch"},
          %{"mode" => "branch", "remote" => "--all"},
          %{"mode" => "pull_request", "remote" => "origin"},
          %{"mode" => "branch", "remote" => "origin", "force" => true},
          %{
            "mode" => "pull_request",
            "remote" => "origin",
            "repository" => "owner/repo",
            "base" => "main:other"
          }
        ] do
      assert {:error, _} = KanbanGitWorkflow.normalize(%{"publish" => publish})
    end

    assert {:ok, %{publish: %{mode: :pull_request, draft: true}}} =
             KanbanGitWorkflow.normalize(%{
               "publish" => %{
                 "mode" => "pull_request",
                 "remote" => "origin",
                 "repository" => "owner/repo",
                 "base" => "main"
               }
             })
  end

  test "isolated commit contains the reviewed tree and never pushes by default", context do
    remote = bare_remote!(context.root)
    File.write!(Path.join(context.workspace.cwd, "file.txt"), "reviewed\n")
    File.write!(Path.join(context.workspace.cwd, "new.txt"), "new\n")
    File.write!(Path.join(context.workspace.cwd, "ignored.txt"), "not reviewed\n")
    assert {:ok, snapshot} = KanbanGitWorkflow.snapshot(context.checkpoint)
    assert snapshot["changed"]
    assert snapshot["diff"] =~ "+reviewed"
    assert snapshot["diff"] =~ "+new"
    refute snapshot["diff"] =~ "not reviewed"
    assert {:ok, sha} = KanbanGitWorkflow.commit(context.checkpoint, snapshot, "Reviewed work")
    assert git!(context.workspace.cwd, ["rev-parse", "HEAD^{tree}"]) == snapshot["tree"]
    assert git!(context.workspace.cwd, ["status", "--porcelain"]) == ""
    assert git!(context.root, ["show", "HEAD:file.txt"]) == "initial"

    assert {:ok, %{"published" => false}} =
             KanbanGitWorkflow.publish(
               context.checkpoint,
               sha,
               context.config,
               "Reviewed",
               "body"
             )

    assert git!(remote, ["for-each-ref", "--format=%(refname)"]) == ""

    assert {:ok, ^sha} =
             KanbanGitWorkflow.reconcile_commit(context.checkpoint, Map.delete(snapshot, "diff"))
  end

  test "preexisting coding commits remain in review against saved base", context do
    File.write!(Path.join(context.workspace.cwd, "file.txt"), "committed by coding run\n")
    git!(context.workspace.cwd, ["add", "-A"])
    git!(context.workspace.cwd, ["commit", "-m", "coding run"])

    assert {:ok, saved} =
             KanbanGitWorkflow.prepare(context.workspace, context.task, context.config,
               checkpoint: context.checkpoint
             )

    assert saved == context.checkpoint
    assert {:ok, snapshot} = KanbanGitWorkflow.snapshot(saved)
    assert snapshot["diff"] =~ "+committed by coding run"
    assert {:ok, sha} = KanbanGitWorkflow.commit(saved, snapshot, "Reviewed")
    assert sha == snapshot["headCommit"]
  end

  test "unchanged trees cannot become successful reviewed commits", context do
    assert {:ok, snapshot} = KanbanGitWorkflow.snapshot(context.checkpoint)
    refute snapshot["changed"]

    assert {:error, :changed_after_review} =
             KanbanGitWorkflow.commit(context.checkpoint, snapshot, "Nothing")
  end

  test "tracked, staged and untracked edits after review fail without deleting changes",
       context do
    path = Path.join(context.workspace.cwd, "file.txt")
    File.write!(path, "reviewed\n")
    assert {:ok, snapshot} = KanbanGitWorkflow.snapshot(context.checkpoint)
    File.write!(path, "later\n")

    assert {:error, :changed_after_review} =
             KanbanGitWorkflow.commit(context.checkpoint, snapshot, "No")

    assert File.read!(path) == "later\n"
    git!(context.workspace.cwd, ["add", "file.txt"])

    assert {:error, :changed_after_review} =
             KanbanGitWorkflow.commit(context.checkpoint, snapshot, "No")

    assert {:ok, snapshot} = KanbanGitWorkflow.snapshot(context.checkpoint)
    File.write!(Path.join(context.workspace.cwd, "late.txt"), "late\n")

    assert {:error, :changed_after_review} =
             KanbanGitWorkflow.commit(context.checkpoint, snapshot, "No")

    assert git!(context.workspace.cwd, ["rev-parse", "HEAD"]) == context.checkpoint["baseCommit"]

    assert {:error, :commit_outcome_unknown} =
             KanbanGitWorkflow.reconcile_commit(context.checkpoint, snapshot)
  end

  test "binary and oversized review diffs fail closed", context do
    path = Path.join(context.workspace.cwd, "file.txt")
    File.write!(path, <<0, 1, 2, 3>>)
    assert {:error, :unreviewable_diff} = KanbanGitWorkflow.snapshot(context.checkpoint)
    File.write!(path, String.duplicate("large line\n", 20_000))
    assert {:error, :diff_too_large} = KanbanGitWorkflow.snapshot(context.checkpoint)
  end

  test "isolation checks reject wrong branch, root, symlink aliases and unrelated directories",
       context do
    assert {:error, :invalid_worktree} =
             KanbanGitWorkflow.prepare(
               %{cwd: context.root, worktree: nil},
               context.task,
               context.config
             )

    wrong = put_in(context.workspace, [:worktree, :branch], "main")

    assert {:error, :invalid_worktree} =
             KanbanGitWorkflow.prepare(wrong, context.task, context.config)

    assert {:error, :invalid_checkpoint} =
             KanbanGitWorkflow.prepare(context.workspace, context.task, context.config,
               checkpoint: Map.put(context.checkpoint, "root", "/other")
             )

    alias_path = Path.join(context.root, "alias")
    File.ln_s!(context.workspace.cwd, alias_path)

    assert {:error, :invalid_worktree} =
             KanbanWorktree.prepare(context.task, %{workspace: context.root},
               worktree_path: alias_path
             )

    assert {:error, :invalid_worktree} =
             KanbanWorktree.prepare(context.task, %{workspace: context.root},
               worktree_branch: "main"
             )

    unrelated = Path.join(context.root, "unrelated")
    File.mkdir_p!(unrelated)
    git!(unrelated, ["init", "-b", "main"])

    assert {:error, :invalid_worktree} =
             KanbanWorktree.prepare(context.task, %{workspace: context.root},
               worktree_path: unrelated
             )
  end

  test "explicit branch publication pushes only the owned ref to a local bare remote", context do
    remote = bare_remote!(context.root)
    {snapshot, sha} = reviewed_commit!(context)
    git!(context.root, ["tag", "not-to-push", sha])
    git!(context.root, ["config", "push.followTags", "true"])
    config = %{publish: %{mode: :branch, remote: "origin"}}

    assert {:ok, %{"published" => true, "prUrl" => nil}} =
             KanbanGitWorkflow.publish(context.checkpoint, sha, config, "Reviewed", "body")

    assert git!(remote, ["for-each-ref", "--format=%(refname)"]) ==
             "refs/heads/" <> context.checkpoint["branch"]

    assert git!(remote, ["rev-parse", "refs/heads/" <> context.checkpoint["branch"]]) == sha

    assert {:ok, %{"published" => true}} =
             KanbanGitWorkflow.reconcile_publication(context.checkpoint, sha, config)

    assert {:ok, ^sha} = KanbanGitWorkflow.reconcile_commit(context.checkpoint, snapshot)
  end

  test "PR creation uses exact argv, draft default, and independently observed matching PR",
       context do
    bare_remote!(context.root)
    {_snapshot, sha} = reviewed_commit!(context)
    owner = self()
    {:ok, state} = Agent.start_link(fn -> false end)
    on_exit(fn -> if Process.alive?(state), do: Agent.stop(state) end)

    runner = fn
      "gh", ["pr", "list" | _] = args, _opts ->
        send(owner, {:gh, args})
        entries = if Agent.get(state, & &1), do: [pr(context, sha)], else: []
        {:ok, Jason.encode!(entries)}

      "gh", ["pr", "create" | _] = args, _opts ->
        send(owner, {:gh, args})
        Agent.update(state, fn _ -> true end)
        {:ok, "https://github.com/owner/repo/pull/12\n"}

      program, args, opts ->
        KanbanGitWorkflow.command(program, args, Keyword.delete(opts, :runner))
    end

    config = pr_config()

    assert {:ok, %{"published" => true, "prUrl" => "https://github.com/owner/repo/pull/12"}} =
             KanbanGitWorkflow.publish(
               context.checkpoint,
               sha,
               config,
               "Reviewed title",
               "Reviewed body",
               runner: runner
             )

    assert_receive {:gh, ["pr", "list" | _]}

    assert_receive {:gh,
                    [
                      "pr",
                      "create",
                      "--repo",
                      "owner/repo",
                      "--head",
                      "lemon-kanban/review-test",
                      "--base",
                      "main",
                      "--title",
                      "Reviewed title",
                      "--body",
                      "Reviewed body",
                      "--draft"
                    ]}

    assert_receive {:gh, ["pr", "list" | _]}

    assert {:ok, %{"published" => true}} =
             KanbanGitWorkflow.reconcile_publication(context.checkpoint, sha, config,
               runner: runner
             )

    assert_receive {:gh, ["pr", "list" | _]}
    refute_receive {:gh, ["pr", "create" | _]}
  end

  test "existing matching PR is reused and invalid create URLs remain ambiguous", context do
    bare_remote!(context.root)
    {_snapshot, sha} = reviewed_commit!(context)
    owner = self()

    existing = fn
      "gh", ["pr", "list" | _], _opts ->
        {:ok, Jason.encode!([pr(context, sha)])}

      "gh", args, _opts ->
        send(owner, {:unexpected_gh, args})
        {:error, :unexpected_command}

      program, args, opts ->
        KanbanGitWorkflow.command(program, args, Keyword.delete(opts, :runner))
    end

    assert {:ok, %{"prUrl" => "https://github.com/owner/repo/pull/12"}} =
             KanbanGitWorkflow.publish(context.checkpoint, sha, pr_config(), "Reviewed", "body",
               runner: existing
             )

    refute_receive {:unexpected_gh, _}

    for url <- [
          "http://github.com/owner/repo/pull/12",
          "https://github.com/other/repo/pull/12",
          "not a URL"
        ] do
      invalid = fn
        "gh", ["pr", "list" | _], _opts ->
          {:ok, "[]"}

        "gh", ["pr", "create" | _], _opts ->
          {:ok, url}

        program, args, opts ->
          KanbanGitWorkflow.command(program, args, Keyword.delete(opts, :runner))
      end

      assert {:error, :publication_outcome_unknown} =
               KanbanGitWorkflow.publish(context.checkpoint, sha, pr_config(), "Reviewed", "body",
                 runner: invalid
               )
    end
  end

  test "failed dispatched push is ambiguous and reconciliation never mutates", context do
    bare_remote!(context.root)
    {_snapshot, sha} = reviewed_commit!(context)
    owner = self()

    runner = fn program, args, opts ->
      if program == "git" and "push" in args do
        send(owner, :push)
        {:error, :command_timeout}
      else
        KanbanGitWorkflow.command(program, args, Keyword.delete(opts, :runner))
      end
    end

    config = %{publish: %{mode: :branch, remote: "origin"}}

    assert {:error, :publication_outcome_unknown} =
             KanbanGitWorkflow.publish(context.checkpoint, sha, config, "Reviewed", "body",
               runner: runner
             )

    assert_receive :push

    assert {:error, :publication_outcome_unknown} =
             KanbanGitWorkflow.reconcile_publication(context.checkpoint, sha, config,
               runner: runner
             )

    refute_receive :push
    forbidden = fn _, _, _ -> flunk("disabled publication dispatched a command") end

    assert {:ok, %{"published" => false}} =
             KanbanGitWorkflow.publish(nil, nil, nil, nil, nil, runner: forbidden)
  end

  test "command output is bounded and timed-out OS processes are reaped", context do
    assert {:error, :output_too_large} =
             KanbanGitWorkflow.command("git", ["--version"], max_output_bytes: 1)

    script = sleeper!(context.root)
    pid_path = Path.join(context.root, "timeout.pid")

    assert {:error, :command_timeout} =
             KanbanGitWorkflow.command(script, [pid_path], timeout_ms: 1_000)

    pid = File.read!(pid_path)
    assert {:error, _} = KanbanGitWorkflow.command("kill", ["-0", pid])
  end

  test "worker death terminates its supervised OS command", context do
    script = sleeper!(context.root)
    pid_path = Path.join(context.root, "owner.pid")
    worker = spawn(fn -> KanbanGitWorkflow.command(script, [pid_path]) end)
    assert_eventually(fn -> File.exists?(pid_path) and File.read!(pid_path) != "" end)
    pid = File.read!(pid_path)
    Process.exit(worker, :kill)

    assert_eventually(fn ->
      match?({:error, _}, KanbanGitWorkflow.command("kill", ["-0", pid]))
    end)
  end

  test "hidden index flags cannot bypass reviewed worktree checks", context do
    File.write!(Path.join(context.workspace.cwd, "file.txt"), "reviewed\n")
    assert {:ok, snapshot} = KanbanGitWorkflow.snapshot(context.checkpoint)
    git!(context.workspace.cwd, ["update-index", "--assume-unchanged", "file.txt"])
    File.write!(Path.join(context.workspace.cwd, "file.txt"), "hidden edit\n")

    assert {:error, :changed_after_review} =
             KanbanGitWorkflow.commit(context.checkpoint, snapshot, "No")
  end

  defp sleeper!(root) do
    script = Path.join(root, "sleeper")
    File.write!(script, "#!/bin/sh\nprintf '%s' \"$$\" > \"$1\"\nexec sleep 30\n")
    File.chmod!(script, 0o700)
    script
  end

  defp assert_eventually(fun, attempts \\ 250)
  defp assert_eventually(fun, 0), do: assert(fun.())

  defp assert_eventually(fun, attempts) do
    unless fun.() do
      Process.sleep(20)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp reviewed_commit!(context) do
    File.write!(Path.join(context.workspace.cwd, "file.txt"), "reviewed\n")
    assert {:ok, snapshot} = KanbanGitWorkflow.snapshot(context.checkpoint)
    assert {:ok, sha} = KanbanGitWorkflow.commit(context.checkpoint, snapshot, "Reviewed")
    {snapshot, sha}
  end

  defp bare_remote!(root) do
    path = Path.join(root, "local-remote.git")
    File.mkdir_p!(path)
    git!(path, ["init", "--bare"])
    git!(root, ["remote", "add", "origin", path])
    path
  end

  defp pr_config,
    do: %{
      publish: %{mode: :pull_request, remote: "origin", repository: "owner/repo", base: "main"}
    }

  defp pr(context, sha),
    do: %{
      "url" => "https://github.com/owner/repo/pull/12",
      "headRefName" => context.checkpoint["branch"],
      "baseRefName" => "main",
      "headRefOid" => sha,
      "isCrossRepository" => false
    }

  defp git!(cwd, args) do
    assert {:ok, output} = KanbanGitWorkflow.git(cwd, args)
    String.trim(output)
  end
end
