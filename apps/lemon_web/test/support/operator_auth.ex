defmodule LemonWeb.Test.OperatorAuth do
  @moduledoc """
  Test helpers for operator-authenticated web requests.

      setup :configure_operator_token

      test "...", %{conn: conn} do
        {:ok, view, _html} = live(conn, "/")
      end

  `configure_operator_token/1` installs a unique control-plane operator token
  (restored on exit) and returns `%{token: token, conn: authed_conn}` where the
  conn already carries the session marker a real login would store.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @app :lemon_control_plane
  @keys [:operator_token, :allow_unauthenticated_loopback_operator]

  @doc "ExUnit setup: unique operator token + an authenticated conn."
  def configure_operator_token(_context \\ %{}) do
    token = "web-test-token-#{System.unique_integer([:positive, :monotonic])}"
    restore_on_exit()
    Application.put_env(@app, :operator_token, token)
    Application.put_env(@app, :allow_unauthenticated_loopback_operator, false)
    %{token: token, conn: log_in(Phoenix.ConnTest.build_conn(), token)}
  end

  @doc "Removes the operator token (and tokenless loopback) for the test."
  def clear_operator_token(_context \\ %{}) do
    restore_on_exit()
    Application.delete_env(@app, :operator_token)
    Application.put_env(@app, :allow_unauthenticated_loopback_operator, false)
    :ok
  end

  @doc "Returns `conn` with the session marker for `token`."
  def log_in(conn, token) do
    {:ok, marker} = LemonWeb.Auth.login(token, {127, 0, 0, 1})
    Plug.Test.init_test_session(conn, %{LemonWeb.Auth.session_key() => marker})
  end

  defp restore_on_exit do
    previous = Map.new(@keys, &{&1, Application.fetch_env(@app, &1)})
    env_token = System.get_env("LEMON_CONTROL_PLANE_OPERATOR_TOKEN")
    System.delete_env("LEMON_CONTROL_PLANE_OPERATOR_TOKEN")

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(@app, key, value)
        {key, :error} -> Application.delete_env(@app, key)
      end)

      if env_token, do: System.put_env("LEMON_CONTROL_PLANE_OPERATOR_TOKEN", env_token)
    end)
  end
end
