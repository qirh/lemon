defmodule Mix.Tasks.Lemon.Sim.Verify do
  @moduledoc """
  Verify a LemonSim run artifact bundle.

      mix lemon.sim.verify path/to/run

  Checks every hash in `hashes.json`, re-folds `inputs.jsonl` through the
  domain updater for replay-capable domains (vending_bench, werewolf, poker)
  and compares the result with `events.jsonl` and `final_world.json`, then
  recomputes the scorecard. Bundles without `manifest.json`/`hashes.json`
  fail. Exits non-zero on any failure.
  """

  use Mix.Task

  alias Mix.Tasks.Lemon.Sim.Common

  @impl true
  def run(args) do
    case args do
      [artifact_dir] ->
        Common.ensure_runtime_started!()

        case LemonSim.Bench.Artifacts.Verifier.verify_run(artifact_dir) do
          {:ok, result} ->
            Mix.shell().info("Verified #{get_in(result.manifest, ["sim", "id"])} run")
            Mix.shell().info(replay_line(result.replay))
            Mix.shell().info("Status: #{result.scorecard["status"]}")

          {:error, reason} ->
            Mix.shell().error("Verification failed: #{inspect(reason)}")
            exit({:shutdown, 1})
        end

      _ ->
        Mix.shell().error(@moduledoc)
        exit({:shutdown, 1})
    end
  end

  defp replay_line(%{batches: batches, events: events}),
    do: "Replay: #{batches} input batches re-folded into #{events} events; final world matches"

  defp replay_line(:unsupported), do: "Replay: not supported for this domain (hashes only)"
end
