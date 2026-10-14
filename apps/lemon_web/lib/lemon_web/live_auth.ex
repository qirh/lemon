defmodule LemonWeb.LiveAuth do
  @moduledoc """
  `on_mount` hook that re-verifies operator access for every LiveView mount,
  including the connected (WebSocket) mount, using the session marker from the
  signed cookie and the actual socket peer (`peer_data`). A rotated or removed
  token sends the browser back to `/login`.

  Only root LiveViews can read `connect_info`. A nested or sticky LiveView
  without a peer is admitted in token mode by the cookie marker alone; for
  tokenless loopback it relies on the `"parent_access"` value its verified
  parent signed into the child session at render time, and only while
  tokenless compatibility is still the active mode.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView

  alias LemonControlPlane.Auth.Authorize
  alias LemonWeb.Auth

  def on_mount(:require_operator, _params, session, socket) do
    peer = peer(socket)

    case Auth.verify(session[Auth.session_key()], peer) do
      {:ok, access} ->
        {:cont, assign(socket, :operator_access, access)}

      {:error, _reason} ->
        if is_nil(peer) and inherited_tokenless?(session) do
          {:cont, assign(socket, :operator_access, :tokenless_loopback)}
        else
          {:halt, redirect(socket, to: "/login")}
        end
    end
  end

  defp peer(socket) do
    case get_connect_info(socket, :peer_data) do
      %{address: address} -> address
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp inherited_tokenless?(%{"parent_access" => "tokenless_loopback"}) do
    is_nil(Authorize.configured_operator_token()) and
      Application.get_env(:lemon_control_plane, :allow_unauthenticated_loopback_operator, false) ==
        true
  end

  defp inherited_tokenless?(_session), do: false
end
