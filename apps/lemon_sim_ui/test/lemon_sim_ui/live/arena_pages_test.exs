defmodule LemonSimUi.ArenaPagesTest do
  use LemonSimUi.ConnCase

  alias LemonSim.Bench.League
  alias LemonSimUi.Arena

  @moduletag :tmp_dir

  defp with_league_dir(domain, tmp_dir) do
    original = Application.get_env(:lemon_sim_ui, :arenas)
    Application.put_env(:lemon_sim_ui, :arenas, [{domain, [league_dir: tmp_dir]}])

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:lemon_sim_ui, :arenas)
        value -> Application.put_env(:lemon_sim_ui, :arenas, value)
      end
    end)
  end

  defp record_werewolf_game(tmp_dir, game_id) do
    world = %{
      status: "game_over",
      winner: "villagers",
      day_number: 3,
      players: %{
        "Aria" => %{role: "werewolf", model: "openai/gpt-x", status: "dead"},
        "Brin" => %{role: "seer", model: "zai/glm-5", status: "alive"},
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

    record =
      League.game_record(LemonSim.Examples.Werewolf.League, world,
        game_id: game_id,
        recorded_at: "2026-07-06T00:00:00Z"
      )

    {:ok, _} = League.record_game!(tmp_dir, record)
  end

  defp record_poker_game(tmp_dir, game_id) do
    world = %{
      status: "game_over",
      winner: "player_1",
      winner_ids: ["player_1"],
      completed_hands: 8,
      table: %{big_blind: 100, small_blind: 50},
      players: %{
        "player_1" => %{seat: 1, model: "anthropic/claude-x"},
        "player_2" => %{seat: 2, model: "zai/glm-5"}
      },
      chip_counts: [
        %{"seat" => 1, "player_id" => "player_1", "stack" => 3200, "status" => "active"},
        %{"seat" => 2, "player_id" => "player_2", "stack" => 800, "status" => "active"}
      ],
      player_stats: %{
        "player_1" => %{starting_stack: 2000, hands_played: 8, hands_won: 5},
        "player_2" => %{starting_stack: 2000, hands_played: 8, hands_won: 3}
      }
    }

    record =
      League.game_record(LemonSim.Examples.Poker.League, world,
        game_id: game_id,
        recorded_at: "2026-07-06T00:00:00Z"
      )

    {:ok, _} = League.record_game!(tmp_dir, record)
  end

  describe "/arena/:domain" do
    test "shows the intermission page when no game is live", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/arena/poker")

      assert html =~ "Poker Arena"
      assert html =~ "Intermission"
      assert html =~ "/arena/poker/leaderboard"
    end

    test "rejects unknown domains", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, "/arena/frisbee")
    end
  end

  describe "legacy werewolf routes" do
    test "redirect to the arena routes", %{conn: conn} do
      assert redirected_to(get(conn, "/werewolf")) == "/arena/werewolf"
      assert redirected_to(get(conn, "/werewolf/leaderboard")) == "/arena/werewolf/leaderboard"
    end
  end

  describe "/arena/:domain/leaderboard" do
    test "shows empty state without any recorded games", %{conn: conn, tmp_dir: tmp_dir} do
      with_league_dir(:poker, tmp_dir)

      {:ok, _view, html} = live(conn, "/arena/poker/leaderboard")

      assert html =~ "Poker Arena League"
      assert html =~ "No Games Recorded Yet"
    end

    test "renders team standings with role specialists", %{conn: conn, tmp_dir: tmp_dir} do
      with_league_dir(:werewolf, tmp_dir)
      record_werewolf_game(tmp_dir, "ww_page1")

      {:ok, _view, html} = live(conn, "/arena/werewolf/leaderboard")

      assert html =~ "Werewolf League"
      assert html =~ "Overall Standings"
      assert html =~ "Role-adjusted"
      assert html =~ "Provisional"
      assert html =~ "zai/glm-5"
      assert html =~ "Role Specialists"
      assert html =~ "Seer"
      assert html =~ "Recent Games"
      assert html =~ "ww_page1"
      assert html =~ "Village"
    end

    test "renders poker ranked standings with stat leaders", %{conn: conn, tmp_dir: tmp_dir} do
      with_league_dir(:poker, tmp_dir)
      record_poker_game(tmp_dir, "pkr_page1")

      {:ok, _view, html} = live(conn, "/arena/poker/leaderboard")

      assert html =~ "Poker Arena League"
      assert html =~ "Mean value"
      assert html =~ "anthropic/claude-x"
      refute html =~ "Role Specialists"
      assert html =~ "Stat Leaders"
    end

    test "refreshes when the arena records a game", %{conn: conn, tmp_dir: tmp_dir} do
      with_league_dir(:poker, tmp_dir)

      {:ok, view, html} = live(conn, "/arena/poker/leaderboard")
      assert html =~ "No Games Recorded Yet"

      record_poker_game(tmp_dir, "pkr_page2")

      LemonCore.Bus.broadcast(
        Arena.league_topic(:poker),
        LemonCore.Event.new(:arena_league_updated, %{game_id: "pkr_page2"}, %{domain: :poker})
      )

      assert render_eventually(view, "pkr_page2")
    end
  end

  describe "lobby" do
    test "features the arenas with watch and league links", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "Always-on leagues"
      assert html =~ "Werewolf"
      assert html =~ "Poker Arena"
      assert html =~ "/arena/poker/leaderboard"
    end
  end

  defp render_eventually(view, needle, attempts \\ 50)

  defp render_eventually(_view, needle, 0) do
    flunk("leaderboard never rendered #{inspect(needle)}")
  end

  defp render_eventually(view, needle, attempts) do
    html = render(view)

    if html =~ needle do
      true
    else
      Process.sleep(20)
      render_eventually(view, needle, attempts - 1)
    end
  end
end
