defmodule LemonSimUi.ArenaDomains do
  @moduledoc """
  Presentation config for the always-on arena domains.

  Pure data consumed by the arena LiveViews: display names, taglines, icons,
  role-specialist definitions (team games), and stat-leader definitions
  (games without fixed roles). Runtime behavior lives in `LemonSimUi.Arena`.
  """

  @type role_spec :: {String.t(), String.t(), String.t(), String.t(), String.t()}
  @type stat_spec :: {String.t(), String.t(), String.t()}

  @domains %{
    werewolf: %{
      title: "Werewolf",
      tagline: "Which model is the best liar, detective, and last one standing?",
      icon: "🐺",
      accent: "red",
      # {role_key, label, icon, metric_key, metric_label}
      roles: [
        {"werewolf", "Werewolf", "🐺", "successful_kills", "kills"},
        {"seer", "Seer", "🔮", "wolf_checks_found", "wolves found"},
        {"doctor", "Doctor", "🩺", "doctor_saves", "saves"},
        {"villager", "Villager", "🏘️", "votes_for_werewolf", "wolf votes"}
      ],
      stats: [],
      winner_labels: %{"werewolves" => "🐺 Wolves", "villagers" => "🏘️ Village"}
    },
    poker: %{
      title: "Poker Arena",
      tagline: "Deep stacks, no mercy — which model can out-bluff the table?",
      icon: "♠️",
      accent: "teal",
      roles: [],
      # {metric_key, label, icon}
      stats: [
        {"profit_loss", "Profit / loss", "💰"},
        {"bb_per_hand", "BB per hand", "📊"},
        {"vpip", "VPIP", "🎲"},
        {"pfr", "PFR", "⚔️"},
        {"hands_won", "Hands won", "🏆"}
      ],
      winner_labels: %{}
    }
  }

  @spec get(atom()) :: map() | nil
  def get(domain), do: Map.get(@domains, domain)

  @doc false
  @spec keys() :: [atom()]
  def keys, do: Map.keys(@domains)

  @spec domain_atom(String.t()) :: {:ok, atom()} | :error
  def domain_atom(slug) when is_binary(slug) do
    Enum.find_value(Map.keys(@domains), :error, fn domain ->
      if Atom.to_string(domain) == slug, do: {:ok, domain}
    end)
  end

  @spec winner_label(atom(), String.t() | nil) :: String.t()
  def winner_label(domain, winner) do
    labels = get(domain)[:winner_labels] || %{}
    Map.get(labels, winner, to_string(winner || "?"))
  end
end
