defmodule LemonSim.Bench.Artifacts.ReplayTest do
  use ExUnit.Case, async: true

  alias LemonSim.Bench.Artifacts.Verifier
  alias LemonSim.Bench.Scorecard.Registry
  alias LemonSim.Bench.Suite
  alias LemonSim.Examples.{Poker, VendingBench, Werewolf}

  # Byte-identical Werewolf bundles need the seeded, world-carried RNG from the
  # SimDeterminism workstream (Werewolf.initial_state(seed:) + Rng-driven
  # updaters); with process-global :rand the second run deals different roles.
  test "werewolf offline heuristic runs are byte-identical per seed and replay-verify" do
    dir_a = tmp_dir("ww_heuristic_a")
    dir_b = tmp_dir("ww_heuristic_b")

    for dir <- [dir_a, dir_b] do
      assert {:ok, %{state: state, steps: steps}} =
               Werewolf.run_offline_strategy("heuristic",
                 seed: 3,
                 sim_id: "ww_heuristic_repro",
                 player_count: 6,
                 artifact_dir: dir,
                 deterministic_artifacts?: true
               )

      assert state.world.status == "game_over"
      assert state.world.winner in ["villagers", "werewolves"]
      assert steps > 0
    end

    assert bundle_files(dir_a) == bundle_files(dir_b)
    assert {:ok, %{replay: %{batches: batches}}} = Verifier.verify_run(dir_a)
    assert batches > 0
  end

  test "editing one werewolf events.jsonl line and rehashing fails replay verification" do
    dir = tmp_dir("ww_tamper")

    assert {:ok, _result} =
             Werewolf.run_offline_strategy("heuristic",
               seed: 5,
               player_count: 5,
               artifact_dir: dir,
               deterministic_artifacts?: true
             )

    assert {:ok, _verified} = Verifier.verify_run(dir)

    tamper_jsonl_line!(dir, "events.jsonl", 3, fn event ->
      put_in(event, ["payload", "tampered"], true)
    end)

    assert {:error, {:replay_mismatch, {:events_jsonl_line, 3}}} = Verifier.verify_run(dir)
  end

  test "poker heuristic bundle replays; a consistently forged world and scorecard fail" do
    dir = tmp_dir("poker_forged")

    assert {:ok, %{state: state}} =
             Poker.run_offline_strategy("heuristic",
               seed: 9,
               player_count: 3,
               max_hands: 3,
               artifact_dir: dir,
               deterministic_artifacts?: true
             )

    assert state.world.completed_hands > 0
    assert {:ok, %{replay: %{batches: batches}}} = Verifier.verify_run(dir)
    assert batches > 0

    # Forge the final world and recompute a matching scorecard and hashes: the
    # hash and scorecard checks alone would accept this bundle.
    forged_world =
      dir
      |> read_json("final_world.json")
      |> put_in(["player_stats", "player_1", "hands_won"], 99)

    scorecard = read_json(dir, "scorecard.json")
    {:ok, forged_scorecard} = Registry.scorecard("poker", forged_world)

    forged_scorecard =
      forged_scorecard
      |> Jason.encode!()
      |> Jason.decode!()
      |> Map.put("sim_id", scorecard["sim_id"])

    rewrite_hashed!(dir, "final_world.json", Jason.encode!(forged_world, pretty: true))
    rewrite_hashed!(dir, "scorecard.json", Jason.encode!(forged_scorecard, pretty: true))

    assert {:error, {:replay_mismatch, {:final_world, "player_stats"}}} = Verifier.verify_run(dir)
  end

  test "editing one vending bench events.jsonl line and rehashing fails replay verification" do
    dir = tmp_dir("vb_tamper")

    assert {:ok, _result} =
             VendingBench.run_offline_strategy("baseline",
               sim_id: "vb_replay_tamper",
               max_days: 2,
               seed: 1,
               driver_max_turns: 10,
               artifact_dir: dir,
               deterministic_artifacts?: true
             )

    assert {:ok, %{replay: %{batches: batches}}} = Verifier.verify_run(dir)
    assert batches > 0

    tamper_jsonl_line!(dir, "events.jsonl", 1, fn event ->
      put_in(event, ["payload", "tampered"], true)
    end)

    assert {:error, {:replay_mismatch, {:events_jsonl_line, 1}}} = Verifier.verify_run(dir)
  end

  test "werewolf and poker heuristic suites rank verified keyless runs" do
    for scenario <- ["werewolf", "poker"] do
      suite_dir = tmp_dir("#{scenario}_suite")

      assert {:ok, %{suite: suite}} =
               Suite.run(
                 %{
                   "scenario" => scenario,
                   "preset" => "ci",
                   "seeds" => [1],
                   "competitors" => [%{"offline_strategy" => "heuristic"}]
                 },
                 suite_dir: suite_dir
               )

      assert suite.failures == []
      assert [%{"competitor" => "heuristic", "included_runs" => 1}] = suite.rankings
    end
  end

  defp bundle_files(dir) do
    dir
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Map.new(&{Path.relative_to(&1, dir), File.read!(&1)})
  end

  defp tamper_jsonl_line!(dir, file, line_no, fun) do
    body =
      dir
      |> Path.join(file)
      |> File.read!()
      |> String.split("\n", trim: true)
      |> List.update_at(line_no - 1, fn line ->
        line |> Jason.decode!() |> fun.() |> Jason.encode!()
      end)
      |> Enum.map_join(&(&1 <> "\n"))

    rewrite_hashed!(dir, file, body)
  end

  # Rewrites a bundle file and re-signs hashes.json plus the manifest integrity
  # block, as a tamperer would.
  defp rewrite_hashed!(dir, file, body) do
    File.write!(Path.join(dir, file), body)
    hash = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

    hashes = dir |> read_json("hashes.json") |> put_in(["files", file], hash)
    File.write!(Path.join(dir, "hashes.json"), Jason.encode!(hashes, pretty: true))

    integrity_key =
      case file do
        "events.jsonl" -> "events_sha256"
        "scorecard.json" -> "scorecard_sha256"
        _ -> nil
      end

    if integrity_key do
      manifest = dir |> read_json("manifest.json") |> put_in(["integrity", integrity_key], hash)
      File.write!(Path.join(dir, "manifest.json"), Jason.encode!(manifest, pretty: true))
    end
  end

  defp read_json(dir, file), do: dir |> Path.join(file) |> File.read!() |> Jason.decode!()

  defp tmp_dir(prefix) do
    dir = Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end
end
