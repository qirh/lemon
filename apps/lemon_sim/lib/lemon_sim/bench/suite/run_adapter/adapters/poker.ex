defmodule LemonSim.Bench.Suite.RunAdapter.Adapters.Poker do
  @moduledoc false

  @behaviour LemonSim.Bench.Suite.RunAdapter

  alias LemonSim.Examples.Poker

  @impl true
  def supported_modes, do: [:offline, :live]

  @impl true
  def supported_presets, do: ["ci", "standard"]

  @impl true
  def preset_opts("ci"), do: [player_count: 4, max_hands: 4, persist?: false]
  def preset_opts("standard"), do: [player_count: 6, max_hands: 12]

  @impl true
  def run(:offline, strategy, _seed, opts) do
    strategy
    |> Poker.run_offline_strategy(opts)
    |> normalize_result(opts)
  end

  def run(:live, _model_id, _seed, opts) do
    opts
    |> Poker.run()
    |> normalize_result(opts)
  end

  defp normalize_result({:ok, _result}, opts), do: {:ok, Keyword.fetch!(opts, :artifact_dir)}
  defp normalize_result({:error, reason}, _opts), do: {:error, reason}
end
