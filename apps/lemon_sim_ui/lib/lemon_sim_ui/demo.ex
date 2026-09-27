defmodule LemonSimUi.Demo do
  @moduledoc """
  Keyless LemonSim demo behind `mix lemon.sim.demo`.

  `start_werewolf/1` starts an offline Werewolf game through `SimManager`
  with the `"heuristic"` offline strategy (`LemonSimUi.Demo.WerewolfHeuristic`),
  so no provider API key or model config is read. The run is an ordinary
  persisted, resumable SimManager run: spectators watch it at
  `watch_path/1`, and it is marked completed when the game ends.
  """

  alias LemonSimUi.SimManager

  @default_player_count 6
  @default_step_delay_ms 1_200

  @doc """
  Starts an offline Werewolf game and returns its sim id.

  Options:

    * `:seed` - game seed (roles, names, and every heuristic decision);
      a fresh seed is drawn when omitted
    * `:player_count` - 5..8 seats (default #{@default_player_count})
    * `:step_delay_ms` - pause between turns so the game can be watched live
      (default #{@default_step_delay_ms}; `0` plays out immediately)
    * `:max_turns` - turn budget (SimManager's offline default when omitted)
    * `:sim_id` - explicit sim id (default: generated `ww_*` id)
  """
  @spec start_werewolf(keyword()) :: {:ok, String.t()} | {:error, term()}
  def start_werewolf(opts \\ []) when is_list(opts) do
    start_opts =
      [
        offline_strategy: "heuristic",
        seed: Keyword.get_lazy(opts, :seed, fn -> System.unique_integer([:positive]) end),
        player_count: Keyword.get(opts, :player_count, @default_player_count),
        offline_step_delay_ms: Keyword.get(opts, :step_delay_ms, @default_step_delay_ms)
      ]
      |> maybe_put(:max_turns, Keyword.get(opts, :max_turns))
      |> maybe_put(:sim_id, Keyword.get(opts, :sim_id))

    SimManager.start_sim(:werewolf, start_opts)
  end

  @doc "Public spectator path for a sim."
  @spec watch_path(String.t()) :: String.t()
  def watch_path(sim_id) when is_binary(sim_id), do: "/watch/#{sim_id}"

  @doc "Absolute spectator URL for a sim on the configured endpoint."
  @spec watch_url(String.t()) :: String.t()
  def watch_url(sim_id) when is_binary(sim_id),
    do: LemonSimUi.Endpoint.url() <> watch_path(sim_id)

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
