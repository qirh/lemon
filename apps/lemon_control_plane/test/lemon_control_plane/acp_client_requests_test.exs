defmodule LemonControlPlane.ACP.ClientRequestsTest do
  use ExUnit.Case, async: true
  alias LemonControlPlane.ACP.ClientRequests
  alias LemonCore.ACPClientBridge

  test "requester death withdraws an outstanding client callback" do
    owner = self()
    run = LemonCore.Id.run_id()

    {:ok, bridge} =
      ClientRequests.start_link(run, owner, fn _payload ->
        send(owner, {:waiting, self()})

        receive do
          :never -> {%{}, %{}}
        end
      end)

    requester =
      spawn(fn -> ACPClientBridge.request(run, "session/request_permission", %{}, :infinity) end)

    assert_receive {:waiting, callback}
    monitor = Process.monitor(callback)
    Process.exit(requester, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^callback, :killed}
    GenServer.stop(bridge)
  end

  test "long exit wait does not serialize independent output requests" do
    owner = self()
    run = LemonCore.Id.run_id()

    {:ok, bridge} =
      ClientRequests.start_link(run, owner, fn payload ->
        if payload.method == "terminal/wait_for_exit" do
          send(owner, {:waiting, self()})

          receive do
            :never -> :ok
          end
        end

        {%{"result" => %{"output" => "live"}}, %{"method" => payload.method}}
      end)

    waiter =
      spawn(fn -> ACPClientBridge.request(run, "terminal/wait_for_exit", %{}, :infinity) end)

    assert_receive {:waiting, _}

    assert {:ok, %{"result" => %{"output" => "live"}}} =
             ACPClientBridge.request(run, "terminal/output", %{}, 500)

    Process.exit(waiter, :kill)
    GenServer.stop(bridge)
  end
end
