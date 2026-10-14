defmodule Mix.Tasks.Lemon.New do
  @shortdoc "Creates a new Lemon agent project"

  @moduledoc """
  Creates a new BEAM agent project wired to the Lemon platform packages.

      mix lemon.new my_agent

  The generated project is a plain, standalone Mix project — not an umbrella
  app — that depends on `lemon_core`, `lemon_ai` and `lemon_agent`. It contains
  a supervised agent, one example tool, a console channel, and a test suite that
  passes with no API key because the LLM is faked at the `stream_fn` seam.

  ## What you get

      my_agent/
        lib/my_agent.ex                  facade: MyAgent.ask/1
        lib/my_agent/application.ex      supervision tree
        lib/my_agent/agent.ex            model, prompt and tool wiring
        lib/my_agent/console.ex          the console channel: stdin -> agent -> stdout
        lib/my_agent/tools/word_count.ex the example tool
        test/support/fake_llm.ex         scripted LLM, so tests need no network

  ## Options

    * `--app` — the OTP application name. Defaults to the directory basename.
    * `--module` — the base module name. Defaults to the camel-cased app name.
    * `--channel` — additionally generate a real `LemonChannels.Plugin` adapter
      and a `LemonPlatformTest.PluginCase` compliance suite for it. This adds a
      dependency on `lemon_channels` and, for tests, `lemon_platform_test`.
    * `--memory` — additionally generate durable memory wiring on
      `lemon_memory` (adds a SQLite-backed dependency).
    * `--hex` — depend on the published Hex packages (`lemon_core`, `lemon_ai`,
      `lemon_agent`, and `lemon_memory` with `--memory`) as `~> 0.2`
      requirements. Needs no checkout of the `lemon` repository. Cannot be
      combined with `--channel`, `--lemon-path` or `--packages-path`:
      `lemon_channels` is not a published package, so a `--channel` project
      could not resolve. `mix deps.get` resolves once 0.2.0 is on hex.pm.
    * `--lemon-path` — path to a checkout of the `lemon` repository. The
      generated `mix.exs` uses path dependencies on the packages under its
      `apps/`, with the matching Hex requirement commented beneath each.
      Defaults to `$LEMON_PATH`, then to the checkout this installer was built
      from. An installer that was not built from a checkout (one installed from
      Hex) knows of none, and generates the `--hex` form instead.
    * `--packages-path` — instead of a checkout, a directory holding the
      published packages as unpacked Hex tarballs (`<dir>/lemon_core`,
      `<dir>/lemon_ai`, …, as `mix hex.build --unpack` writes them). This is
      how `scripts/verify_packages` proves a project builds from exactly what
      ships. Cannot be combined with `--channel`: `lemon_channels` is not a
      published package.
    * `--install` / `--no-install` — run `mix deps.get` in the new project.
      Defaults to asking.

  ## Examples

      mix lemon.new my_agent
      mix lemon.new my_agent --hex --memory
      mix lemon.new my_agent --channel --memory
      mix lemon.new agents/support_bot --app support_bot --module SupportBot
  """

  use Mix.Task

  alias LemonNew.{Generator, Project}

  # The lemon checkout this installer was built from, or nil. An archive built
  # out of a checkout (`installer/` under it) has one; one built from the Hex
  # package (`mix archive.install hex lemon_new`) is compiled somewhere that
  # is not a checkout and falls back to --hex.
  @built_from (
                root = Path.expand("../../../..", __DIR__)

                if File.exists?(Path.join(root, "apps/lemon_agent/mix.exs")), do: root
              )

  @switches [
    app: :string,
    module: :string,
    channel: :boolean,
    hex: :boolean,
    memory: :boolean,
    lemon_path: :string,
    packages_path: :string,
    install: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, argv} = OptionParser.parse!(argv, strict: @switches)

    case argv do
      [] ->
        Mix.raise("""
        Expected a project path.

            mix lemon.new PATH

        For example:

            mix lemon.new my_agent
        """)

      [base_path | _] ->
        generate(base_path, opts)
    end
  end

  defp generate(base_path, opts) do
    project =
      try do
        Project.new(base_path, package_source(opts))
      rescue
        error in ArgumentError -> Mix.raise(Exception.message(error))
      end

    Project.validate_app!(project.app)
    Project.validate_module!(project.app_module)
    check_directory!(project)

    created = Generator.copy(project)

    Mix.shell().info([:green, "* creating ", :reset, Path.relative_to_cwd(project.base_path)])

    for file <- created do
      Mix.shell().info([
        :green,
        "* creating ",
        :reset,
        Path.join(project.base_path, file) |> Path.relative_to_cwd()
      ])
    end

    maybe_install(project, opts)
    print_next_steps(project, opts)
  end

  defp check_directory!(%Project{base_path: path}) do
    if File.exists?(Path.join(path, "mix.exs")) do
      Mix.raise("""
      #{Path.relative_to_cwd(path)} already contains a mix.exs.

      Refusing to overwrite an existing project. Remove it or choose another path.
      """)
    end

    File.mkdir_p!(path)
  end

  # --hex and --packages-path are explicit and win over the checkout defaults;
  # combinations with --lemon-path are rejected by Project.new/2. With none of
  # them, a lemon checkout is used when one is known, else Hex.
  defp package_source(opts) do
    cond do
      opts[:hex] ->
        opts

      opts[:packages_path] ->
        Keyword.update!(opts, :packages_path, &resolve_packages_path/1)

      path = lemon_path(opts) ->
        Keyword.put(opts, :lemon_path, resolve_lemon_path(path))

      opts[:channel] ->
        Mix.raise("""
        --channel needs a lemon checkout, and none is known: this installer was \
        not built from one. lemon_channels is not published to Hex.

        Pass --lemon-path (or set $LEMON_PATH) to a checkout of the lemon \
        repository.
        """)

      true ->
        Mix.shell().info("No lemon checkout found; depending on the Hex packages (--hex).")
        Keyword.put(opts, :hex, true)
    end
  end

  defp lemon_path(opts) do
    Enum.find([opts[:lemon_path], System.get_env("LEMON_PATH"), @built_from], & &1)
  end

  defp resolve_packages_path(path) do
    path = Path.expand(path)

    unless File.exists?(Path.join(path, "lemon_agent/mix.exs")) do
      Mix.shell().error("""
      Warning: #{path} has no lemon_agent/mix.exs.

      --packages-path expects one unpacked package per directory, as written by
      `mix hex.build --unpack`. `mix deps.get` will fail until it points there.
      """)
    end

    path
  end

  defp resolve_lemon_path(path) do
    path = Path.expand(path)

    unless File.exists?(Path.join(path, "apps/lemon_agent/mix.exs")) do
      Mix.shell().error("""
      Warning: #{path} does not look like a lemon checkout (no apps/lemon_agent/mix.exs).

      The generated mix.exs will point its path dependencies there anyway, so
      `mix deps.get` will fail until you fix it. Pass --lemon-path or set
      $LEMON_PATH to the right directory.
      """)
    end

    path
  end

  defp maybe_install(project, opts) do
    install? =
      case Keyword.fetch(opts, :install) do
        {:ok, value} -> value
        :error -> Mix.shell().yes?("\nFetch and install dependencies?")
      end

    if install? do
      File.cd!(project.base_path, fn ->
        Mix.shell().cmd("mix deps.get")
      end)
    end
  end

  defp print_next_steps(project, opts) do
    relative = Path.relative_to_cwd(project.base_path)
    fetched? = opts[:install] == true

    Mix.shell().info("""

    Your Lemon agent project is ready.

        cd #{relative}#{unless fetched?, do: "\n    mix deps.get"}
        mix test

    The tests pass without an API key: `test/support/fake_llm.ex` scripts the
    model at the same seam the real provider plugs into. To talk to a real
    model, export a key and start the console:

        export ANTHROPIC_API_KEY=...
        mix run --no-halt -e "#{project.app_module}.Console.start()"

    Guides live in the lemon repo under docs/getting-started/.
    """)

    if project.source == :hex do
      Mix.shell().info(
        "The platform packages are Hex requirements (`~> 0.2`); `mix deps.get` " <>
          "resolves them once 0.2.0 is on hex.pm.\n"
      )
    end
  end
end
