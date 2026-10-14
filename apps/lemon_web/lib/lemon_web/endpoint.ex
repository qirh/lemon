defmodule LemonWeb.Endpoint do
  @moduledoc "Phoenix endpoint for the LemonWeb application."

  use Phoenix.Endpoint, otp_app: :lemon_web

  # The cookie is signed and encrypted with secret_key_base and is httpOnly.
  # It carries only the derived operator marker (see LemonWeb.Auth).
  @session_options [
    store: :cookie,
    key: "_lemon_web_key",
    signing_salt: "lemonweb",
    encryption_salt: "lemonweb-operator",
    same_site: "Lax",
    http_only: true,
    max_age: 14 * 24 * 60 * 60
  ]

  @plain_session Plug.Session.init(@session_options)
  @secure_session Plug.Session.init(Keyword.put(@session_options, :secure, true))

  @doc false
  def session_options, do: @session_options

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [:peer_data, session: @session_options]],
    longpoll: false
  )

  plug(Plug.Static,
    at: "/",
    from: :lemon_web,
    gzip: false,
    only: LemonWeb.static_paths()
  )

  if code_reloading? do
    plug(Phoenix.CodeReloader)
    plug(Phoenix.LiveReloader)
  end

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(:session)
  plug(LemonWeb.Router)

  # Mark the cookie Secure whenever the request itself arrived over TLS.
  defp session(%Plug.Conn{scheme: :https} = conn, _opts),
    do: Plug.Session.call(conn, @secure_session)

  defp session(conn, _opts), do: Plug.Session.call(conn, @plain_session)
end
