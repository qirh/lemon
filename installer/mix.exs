defmodule LemonNew.MixProject do
  use Mix.Project

  # Built and installed as a local Mix archive from a lemon checkout
  # (`MIX_ENV=prod mix archive.build`); it is not published to Hex.
  def project do
    [
      app: :lemon_new,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:eex]]
  end

  # Deliberately none. The installer is distributed as a mix archive, which
  # cannot carry dependencies: anything listed here is simply unavailable at
  # `mix lemon.new` time. Templates are compiled into the beam files.
  defp deps, do: []
end
