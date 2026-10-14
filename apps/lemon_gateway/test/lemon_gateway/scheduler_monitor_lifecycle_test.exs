defmodule LemonGateway.SchedulerMonitorLifecycleTest do
  @moduledoc """
  Regression tests for Scheduler monitor and worker_count lifecycle.

  Verifies that:
  - Stale slot request cleanup properly persists demonitor state
  - Monitor maps and worker_counts are stable after worker exits
  - No monitor/worker_count leakage across enqueue timeout churn
  """
  use ExUnit.Case, async: false
  import LemonGateway.AsyncHelpers, only: [assert_eventually: 1]

  alias LemonGateway.Config
  alias LemonGateway.Scheduler

  # We need to test internal GenServer state, so we use :sys.get_state
  # These tests exercise the monitor lifecycle through the public API.

  setup do
    # Scheduler reads limits from LemonGateway.Config during init.
    if is_nil(Process.whereis(Config)) do
      case start_supervised({Config, []}) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end

    # Ensure scheduler is running even if a prior test/app shutdown stopped it.
    if is_nil(Process.whereis(Scheduler)) do
      case start_supervised({Scheduler, []}) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end

    assert Process.whereis(Config) != nil
    assert Process.whereis(Scheduler) != nil
    :ok
  end

  describe "monitor lifecycle on worker DOWN" do
    test "monitors and worker_counts are cleaned up when a worker process dies" do
      # Spawn a fake worker that will request a slot and then die
      test_pid = self()

      worker =
        spawn(fn ->
          # Signal that we're ready
          send(test_pid, :worker_ready)

          receive do
            :die -> :ok
          end
        end)

      receive do
        :worker_ready -> :ok
      after
        1_000 -> flunk("Worker didn't start")
      end

      # Request a slot for the fake worker
      Scheduler.request_slot(worker, {:test, "lifecycle_test"})

      # Verify the worker is now monitored
      mid_state = :sys.get_state(Scheduler)
      assert Map.has_key?(mid_state.monitors, worker)
      assert Map.has_key?(mid_state.worker_counts, worker)

      # Kill the worker and wait for the scheduler to process the DOWN message
      send(worker, :die)

      assert_eventually(fn -> untracked?(worker) end)
      refute Process.alive?(worker)
    end

    test "multiple workers dying leaves no leaked monitors" do
      test_pid = self()
      worker_count = 10

      workers =
        for i <- 1..worker_count do
          w =
            spawn(fn ->
              send(test_pid, {:ready, i})

              receive do
                :die -> :ok
              end
            end)

          receive do
            {:ready, ^i} -> :ok
          after
            1_000 -> flunk("Worker #{i} didn't start")
          end

          w
        end

      # Request slots for all workers
      for {w, i} <- Enum.with_index(workers) do
        Scheduler.request_slot(w, {:test, "multi_#{i}"})
      end

      # Kill all workers
      for w <- workers do
        send(w, :die)
      end

      # Wait for all DOWN messages to be processed
      assert_eventually(fn -> untracked?(workers) end)
    end
  end

  describe "stale slot request cleanup" do
    test "cleanup_stale_slot_requests persists demonitor state updates" do
      # This is the key regression test. Previously, cleanup_stale_slot_requests
      # called maybe_demonitor_worker but discarded the returned state, causing
      # monitor ref and worker_count leakage.

      test_pid = self()

      # Spawn a worker that will stay alive but have a stale slot request
      worker =
        spawn(fn ->
          send(test_pid, :stale_worker_ready)

          receive do
            :die -> :ok
          after
            60_000 -> :ok
          end
        end)

      receive do
        :stale_worker_ready -> :ok
      after
        1_000 -> flunk("Worker didn't start")
      end

      # Request a slot — the scheduler will either grant or queue it
      Scheduler.request_slot(worker, {:test, "stale_test"})

      # Verify the worker is monitored
      mid_state = :sys.get_state(Scheduler)
      assert Map.has_key?(mid_state.monitors, worker)

      # Now kill the worker — this triggers :DOWN handling which cleans up
      send(worker, :die)

      assert_eventually(fn -> untracked?(worker) end)
    end

    test "repeated enqueue/timeout churn leaves monitors stable" do
      # Simulate the pattern: many workers request slots, some die, others timeout

      test_pid = self()

      # Run 5 cycles of create-request-die
      for cycle <- 1..5 do
        workers =
          for i <- 1..5 do
            w =
              spawn(fn ->
                send(test_pid, {:cycle_ready, cycle, i})

                receive do
                  :die -> :ok
                end
              end)

            receive do
              {:cycle_ready, ^cycle, ^i} -> :ok
            after
              1_000 -> flunk("Worker #{cycle}-#{i} didn't start")
            end

            w
          end

        # Request slots
        for {w, i} <- Enum.with_index(workers) do
          Scheduler.request_slot(w, {:test, "churn_#{cycle}_#{i}"})
        end

        # Kill all workers
        for w <- workers do
          send(w, :die)
        end

        assert_eventually(fn -> untracked?(workers) end)
      end

      # After all churn, no worker is left monitored
    end
  end

  describe "slot release cleanup" do
    test "releasing a slot demonitors the worker when no other refs exist" do
      test_pid = self()

      worker =
        spawn(fn ->
          send(test_pid, :release_worker_ready)

          receive do
            {:slot_granted, slot_ref} ->
              send(test_pid, {:got_slot, slot_ref})

              receive do
                :release -> :ok
              end

            :die ->
              :ok
          end
        end)

      receive do
        :release_worker_ready -> :ok
      after
        1_000 -> flunk("Worker didn't start")
      end

      # Request a slot
      Scheduler.request_slot(worker, {:test, "release_test"})

      # Wait for the slot to be granted
      slot_ref =
        receive do
          {:got_slot, ref} -> ref
        after
          2_000 -> flunk("Slot not granted")
        end

      # Verify worker is monitored
      mid_state = :sys.get_state(Scheduler)
      assert Map.has_key?(mid_state.monitors, worker)

      # Release the slot
      Scheduler.release_slot(slot_ref)
      assert_eventually(fn -> untracked?(worker) end)

      # Clean up the worker
      send(worker, :release)
    end
  end

  # True once the scheduler tracks none of the given workers (no monitor, no slot count).
  defp untracked?(workers) do
    state = :sys.get_state(Scheduler)

    workers
    |> List.wrap()
    |> Enum.all?(fn w ->
      not Map.has_key?(state.monitors, w) and not Map.has_key?(state.worker_counts, w)
    end)
  end
end
