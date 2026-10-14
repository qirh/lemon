defmodule LemonWeb.Chat.Transcript do
  @moduledoc """
  Transcript items for the chat stream.

  Every item is a map with a stable DOM `:id` and a `:kind`:

    * `:user` — `text`, `files` (display names only), `mode` (`nil` or a queue mode)
    * `:assistant` — `text`, `streaming` (true while deltas arrive), `run_id`
    * `:thinking` — reasoning text, `streaming`
    * `:tool` — see `LemonWeb.Chat.Tool`
    * `:notice` — `tone` and fixed, safe `text`
    * `:run` — per-run footer: `ok`, `model`, `duration_ms`, `usage`

  `from_history/1` turns `chat.history` rows (native session entries or the
  run-store fallback) into items in conversation order, folding each tool
  call's `tool_use`/`tool_result` rows into one card.
  """

  alias LemonWeb.Chat.Tool

  @max_items 400

  def max_items, do: @max_items

  @spec from_history([map()]) :: [map()]
  def from_history(rows) when is_list(rows) do
    rows
    |> Enum.filter(&is_map/1)
    |> Enum.with_index()
    |> Enum.sort_by(fn {row, index} -> {timestamp(row), index} end)
    |> Enum.reduce({[], %{}}, fn {row, _index}, {items, tools} ->
      case row["role"] do
        role when role in ["tool_use", "tool_result"] ->
          case Tool.from_history(row) do
            nil ->
              {items, tools}

            tool ->
              if Map.has_key?(tools, tool.id),
                do: {items, Map.update!(tools, tool.id, &Tool.merge(&1, tool))},
                else: {[{:tool, tool.id} | items], Map.put(tools, tool.id, tool)}
          end

        "user" ->
          {[user(row) | items], tools}

        "assistant" ->
          case text(row["content"]) do
            nil -> {items, tools}
            text -> {[assistant(row, text) | items], tools}
          end

        _ ->
          {items, tools}
      end
    end)
    |> then(fn {items, tools} ->
      items
      |> Enum.reverse()
      |> Enum.map(fn
        {:tool, id} -> Map.fetch!(tools, id)
        item -> item
      end)
      |> Enum.take(-@max_items)
    end)
  end

  defp user(row) do
    %{
      id: "h-" <> digest(to_string(row["id"]) <> ":user"),
      kind: :user,
      text: text(row["content"]) || "",
      files: [],
      mode: nil,
      ts: timestamp(row)
    }
  end

  defp assistant(row, text) do
    %{
      id: "h-" <> digest(to_string(row["id"]) <> ":assistant"),
      kind: :assistant,
      text: text,
      streaming: false,
      run_id: nil,
      ok: row["ok"] != false,
      ts: timestamp(row)
    }
  end

  @doc "A fresh user item."
  def user_item(text, files \\ [], mode \\ nil) do
    %{id: unique("u"), kind: :user, text: text, files: files, mode: mode, ts: now()}
  end

  @doc "A fresh assistant item for `run_id`."
  def assistant_item(run_id, text, streaming) do
    %{id: unique("a"), kind: :assistant, text: text, streaming: streaming, run_id: run_id, ok: true, ts: now()}
  end

  @doc "A notice; `tone` is `info | success | warning | danger`."
  def notice_item(tone, text), do: %{id: unique("n"), kind: :notice, tone: tone, text: text, ts: now()}

  @doc "A thinking item keyed by its reasoning action."
  def thinking_item(run_id, action_id, text, streaming) do
    %{
      id: "think-" <> digest("#{run_id}:#{action_id}"),
      kind: :thinking,
      text: text,
      streaming: streaming,
      ts: now()
    }
  end

  @doc "Run footer shown after a run completes."
  def run_item(run_id, attrs) do
    Map.merge(%{id: "run-" <> digest(to_string(run_id)), kind: :run, ts: now()}, attrs)
  end

  defp timestamp(row) do
    case row["timestampMs"] do
      ts when is_integer(ts) -> ts
      _ -> 0
    end
  end

  defp text(value) when is_binary(value) and value != "", do: value
  defp text(_), do: nil

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"

  defp now, do: System.system_time(:millisecond)

  defp digest(value),
    do: :crypto.hash(:sha256, value) |> Base.url_encode64(padding: false) |> binary_part(0, 16)
end
