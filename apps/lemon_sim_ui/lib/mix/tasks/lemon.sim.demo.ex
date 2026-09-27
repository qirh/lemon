defmodule Mix.Tasks.Lemon.Sim.Demo do
  use Mix.Task

  @shortdoc "Boot the sim UI and watch a keyless offline Werewolf game"

  @moduledoc """
  One-command, keyless LemonSim demo.

      mix lemon.sim.demo
      mix lemon.sim.demo --seed 42 --player-count 7 --step-delay-ms 600

  Boots `lemon_sim_ui` with its HTTP endpoint (unless it is already running in
  this VM), starts an offline Werewolf game driven by the deterministic
  heuristic seat policy (`LemonSim.Examples.Werewolf.OfflineRunner`), prints the
  spectator URL, and keeps serving until interrupted. No provider API keys or
  model configuration are read.

  If another node already serves the sim UI port, run the demo inside that
  node instead (`LemonSimUi.Demo.start_werewolf()` from its IEx shell) or pick
  another port with `LEMON_SIM_UI_PORT`.
  """

  @switches [
    seed: :integer,
    player_count: :integer,
    step_delay_ms: :integer,
    max_turns: :integer,
    sim_id: :string,
    help: :boolean
  ]

  @impl true
  def run(args) do
    {opts, argv, invalid} = OptionParser.parse(args, strict: @switches)

    cond do
      opts[:help] ->
        Mix.Task.run("help", ["lemon.sim.demo"])

      invalid != [] or argv != [] ->
        Mix.raise("invalid arguments: #{inspect(invalid ++ argv)}; see `mix help lemon.sim.demo`")

      true ->
        boot_ui!()

        case LemonSimUi.Demo.start_werewolf(Keyword.delete(opts, :help)) do
          {:ok, sim_id} ->
            announce(sim_id)
            unless iex_running?(), do: Process.sleep(:infinity)

          {:error, reason} ->
            Mix.raise("failed to start the demo Werewolf game: #{inspect(reason)}")
        end
    end
  end

  defp boot_ui! do
    if List.keymember?(Application.started_applications(), :lemon_sim_ui, 0) do
      :ok
    else
      Application.put_env(:phoenix, :serve_endpoints, true, persistent: true)
      Mix.Task.run("app.config")
      ensure_port_free!()

      case Application.ensure_all_started(:lemon_sim_ui) do
        {:ok, _started} -> :ok
        {:error, reason} -> Mix.raise("failed to start lemon_sim_ui: #{inspect(reason)}")
      end
    end
  end

  defp ensure_port_free! do
    port =
      :lemon_sim_ui
      |> Application.get_env(LemonSimUi.Endpoint, [])
      |> Keyword.get(:http, [])
      |> Keyword.get(:port)

    with port when is_integer(port) <- port,
         {:ok, socket} <- :gen_tcp.connect(~c"127.0.0.1", port, [], 500) do
      :gen_tcp.close(socket)

      Mix.raise("""
      port #{port} is already in use (another sim UI node?).
      Run `LemonSimUi.Demo.start_werewolf()` inside that node, or set LEMON_SIM_UI_PORT.
      """)
    else
      _ -> :ok
    end
  end

  defp announce(sim_id) do
    assets = Application.app_dir(:lemon_sim_ui, "priv/static/assets/app.js")

    unless File.exists?(assets) do
      Mix.shell().info(
        "Browser assets are missing; run `mix sim_ui.assets.setup && mix sim_ui.assets.build` first."
      )
    end

    Mix.shell().info("""
    Offline Werewolf demo #{sim_id} is running (heuristic seats, no API keys).
    Watch it live: #{LemonSimUi.Demo.watch_url(sim_id)}
    Press Ctrl+C twice to stop.
    """)
  end

  # IEx is not a dependency of this app; resolve it at runtime so the task
  # compiles without an :iex application dependency.
  defp iex_running? do
    iex = IEx
    Code.ensure_loaded?(iex) and apply(iex, :started?, [])
  end
end
