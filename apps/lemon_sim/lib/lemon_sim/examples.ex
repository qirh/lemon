defmodule LemonSim.Examples do
  @moduledoc """
  Registry of the shipped example scenarios and the single "is this run
  finished?" predicate.

  Each scenario declares the world `:status` values that end it through
  `terminal_statuses/0`: Tic Tac Toe ends `won`/`draw`, VendingBench
  (single-operator and Arena) `complete`/`bankrupt`, Werewolf and Poker
  `game_over`. Runtime and UI code that only holds a world (run managers,
  arenas, spectators, lobbies) must use `terminal?/1` instead of comparing
  against one scenario's status string.
  """

  alias LemonCore.MapHelpers
  alias LemonSim.Examples.{Poker, TicTacToe, VendingBench, Werewolf}
  alias LemonSim.Kernel.State

  @scenarios [TicTacToe, VendingBench, Werewolf, Poker]

  @doc "Scenario modules that declare `terminal_statuses/0`."
  @spec scenarios() :: [module()]
  def scenarios, do: @scenarios

  @doc "Union of every scenario's terminal world statuses."
  @spec terminal_statuses() :: [String.t()]
  def terminal_statuses do
    @scenarios
    |> Enum.flat_map(& &1.terminal_statuses())
    |> Enum.uniq()
  end

  @doc """
  Returns true when a state (or bare world map) has reached its scenario's
  terminal status.
  """
  @spec terminal?(State.t() | map() | nil) :: boolean()
  def terminal?(%State{world: world}), do: terminal?(world)

  def terminal?(world) when is_map(world),
    do: terminal_status?(MapHelpers.get_key(world, :status))

  def terminal?(_other), do: false

  @doc "Returns true when `status` is a terminal world status of any scenario."
  @spec terminal_status?(term()) :: boolean()
  def terminal_status?(status) when is_binary(status), do: status in terminal_statuses()

  def terminal_status?(status)
      when is_atom(status) and not is_nil(status) and not is_boolean(status),
      do: terminal_status?(Atom.to_string(status))

  def terminal_status?(_status), do: false
end
