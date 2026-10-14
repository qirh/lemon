defmodule LemonWeb.LiveAuth do
  @moduledoc """
  `on_mount` hook that re-verifies operator access for every LiveView mount,
  including the connected (WebSocket) mount, using the session marker from the
  signed cookie and the actual socket peer (`peer_data`). A rotated or removed
  token sends the browser back to `/login`.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView

  alias LemonWeb.Auth

  def on_mount(:require_operator, _params, session, socket) do
    peer =
      case get_connect_info(socket, :peer_data) do
        %{address: address} -> address
        _ -> nil
      end

    case Auth.verify(session[Auth.session_key()], peer) do
      {:ok, access} ->
        {:cont, assign(socket, :operator_access, access)}

      {:error, _reason} ->
        {:halt, redirect(socket, to: "/login")}
    end
  end
end
