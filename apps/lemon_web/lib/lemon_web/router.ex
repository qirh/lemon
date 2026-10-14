defmodule LemonWeb.Router do
  @moduledoc """
  Phoenix router for LemonWeb.

  Every page requires operator access (`LemonWeb.Plugs.RequireOperator` for
  HTTP, `LemonWeb.LiveAuth` for each LiveView mount). Only `/login` and
  `/healthz` are reachable without it.
  """

  use LemonWeb, :router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {LemonWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers, %{"referrer-policy" => "no-referrer"})
  end

  pipeline :operator do
    plug(LemonWeb.Plugs.RequireOperator)
  end

  scope "/", LemonWeb do
    pipe_through(:browser)

    get("/login", LoginController, :new)
    post("/login", LoginController, :create)
    delete("/logout", LoginController, :delete)
  end

  scope "/", LemonWeb do
    pipe_through([:browser, :operator])

    get("/sessions/:session_key/export/:format", SessionExportController, :show)

    live_session :operator, on_mount: [{LemonWeb.LiveAuth, :require_operator}] do
      live("/", SessionLive, :index)
      live("/chat/:session_key", SessionLive, :show)
      live("/sessions", ManagementLive, :index)
      live("/sessions/:session_key", ManagementLive, :show)
      live("/automation", WorkManagementLive, :index)
      live("/blueprints", BlueprintManagementLive, :index)
      live("/skills", SkillsLive, :index)
      live("/memory", MemoryManagementLive, :index)
      live("/mcp", McpLive, :index)
      live("/profiles", ProfileManagementLive, :index)
      live("/models", ProviderManagementLive, :index)
      live("/nodes", NodesLive, :index)
    end
  end

  # Health check endpoint for load balancers
  scope "/", LemonWeb do
    get("/healthz", HealthController, :index)
  end
end
