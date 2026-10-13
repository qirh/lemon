defmodule LemonControlPlane.ACP.ConnectionTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias LemonControlPlane.ACP.Connection
  alias LemonControlPlane.HTTP.Router

  test "malformed JSON produces a protocol error without killing the connection" do
    {:ok, state} = Connection.init([])

    assert {:push, {:text, encoded}, ^state} =
             Connection.handle_in({"{broken", [opcode: :text]}, state)

    assert Jason.decode!(encoded) == %{
             "jsonrpc" => "2.0",
             "id" => nil,
             "error" => %{"code" => -32_700, "message" => "parse error"}
           }

    assert {:ok, ^state} =
             Connection.handle_in(
               {~s({"jsonrpc":"2.0","id":"unknown","result":{}}), [opcode: :text]},
               state
             )
  end

  test "session/cancel releases a pending permission callback" do
    {:ok, state} = Connection.init([])
    ref = make_ref()
    state = %{state | clients: %{"permission" => {self(), ref, "session"}}}
    request = ~s({"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"session"}})
    assert {:ok, state} = Connection.handle_in({request, [opcode: :text]}, state)
    assert state.clients == %{}
    assert_receive {:acp_client_response, ^ref, {:error, :cancelled}}
    Connection.terminate(:normal, state)
  end

  test "duplex transport is not exposed by the optional unauthenticated HTTP ACP endpoint" do
    previous = Application.get_env(:lemon_control_plane, :operator_token)

    previous_loopback =
      Application.get_env(:lemon_control_plane, :allow_unauthenticated_loopback_operator)

    Application.put_env(:lemon_control_plane, :operator_token, "transport-test-token")
    Application.put_env(:lemon_control_plane, :allow_unauthenticated_loopback_operator, false)

    on_exit(fn ->
      restore(:operator_token, previous)
      restore(:allow_unauthenticated_loopback_operator, previous_loopback)
    end)

    response = conn(:get, "/acp/ws") |> Router.call(Router.init([]))
    assert response.status == 401

    response =
      conn(:get, "/acp/ws")
      |> put_req_header("authorization", "Bearer invalid")
      |> Router.call(Router.init([]))

    assert response.status == 401
  end

  defp restore(key, nil), do: Application.delete_env(:lemon_control_plane, key)
  defp restore(key, value), do: Application.put_env(:lemon_control_plane, key, value)
end
