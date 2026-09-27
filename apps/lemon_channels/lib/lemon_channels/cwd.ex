defmodule LemonChannels.Cwd do
  @moduledoc """
  Default working directory for channel adapters (`/cwd`, `/file`, `/new`
  path selectors): configured `gateway.default_cwd`, else the assistant home.
  Matches the cwd the router gives channel-originated runs.
  """

  alias LemonCore.Cwd, as: SharedCwd

  @spec default_cwd() :: String.t()
  def default_cwd, do: SharedCwd.channel_default_cwd()
end
