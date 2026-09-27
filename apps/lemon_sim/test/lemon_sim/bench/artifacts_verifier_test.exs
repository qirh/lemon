defmodule LemonSim.Bench.Artifacts.VerifierTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias LemonSim.Bench.Artifacts.{Bundle, Verifier}
  alias LemonSim.Bench.Suite
  alias LemonSim.Examples.Poker
  alias LemonSim.Examples.Poker.Artifacts, as: PokerArtifacts
  alias Mix.Tasks.Lemon.Sim.Verify, as: VerifyTask

  test "registered poker bundle recomputes and rejects a tampered scorecard" do
    artifact_dir = tmp_dir("poker_bundle")
    write_poker_bundle!(artifact_dir, "poker_bundle_test", 7)

    assert {:ok, verified} = Verifier.verify_run(artifact_dir)
    assert verified.manifest["sim"]["id"] == "poker"
    assert verified.scorecard["sim_id"] == "poker_bundle_test"
    assert verified.replay == %{batches: 0, events: 0}

    tamper_scorecard!(artifact_dir, fn scorecard ->
      Map.update!(scorecard, "hands_completed", &(&1 + 1))
    end)

    assert {:error, {:scorecard_mismatch, "poker"}} = Verifier.verify_run(artifact_dir)
  end

  test "bundle with hashes.json deleted and an edited scorecard fails verify and is excluded from recompute" do
    suite_dir = tmp_dir("suite_unhashed")
    good_dir = Path.join([suite_dir, "runs", "good", "1"])
    bad_dir = Path.join([suite_dir, "runs", "bad", "1"])

    write_poker_bundle!(good_dir, "poker_good", 10)
    write_poker_bundle!(bad_dir, "poker_bad", 11)

    File.rm!(Path.join(bad_dir, "hashes.json"))

    scorecard_path = Path.join(bad_dir, "scorecard.json")

    scorecard_path
    |> File.read!()
    |> Jason.decode!()
    |> Map.put("best_profit_loss", 1_000_000)
    |> Jason.encode!()
    |> then(&File.write!(scorecard_path, &1))

    assert {:error, {:missing_bundle_file, "hashes.json"}} = Verifier.verify_run(bad_dir)

    capture_io(:stderr, fn ->
      assert catch_exit(VerifyTask.run([bad_dir])) == {:shutdown, 1}
    end)

    write_suite_json!(suite_dir, [
      %{"competitor" => "good", "sim_id" => "poker_good", "artifact_dir" => "runs/good/1"},
      %{"competitor" => "bad", "sim_id" => "poker_bad", "artifact_dir" => "runs/bad/1"}
    ])

    assert {:ok, suite} = Suite.recompute(suite_dir)
    assert Enum.map(suite.rankings, & &1["competitor"]) == ["good"]
    assert [%{"competitor" => "bad", "error" => error}] = suite.failures
    assert error =~ "missing_bundle_file"
  end

  test "bundle without manifest.json fails verification" do
    artifact_dir = tmp_dir("poker_no_manifest")
    write_poker_bundle!(artifact_dir, "poker_no_manifest", 3)
    File.rm!(Path.join(artifact_dir, "manifest.json"))

    assert {:error, {:missing_bundle_file, "manifest.json"}} = Verifier.verify_run(artifact_dir)
  end

  test "replay-capable bundles must hash their replay inputs" do
    artifact_dir = tmp_dir("poker_no_inputs")
    state = Poker.initial_state(sim_id: "poker_no_inputs", player_count: 2, max_hands: 1, seed: 5)

    assert {:ok, _paths} =
             PokerArtifacts.write_run_artifacts(state, [], [],
               artifact_dir: artifact_dir,
               deterministic_artifacts?: true
             )

    assert {:error, {:missing_required_hashed_file, "config.json"}} =
             Verifier.verify_run(artifact_dir)
  end

  test "unregistered bundles still skip scorecard recompute" do
    artifact_dir = tmp_dir("unregistered_bundle")
    File.mkdir_p!(artifact_dir)

    usage = LemonSim.LLM.Usage.artifact(nil, "unregistered_bundle_test")

    contents = %{
      Path.join(artifact_dir, "final_world.json") => Bundle.encode_json(%{"status" => "done"}),
      Path.join(artifact_dir, "events.jsonl") => Bundle.jsonl([%{kind: "done", payload: %{}}]),
      Path.join(artifact_dir, "actions.jsonl") => "",
      Path.join(artifact_dir, "scorecard.json") => Bundle.encode_json(%{"made_up" => 1}),
      Path.join(artifact_dir, "usage.json") => LemonSim.LLM.Usage.encode_artifact(usage)
    }

    Bundle.write_bundle!(
      artifact_dir,
      contents,
      Path.join(artifact_dir, "hashes.json"),
      Path.join(artifact_dir, "manifest.json"),
      fn hashes ->
        %{
          schema_version: "lemon_sim.run.v1",
          sim: %{id: "unregistered", version: "1.0.0", ruleset_hash: nil, seed: nil},
          agent: nil,
          runtime: %{lemon_commit: nil, elixir: System.version(), otp: "test"},
          integrity: %{
            events_sha256: hashes.files["events.jsonl"],
            scorecard_sha256: hashes.files["scorecard.json"],
            usage_sha256: hashes.files["usage.json"]
          }
        }
      end
    )

    tamper_scorecard!(artifact_dir, fn scorecard -> Map.put(scorecard, "made_up", 2) end)

    assert {:ok, verified} = Verifier.verify_run(artifact_dir)
    assert verified.scorecard["made_up"] == 2
    assert verified.replay == :unsupported
  end

  defp write_poker_bundle!(artifact_dir, sim_id, seed) do
    state = Poker.initial_state(sim_id: sim_id, player_count: 2, max_hands: 1, seed: seed)

    assert {:ok, _paths} =
             PokerArtifacts.write_run_artifacts(state, [], [],
               artifact_dir: artifact_dir,
               deterministic_artifacts?: true,
               replay: %{config: PokerArtifacts.replay_config(state), batches: []}
             )
  end

  defp write_suite_json!(suite_dir, runs) do
    suite_json = %{
      "schema_version" => "lemon_sim.suite.v1",
      "spec" => %{
        "scenario" => "poker",
        "preset" => nil,
        "seeds" => [1],
        "competitors" =>
          Enum.map(runs, &%{"id" => &1["competitor"], "offline_strategy" => "fixture"})
      },
      "runs" =>
        runs
        |> Enum.with_index()
        |> Enum.map(fn {run, index} -> Map.merge(run, %{"index" => index, "seed" => 1}) end)
    }

    File.write!(Path.join(suite_dir, "suite.json"), Jason.encode!(suite_json, pretty: true))
  end

  defp tmp_dir(prefix) do
    dir = Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp tamper_scorecard!(artifact_dir, fun) do
    scorecard_path = Path.join(artifact_dir, "scorecard.json")
    manifest_path = Path.join(artifact_dir, "manifest.json")
    hashes_path = Path.join(artifact_dir, "hashes.json")

    scorecard =
      scorecard_path
      |> File.read!()
      |> Jason.decode!()
      |> fun.()

    File.write!(scorecard_path, Jason.encode!(scorecard, pretty: true))
    scorecard_hash = sha256(File.read!(scorecard_path))

    manifest =
      manifest_path
      |> File.read!()
      |> Jason.decode!()
      |> put_in(["integrity", "scorecard_sha256"], scorecard_hash)

    hashes =
      hashes_path
      |> File.read!()
      |> Jason.decode!()
      |> put_in(["files", "scorecard.json"], scorecard_hash)

    File.write!(manifest_path, Jason.encode!(manifest, pretty: true))
    File.write!(hashes_path, Jason.encode!(hashes, pretty: true))
  end

  defp sha256(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
end
