defmodule LemonSim.Kernel.Rng do
  @moduledoc """
  Explicit, serializable random-number state for deterministic updaters.

  Scenarios that need randomness carry the generator in their world map under
  `:rng_state` and thread it through every draw, so a run is a pure function of
  its seed and event sequence. Nothing here touches the process-global `:rand`
  state, so other `:rand` consumers in the same process cannot perturb a game.

  The state is a two-integer list (the `:exsss` generator state), which
  survives `Jason` and `:erlang.term_to_binary/1` round trips unchanged.

      rng = Rng.new(seed)
      {roll, rng} = Rng.uniform(rng)
      {winner, rng} = Rng.pick(["a", "b"], rng)
  """

  @alg :exsss

  @typedoc "Serializable generator state stored in `world.rng_state`."
  @type t :: [non_neg_integer()]

  @doc "Builds a generator state from an integer seed."
  @spec new(integer()) :: t()
  def new(seed) when is_integer(seed) do
    @alg
    |> :rand.seed_s({seed, seed + 1, seed + 2})
    |> dump()
  end

  @doc """
  Reads `:rng_state` (atom or string key) from a world map.

  Raises when the world carries no generator: a missing state means the world
  was not built by the scenario's seeded `initial_world/1`.
  """
  @spec fetch!(map()) :: t()
  def fetch!(world) when is_map(world) do
    case Map.get(world, :rng_state, Map.get(world, "rng_state")) do
      [_, _] = rng ->
        rng

      other ->
        raise ArgumentError,
              "world has no valid :rng_state (got #{inspect(other)}); build it with a seeded initial_world/1"
    end
  end

  @doc "Returns a float uniformly distributed in `0.0 =< x < 1.0`."
  @spec uniform(t()) :: {float(), t()}
  def uniform(rng) do
    {value, state} = :rand.uniform_s(load(rng))
    {value, dump(state)}
  end

  @doc "Returns an integer uniformly distributed in `1..n`."
  @spec uniform(pos_integer(), t()) :: {pos_integer(), t()}
  def uniform(n, rng) when is_integer(n) and n > 0 do
    {value, state} = :rand.uniform_s(n, load(rng))
    {value, dump(state)}
  end

  @doc "Picks one element of a non-empty list."
  @spec pick([term(), ...], t()) :: {term(), t()}
  def pick([_ | _] = list, rng) do
    {index, rng} = uniform(length(list), rng)
    {Enum.at(list, index - 1), rng}
  end

  @doc "Returns a Fisher-Yates permutation of `list`."
  @spec shuffle([term()], t()) :: {[term()], t()}
  def shuffle(list, rng) when is_list(list) do
    tuple = List.to_tuple(list)
    {shuffled, state} = fisher_yates(tuple, tuple_size(tuple), load(rng))
    {Tuple.to_list(shuffled), dump(state)}
  end

  @doc "Returns `count` distinct elements of `list` in random order."
  @spec take_random([term()], non_neg_integer(), t()) :: {[term()], t()}
  def take_random(list, count, rng) when is_list(list) and is_integer(count) and count >= 0 do
    {shuffled, rng} = shuffle(list, rng)
    {Enum.take(shuffled, count), rng}
  end

  defp fisher_yates(tuple, i, state) when i <= 1, do: {tuple, state}

  defp fisher_yates(tuple, i, state) do
    {j, state} = :rand.uniform_s(i, state)
    last = elem(tuple, i - 1)
    swapped = tuple |> put_elem(i - 1, elem(tuple, j - 1)) |> put_elem(j - 1, last)
    fisher_yates(swapped, i - 1, state)
  end

  defp load([s0, s1]) when is_integer(s0) and is_integer(s1), do: :rand.seed_s({@alg, [s0 | s1]})

  defp load(other), do: raise(ArgumentError, "invalid rng state: #{inspect(other)}")

  defp dump(state) do
    {@alg, [s0 | s1]} = :rand.export_seed_s(state)
    [s0, s1]
  end
end
