defmodule LemonSim.Examples.VendingBench.Runtime do
  @moduledoc false

  # Same window diff the replay verifier uses to rebuild events.jsonl.
  defdelegate appended_recent_events(before_recent, after_recent),
    to: LemonSim.Bench.Artifacts.Replay,
    as: :appended_events

  def get(map, key, default \\ nil)

  def get(map, key, default) when is_map(map) and is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  def get(map, key, default) when is_map(map), do: Map.get(map, key, default)
  def get(_map, _key, default), do: default
end
