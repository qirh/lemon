defmodule LemonControlPlane.WS.HeartbeatTest do
  use ExUnit.Case, async: true

  alias LemonControlPlane.WS.Connection

  test "authenticated heartbeats are RFC ping frames without consuming event sequence" do
    state = %Connection{connected: true, event_seq: 7, state_version: %{health: 2}}
    assert {:push, {:ping, ""}, next} = Connection.handle_info(:heartbeat, state)
    assert next.event_seq == 7
    assert next.state_version == %{health: 2}
    assert is_reference(next.heartbeat_timer_ref)
    remaining = Process.cancel_timer(next.heartbeat_timer_ref)
    assert remaining > 24_000 and remaining <= 25_000
  end

  test "unauthenticated connections do not schedule heartbeats" do
    state = %Connection{connected: false, event_seq: 0, state_version: %{}}
    assert {:ok, ^state} = Connection.handle_info(:heartbeat, state)
  end

  test "termination cancels the pending ping timer" do
    timer = Process.send_after(self(), :heartbeat, 25_000)

    state = %Connection{
      conn_id: "heartbeat-cleanup",
      connected: false,
      heartbeat_timer_ref: timer
    }

    assert :ok = Connection.terminate(:normal, state)
    assert Process.read_timer(timer) == false
  end
end
