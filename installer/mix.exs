defmodule LemonNew.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/z80dev/lemon"

  # This file ships verbatim in the hex tarball, so it must not read anything
  # outside its own directory. The templates the generator embeds at compile
  # time live in `templates/`, inside the package.
  #
  # Installed either way as a local Mix archive: from a lemon checkout
  # (`MIX_ENV=prod mix archive.build`) or, once published, from Hex
  # (`mix archive.install hex lemon_new`).
  def project do
    [
      app: :lemon_new,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "lemon_new",
      description: description(),
      package: package()
    ]
  end

  def application do
    [extra_applications: [:eex]]
  end

  defp description do
    "Project generator for the Lemon agent platform: `mix lemon.new` scaffolds " <>
      "a supervised agent with a tool, a console channel and an offline test suite."
  end

  defp package do
    [
      licenses: ["MIT"],
      files: ~w(lib templates mix.exs README.md CHANGELOG.md LICENSE),
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/installer/CHANGELOG.md"
      }
    ]
  end

  # Deliberately none. The installer is distributed as a mix archive, which
  # cannot carry dependencies: anything listed here is simply unavailable at
  # `mix lemon.new` time. Templates are compiled into the beam files.
  defp deps, do: []
end
