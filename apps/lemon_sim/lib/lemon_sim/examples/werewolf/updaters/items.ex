defmodule LemonSim.Examples.Werewolf.Updaters.Items do
  @moduledoc false

  alias LemonSim.Examples.Werewolf.Roles
  alias LemonSim.Examples.Werewolf.RulesConfig
  alias LemonSim.Kernel.Rng

  @item_pool [
    {"lantern", "You found an old lantern! Use it at night to see clearly."},
    {"lock", "You found a sturdy lock! Use it to secure your door tonight."},
    {"anonymous_letter",
     "You found blank parchment and a disguised seal! Send an anonymous message."},
    {"wolfsbane", "You found a bundle of wolfsbane! If wolves attack you, you'll survive."}
  ]

  @spec maybe_distribute_items(map(), pos_integer(), map(), Rng.t()) ::
          {{String.t(), String.t(), String.t()} | nil, Rng.t()}
  def maybe_distribute_items(players, day_number, world, rng) do
    if RulesConfig.enabled?(world, :items) and day_number > 1 do
      {roll, rng} = Rng.uniform(rng)

      if roll < 0.4 do
        living = Roles.living_players(players) |> Enum.map(fn {id, _} -> id end)
        {lucky_player, rng} = Rng.pick(living, rng)
        {{item_type, description}, rng} = Rng.pick(@item_pool, rng)
        {{lucky_player, item_type, description}, rng}
      else
        {nil, rng}
      end
    else
      {nil, rng}
    end
  end

  def remove_first_item(items, item_type) do
    idx =
      Enum.find_index(items, fn i ->
        (Map.get(i, :type) || Map.get(i, "type")) == item_type
      end)

    if idx, do: List.delete_at(items, idx), else: items
  end

  def has_item?(items, item_type) do
    Enum.any?(items, fn item ->
      (Map.get(item, :type) || Map.get(item, "type")) == item_type
    end)
  end
end
