defmodule LemonBrowser.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: LemonBrowser.CloudSessionRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: LemonBrowser.CloudSessionSupervisor},
      {Registry, keys: :unique, name: LemonBrowser.CamofoxSessionRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: LemonBrowser.CamofoxSessionSupervisor},
      LemonBrowser.HybridRouter,
      LemonBrowser.LocalServer,
      LemonBrowser.ControllerBroker
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: LemonBrowser.Supervisor)
  end
end
