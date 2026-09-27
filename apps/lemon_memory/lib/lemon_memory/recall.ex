defmodule LemonMemory.Recall do
  @moduledoc """
  The bounded "Relevant memory" block that is put into a turn automatically.

  Recall used to happen only when the model remembered to call a memory tool.
  This module answers the cheaper question on every turn instead: *which of this
  agent's earlier conversations share keywords with the message just sent?* The
  answer is a short plain-text block that `LemonSkills.MemoryRecall` contributes
  to the turn through `LemonAgent.ContextRegistry`, placed in the user message
  (not the cached system prompt, because it changes every turn).

  It is deliberately cheap and conservative:

    * **No model call.** One local SQLite FTS5 query (`LemonMemory.Store.search/3`,
      agent scope, BM25-ranked) and some string work.
    * **Skipped for trivial prompts.** A message with fewer than
      two search terms after stopword removal ("ok", "thanks", "continue")
      gets no block.
    * **Any keyword may match.** The store's OR query and BM25 ordering retain
      useful paraphrases even when only one meaningful keyword is shared.
    * **Bounded.** At most three conversations by default (five maximum), plus
      a short USER.md excerpt from the session's own assistant workspace.
      The title and body never exceed 2,048 bytes; overflowing conversations
      are dropped whole. No global workspace fallback is used.

  Workspace bootstrap context remains available independently of automatic
  recall. The excerpt here carries current profile facts with the volatile
  conversation matches without changing the static system-prefix contract.
  """

  alias LemonMemory.{Document, Query, Store}

  @title "Relevant memory"
  @default_limit 3
  @default_max_bytes 2_048
  @min_terms 2
  @prompt_snippet_bytes 160
  @answer_snippet_bytes 220
  @user_snippet_bytes 512

  @intro "Earlier conversations that share keywords with this message " <>
           "(keyword search, may be outdated; the current conversation wins):"

  @doc "The section title the block is contributed under."
  @spec title() :: String.t()
  def title, do: @title

  @doc """
  Builds the block body for `query`, or `:skip` when nothing relevant is found.

  ## Options

    * `:agent_id` (required) - whose conversations to search; `:skip` without it
    * `:store` - the `LemonMemory.Store` server (default `LemonMemory.Store`)
    * `:limit` - maximum conversations in the block (default #{@default_limit})
    * `:max_bytes` - budget for title plus body (default #{@default_max_bytes})
    * `:workspace_dir` - session/profile assistant home containing `USER.md`
  """
  @spec block(String.t() | nil, keyword()) :: {:ok, String.t()} | :skip
  def block(query, opts) when is_list(opts) do
    agent_id = Keyword.get(opts, :agent_id)
    terms = Query.terms(query)

    if present?(agent_id) and length(terms) >= @min_terms do
      limit = opts |> Keyword.get(:limit, @default_limit) |> max(1) |> min(5)
      max_bytes = opts |> Keyword.get(:max_bytes, @default_max_bytes) |> min(@default_max_bytes)
      user_facts = user_facts(Keyword.get(opts, :workspace_dir))

      opts
      |> Keyword.get(:store, Store)
      |> Store.search(query,
        scope: :agent,
        scope_key: agent_id,
        limit: limit
      )
      |> Enum.take(limit)
      |> render(user_facts, max_bytes - byte_size(@title) - 6)
    else
      :skip
    end
  end


  defp render([], nil, _budget), do: :skip

  defp render(docs, user_facts, budget) do
    entries =
      [user_facts | Enum.map(docs, &entry/1)]
      |> Enum.reject(&is_nil/1)
      |> Enum.reduce_while({[], byte_size(@intro)}, fn entry, {kept, used} ->
        size = used + byte_size(entry) + 2

        if size <= budget, do: {:cont, {[entry | kept], size}}, else: {:cont, {kept, used}}
      end)
      |> elem(0)
      |> Enum.reverse()

    case entries do
      [] -> :skip
      entries -> {:ok, Enum.join([@intro | entries], "\n\n")}
    end
  end

  defp user_facts(workspace_dir) when is_binary(workspace_dir) and workspace_dir != "" do
    case File.open(Path.join(workspace_dir, "USER.md"), [:read, :binary]) do
      {:ok, file} ->
        try do
          case IO.binread(file, 2_048) do
            content when is_binary(content) ->
              content = binary_part(content, 0, utf8_boundary(content, byte_size(content)))
              if String.trim(content) != "", do: "USER.md: " <> snippet(content, @user_snippet_bytes)

            _ ->
              nil
          end
        after
          File.close(file)
        end

      _ ->
        nil
    end
  end

  defp user_facts(_workspace_dir), do: nil

  defp entry(%Document{} = doc) do
    [
      "[#{date(doc.ingested_at_ms)}] User: #{snippet(doc.prompt_summary, @prompt_snippet_bytes)}",
      "Assistant: #{snippet(doc.answer_summary, @answer_snippet_bytes)}"
    ]
    |> Enum.join("\n")
  end

  defp date(ms) when is_integer(ms) and ms > 0 do
    ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_date() |> Date.to_iso8601()
  rescue
    _ -> "unknown date"
  end

  defp date(_ms), do: "unknown date"

  # Whitespace is collapsed so a multi-line answer cannot mimic block structure,
  # and a long text is cut back to the last word boundary inside the budget.
  defp snippet(text, max_bytes) when is_binary(text) do
    text = text |> String.split() |> Enum.join(" ")

    if byte_size(text) <= max_bytes do
      text
    else
      text
      |> binary_part(0, utf8_boundary(text, max_bytes))
      |> String.replace(~r/\s+\S*$/u, "")
      |> Kernel.<>(" …")
    end
  end

  defp snippet(_text, _max_bytes), do: ""

  defp utf8_boundary(text, pos) when pos > 0 do
    if String.valid?(binary_part(text, 0, pos)), do: pos, else: utf8_boundary(text, pos - 1)
  end

  defp utf8_boundary(_text, 0), do: 0

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
