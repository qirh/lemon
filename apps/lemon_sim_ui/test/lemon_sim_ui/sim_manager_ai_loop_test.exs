defmodule LemonSimUi.SimManagerAiLoopTest do
  @moduledoc """
  Durable run-lifecycle coverage for the real, already-running
  `LemonSimUi.SimManager` GenServer. The delegated `run_ai_only/3` loop is
  driven end to end through Tic Tac Toe games with a scripted `complete_fn`
  (no network calls): natural completion, retry after a crashed step, and
  turn-budget exhaustion. Also covers scenario-specific terminal statuses
  (`won`, `bankrupt`) never being recovered, recovery and turn-budget limits,
  transient recovery persistence failures, the recovery queue, final usage
  persistence on runner teardown, operator stop, and terminal snapshot
  retention.
  """

  use ExUnit.Case, async: false

  alias LemonAi.Types.{AssistantMessage, Model, ToolCall}
  alias LemonCore.MapHelpers
  alias LemonSim.Examples.{Poker, TicTacToe}
  alias LemonSim.Kernel.{State, Store}
  alias LemonSim.LLM.Usage, as: SimUsage
  alias LemonSimUi.SimManager

  # SimManager is a global singleton and Store persists sim state, so
  # anything created here leaks into other tests' listings (e.g.
  # SimDashboardLiveTest's "0 active" mount assertion) unless removed.
  defp cleanup_sim(sim_id) do
    on_exit(fn ->
      SimManager.stop_sim(sim_id)
      Store.delete_state(sim_id)
    end)
  end

  test "the delegated loop persists every turn and marks a naturally won game completed" do
    sim_id = "ttt_natural_#{System.unique_integer([:positive])}"
    cleanup_sim(sim_id)

    LemonSim.Kernel.Bus.subscribe(sim_id)

    assert {:ok, ^sim_id} =
             SimManager.start_sim(:tic_tac_toe,
               sim_id: sim_id,
               model: fake_model(),
               stream_options: %{},
               complete_fn: scripted_moves()
             )

    states = collect_states_until_terminal(sim_id)

    # One plan_history entry per completed turn, never going backwards: the
    # traced state returned by the after-step hook is what the loop keeps
    # feeding into the next turn.
    plan_history_lengths = Enum.map(states, &length(&1.plan_history))
    assert plan_history_lengths == Enum.sort(plan_history_lengths)

    final = List.last(states)
    assert MapHelpers.get_key(final.world, :status) == "won"
    assert MapHelpers.get_key(final.world, :winner) == "X"

    # Natural completion: the runner exits on its own and SimManager's :DOWN
    # bookkeeping records a finished, non-resumable run.
    wait_until(fn -> sim_id not in SimManager.list_running() end, 250)

    stored = Store.get_state(sim_id)
    assert MapHelpers.get_key(stored.world, :status) == "won"
    assert stored.meta.run.status == "completed"
    assert is_integer(stored.meta.run.finished_at_ms)
    refute stored.meta.run.resumable
    assert stored.meta.run.turns_completed == 7
    assert length(stored.plan_history) == 7
    assert {:error, :finished} = SimManager.resume_sim(sim_id)
  end

  test "a crashed step is retried from the last good state and the game still finishes" do
    sim_id = "ttt_retry_#{System.unique_integer([:positive])}"
    cleanup_sim(sim_id)

    {:ok, calls} = Agent.start_link(fn -> 0 end)
    moves = scripted_moves()

    # The third model call crashes without consuming a move; the retry must
    # resume from the two-move checkpoint rather than skip or replay a turn.
    complete_fn = fn model, context, stream_opts ->
      if Agent.get_and_update(calls, &{&1 + 1, &1 + 1}) == 3 do
        raise "boom (simulated transient failure)"
      else
        moves.(model, context, stream_opts)
      end
    end

    LemonSim.Kernel.Bus.subscribe(sim_id)

    assert {:ok, ^sim_id} =
             SimManager.start_sim(:tic_tac_toe,
               sim_id: sim_id,
               model: fake_model(),
               stream_options: %{},
               complete_fn: complete_fn
             )

    states = collect_states_until_terminal(sim_id, 30_000)
    plan_history_lengths = Enum.map(states, &length(&1.plan_history))
    assert plan_history_lengths == Enum.sort(plan_history_lengths)

    final = List.last(states)
    assert MapHelpers.get_key(final.world, :status) == "won"

    errors = MapHelpers.get_key(final.world, :runner_errors) || []
    assert Enum.any?(errors, &(MapHelpers.get_key(&1, :kind) == :step_crash))
    refute Enum.any?(errors, &(MapHelpers.get_key(&1, :kind) == :retry_limit_exceeded))

    wait_until(fn -> sim_id not in SimManager.list_running() end, 250)

    stored = Store.get_state(sim_id)
    assert stored.meta.run.status == "completed"
    assert stored.meta.run.turns_completed == 7
    refute stored.meta.run.resumable
  end

  test "scenario-specific terminal statuses are finished and never recovered" do
    suffix = System.unique_integer([:positive])
    won_id = "ttt_won_legacy_#{suffix}"
    bankrupt_id = "vb_bankrupt_legacy_#{suffix}"

    on_exit(fn -> Enum.each([won_id, bankrupt_id], &Store.delete_state/1) end)

    # Rows persisted before terminal statuses were recognized: the world has
    # ended but the lifecycle still says running/resumable.
    legacy_run = %{
      status: "running",
      resumable: true,
      recovery_attempts: 0,
      max_turns: 50,
      turns_completed: 7
    }

    won_state =
      %{TicTacToe.initial_state(sim_id: won_id) | world: %{status: "won", winner: "X", board: []}}
      |> with_run_metadata(Map.put(legacy_run, :domain, "tic_tac_toe"))

    bankrupt_state =
      State.new(sim_id: bankrupt_id, world: %{status: "bankrupt", machine: %{}})
      |> with_run_metadata(Map.put(legacy_run, :domain, "vending_bench"))

    assert :ok = Store.put_state(won_state)
    assert :ok = Store.put_state(bankrupt_state)

    base_state =
      SimManager
      |> :sys.get_state()
      |> Map.merge(%{runners: %{}, recovery_queue: [], recovery_failures: %{}})

    # Boot recovery never queues them (capacity 0 keeps other stored rows
    # from being resumed by this test).
    assert {:noreply, booted} =
             SimManager.handle_info(
               {:recover_persisted, 0},
               %{base_state | max_concurrent_runners: 0}
             )

    refute won_id in booted.recovery_queue
    refute bankrupt_id in booted.recovery_queue

    # A crash-recovery attempt treats them as finished, not as a failure to retry.
    for sim_id <- [won_id, bankrupt_id] do
      assert {:noreply, recovered} = SimManager.handle_info({:recover_runner, sim_id}, base_state)
      refute Map.has_key?(recovered.runners, sim_id)
      refute Map.has_key?(recovered.recovery_failures, sim_id)
      assert {:error, :finished} = SimManager.resume_sim(sim_id)
    end
  end

  test "turn budget exhaustion is durable and non-resumable" do
    sim_id = "ttt_turn_limit_#{System.unique_integer([:positive])}"
    cleanup_sim(sim_id)

    LemonSim.Kernel.Bus.subscribe(sim_id)

    assert {:ok, ^sim_id} =
             SimManager.start_sim(:tic_tac_toe,
               sim_id: sim_id,
               driver_max_turns: 1,
               model: fake_model(),
               stream_options: %{},
               complete_fn: scripted_moves()
             )

    assert_receive %LemonCore.Event{type: :sim_world_updated, meta: %{sim_id: ^sim_id}}, 5_000
    wait_until(fn -> sim_id not in SimManager.list_running() end)

    stored = Store.get_state(sim_id)
    assert stored.meta.run.status == "failed"
    assert stored.meta.run.failure_reason == "turn_limit_exceeded"
    assert stored.meta.run.turns_completed == 1
    refute stored.meta.run.resumable
    assert {:error, {:not_resumable, "failed"}} = SimManager.resume_sim(sim_id)
  end

  test "persisted recovery attempts are capped and marked failed" do
    sim_id = "ww_recovery_limit_#{System.unique_integer([:positive])}"
    cleanup_sim(sim_id)

    state =
      LemonSim.Kernel.State.new(
        sim_id: sim_id,
        world: %{status: "in_progress", players: %{}},
        meta: %{
          run: %{
            domain: "werewolf",
            status: "running",
            resumable: true,
            resume_count: 11,
            recovery_attempts: 5,
            max_turns: 50,
            turns_completed: 1
          }
        }
      )

    assert :ok = Store.put_state(state)

    assert {:error, {:not_resumable, "recovery_limit_exceeded"}} =
             SimManager.resume_sim(sim_id)

    stored = Store.get_state(sim_id)
    assert stored.meta.run.status == "failed"
    assert stored.meta.run.failure_reason == "recovery_limit_exceeded"
    refute stored.meta.run.resumable
  end

  test "recovery at an exhausted turn budget is durably marked failed" do
    sim_id = "pkr_recovery_turn_budget_#{System.unique_integer([:positive])}"
    cleanup_sim(sim_id)

    state =
      LemonSim.Kernel.State.new(
        sim_id: sim_id,
        world: %{status: "in_progress", players: %{}},
        meta: %{
          run: %{
            domain: "poker",
            status: "running",
            resumable: true,
            recovery_attempts: 0,
            max_turns: 3,
            turns_completed: 3
          }
        }
      )

    assert :ok = Store.put_state(state)

    assert {:error, {:not_resumable, "turn_budget_exhausted"}} =
             SimManager.resume_sim(sim_id)

    stored = Store.get_state(sim_id)
    assert stored.meta.run.status == "failed"
    assert stored.meta.run.failure_reason == "turn_budget_exhausted"
    refute stored.meta.run.resumable
  end

  test "transient recovery persistence failures retry and then durably terminalize" do
    sim_id = "pkr_transient_recovery_#{System.unique_integer([:positive])}"
    on_exit(fn -> Store.delete_state(sim_id) end)

    state =
      LemonSim.Kernel.State.new(
        sim_id: sim_id,
        world: %{status: "in_progress", players: %{}},
        meta: %{
          run: %{
            domain: "poker",
            status: "running",
            resumable: true,
            recovery_attempts: 0,
            max_turns: 50,
            turns_completed: 1
          }
        }
      )

    assert :ok = Store.put_state(state)

    manager_state =
      SimManager
      |> :sys.get_state()
      |> Map.merge(%{
        runners: %{},
        recovery_queue: [],
        recovery_failures: %{},
        recovery_persist: fn candidate, _retries ->
          if candidate.meta.run.status == "failed" do
            Store.put_state(candidate)
          else
            {:error, :disk_unavailable}
          end
        end
      })

    assert {:noreply, manager_state} =
             SimManager.handle_info({:recover_runner, sim_id}, manager_state)

    assert manager_state.recovery_failures[sim_id] == 1
    original_capacity = manager_state.max_concurrent_runners

    assert {:noreply, capacity_state} =
             SimManager.handle_info(
               {:recover_runner, sim_id},
               %{manager_state | max_concurrent_runners: 0}
             )

    assert sim_id in capacity_state.recovery_queue
    assert capacity_state.recovery_failures[sim_id] == 1

    manager_state = %{
      capacity_state
      | max_concurrent_runners: original_capacity,
        recovery_queue: []
    }

    manager_state =
      Enum.reduce(2..4, manager_state, fn attempt, acc ->
        assert {:noreply, next} = SimManager.handle_info({:recover_runner, sim_id}, acc)
        assert next.recovery_failures[sim_id] == attempt
        assert Store.get_state(sim_id).meta.run.status == "running"
        next
      end)

    assert {:noreply, terminal_state} =
             SimManager.handle_info({:recover_runner, sim_id}, manager_state)

    stored = Store.get_state(sim_id)
    assert stored.meta.run.status == "failed"
    refute stored.meta.run.resumable
    assert stored.meta.run.failure_reason =~ "recovery_failed"
    assert terminal_state.recovery_failures == %{}
    refute Map.has_key?(terminal_state.runners, sim_id)
  end

  test "recovery queue continues after a non-resumable entry without wasting capacity" do
    suffix = System.unique_integer([:positive])
    exhausted_id = "pkr_recovery_exhausted_#{suffix}"
    resumable_id = "pkr_recovery_ready_#{suffix}"

    exhausted_state =
      Poker.initial_state(sim_id: exhausted_id, player_count: 4)
      |> with_run_metadata(%{
        domain: "poker",
        status: "running",
        resumable: true,
        recovery_attempts: 0,
        max_turns: 3,
        turns_completed: 3
      })

    resumable_state =
      Poker.initial_state(sim_id: resumable_id, player_count: 4)
      |> with_run_metadata(%{
        domain: "poker",
        status: "running",
        resumable: true,
        recovery_attempts: 0,
        max_turns: 50,
        turns_completed: 1
      })

    assert :ok = Store.put_state(exhausted_state)
    assert :ok = Store.put_state(resumable_state)

    manager_state =
      SimManager
      |> :sys.get_state()
      |> Map.merge(%{
        runners: %{},
        recovery_queue: [exhausted_id, resumable_id],
        recovery_failures: %{},
        max_concurrent_runners: 1
      })

    assert {:noreply, recovered_state} =
             SimManager.handle_info({:recover_persisted, 0}, manager_state)

    assert Store.get_state(exhausted_id).meta.run.status == "failed"
    assert Map.has_key?(recovered_state.runners, resumable_id)
    refute resumable_id in recovered_state.recovery_queue

    %{ref: runner, usage_collector: collector} = recovered_state.runners[resumable_id]

    on_exit(fn ->
      if Process.alive?(runner) do
        DynamicSupervisor.terminate_child(LemonSimUi.SimRunnerSupervisor, runner)
      end

      if Process.alive?(collector), do: Agent.stop(collector)
      Store.delete_state(exhausted_id)
      Store.delete_state(resumable_id)
    end)
  end

  test "runner teardown persists final usage before the collector is stopped" do
    sim_id = "pkr_final_usage_#{System.unique_integer([:positive])}"
    {:ok, collector} = SimUsage.start_link(sim_id)
    SimUsage.record_external_decision(collector, "player_1", "test-model")

    terminal_state =
      Poker.initial_state(sim_id: sim_id, player_count: 4)
      |> with_run_metadata(%{
        domain: "poker",
        status: "completed",
        resumable: false,
        started_at_ms: System.system_time(:millisecond) - 1_000,
        finished_at_ms: System.system_time(:millisecond)
      })

    assert :ok = Store.put_state(terminal_state)

    manager_state =
      SimManager
      |> :sys.get_state()
      |> Map.merge(%{
        runners: %{
          sim_id => %{ref: self(), domain: :poker, usage_collector: collector}
        },
        usage_artifacts: %{},
        recovery_queue: [],
        recovery_failures: %{}
      })

    assert {:noreply, stopped_state} =
             SimManager.handle_info({:DOWN, make_ref(), :process, self(), :normal}, manager_state)

    refute Process.alive?(collector)
    refute Map.has_key?(stopped_state.runners, sim_id)

    assert {:reply, usage, ^stopped_state} =
             SimManager.handle_call({:usage, sim_id}, self(), stopped_state)

    assert usage.totals.decisions == 1
    assert usage.actors["player_1"].model_id == "test-model"
    assert Store.get_state(sim_id).meta.run.usage.totals.decisions == 1

    on_exit(fn -> Store.delete_state(sim_id) end)
  end

  test "operator stop terminalizes a persisted run without a live runner" do
    sim_id = "ww_orphan_stop_#{System.unique_integer([:positive])}"
    cleanup_sim(sim_id)

    state =
      LemonSim.Kernel.State.new(
        sim_id: sim_id,
        world: %{status: "in_progress", players: %{}},
        meta: %{run: %{domain: "werewolf", status: "running", resumable: true}}
      )

    assert :ok = Store.put_state(state)
    assert :ok = SimManager.stop_sim(sim_id)

    stored = Store.get_state(sim_id)
    assert stored.meta.run.status == "stopped"
    assert stored.meta.run.failure_reason == "operator_stop"
    refute stored.meta.run.resumable
  end

  test "terminal snapshot retention keeps the newest configured records" do
    suffix = System.unique_integer([:positive])
    old_id = "ww_retention_old_#{suffix}"
    newer_id = "ww_retention_newer_#{suffix}"
    target_id = "ww_retention_target_#{suffix}"
    original_manager_state = :sys.get_state(SimManager)

    on_exit(fn ->
      :sys.replace_state(SimManager, fn _ -> original_manager_state end)
      Enum.each([old_id, newer_id, target_id], &Store.delete_state/1)
    end)

    :sys.replace_state(SimManager, fn state -> %{state | max_stored_simulations: 1} end)

    for {sim_id, finished_at_ms} <- [{old_id, 1}, {newer_id, 2}] do
      assert :ok =
               Store.put_state(
                 LemonSim.Kernel.State.new(
                   sim_id: sim_id,
                   world: %{status: "game_over"},
                   meta: %{
                     run: %{
                       status: "completed",
                       resumable: false,
                       finished_at_ms: finished_at_ms
                     }
                   }
                 )
               )
    end

    assert :ok =
             Store.put_state(
               LemonSim.Kernel.State.new(
                 sim_id: target_id,
                 world: %{status: "in_progress"},
                 meta: %{run: %{status: "running", resumable: true}}
               )
             )

    assert :ok = SimManager.stop_sim(target_id)
    assert Store.get_state(target_id).meta.run.status == "stopped"
    assert Store.get_state(old_id) == nil
    assert Store.get_state(newer_id) == nil
  end

  # Collects every broadcast state for `sim_id` up to and including the first
  # terminal one.
  defp collect_states_until_terminal(sim_id, timeout \\ 20_000, acc \\ []) do
    assert_receive %LemonCore.Event{type: :sim_world_updated, meta: %{sim_id: ^sim_id}} = event,
                   timeout

    acc =
      case event.payload do
        %{state: %State{} = state} -> acc ++ [state]
        _ -> acc
      end

    if acc != [] and LemonSim.Examples.terminal?(List.last(acc)) do
      acc
    else
      collect_states_until_terminal(sim_id, timeout, acc)
    end
  end

  # Scripted Tic Tac Toe player: every call claims the next free cell in 0..8,
  # so it never proposes an occupied cell.
  defp scripted_moves do
    {:ok, agent} = Agent.start_link(fn -> Enum.to_list(0..8) end)

    fn _model, _context, _stream_opts ->
      cell = Agent.get_and_update(agent, fn [cell | rest] -> {cell, rest} end)
      {:ok, tool_call("place_mark", %{"row" => div(cell, 3), "col" => rem(cell, 3)})}
    end
  end

  defp wait_until(fun, attempts \\ 150)

  defp wait_until(_fun, 0), do: flunk("condition not met in time")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      wait_until(fun, attempts - 1)
    end
  end

  defp tool_call(name, arguments) do
    %AssistantMessage{
      role: :assistant,
      content: [
        %ToolCall{
          type: :tool_call,
          id: "call-#{System.unique_integer([:positive])}",
          name: name,
          arguments: arguments
        }
      ],
      stop_reason: :tool_use,
      timestamp: System.system_time(:millisecond)
    }
  end

  defp fake_model do
    %Model{
      id: "test-model",
      name: "Test Model",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://example.invalid",
      reasoning: false,
      input: [:text],
      cost: %LemonAi.Types.ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 4_096,
      headers: %{},
      compat: nil
    }
  end

  defp with_run_metadata(state, run) do
    %{state | meta: Map.put(state.meta || %{}, :run, run)}
  end
end
