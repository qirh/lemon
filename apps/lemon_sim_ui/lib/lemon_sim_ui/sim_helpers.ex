defmodule LemonSimUi.SimHelpers do
  @moduledoc """
  Utility functions for inspecting and summarizing sim state.
  """

  alias LemonCore.MapHelpers
  alias LemonSim.Kernel.State

  @spec infer_domain_type(State.t()) ::
          :tic_tac_toe
          | :werewolf
          | :vending_bench
          | :poker
          | :unknown
  def infer_domain_type(%State{world: world}) do
    cond do
      # Poker's world has both :table (engine state) and :player_stats
      # (session VPIP/PFR tracking), unlike any other domain. Must be
      # checked before the generic :players fallthrough below, since poker
      # worlds also carry a :players map (%{player_id => %{seat, model}}).
      (Map.has_key?(world, :table) or Map.has_key?(world, "table")) and
          (Map.has_key?(world, :player_stats) or Map.has_key?(world, "player_stats")) ->
        :poker

      Map.has_key?(world, :board) or Map.has_key?(world, "board") ->
        :tic_tac_toe

      MapHelpers.get_key(world, :mode) == "vending_bench_arena" ->
        :vending_bench

      Map.has_key?(world, :arena_agents) or Map.has_key?(world, "arena_agents") ->
        :vending_bench

      Map.has_key?(world, :machine) or Map.has_key?(world, "machine") ->
        :vending_bench

      Map.has_key?(world, :day_number) or Map.has_key?(world, "day_number") ->
        :werewolf

      Map.has_key?(world, :players) or Map.has_key?(world, "players") ->
        :werewolf

      true ->
        :unknown
    end
  end

  @spec sim_summary(State.t()) :: map()
  def sim_summary(%State{} = state) do
    %{
      sim_id: state.sim_id,
      version: state.version,
      domain_type: infer_domain_type(state),
      status: MapHelpers.get_key(state.world, :status) || "unknown",
      finished?: LemonSim.Examples.terminal?(state),
      event_count: length(state.recent_events),
      last_activity: last_event_time(state),
      world_summary: world_summary(state)
    }
  end

  defp last_event_time(%State{recent_events: []}), do: nil

  defp last_event_time(%State{recent_events: events}) do
    events
    |> List.last()
    |> Map.get(:ts_ms)
  end

  defp world_summary(%State{} = state) do
    case infer_domain_type(state) do
      :tic_tac_toe ->
        player = MapHelpers.get_key(state.world, :current_player)
        moves = MapHelpers.get_key(state.world, :move_count) || 0
        winner = MapHelpers.get_key(state.world, :winner)

        if winner do
          "Winner: #{winner}"
        else
          "#{player}'s turn (#{moves} moves)"
        end

      :werewolf ->
        phase = MapHelpers.get_key(state.world, :phase) || "unknown"
        day = MapHelpers.get_key(state.world, :day_number) || 1
        winner = MapHelpers.get_key(state.world, :winner)

        if winner do
          "Winner: #{winner}"
        else
          "Day #{day} - Phase: #{phase}"
        end

      :vending_bench ->
        day = MapHelpers.get_key(state.world, :day_number) || 1
        max_days = MapHelpers.get_key(state.world, :max_days) || 30
        balance = vending_bench_balance(state.world)
        status = MapHelpers.get_key(state.world, :status)

        case status do
          "bankrupt" -> "Bankrupt (Day #{day})"
          "complete" -> "Complete - $#{:erlang.float_to_binary(balance + 0.0, decimals: 2)}"
          _ -> "Day #{day}/#{max_days} - $#{:erlang.float_to_binary(balance + 0.0, decimals: 2)}"
        end

      :poker ->
        completed_hands = MapHelpers.get_key(state.world, :completed_hands) || 0
        max_hands = MapHelpers.get_key(state.world, :max_hands) || 1
        winner = MapHelpers.get_key(state.world, :winner)

        if LemonSim.Examples.terminal?(state) do
          "Winner: #{winner || "unknown"}"
        else
          "Hand #{completed_hands + 1}/#{max_hands}"
        end

      :unknown ->
        "v#{state.version}"
    end
  end

  defp vending_bench_balance(world) do
    case MapHelpers.get_key(world, :bank_balance) do
      nil ->
        world
        |> MapHelpers.get_key(:leaderboard)
        |> case do
          [leader | _] -> MapHelpers.get_key(leader, :money_balance) || 0.0
          _ -> 0.0
        end

      balance ->
        balance
    end
  end

  @spec format_ts(non_neg_integer() | nil) :: String.t()
  def format_ts(nil), do: "--"

  def format_ts(ts_ms) when is_integer(ts_ms) do
    seconds_ago = div(System.system_time(:millisecond) - ts_ms, 1000)

    cond do
      seconds_ago < 5 -> "just now"
      seconds_ago < 60 -> "#{seconds_ago}s ago"
      seconds_ago < 3600 -> "#{div(seconds_ago, 60)}m ago"
      true -> "#{div(seconds_ago, 3600)}h ago"
    end
  end

  @spec status_color(String.t() | nil) :: String.t()
  def status_color("in_progress"), do: "text-blue-400"
  def status_color("won"), do: "text-emerald-400"
  def status_color("draw"), do: "text-amber-400"
  def status_color("lost"), do: "text-red-400"
  def status_color("game_over"), do: "text-emerald-400"
  def status_color("complete"), do: "text-emerald-400"
  def status_color("bankrupt"), do: "text-red-400"
  def status_color("finished"), do: "text-gray-400"
  def status_color(_), do: "text-gray-500"

  @spec domain_label(atom()) :: String.t()
  def domain_label(:tic_tac_toe), do: "Tic Tac Toe"
  def domain_label(:werewolf), do: "Werewolf"
  def domain_label(:vending_bench), do: "Vending Bench"
  def domain_label(:poker), do: "Poker"
  def domain_label(_), do: "Unknown"

  @spec domain_badge_color(atom()) :: String.t()
  def domain_badge_color(:tic_tac_toe),
    do: "bg-violet-900/60 text-violet-300 border-violet-500/30"

  def domain_badge_color(:werewolf),
    do: "bg-fuchsia-900/60 text-fuchsia-300 border-fuchsia-500/30"

  def domain_badge_color(:vending_bench), do: "bg-green-900/60 text-green-300 border-green-500/30"
  def domain_badge_color(:poker), do: "bg-sky-900/60 text-sky-300 border-sky-500/30"
  def domain_badge_color(_), do: "bg-gray-800/60 text-gray-400 border-gray-600/30"
end
