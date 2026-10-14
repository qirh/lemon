defmodule LemonOmp.MixProject do
  use Mix.Project

  def project do
    [
      app: :lemon_omp,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      test_pattern: "*_test.exs",
      elixirc_paths: elixirc_paths(Mix.env()),
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      test_coverage: [summary: [threshold: 60]],
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {LemonOmp.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:lemon_core, in_umbrella: true},
      # The `omp` agent tool implements the platform tool contract and registers
      # itself through `LemonAgent.ToolRegistry`; nothing in the coding product
      # names this app.
      {:lemon_agent, in_umbrella: true},
      {:lemon_ai, in_umbrella: true},
      {:jason, "~> 1.4"}
    ]
  end
end
