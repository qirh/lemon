defmodule LemonWeb.ShellLive.Palette do
  @moduledoc """
  Command palette catalog and ranking for `LemonWeb.ShellLive`.

  Pure functions: the static catalog (navigation from `LemonWeb.Nav`, global
  actions, chat-workspace actions), fuzzy ranking, query-mode parsing and the
  projections of session, memory and automation rows into palette items. Rows
  are already bounded/redacted by their sources; items carry only labels,
  icons, hints and in-app hrefs.

  An item is a map with `:id` (stable, used for "recent"), `:label`,
  `:sublabel`, `:icon`, `:kind` (`"navigate" | "action" | "chat"`), `:href`,
  `:action`, `:hint` (key chord) and optional `:session_key`.
  """

  alias LemonWeb.Nav

  @label_max 90
  @search_prefix "/"

  @actions [
    %{
      id: "action:new-session",
      label: "New session",
      icon: "plus",
      kind: "navigate",
      href: "/",
      keywords: "create start chat conversation"
    },
    %{
      id: "action:toggle-theme",
      label: "Toggle theme",
      icon: "sun",
      kind: "action",
      action: "toggle-theme",
      hint: "mod+shift+l",
      keywords: "dark light system appearance"
    },
    %{
      id: "action:shortcuts",
      label: "Keyboard shortcuts",
      icon: "keyboard",
      kind: "action",
      action: "shortcuts",
      hint: "?",
      keywords: "help keys bindings"
    },
    %{
      id: "action:notifications",
      label: "Notifications",
      icon: "bell",
      kind: "action",
      action: "notifications",
      keywords: "alerts runs approvals desktop"
    },
    %{
      id: "action:sign-out",
      label: "Sign out",
      icon: "log-out",
      kind: "action",
      action: "sign-out",
      keywords: "logout log out exit"
    }
  ]

  @chat_actions [
    {"new-session", "New session", "plus", "mod+shift+o", "create start"},
    {"fork", "Fork session", "git-fork", nil, "branch copy duplicate"},
    {"toggle-plan", "Toggle plan mode", "clipboard-list", "mod+shift+p", "plan read-only"},
    {"stop", "Stop run", "square", "mod+.", "abort cancel halt"},
    {"compact", "Compact context", "layers", nil, "summarize shrink tokens"},
    {"toggle-inspector", "Toggle inspector", "panel-right", "mod+i",
     "context plan subagents changes details"},
    {"toggle-split", "Toggle split view", "columns", "mod+\\", "side by side pane"},
    {"focus-composer", "Focus composer", "pencil", "mod+/", "prompt input type"},
    {"model-picker", "Change model…", "cpu", "mod+shift+m", "provider llm"},
    {"thinking-picker", "Change thinking level…", "brain-circuit", "shift+tab",
     "reasoning effort"}
  ]

  @doc "Splits raw input into `{mode, query}`; a leading `/` selects global search."
  @spec parse_query(String.t(), :all | :search) :: {:all | :search, String.t()}
  def parse_query(raw, mode) when is_binary(raw) do
    raw = String.slice(raw, 0, 200)

    case raw do
      @search_prefix <> rest -> {:search, String.trim(rest)}
      _ -> {mode, String.trim(raw)}
    end
  end

  def parse_query(_raw, mode), do: {mode, ""}

  @doc "Navigation entries as palette items."
  @spec nav_items() :: [map()]
  def nav_items do
    Enum.map(Nav.items(), fn item ->
      %{
        id: "nav:#{item.id}",
        label: item.label,
        sublabel: item.group,
        icon: item.icon,
        kind: "navigate",
        href: item.path,
        hint: item.shortcut && "g #{item.shortcut}",
        keywords: item.keywords
      }
    end)
  end

  @doc "Global actions, without sign-out for tokenless loopback access."
  @spec action_items(keyword()) :: [map()]
  def action_items(opts \\ []) do
    chat? = Keyword.get(opts, :chat, false)
    sign_out? = Keyword.get(opts, :operator_access) != :tokenless_loopback

    @actions
    |> Enum.reject(&(&1.id == "action:sign-out" and not sign_out?))
    # Inside a chat workspace the chat's own new-session action takes over.
    |> Enum.reject(&(&1.id == "action:new-session" and chat?))
    |> Enum.map(&Map.merge(%{sublabel: nil, hint: nil, href: nil, action: nil}, &1))
  end

  @doc "Chat-workspace actions dispatched as `lemon:chat-action`."
  @spec chat_items() :: [map()]
  def chat_items do
    Enum.map(@chat_actions, fn {action, label, icon, hint, keywords} ->
      %{
        id: "chat:#{action}",
        label: label,
        sublabel: "Chat",
        icon: icon,
        kind: "chat",
        action: action,
        href: nil,
        hint: hint,
        keywords: keywords
      }
    end)
  end

  @doc "Chat action names accepted from the client."
  def chat_actions, do: Enum.map(@chat_actions, &elem(&1, 0))

  @doc """
  Ranks `items` against `query` (labels weigh more than keywords) and drops
  non-matches. An empty query keeps the original order.
  """
  @spec rank([map()], String.t()) :: [map()]
  def rank(items, ""), do: items

  def rank(items, query) do
    items
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, index} ->
      label = score(query, item.label)
      # Keywords and sublabels match on words/substrings only: fuzzy
      # subsequences over long keyword lists would match nearly anything.
      keywords = substring_score(query, Map.get(item, :keywords))
      sub = substring_score(query, Map.get(item, :sublabel))

      case Enum.reject(
             [label && label + 40, keywords && keywords - 20, sub && sub - 30],
             &is_nil/1
           ) do
        [] -> []
        scores -> [{Enum.max(scores), index, item}]
      end
    end)
    |> Enum.sort_by(fn {score, index, _} -> {-score, index} end)
    |> Enum.map(&elem(&1, 2))
  end

  defp substring_score(query, text) when is_binary(text) do
    case score(query, text) do
      score when is_integer(score) and score >= 60 -> score
      _ -> nil
    end
  end

  defp substring_score(_query, _text), do: nil

  @doc """
  Fuzzy score of `query` against `text` (case-insensitive), or `nil` when the
  query's characters do not all appear in order. Exact > prefix > word-start >
  substring > subsequence; tighter subsequences score higher.
  """
  @spec score(String.t(), String.t()) :: integer() | nil
  def score(query, text) when is_binary(query) and is_binary(text) do
    q = String.downcase(query)
    t = String.downcase(text)

    cond do
      q == "" -> 0
      t == q -> 100
      String.starts_with?(t, q) -> 90
      word_start?(t, q) -> 80
      String.contains?(t, q) -> 60
      true -> subsequence(String.graphemes(q), String.graphemes(t))
    end
  end

  def score(_query, _text), do: nil

  defp word_start?(text, query) do
    text
    |> String.split(~r/[\s_\-.:\/]+/, trim: true)
    |> Enum.any?(&String.starts_with?(&1, query))
  end

  # Greedy in-order match; penalize gaps so "nse" ranks "New session" above
  # longer scattered matches.
  defp subsequence(query, text), do: subsequence(query, text, 0, nil, 0)

  defp subsequence([], _text, _pos, _last, gaps), do: max(40 - gaps, 1)
  defp subsequence(_query, [], _pos, _last, _gaps), do: nil

  defp subsequence([q | qs] = query, [t | ts], pos, last, gaps) do
    if q == t do
      gap = if last, do: pos - last - 1, else: 0
      subsequence(qs, ts, pos + 1, pos, gaps + min(gap, 5))
    else
      subsequence(query, ts, pos + 1, last, gaps)
    end
  end

  # ── Row projections ────────────────────────────────────────────────────

  @doc "A `sessions.list` row as a palette item."
  @spec session_item(map(), keyword()) :: map() | nil
  def session_item(%{"sessionKey" => key} = row, opts) when is_binary(key) do
    title = clean(row["title"]) || "Untitled session"
    runs = row["runCount"]

    %{
      id: "session:#{key}",
      label: title,
      sublabel:
        [
          LemonWeb.UI.relative_time(row["updatedAtMs"]),
          is_integer(runs) && runs > 0 && "#{runs} #{if runs == 1, do: "run", else: "runs"}",
          row["pinned"] == true && "pinned",
          row["archived"] == true && "archived"
        ]
        |> Enum.filter(&is_binary/1)
        |> Enum.join(" · "),
      icon: if(row["pinned"] == true, do: "pin", else: "message-square"),
      kind: "navigate",
      href: chat_path(key),
      split_href: split_href(Keyword.get(opts, :current_chat), key),
      session_key: key,
      hint: nil,
      action: nil
    }
  end

  def session_item(_row, _opts), do: nil

  @doc "A memory lifecycle summary as a search hit (bounded, already redacted)."
  @spec memory_item(map(), String.t()) :: map() | nil
  def memory_item(%{id: id} = summary, query) when is_binary(id) do
    %{
      id: "memory:#{id}",
      label: clean(summary[:excerpt]) || "Memory record",
      sublabel:
        [
          memory_kind(summary[:kind]),
          summary[:agent] && "agent #{summary[:agent]}",
          LemonWeb.UI.relative_time(summary[:ingested_at_ms])
        ]
        |> Enum.filter(&is_binary/1)
        |> Enum.join(" · "),
      icon: "brain",
      kind: "navigate",
      href: "/memory?" <> URI.encode_query(%{"query" => query}),
      hint: nil,
      action: nil
    }
  end

  def memory_item(_summary, _query), do: nil

  defp memory_kind("learned_source"), do: "Learned source"
  defp memory_kind("project_learning"), do: "Project learning"
  defp memory_kind(_), do: "Run memory"

  @doc "A `cron.list` job as a search hit when its name matches."
  @spec cron_item(map()) :: map() | nil
  def cron_item(%{"id" => id, "name" => name} = job) when is_binary(id) and is_binary(name) do
    %{
      id: "cron:#{id}",
      label: clean(name) || "Cron job",
      sublabel:
        ["Cron job", job["enabled"] == false && "paused"]
        |> Enum.filter(&is_binary/1)
        |> Enum.join(" · "),
      icon: "calendar-clock",
      kind: "navigate",
      href: "/automation",
      hint: nil,
      action: nil,
      keywords: nil
    }
  end

  def cron_item(_job), do: nil

  @doc """
  Resolves remembered `%{"id" => id, "label" => label}` entries (from the
  browser's localStorage) against the current catalog; unknown ids drop out.
  Session entries keep their remembered (bounded) label.
  """
  @spec resolve_recent([map()], [map()], keyword()) :: [map()]
  def resolve_recent(recent, catalog, opts) when is_list(recent) do
    by_id = Map.new(catalog, &{&1.id, &1})

    recent
    |> Enum.take(8)
    |> Enum.flat_map(fn
      %{"id" => "session:" <> key, "label" => label} when byte_size(key) in 1..1024 ->
        [
          %{
            id: "session:#{key}",
            label: clean(label) || "Untitled session",
            sublabel: "Session",
            icon: "history",
            kind: "navigate",
            href: chat_path(key),
            split_href: split_href(Keyword.get(opts, :current_chat), key),
            session_key: key,
            hint: nil,
            action: nil
          }
        ]

      %{"id" => id} when is_binary(id) ->
        case Map.fetch(by_id, id) do
          {:ok, item} -> [item]
          :error -> []
        end

      _ ->
        []
    end)
    |> Enum.uniq_by(& &1.id)
    |> Enum.take(5)
  end

  def resolve_recent(_recent, _catalog, _opts), do: []

  @doc "In-app chat path for a session key."
  @spec chat_path(String.t()) :: String.t()
  def chat_path(key), do: "/chat/" <> URI.encode(key, &URI.char_unreserved?/1)

  @doc "Split-view href (`/chat/<current>?split=<key>`), or nil off a chat page."
  def split_href(nil, _key), do: nil
  def split_href(current, current), do: nil

  def split_href(current, key),
    do: chat_path(current) <> "?" <> URI.encode_query(%{"split" => key})

  @doc "Bounded single-line display text, or nil when blank."
  @spec clean(term()) :: String.t() | nil
  def clean(value) when is_binary(value) do
    value =
      value
      |> String.replace(~r/[[:cntrl:]\s]+/u, " ")
      |> String.trim()

    cond do
      value == "" -> nil
      String.length(value) > @label_max -> String.slice(value, 0, @label_max - 1) <> "…"
      true -> value
    end
  end

  def clean(_value), do: nil
end
