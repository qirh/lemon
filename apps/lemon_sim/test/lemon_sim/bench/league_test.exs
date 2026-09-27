defmodule LemonSim.Bench.LeagueTest do
  use ExUnit.Case, async: true

  alias LemonSim.Bench.League
  alias LemonSim.Bench.League.Registry
  alias LemonSim.Examples.Poker
  alias LemonSim.Examples.Werewolf

  @moduletag :tmp_dir

  describe "plan_match/2" do
    test "is deterministic for a given seed and samples without replacement" do
      pool = ["a:m1", "b:m2", "c:m3", "d:m4", "e:m5", "f:m6", "g:m7"]

      plan1 = League.plan_match(pool, player_count: 6, seed: 42)
      plan2 = League.plan_match(pool, player_count: 6, seed: 42)

      assert plan1 == plan2
      assert length(plan1.model_specs) == 6
      assert plan1.model_specs == Enum.uniq(plan1.model_specs)
      assert Enum.all?(plan1.model_specs, &(&1 in pool))
    end

    test "cycles a small pool to fill all seats" do
      plan = League.plan_match(["a:m1", "b:m2"], player_count: 6, seed: 7)

      counts = Enum.frequencies(plan.model_specs)
      assert counts["a:m1"] == 3
      assert counts["b:m2"] == 3
    end

    test "different seeds vary assignments and a missing seed is generated" do
      pool = Enum.map(1..8, &"p:m#{&1}")

      plans =
        Enum.map(1..20, fn seed ->
          League.plan_match(pool, player_count: 8, seed: seed).model_specs
        end)

      assert plans |> Enum.uniq() |> length() > 1
      assert League.plan_match(pool, player_count: 5).seed > 0
    end

    test "rotation index gives every model every seat across a full cycle" do
      pool = Enum.map(1..5, &"provider:model-#{&1}")

      plans =
        Enum.map(0..4, fn rotation_index ->
          League.plan_match(pool,
            player_count: 5,
            seed: 100 + rotation_index,
            rotation_index: rotation_index
          ).model_specs
        end)

      for seat_index <- 0..4 do
        assert plans |> Enum.map(&Enum.at(&1, seat_index)) |> Enum.sort() == Enum.sort(pool)
      end
    end
  end

  describe "registry" do
    test "registers the arena scenarios" do
      assert Registry.scenario_ids() == ["poker", "werewolf"]

      assert {:ok, Werewolf.League} = Registry.fetch(:werewolf)
      assert Registry.get("nope") == nil
    end
  end

  describe "team mode (werewolf adapter)" do
    test "records per-role seats and rates winners above losers", %{tmp_dir: dir} do
      for index <- 1..4 do
        record =
          League.game_record(Werewolf.League, werewolf_world(),
            game_id: "g#{index}",
            recorded_at: "2026-07-06T00:00:0#{index}Z",
            seed: index
          )

        {:ok, _} = League.record_game!(dir, record)
      end

      {:ok, league} = League.load(dir)

      assert league["scenario"] == "werewolf"
      assert league["mode"] == "team"
      assert league["game_count"] == 4
      assert league["rating_status"] == "provisional"

      [top | _] = league["models"]
      assert top["model"] in ["anthropic/claude-x", "google/gemini-x"]

      wolf = Enum.find(league["models"], &(&1["model"] == "openai/gpt-x"))
      assert wolf["rating"] < top["rating"]
      assert wolf["roles"]["werewolf"]["seats"] == 4
      assert wolf["roles"]["werewolf"]["metrics"]["failed_kills"] == 4

      seer = Enum.find(league["models"], &(&1["model"] == "anthropic/claude-x"))
      assert seer["roles"]["seer"]["metrics"]["wolf_checks_found"] == 4
      assert is_number(seer["role_adjusted_win_rate"])
    end

    test "failed attempts affect reliability without changing game ratings", %{tmp_dir: dir} do
      completed =
        League.game_record(Werewolf.League, werewolf_world(),
          game_id: "complete",
          recorded_at: "2026-07-06T00:00:00Z"
        )

      failed =
        League.game_record(Werewolf.League, werewolf_world(),
          game_id: "failed",
          recorded_at: "2026-07-06T00:01:00Z",
          status: "failed",
          failure_reason: "model returned no tool call",
          failure_actor: "Cora",
          failure_model: "openai/gpt-x"
        )

      {:ok, _} = League.record_game!(dir, completed)
      {:ok, league} = League.record_game!(dir, failed)

      assert league["game_count"] == 1
      assert league["attempt_count"] == 2
      assert league["failed_attempt_count"] == 1
      assert hd(league["recent_failed_attempts"])["game_id"] == "failed"

      row = Enum.find(league["models"], &(&1["model"] == "openai/gpt-x"))
      assert row["games"] == 1
      assert row["attempts"] == 2
      assert row["failed_attempts"] == 1
      assert row["completion_rate"] == 0.5

      unaffected = Enum.find(league["models"], &(&1["model"] == "anthropic/claude-x"))
      assert unaffected["failed_attempts"] == 0
      assert unaffected["completion_rate"] == 1.0
    end
  end

  describe "ranked mode (poker adapter)" do
    test "pairwise ratings follow final chip stacks", %{tmp_dir: dir} do
      record =
        League.game_record(Poker.League, poker_world(),
          game_id: "p1",
          recorded_at: "2026-07-06T00:00:00Z"
        )

      {:ok, league} = League.record_game!(dir, record)

      assert record["mode"] == "ranked"
      assert record["direction"] == "maximize"
      assert record["winner"] == "player_1"
      assert record["rounds"] == 12

      winner_seat = record["seats"]["player_1"]
      assert winner_seat["won"]
      assert winner_seat["model"] == "anthropic/claude-x"
      assert winner_seat["value"] == 4200
      assert winner_seat["metrics"]["profit_loss"] == 2200
      assert winner_seat["metrics"]["hands_won"] == 6

      [top | _rest] = league["models"]
      assert top["model"] == "anthropic/claude-x"

      bottom = List.last(league["models"])
      assert bottom["model"] == "openai/gpt-x"
      assert bottom["rating"] < top["rating"]
    end
  end

  describe "persistence" do
    test "recompute is byte-deterministic and load round-trips", %{tmp_dir: dir} do
      record =
        League.game_record(Werewolf.League, werewolf_world(),
          game_id: "g1",
          recorded_at: "2026-07-06T00:00:00Z"
        )

      {:ok, league} = League.record_game!(dir, record)
      first = File.read!(Path.join(dir, "league.json"))
      {:ok, _} = League.recompute!(dir)

      assert File.read!(Path.join(dir, "league.json")) == first
      assert {:ok, ^league} = League.load(dir)
      assert File.regular?(Path.join(dir, "league.md"))
    end

    test "rolling retention removes oldest records and recomputes standings", %{tmp_dir: dir} do
      for index <- 1..4 do
        record =
          League.game_record(Werewolf.League, werewolf_world(),
            game_id: "retained-#{index}",
            recorded_at: "2026-07-06T00:00:0#{index}Z"
          )

        {:ok, _league} = League.record_game!(dir, record, max_game_records: 2)
      end

      assert Enum.map(League.load_games(dir), & &1["game_id"]) == ["retained-3", "retained-4"]
      assert {:ok, %{"game_count" => 2}} = League.load(dir)
      refute File.exists?(Path.join([dir, "games", "retained-1.json"]))
    end
  end

  ## Fixture worlds (minimal finished worlds per scenario)

  defp werewolf_world do
    %{
      status: "game_over",
      winner: "villagers",
      day_number: 3,
      players: %{
        "Aria" => %{role: "werewolf", model: "openai/gpt-x", status: "dead"},
        "Brin" => %{role: "seer", model: "anthropic/claude-x", status: "alive"},
        "Cole" => %{role: "doctor", model: "google/gemini-x", status: "alive"},
        "Dara" => %{role: "villager", model: "anthropic/claude-x", status: "alive"}
      },
      vote_history: [
        %{voter: "Brin", target: "Aria", voter_role: "seer", target_role: "werewolf"}
      ],
      night_history: [
        %{player: "Aria", action: "choose_victim", successful: false},
        %{player: "Brin", action: "investigate", result: "werewolf"}
      ]
    }
  end

  defp poker_world do
    %{
      status: "game_over",
      winner: "player_1",
      winner_ids: ["player_1"],
      completed_hands: 12,
      table: %{big_blind: 100, small_blind: 50},
      players: %{
        "player_1" => %{seat: 1, model: "anthropic/claude-x"},
        "player_2" => %{seat: 2, model: "zai/glm-5"},
        "player_3" => %{seat: 3, model: "openai/gpt-x"}
      },
      chip_counts: [
        %{"seat" => 1, "player_id" => "player_1", "stack" => 4200, "status" => "active"},
        %{"seat" => 2, "player_id" => "player_2", "stack" => 1500, "status" => "active"},
        %{"seat" => 3, "player_id" => "player_3", "stack" => 300, "status" => "active"}
      ],
      player_stats: %{
        "player_1" => poker_stats(hands_won: 6, vpip_hands: 8, pfr_hands: 5),
        "player_2" => poker_stats(hands_won: 4, vpip_hands: 6, pfr_hands: 3),
        "player_3" => poker_stats(hands_won: 2, vpip_hands: 10, pfr_hands: 1)
      }
    }
  end

  defp poker_stats(overrides) do
    Enum.into(overrides, %{
      starting_stack: 2000,
      hands_played: 12,
      hands_won: 0,
      vpip_hands: 0,
      pfr_hands: 0,
      total_actions: 30,
      fold_count: 5,
      check_count: 5,
      call_count: 8,
      bet_count: 6,
      raise_count: 6
    })
  end
end
