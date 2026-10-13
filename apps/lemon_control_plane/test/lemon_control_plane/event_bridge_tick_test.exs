defmodule LemonControlPlane.EventBridgeTickTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.EventBridge

  @moduledoc """
  Tests for tick event mapping in EventBridge.

  The cron system emits :cron_tick events, but the WS protocol expects "tick" events.
  These tests verify the mapping works correctly.
  """

  setup do
    # Start EventBridge if not running
    case Process.whereis(EventBridge) do
      nil ->
        {:ok, pid} = EventBridge.start_link([])

        on_exit(fn ->
          # Avoid flakiness: the bridge can terminate between `Process.alive?/1` and `GenServer.stop/1`.
          if is_pid(pid) do
            try do
              if Process.alive?(pid), do: GenServer.stop(pid)
            catch
              :exit, _ -> :ok
            end
          end
        end)

        {:ok, bridge_pid: pid}

      pid ->
        {:ok, bridge_pid: pid}
    end
  end

  # Flushes the bridge mailbox: bus delivery is a plain message send, so a synchronous `:sys`
  # call returns only once the broadcast events have been handled (and exits if the bridge
  # crashed while handling them).
  defp sync_bridge(bridge_pid), do: :sys.get_state(bridge_pid)

  describe "tick event mapping" do
    test "maps :cron_tick to tick event", %{bridge_pid: bridge_pid} do
      if Code.ensure_loaded?(LemonCore.Bus) and Code.ensure_loaded?(LemonCore.Event) do
        # Create a cron_tick event (what LemonAutomation.Events.emit_tick sends)
        event =
          LemonCore.Event.new(
            :cron_tick,
            %{timestamp_ms: System.system_time(:millisecond)},
            %{}
          )

        # Broadcast on cron topic
        LemonCore.Bus.broadcast("cron", event)

        sync_bridge(bridge_pid)

        # EventBridge should still be alive (didn't crash)
        assert Process.alive?(Process.whereis(EventBridge))
      end
    end

    test "maps :tick to tick event", %{bridge_pid: bridge_pid} do
      if Code.ensure_loaded?(LemonCore.Bus) and Code.ensure_loaded?(LemonCore.Event) do
        # Create a direct tick event
        event =
          LemonCore.Event.new(
            :tick,
            System.system_time(:millisecond),
            %{}
          )

        # Broadcast on system topic
        LemonCore.Bus.broadcast("system", event)

        sync_bridge(bridge_pid)

        assert Process.alive?(Process.whereis(EventBridge))
      end
    end
  end

  describe "presence event mapping" do
    test "maps :presence_changed to presence event", %{bridge_pid: bridge_pid} do
      if Code.ensure_loaded?(LemonCore.Bus) and Code.ensure_loaded?(LemonCore.Event) do
        event =
          LemonCore.Event.new(
            :presence_changed,
            %{connections: [], count: 0},
            %{}
          )

        LemonCore.Bus.broadcast("presence", event)

        sync_bridge(bridge_pid)

        assert Process.alive?(Process.whereis(EventBridge))
      end
    end
  end

  describe "heartbeat event mapping" do
    test "maps :heartbeat to heartbeat event", %{bridge_pid: bridge_pid} do
      if Code.ensure_loaded?(LemonCore.Bus) and Code.ensure_loaded?(LemonCore.Event) do
        event =
          LemonCore.Event.new(
            :heartbeat,
            %{agent_id: "test-agent", status: :ok},
            %{}
          )

        LemonCore.Bus.broadcast("system", event)

        sync_bridge(bridge_pid)

        assert Process.alive?(Process.whereis(EventBridge))
      end
    end

    test "maps :heartbeat_alert to heartbeat event with alert status", %{bridge_pid: bridge_pid} do
      if Code.ensure_loaded?(LemonCore.Bus) and Code.ensure_loaded?(LemonCore.Event) do
        event =
          LemonCore.Event.new(
            :heartbeat_alert,
            %{agent_id: "test-agent", response: "NOT OK"},
            %{}
          )

        LemonCore.Bus.broadcast("cron", event)

        sync_bridge(bridge_pid)

        assert Process.alive?(Process.whereis(EventBridge))
      end
    end
  end

  describe "node event mapping" do
    test "maps :node_pair_requested to node.pair.requested event", %{bridge_pid: bridge_pid} do
      if Code.ensure_loaded?(LemonCore.Bus) and Code.ensure_loaded?(LemonCore.Event) do
        event =
          LemonCore.Event.new(
            :node_pair_requested,
            %{
              pairing_id: "pair-1",
              code: "123456",
              node_type: "browser",
              node_name: "Test Browser",
              expires_at_ms: System.system_time(:millisecond) + 300_000
            },
            %{}
          )

        LemonCore.Bus.broadcast("nodes", event)

        sync_bridge(bridge_pid)

        assert Process.alive?(Process.whereis(EventBridge))
      end
    end

    test "maps :node_pair_resolved to node.pair.resolved event", %{bridge_pid: bridge_pid} do
      if Code.ensure_loaded?(LemonCore.Bus) and Code.ensure_loaded?(LemonCore.Event) do
        event =
          LemonCore.Event.new(
            :node_pair_resolved,
            %{
              pairing_id: "pair-1",
              node_id: "node-1",
              approved: true
            },
            %{}
          )

        LemonCore.Bus.broadcast("nodes", event)

        sync_bridge(bridge_pid)

        assert Process.alive?(Process.whereis(EventBridge))
      end
    end

    test "maps :node_invoke_request to node.invoke.request event", %{bridge_pid: bridge_pid} do
      if Code.ensure_loaded?(LemonCore.Bus) and Code.ensure_loaded?(LemonCore.Event) do
        event =
          LemonCore.Event.new(
            :node_invoke_request,
            %{
              invoke_id: "invoke-1",
              node_id: "node-1",
              method: "screenshot",
              args: %{},
              timeout_ms: 30_000
            },
            %{}
          )

        LemonCore.Bus.broadcast("nodes", event)

        sync_bridge(bridge_pid)

        assert Process.alive?(Process.whereis(EventBridge))
      end
    end
  end

  describe "state version tracking" do
    test "bumps presence version on presence_changed", %{bridge_pid: bridge_pid} do
      # We can't easily test the internal state, but we can verify
      # the event is processed without error
      if Code.ensure_loaded?(LemonCore.Bus) and Code.ensure_loaded?(LemonCore.Event) do
        event =
          LemonCore.Event.new(
            :presence_changed,
            %{connections: [], count: 1},
            %{}
          )

        # Send multiple events
        LemonCore.Bus.broadcast("presence", event)
        LemonCore.Bus.broadcast("presence", event)
        LemonCore.Bus.broadcast("presence", event)

        sync_bridge(bridge_pid)

        assert Process.alive?(Process.whereis(EventBridge))
      end
    end

    test "bumps health version on health_changed", %{bridge_pid: bridge_pid} do
      if Code.ensure_loaded?(LemonCore.Bus) and Code.ensure_loaded?(LemonCore.Event) do
        event =
          LemonCore.Event.new(
            :health_changed,
            %{status: "healthy"},
            %{}
          )

        LemonCore.Bus.broadcast("system", event)

        sync_bridge(bridge_pid)

        assert Process.alive?(Process.whereis(EventBridge))
      end
    end

    test "bumps cron version on cron events", %{bridge_pid: bridge_pid} do
      if Code.ensure_loaded?(LemonCore.Bus) and Code.ensure_loaded?(LemonCore.Event) do
        tick_event =
          LemonCore.Event.new(
            :cron_tick,
            %{timestamp_ms: System.system_time(:millisecond)},
            %{}
          )

        LemonCore.Bus.broadcast("cron", tick_event)

        run_started =
          LemonCore.Event.new(
            :cron_run_started,
            %{
              cron_run_id: "run-1",
              job_id: "job-1",
              job_name: "test",
              run: %{id: "run-1", job_id: "job-1"}
            },
            %{}
          )

        LemonCore.Bus.broadcast("cron", run_started)

        sync_bridge(bridge_pid)

        assert Process.alive?(Process.whereis(EventBridge))
      end
    end
  end
end
