defmodule LemonSim.Bench.Domains do
  @moduledoc """
  Single source of truth for every benchmarked scenario domain.

  `LemonSim.Bench.Scorecard.Registry` and `LemonSim.Bench.League.Registry`
  both derive their lookup maps from `all/0` below instead of keeping their
  own parallel literal maps. Registering a new scenario for scorecards, or
  wiring an existing one into the always-on arena league, means adding or
  editing one entry here rather than several.

  ## `sim_id_prefix`

  `sim_id_prefix` is the sim-id prefix `LemonSimUi.Arena` uses for the arena
  domains (`"ww_"`, `"pkr_"`) and `SimManager.generate_id/1` uses for
  `vending_bench` (`"vb_"`). `lemon_sim_ui` derives its arena and public
  spectator domain lists from `arena_domains/0`. `tic_tac_toe` isn't
  registered here: it has no scorecard module, and
  `id`/`example_module`/`scorecard_module` are required on every descriptor.

  `default_player_count` mirrors the `@default_player_count` module attribute
  the domain's own `LemonSim.Examples.*` module falls back to when no
  `:player_count` option is given. It's `nil` for domains that don't model a
  variable player count. Note this can differ from what the always-on arena
  actually configures at runtime (e.g. poker defaults to 4 seats on its own,
  but `LemonSimUi.Arena` runs its always-on poker table with 6).

  ## Declaration order is the arena display order

  `arena_domains/0` filters `@domains` and so preserves declaration order:
  werewolf, then poker. That is the order `LemonSimUi.Arena.domains/0` and
  the lobby page show (see `domains_test.exs`).
  """

  alias LemonSim.Bench.Domains.Descriptor
  alias LemonSim.Examples

  @domains [
    %Descriptor{
      id: "werewolf",
      example_module: Examples.Werewolf,
      scorecard_module: Examples.Werewolf.Performance,
      league_adapter: Examples.Werewolf.League,
      sim_id_prefix: "ww_",
      default_player_count: 6
    },
    %Descriptor{
      id: "vending_bench",
      example_module: Examples.VendingBench,
      scorecard_module: Examples.VendingBench.Performance,
      sim_id_prefix: "vb_"
    },
    %Descriptor{
      id: "vending_bench_arena",
      example_module: Examples.VendingBench,
      scorecard_module: Examples.VendingBench.ArenaScorecard
    },
    %Descriptor{
      id: "poker",
      example_module: Examples.Poker,
      scorecard_module: Examples.Poker.Performance,
      league_adapter: Examples.Poker.League,
      sim_id_prefix: "pkr_",
      default_player_count: 4
    }
  ]

  @doc "Every registered domain descriptor, in declaration order."
  @spec all() :: [Descriptor.t()]
  def all, do: @domains

  @doc "Every registered domain id."
  @spec keys() :: [String.t()]
  def keys, do: Enum.map(@domains, & &1.id)

  @doc "Looks up a domain descriptor by id (string or atom). `nil` if unregistered."
  @spec get(String.t() | atom()) :: Descriptor.t() | nil
  def get(id), do: Enum.find(@domains, &(&1.id == to_string(id)))

  @doc "Looks up a domain descriptor by id (string or atom)."
  @spec fetch(String.t() | atom()) :: {:ok, Descriptor.t()} | :error
  def fetch(id) do
    case get(id) do
      nil -> :error
      descriptor -> {:ok, descriptor}
    end
  end

  @doc """
  Domains wired into the always-on arena league (those with a `league_adapter`),
  in the order `LemonSimUi.Arena` and the lobby page display them: werewolf,
  poker. See the moduledoc section on declaration order.
  """
  @spec arena_domains() :: [Descriptor.t()]
  def arena_domains, do: Enum.filter(@domains, & &1.league_adapter)
end
