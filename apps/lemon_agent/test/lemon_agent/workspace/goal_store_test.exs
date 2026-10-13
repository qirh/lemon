defmodule LemonAgent.Workspace.GoalStoreTest do
  use ExUnit.Case, async: false

  alias LemonAgent.Workspace.GoalStore

  setup do
    session_key = "goal-store-test-#{System.unique_integer([:positive])}"
    on_exit(fn -> GoalStore.clear(session_key) end)
    {:ok, session_key: session_key}
  end

  test "terminal loop status retains the judge identity rather than a previous continuation", %{
    session_key: session_key
  } do
    assert {:ok, _} = GoalStore.set(session_key, "Verify the completed change")
    assert {:ok, _} = GoalStore.record_continuation(session_key, "prior_continuation")

    assert {:ok, _} =
             GoalStore.record_loop_status(session_key, :running,
               run_id: "terminal_judge",
               run_kind: "judge"
             )

    assert {:ok, goal} = GoalStore.record_loop_status(session_key, :finished)
    assert goal.last_run_id == "prior_continuation"
    assert goal.meta["goalLoop"]["lastRunId"] == "terminal_judge"
    assert goal.meta["goalLoop"]["lastRunKind"] == "judge"

    assert {:ok, goal} =
             GoalStore.record_loop_verdict(session_key, %{action: :done, source: "manual"})

    refute Map.has_key?(goal.meta["goalLoop"]["lastVerdict"], "runId")
  end

  test "sets, transitions, lists, and clears a goal", %{session_key: session_key} do
    assert {:ok, goal} =
             GoalStore.set(session_key, "Ship Hermes parity",
               agent_id: "default",
               run_id: "run_goal_test"
             )

    assert goal.session_key == session_key
    assert goal.objective == "Ship Hermes parity"
    assert goal.status == "active"
    assert is_binary(goal.id)

    assert GoalStore.get(session_key).id == goal.id
    assert Enum.any?(GoalStore.list(agent_id: "default"), &(&1.id == goal.id))

    assert {:ok, paused} = GoalStore.pause(session_key)
    assert paused.status == "paused"
    assert is_integer(paused.paused_at_ms)

    assert {:ok, resumed} = GoalStore.resume(session_key)
    assert resumed.status == "active"
    assert resumed.paused_at_ms == nil

    assert {:ok, continued} = GoalStore.record_continuation(session_key, "run_continue")
    assert continued.status == "active"
    assert continued.last_run_id == "run_continue"
    assert continued.continuation_count == 1

    assert {:ok, looped} =
             GoalStore.record_loop_verdict(
               session_key,
               %{action: :continue, reason: "more work remains", source: "test"},
               run_id: "run_continue"
             )

    assert looped.meta["goalLoop"]["lastVerdict"]["action"] == "continue"
    assert looped.meta["goalLoop"]["lastVerdict"]["reason"] == "more work remains"
    assert looped.meta["goalLoop"]["lastVerdict"]["runId"] == "run_continue"
    assert looped.meta["goalLoop"]["verdictCount"] == 1

    assert {:ok, running} = GoalStore.record_loop_status(session_key, :running)
    assert running.meta["goalLoop"]["status"] == "running"
    assert running.meta["goalLoop"]["lastVerdict"]["action"] == "continue"
    assert is_integer(running.meta["goalLoop"]["startedAtMs"])

    assert {:ok, stopped} = GoalStore.record_loop_status(session_key, :stopped)
    assert stopped.meta["goalLoop"]["status"] == "stopped"
    assert stopped.meta["goalLoop"]["lastVerdict"]["action"] == "continue"
    assert is_integer(stopped.meta["goalLoop"]["stoppedAtMs"])

    assert {:ok, auto_goal} =
             GoalStore.configure_loop_auto(session_key, true,
               max_ticks: 2,
               max_continuations: 3,
               interval_ms: 5,
               wait_timeout_ms: 10,
               judge_model: "judge-model",
               judge_failure_policy: :pause,
               model: "worker-model"
             )

    assert auto_goal.meta["goalLoop"]["auto"]["enabled"] == true
    assert auto_goal.meta["goalLoop"]["auto"]["options"]["maxTicks"] == 2
    assert auto_goal.meta["goalLoop"]["auto"]["options"]["maxContinuations"] == 3
    assert auto_goal.meta["goalLoop"]["auto"]["options"]["judgeFailurePolicy"] == "pause"

    assert {:ok, manual_goal} = GoalStore.configure_loop_auto(session_key, false)
    assert manual_goal.meta["goalLoop"]["auto"]["enabled"] == false
    assert manual_goal.meta["goalLoop"]["lastVerdict"]["action"] == "continue"

    assert {:error, :invalid_loop_action} =
             GoalStore.record_loop_verdict(session_key, %{action: :unknown})

    assert {:error, :invalid_loop_status} = GoalStore.record_loop_status(session_key, :unknown)

    assert {:ok, completed} = GoalStore.complete(session_key)
    assert completed.status == "completed"
    assert is_integer(completed.completed_at_ms)

    assert :ok = GoalStore.clear(session_key)
    assert GoalStore.get(session_key) == %{}
  end

  test "diagnostics redacts objectives and raw session ids", %{session_key: session_key} do
    assert {:ok, _goal} = GoalStore.set(session_key, "private objective text")

    diagnostics = GoalStore.diagnostics(limit: 10)

    assert diagnostics.count >= 1
    assert diagnostics.active_count >= 1
    assert diagnostics.cleanup.includes_objectives == false
    assert diagnostics.cleanup.includes_raw_session_ids == false

    assert Enum.any?(diagnostics.recent, fn goal ->
             goal.session_hash && goal.objective_bytes == byte_size("private objective text") &&
               goal.loop_auto_enabled == false
           end)

    refute inspect(diagnostics) =~ "private objective text"
    refute inspect(diagnostics) =~ session_key
  end

  test "persists cwd without inventing a nil agent id", %{session_key: session_key} do
    assert {:ok, goal} = GoalStore.set(session_key, "Work here", cwd: ".")
    assert goal.cwd == Path.expand(".")
    assert goal.agent_id == nil
    assert {:ok, updated} = GoalStore.set(session_key, "Still here")
    assert updated.cwd == goal.cwd
    assert GoalStore.get(session_key).cwd == goal.cwd
  end

  test "late completion preserves pause and records bounded result once", %{session_key: key} do
    assert {:ok, _} = GoalStore.set(key, "Bound results")
    assert {:ok, _} = GoalStore.record_continuation(key, "run_result")
    assert {:ok, _} = GoalStore.pause(key)

    assert {:ok, goal} =
             GoalStore.record_continuation(key, "run_result",
               completion: {:ok, String.duplicate("x", 9_000)}
             )

    assert goal.status == "paused"
    assert goal.continuation_count == 1
    assert goal.meta["lastResult"]["runId"] == "run_result"
    assert goal.meta["lastResult"]["status"] == "completed"
    assert String.length(goal.meta["lastResult"]["output"]) == 8_000
  end

  test "new run clears prior abort intent", %{session_key: key} do
    assert {:ok, _} = GoalStore.set(key, "Restart explicitly")

    assert {:ok, _} =
             GoalStore.record_loop_status(key, :reconciling,
               run_id: "old",
               abort_attempted: true,
               abort_result: :outcome_unknown
             )

    assert {:ok, goal} = GoalStore.record_loop_status(key, :running, run_id: "new")
    assert goal.meta["goalLoop"]["lastRunId"] == "new"
    refute Map.has_key?(goal.meta["goalLoop"], "abortAttempted")
    refute Map.has_key?(goal.meta["goalLoop"], "abortResult")
  end

  test "rejects empty objectives", %{session_key: session_key} do
    assert {:error, :empty_objective} = GoalStore.set(session_key, "  ")
  end
end
