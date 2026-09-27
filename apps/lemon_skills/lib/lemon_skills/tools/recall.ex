defmodule LemonSkills.Tools.Recall do
  @moduledoc """
  The `recall` tool: search what earlier conversations and memory notes say.

  It searches two places with the same query:

    * **Past conversations** — the durable memory documents written after each
      finished run (`LemonMemory.SessionSearch.search/2`: the local SQLite FTS5
      store plus any registered provider, gated by `[features] session_search`).
      Scope `"agent"` (the default) covers every earlier session of the current
      agent; `"project"` only the runs whose working directory was this project
      root. Matching is lexical: any query term may match, ranked by BM25 (see
      `LemonMemory.Query`).
    * **Memory notes** — markdown files under the assistant home's `memory/`
      directory (daily notes, topic notes), matched line by line on the same
      terms. At most 200 files of up to 64 KiB each are read.

  `USER.md` and `MEMORY.md` are not searched: main sessions already have both in
  the system prompt. Its write-side counterpart is `LemonSkills.Tools.Remember`;
  a few relevant past conversations are also put into each turn automatically
  (`LemonSkills.MemoryRecall`), so this tool is for looking further.
  """

  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent
  alias LemonMemory.{Query, SessionSearch}

  @default_limit 5
  @max_limit 10
  @notes_dir "memory"
  @max_note_files 200
  @max_note_bytes 65_536
  @max_note_line_bytes 300

  @doc """
  Returns the `recall` tool definition.

  ## Options

  - `:agent_id` - current agent, the key for scope `"agent"` (falls back to the
    agent segment of `:session_key`, `"agent:<id>:..."`)
  - `:session_key` - current session key
  - `:workspace_dir` - assistant home whose `memory/` notes are searched
  - `:search_fn` - test override for `LemonMemory.SessionSearch.search/2`
  """
  @spec tool(String.t(), keyword()) :: AgentTool.t()
  def tool(cwd, opts \\ []) do
    context = %{
      agent_id: present(Keyword.get(opts, :agent_id)) || agent_from_session_key(opts),
      project_key: present(cwd),
      workspace_dir: present(Keyword.get(opts, :workspace_dir)),
      search_fn: Keyword.get(opts, :search_fn, &SessionSearch.search/2)
    }

    %AgentTool{
      name: "recall",
      description:
        "Search your memory of earlier conversations with this user, and your memory notes, " <>
          "by keywords. Use it before answering anything that depends on prior work, earlier " <>
          "decisions, or something the user told you before. Scope \"agent\" (default) " <>
          "searches all your earlier sessions; \"project\" only this project root.",
      label: "Recall",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "query" => %{
            "type" => "string",
            "description" =>
              "Keywords to look for (e.g. \"deploy staging\", \"sister birthday\"). " <>
                "Any keyword may match; more matches rank higher."
          },
          "scope" => %{
            "type" => "string",
            "enum" => ["agent", "project"],
            "description" => "agent (default): all your sessions. project: this project only."
          },
          "limit" => %{
            "type" => "integer",
            "minimum" => 1,
            "maximum" => @max_limit,
            "description" => "Maximum results per source (default #{@default_limit})."
          }
        },
        "required" => ["query"]
      },
      execute: &execute(&1, &2, &3, &4, context)
    }
  end

  @doc """
  Tool callback invoked by the agent loop: `execute(tool_call_id, params, signal,
  on_update, context)`.

  Reads `"query"` (required, non-empty), `"scope"` (`"agent"` default or
  `"project"`), and `"limit"` (integer 1-#{@max_limit}, default
  #{@default_limit}; anything else takes the default).

  Returns `%LemonAgent.Types.AgentToolResult{}` whose text lists matching past
  conversations and memory-note lines, and whose `details` carry `query`,
  `scope`, `conversations` and `notes` (hit counts). An empty query, an unknown
  scope, or a scope whose key is unavailable returns `{:error, String.t()}`.
  """
  @spec execute(
          String.t(),
          map(),
          reference() | nil,
          (AgentToolResult.t() -> :ok) | nil,
          map()
        ) :: AgentToolResult.t() | {:error, String.t()}
  def execute(_tool_call_id, params, _signal, _on_update, context) do
    query = params |> Map.get("query", "") |> to_string() |> String.trim()
    limit = parse_limit(Map.get(params, "limit"))

    with :ok <- validate_query(query),
         {:ok, scope} <- parse_scope(Map.get(params, "scope", "agent")),
         {:ok, search_opts} <- search_opts(scope, context, limit) do
      docs = context.search_fn.(query, search_opts)
      notes = search_notes(context.workspace_dir, Query.terms(query), limit)

      %AgentToolResult{
        content: [%TextContent{text: render(query, scope, docs, notes)}],
        details: %{
          query: query,
          scope: scope,
          conversations: length(docs),
          notes: length(notes)
        }
      }
    end
  end

  defp validate_query(""), do: {:error, "query must be a non-empty string"}
  defp validate_query(_query), do: :ok

  defp parse_scope(scope) when scope in ["agent", "project"], do: {:ok, scope}
  defp parse_scope(_scope), do: {:error, "scope must be agent or project"}

  defp parse_limit(limit) when is_integer(limit) and limit in 1..@max_limit, do: limit
  defp parse_limit(_limit), do: @default_limit

  defp search_opts("agent", %{agent_id: agent_id}, limit) when is_binary(agent_id),
    do: {:ok, [scope: :agent, scope_key: agent_id, limit: limit]}

  defp search_opts("agent", _context, _limit),
    do: {:error, "recall scope agent needs a current agent; try scope project"}

  defp search_opts("project", %{project_key: project_key}, limit) when is_binary(project_key),
    do: {:ok, [scope: :workspace, scope_key: project_key, limit: limit]}

  defp search_opts("project", _context, _limit),
    do: {:error, "recall scope project needs a current project root"}

  # ── Memory notes ────────────────────────────────────────────────────────────

  defp search_notes(nil, _terms, _limit), do: []
  defp search_notes(_workspace_dir, [], _limit), do: []

  defp search_notes(workspace_dir, terms, limit) do
    workspace_dir
    |> Path.join(@notes_dir)
    |> Path.join("**/*.md")
    |> Path.wildcard()
    |> Enum.reject(&(Path.basename(&1) == "TEMPLATE.md"))
    |> Enum.sort(:desc)
    |> Enum.take(@max_note_files)
    |> Enum.flat_map(&note_hits(&1, workspace_dir, terms))
    |> Enum.sort_by(fn {score, path, line_no, _line} -> {-score, path, line_no} end)
    |> Enum.take(limit)
  end

  defp note_hits(path, workspace_dir, terms) do
    with {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_note_bytes <-
           File.stat(path),
         {:ok, content} <- File.read(path),
         true <- String.valid?(content) do
      relative = Path.relative_to(path, workspace_dir)

      content
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, line_no} ->
        case Query.shared_term_count(terms, line) do
          0 -> []
          score -> [{score, relative, line_no, clip(String.trim(line))}]
        end
      end)
    else
      _ -> []
    end
  end

  defp clip(line) when byte_size(line) <= @max_note_line_bytes, do: line

  defp clip(line) do
    line |> String.slice(0, @max_note_line_bytes) |> Kernel.<>(" …")
  end

  # ── Rendering ───────────────────────────────────────────────────────────────

  defp render(query, _scope, [], []),
    do: "Nothing in past conversations or memory notes matches: #{query}"

  defp render(_query, scope, docs, notes) do
    [conversations_section(scope, docs), notes_section(notes)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp conversations_section(_scope, []), do: nil

  defp conversations_section(scope, docs) do
    "Past conversations (scope: #{scope}, best match first):\n\n" <>
      SessionSearch.format_results(docs)
  end

  defp notes_section([]), do: nil

  defp notes_section(notes) do
    lines =
      Enum.map_join(notes, "\n", fn {_score, path, line_no, line} ->
        "#{path}:#{line_no}: #{line}"
      end)

    "Memory notes:\n" <> lines
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp agent_from_session_key(opts) do
    case opts |> Keyword.get(:session_key) |> present() do
      "agent:" <> rest -> rest |> String.split(":", parts: 2) |> hd() |> present()
      _ -> nil
    end
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_value), do: nil
end
