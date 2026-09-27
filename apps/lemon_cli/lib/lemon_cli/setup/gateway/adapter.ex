defmodule LemonCli.Setup.Gateway.Adapter do
  @moduledoc """
  Behaviour for gateway transport setup adapters.

  Each transport (Telegram, Discord, …) implements this behaviour to
  participate in `lemon gateway setup`.

  An adapter is responsible for:
  - storing the bot token in encrypted secrets
  - restricting the transport to the owner's conversations (allowlist)
  - optionally running a connectivity smoke test against the transport API
  - writing the `[gateway.<transport>]` section to the canonical config
  """

  @doc "Machine-readable transport name, e.g. `\"telegram\"`."
  @callback name() :: String.t()

  @doc "Short human-readable description shown in the transport picker."
  @callback description() :: String.t()

  @doc """
  Run the interactive (or non-interactive) setup flow for this transport.

  `args` are the remaining CLI arguments after the transport name has been
  consumed.  `io` is the injected IO callbacks map with `:info`, `:error`,
  `:prompt`, and `:secret` keys.
  """
  @callback run([String.t()], map()) :: :ok | {:error, term()}
end
