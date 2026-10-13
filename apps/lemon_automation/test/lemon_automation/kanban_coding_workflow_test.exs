defmodule LemonAutomation.KanbanCodingWorkflowTest do
  use ExUnit.Case, async: false

  alias LemonAgent.Workspace.KanbanStore
  alias LemonAutomation.{KanbanDispatcher, KanbanRunWorker}

  defmodule Router do
    def submit(params) do
      %{state: state, test_pid: test_pid} = :persistent_term.get(__MODULE__)
      phase = if params.meta[:kanban_phase] == "review", do: :review, else: :coding

      output =
        Agent.get_and_update(state, fn data ->
          if phase == :coding do
            count = data.codes + 1
            File.write!(Path.join(params.cwd, "file.txt"), "coding pass #{count}\n")
            {"Implemented coding pass #{count}", %{data | codes: count}}
          else
            [approved | rest] = data.reviews

            output =
              Jason.encode!(%{
                approved: approved,
                findings: if(approved, do: "No blockers", else: "Fix the blocking defect")
              })

            {output, %{data | reviews: rest}}
          end
        end)

      Agent.update(
        state,
        &put_in(&1.runs[params.run_id], %{params: params, phase: phase, output: output})
      )

      send(test_pid, {:submitted, phase, params})
      {:ok, params.run_id}
    end

    def abort_run(run_id, _) do
      %{state: state} = :persistent_term.get(__MODULE__)
      record = Agent.get(state, &Map.fetch!(&1.runs, run_id))

      LemonCore.RunStore.finalize(run_id, %{
        session_key: record.params.session_key,
        completed: %{ok: false, error: "cancelled"}
      })

      :ok
    end
  end

  defmodule Waiter do
    def wait_already_subscribed(run_id, _, _) do
      %{state: state, test_pid: test_pid} = :persistent_term.get(Router)
      {record, block?} = Agent.get(state, &{Map.fetch!(&1.runs, run_id), &1.block_review})

      if record.phase == :review and block? do
        send(test_pid, {:review_waiting, self(), run_id})

        receive do
          :finish_review -> :ok
        after
          10_000 -> exit(:review_fixture_timeout)
        end
      end

      LemonCore.RunStore.finalize(run_id, %{
        session_key: record.params.session_key,
        completed: %{ok: true, answer: record.output}
      })

      {:ok, record.output}
    end
  end

  @moduletag :tmp_dir
  setup %{tmp_dir: directory} do
    git!(directory, ["init", "-b", "main"])
    root = git!(directory, ["rev-parse", "--show-toplevel"])
    git!(root, ["config", "user.name", "Workflow Test"])
    git!(root, ["config", "user.email", "workflow@example.invalid"])
    File.write!(Path.join(root, ".gitignore"), ".worktrees/\nremote.git/\n")
    File.write!(Path.join(root, "file.txt"), "initial\n")
    git!(root, ["add", "."])
    git!(root, ["commit", "-m", "fixture"])
    base = git!(root, ["rev-parse", "HEAD"])
    remote = Path.join(root, "remote.git")
    git!(root, ["init", "--bare", remote])
    git!(root, ["remote", "add", "origin", remote])

    state =
      start_supervised!(
        {Agent, fn -> %{codes: 0, reviews: [true], runs: %{}, block_review: false, pushes: 0} end}
      )

    :persistent_term.put(Router, %{state: state, test_pid: self()})
    name = :"workflow_dispatcher_#{System.unique_integer([:positive])}"
    manager = start_supervised!({KanbanDispatcher, name: name, worker_mod: KanbanRunWorker})
    on_exit(fn -> :persistent_term.erase(Router) end)
    %{root: root, remote: remote, base: base, state: state, name: name, manager: manager}
  end

  test "review gates completion and commits locally without pushing", context do
    Agent.update(context.state, &%{&1 | block_review: true})
    {board, card} = create(context, %{})
    assert {:error, :review_required} = KanbanStore.update_task(card.id, %{status: "done"})

    assert {:error, :review_required} =
             KanbanStore.create_task(board.id, "Bypass", status: "done")

    start(context, board)
    assert_receive {:submitted, :coding, coding}, 5_000
    assert_receive {:submitted, :review, review}, 5_000
    assert_receive {:review_waiting, waiter, _run_id}, 5_000
    assert review.meta.system_prompt =~ "Independent test reviewer"
    assert review.tool_policy.allow == ["read"]
    assert review.prompt =~ "+coding pass 1"
    assert review.meta.parent_run_id == coding.run_id
    leased = KanbanStore.get_task(card.id)

    assert {:error, :review_required} =
             KanbanStore.complete_leased_task(card.id, leased.meta["kanbanLease"]["id"])

    refute leased.status == "done"
    send(waiter, :finish_review)
    done = await_card(card.id, &(&1.status == "done"))
    workflow = done.meta["codingWorkflow"]
    assert workflow["review"]["approved"]
    assert workflow["reviewRunId"] == review.run_id
    assert workflow["phase"] == "completed"
    assert workflow["published"] == false
    assert git!(workflow["cwd"], ["rev-parse", "HEAD"]) == workflow["commitSha"]
    assert git!(workflow["cwd"], ["status", "--porcelain"]) == ""
    assert git!(context.root, ["rev-parse", "HEAD"]) == context.base
    assert git!(context.remote, ["for-each-ref", "--format=%(refname)"]) == ""
  end

  test "a blocking review gets one corrective pass before commit", context do
    Agent.update(context.state, &%{&1 | reviews: [false, true]})
    {board, card} = create(context, %{})
    start(context, board)
    done = await_card(card.id, &(&1.status == "done"))
    assert done.meta["codingWorkflow"]["round"] == 2
    assert Agent.get(context.state, & &1.codes) == 2
    assert_receive {:submitted, :coding, _}
    assert_receive {:submitted, :coding, revision}
    assert revision.prompt =~ "Fix the blocking defect"
    assert git!(done.meta["codingWorkflow"]["cwd"], ["show", "HEAD:file.txt"]) == "coding pass 2"
  end

  test "repeated rejection never commits or marks the card done", context do
    Agent.update(context.state, &%{&1 | reviews: [false, false]})
    {board, card} = create(context, %{})
    start(context, board)
    failed = await_card(card.id, &is_map(&1.meta["lastFailure"]))
    assert failed.meta["lastFailure"]["reason"] == "review_rejected"
    refute failed.status == "done"
    assert failed.meta["codingWorkflow"]["round"] == 2
    assert git!(failed.meta["codingWorkflow"]["cwd"], ["rev-parse", "HEAD"]) == context.base
    assert git!(context.remote, ["for-each-ref", "--format=%(refname)"]) == ""
  end

  test "lost review waiter resumes the original approved run without another editor", context do
    Agent.update(context.state, &%{&1 | block_review: true})
    {board, card} = create(context, %{})
    start(context, board)
    assert_receive {:review_waiting, worker, run_id}, 5_000
    Process.exit(worker, :kill)
    await_card(card.id, &(get_in(&1.meta, ["kanbanRun", "status"]) == "outcome_unknown"))
    record = Agent.get(context.state, &Map.fetch!(&1.runs, run_id))

    LemonCore.RunStore.finalize(run_id, %{
      session_key: record.params.session_key,
      completed: %{ok: true, answer: record.output}
    })

    done = await_card(card.id, &(&1.status == "done"))
    assert done.meta["codingWorkflow"]["reviewRunId"] == run_id
    assert Agent.get(context.state, & &1.codes) == 1
    assert map_size(Agent.get(context.state, & &1.runs)) == 2
  end

  test "stop during review cannot commit or publish after the late result", context do
    Agent.update(context.state, &%{&1 | block_review: true})
    {board, card} = create(context, %{"publish" => %{"mode" => "branch", "remote" => "origin"}})
    start(context, board)
    assert_receive {:review_waiting, _worker, _run_id}, 5_000
    assert {:ok, _} = KanbanDispatcher.stop_board(board.id, name: context.name)
    stopped = await_card(card.id, &is_map(&1.meta["lastFailure"]))
    assert stopped.meta["codingWorkflow"]["cancelRequested"]
    assert stopped.meta["lastFailure"]["reason"] == "cancelled"
    assert git!(stopped.meta["codingWorkflow"]["cwd"], ["rev-parse", "HEAD"]) == context.base
    assert git!(context.remote, ["for-each-ref", "--format=%(refname)"]) == ""
  end

  test "an uncertain successful push is reconciled, never sent twice", context do
    {board, card} = create(context, %{"publish" => %{"mode" => "branch", "remote" => "origin"}})

    runner = fn program, args, _opts ->
      {output, code} = System.cmd(program, args, stderr_to_stdout: true)

      if "push" in args do
        Agent.update(context.state, &%{&1 | pushes: &1.pushes + 1})
        assert code == 0
        {:error, :command_timeout}
      else
        if code == 0, do: {:ok, output}, else: {:error, :git_failed}
      end
    end

    start(context, board, git_opts: [runner: runner])
    done = await_card(card.id, &(&1.status == "done"))
    workflow = done.meta["codingWorkflow"]
    assert workflow["published"]
    assert Agent.get(context.state, & &1.pushes) == 1

    assert git!(context.remote, ["rev-parse", "refs/heads/" <> workflow["branch"]]) ==
             workflow["commitSha"]
  end

  defp create(context, config) do
    {:ok, board} =
      KanbanStore.create_board("Reviewed work",
        workspace: context.root,
        meta: %{"codingWorkflow" => config}
      )

    {:ok, task} = KanbanStore.create_task(board.id, "Fix the fixture")
    on_exit(fn -> KanbanStore.clear_board(board.id) end)
    {board, task}
  end

  defp start(context, board, extra \\ []) do
    resolver = fn _, "reviewer" ->
      {:ok,
       %{
         prompt: "Independent test reviewer",
         model: nil,
         role: nil,
         tool_policy: %{allow: ["read", "bash"]}
       }}
    end

    opts =
      Keyword.merge([router_mod: Router, waiter_mod: Waiter, reviewer_resolver: resolver], extra)

    assert {:ok, _} =
             KanbanDispatcher.start_board(board.id,
               name: context.name,
               interval_ms: 10,
               worker_opts: opts
             )
  end

  defp await_card(id, predicate, attempts \\ 1_000) do
    task = KanbanStore.get_task(id)

    cond do
      predicate.(task) ->
        task

      attempts > 0 ->
        Process.sleep(10)
        await_card(id, predicate, attempts - 1)

      true ->
        flunk("card did not reach expected state: #{inspect(task, limit: 20)}")
    end
  end

  defp git!(cwd, args) do
    {output, 0} = System.cmd("git", ["-C", cwd | args], stderr_to_stdout: true)
    String.trim(output)
  end
end
