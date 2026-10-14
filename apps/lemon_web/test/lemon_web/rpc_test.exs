defmodule LemonWeb.RpcTest do
  use ExUnit.Case, async: false

  alias LemonWeb.Rpc

  test "dispatches registered methods in-process as the web operator" do
    assert {:ok, payload} = Rpc.call("health")
    assert is_map(payload)
    assert Rpc.available?("sessions.context")
    refute Rpc.available?("no.such.method")
  end

  test "unknown methods and invalid params return safe wire errors" do
    assert {:error, %{code: :method_not_found, message: message}} = Rpc.call("no.such.method")
    assert message =~ "no.such.method"

    assert {:error, %{code: code}} = Rpc.call("sessions.context", %{"sessionKey" => 42})
    assert code in [:invalid_request, :invalid_params]
  end

  test "internal error details never leak exception text" do
    assert %{code: :internal_error, details: nil} =
             Rpc.normalize_error({:internal_error, "Method execution failed", "secret path /x"})

    assert %{code: :internal_error, message: "The request could not be completed."} =
             Rpc.normalize_error({:EXIT, :boom})

    assert Rpc.message(%{message: ""}) == "The request could not be completed."
  end

  test "async handlers are reported" do
    assert Rpc.async?("sessions.compact")
    refute Rpc.async?("health")
  end
end
