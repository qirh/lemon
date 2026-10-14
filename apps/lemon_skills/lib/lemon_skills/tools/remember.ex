defmodule LemonSkills.Tools.Remember do
  @moduledoc """
  The `remember` tool: persist, correct, or delete a durable fact in the
  assistant-home `USER.md` (who the user is, their preferences), `MEMORY.md`
  (curated long-term facts), or scoped project memory in `LemonMemory.Project`.

  Both files are loaded into every main-session system prompt as workspace
  bootstrap files, so a remembered fact is in front of the model on the next
  turn without any further tool call. Writes are guarded against secrets,
  invisible or bidirectional control characters, and prompt-injection text, and
  each file is kept compact (`USER.md` 1,375 and `MEMORY.md` 2,200 characters).

  One call shape per intent:

    * `text` alone appends `- text` under the file's heading (a no-op when the
      file already contains it);
    * `text` with `replaces` swaps one exact existing passage for `text`;
    * `replaces` alone deletes one exact existing passage.

  Its read-side counterpart is `LemonSkills.Tools.Recall`. Registered as a
  builtin tool in `CodingAgent.ToolRegistry`.
  """

  alias LemonAgent.AbortSignal
  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent
  alias LemonMemory.{Project, Safety}

  @targets %{
    "user" => %{
      file: "USER.md",
      heading: "## Context",
      max_chars: 1_375,
      label: "user profile"
    },
    "memory" => %{
      file: "MEMORY.md",
      heading: "## Quick Facts",
      max_chars: 2_200,
      label: "long-term memory"
    }
  }

  @prompt_injection_patterns [
    ~r/ignore (all )?(previous|prior|above) instructions/i,
    ~r/disregard (all )?(previous|prior|above) instructions/i,
    ~r/reveal (the )?(system|developer) prompt/i,
    ~r/system prompt/i,
    ~r/developer message/i,
    ~r{<\|/?(?:system|developer|assistant|user)\|>}i
  ]

  @invisible_chars [
    "\u202A",
    "\u202B",
    "\u202C",
    "\u202D",
    "\u202E",
    "\u2066",
    "\u2067",
    "\u2068",
    "\u2069",
    "\u200B",
    "\u200C",
    "\u200D",
    "\u200E",
    "\u200F",
    "\uFEFF"
  ]
  @max_text_bytes 4_096

  @doc """
  Returns the `remember` tool definition wired to `execute/5`.

  `cwd` identifies the current repository. `opts` carries `:workspace_dir`,
  `:agent_id`, `:session_key`, and `:session_scope`. Only explicitly main-scoped
  sessions may write memory. `:store` can select a named memory store.
  """
  @spec tool(String.t(), keyword()) :: AgentTool.t()
  def tool(cwd, opts \\ []) do
    context = %{
      cwd: cwd,
      workspace_dir: Keyword.get(opts, :workspace_dir),
      agent_id: Keyword.get(opts, :agent_id),
      session_key: Keyword.get(opts, :session_key),
      session_scope: Keyword.get(opts, :session_scope),
      store_opts: Keyword.take(opts, [:store])
    }

    %AgentTool{
      name: "remember",
      description:
        "Save a durable fact or preference so it is in your context in every future session: " <>
          "target \"user\" writes USER.md (who the user is, how they like to work), " <>
          "\"memory\" writes MEMORY.md (other personal long-term facts), " <>
          "\"project\" saves repository build commands, conventions, and decisions " <>
          "only for this project, profile, and agent. " <>
          "To add a new fact, pass text and omit replaces (or set it to null, never an empty string). " <>
          "To correct or delete a project fact, first recall it with scope \"project\", then copy " <>
          "its exact saved text into replaces. Pass text as well to correct it; omit or null text to delete.",
      label: "Remember",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "text" => %{
            "type" => ["string", "null"],
            "minLength" => 1,
            "description" =>
              "The fact to save, as one short self-contained sentence. Omit or null only when deleting."
          },
          "target" => %{
            "type" => "string",
            "enum" => ["user", "memory", "project"],
            "description" =>
              "user: USER.md (profile, preferences). memory: MEMORY.md (personal facts). " <>
                "project: facts specific to this repository. Default memory."
          },
          "replaces" => %{
            "type" => ["string", "null"],
            "minLength" => 1,
            "description" =>
              "Omit or null when adding. For correction/deletion, copy the exact existing saved " <>
                "note or project fact, not a guessed summary. An empty string is invalid."
          }
        },
        "required" => []
      },
      execute: &execute(&1, &2, &3, &4, context)
    }
  end

  @doc """
  Tool callback invoked by the agent loop: `execute(tool_call_id, params, signal,
  on_update, context)`.

  Reads from `params`:

  - `"text"` - the note to save (add) or the replacement (with `"replaces"`)
  - `"target"` (default `"memory"`) - `"user"`, `"memory"`, or `"project"`
  - `"replaces"` - exact existing text, matched exactly once, to replace or delete

  Text values must be non-empty strings of at most 4096 bytes without NUL bytes;
  saved text is additionally screened against secrets, invisible or
  bidirectional control characters, and prompt-injection patterns.

  Returns `%LemonAgent.Types.AgentToolResult{}` on success: `content` is a single
  `TextContent` with the status message and resulting file content, and `details`
  merges operation fields (`changed`, and `duplicate` for an add) with `target`,
  `action` (`"add"`, `"replace"`, or `"remove"`), `path`, `bytes`, and `chars`.
  Errors (invalid/missing params, refused content, size overflow, file I/O)
  surface as `{:error, String.t()}` tuples; an aborted signal returns
  `{:error, "Operation aborted"}`.
  """
  @spec execute(
          String.t(),
          map(),
          reference() | nil,
          (AgentToolResult.t() -> :ok) | nil,
          map()
        ) :: AgentToolResult.t() | {:error, term()}
  def execute(_tool_call_id, params, signal, _on_update, context) do
    if AbortSignal.aborted?(signal) do
      {:error, "Operation aborted"}
    else
      with :ok <- validate_workspace_dir(context.workspace_dir),
           :ok <- validate_session_scope(context),
           {:ok, target} <- get_target(params),
           {:ok, action} <- get_action(params) do
        if target == "project",
          do: remember_project(context, action, params),
          else: do_execute(context.workspace_dir, target, action, params)
      end
    end
  end

  defp validate_session_scope(%{session_scope: :main}), do: :ok
  defp validate_session_scope(_), do: {:error, "remember requires a main session"}

  defp remember_project(context, action, params) do
    with {:ok, text} <- optional_text(params, "text"),
         {:ok, replaces} <- optional_text(params, "replaces"),
         {:ok, result} <- Project.remember(context, text, replaces, context.store_opts) do
      %AgentToolResult{
        content: [
          %TextContent{
            text:
              "Project memory #{if result.changed, do: "updated", else: "unchanged"}.\n\n" <>
                Enum.map_join(result.facts, "\n", &("- " <> &1))
          }
        ],
        details: %{
          target: "project",
          action: action,
          changed: result.changed,
          facts: result.facts
        }
      }
    else
      {:error, :not_found} ->
        {:error,
         "No existing project fact matched replaces; nothing was changed. " <>
           "Use recall with scope \"project\" and relevant query keywords, then copy the exact " <>
           "saved fact into replaces. To add a genuinely new fact instead, omit replaces or set it to null."}

      {:error, reason} when is_atom(reason) ->
        {:error, "Project memory refused: #{reason}"}

      error ->
        error
    end
  end

  defp optional_text(params, key) do
    if Map.get(params, key) == nil, do: {:ok, nil}, else: get_text(params, key)
  end

  defp do_execute(workspace_dir, target, action, params) do
    spec = Map.fetch!(@targets, target)
    path = Path.join(workspace_dir, spec.file)

    case action do
      "add" ->
        with {:ok, text} <- get_text(params, "text"),
             :ok <- screen_text(text),
             {:ok, content} <- load_or_init(path, target, spec) do
          add_note(path, target, spec, content, text)
        end

      "replace" ->
        with {:ok, old_text} <- get_text(params, "replaces"),
             {:ok, new_text} <- get_text(params, "text"),
             :ok <- screen_text(new_text),
             {:ok, content} <- load_or_init(path, target, spec) do
          replace_note(path, target, spec, content, old_text, new_text)
        end

      "remove" ->
        with {:ok, text} <- get_text(params, "replaces"),
             {:ok, content} <- load_or_init(path, target, spec) do
          remove_note(path, target, spec, content, text)
        end
    end
  end

  defp validate_workspace_dir(workspace_dir) when is_binary(workspace_dir) do
    if String.trim(workspace_dir) == "" do
      {:error, "workspace_dir is required for remember"}
    else
      :ok
    end
  end

  defp validate_workspace_dir(_), do: {:error, "workspace_dir is required for remember"}

  defp get_target(params) do
    case Map.get(params, "target", "memory") do
      "project" -> {:ok, "project"}
      target when is_map_key(@targets, target) -> {:ok, target}
      _ -> {:error, "target must be user, memory, or project"}
    end
  end

  # The operation follows from which of `text` and `replaces` are present, so
  # the model states what it wants rather than naming an action.
  defp get_action(params) do
    case {present?(Map.get(params, "text")), present?(Map.get(params, "replaces"))} do
      {true, false} -> {:ok, "add"}
      {true, true} -> {:ok, "replace"}
      {false, true} -> {:ok, "remove"}
      {false, false} -> {:error, "remember needs text to save, or replaces to delete a note"}
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp get_text(params, key) do
    value = Map.get(params, key)

    cond do
      not is_binary(value) ->
        {:error, "#{key} must be a string"}

      key == "replaces" and String.trim(value) == "" ->
        {:error,
         "replaces must be a non-empty string; to add a new fact, omit replaces or set it to null. " <>
           "To correct or delete a fact, use its exact existing saved text."}

      String.trim(value) == "" ->
        {:error, "#{key} must be a non-empty string"}

      byte_size(value) > @max_text_bytes ->
        {:error, "#{key} exceeds #{@max_text_bytes} bytes"}

      String.contains?(value, <<0>>) ->
        {:error, "#{key} cannot contain NUL bytes"}

      true ->
        {:ok, String.trim(value)}
    end
  end

  defp screen_text(text) do
    cond do
      Safety.contains_secret?(text) ->
        {:error, "Refusing to store secret-looking content in prompt-injected memory"}

      contains_invisible_char?(text) ->
        {:error, "Refusing to store invisible or bidirectional control characters"}

      Enum.any?(@prompt_injection_patterns, &Regex.match?(&1, text)) ->
        {:error, "Refusing to store prompt-injection-like content in prompt-injected memory"}

      true ->
        :ok
    end
  end

  defp contains_invisible_char?(text) do
    Enum.any?(@invisible_chars, &String.contains?(text, &1))
  end

  defp add_note(path, target, spec, content, text) do
    if String.contains?(content, text) do
      result("#{spec.file} already contains that note.", path, target, "add", content, %{
        changed: false,
        duplicate: true
      })
    else
      updated = append_under_heading(content, spec.heading, "- #{text}\n")
      write_checked(path, target, spec, updated, "add", %{changed: true, duplicate: false})
    end
  end

  defp replace_note(path, target, spec, content, old_text, new_text) do
    with :ok <- ensure_unique(content, old_text, "replaces") do
      updated = String.replace(content, old_text, new_text)
      write_checked(path, target, spec, updated, "replace", %{changed: true})
    end
  end

  defp remove_note(path, target, spec, content, text) do
    with :ok <- ensure_unique(content, text, "replaces") do
      updated =
        content
        |> String.replace("- #{text}\n", "")
        |> String.replace(text, "")
        |> String.replace(~r/\n{3,}/, "\n\n")
        |> String.trim_trailing()
        |> Kernel.<>("\n")

      write_checked(path, target, spec, updated, "remove", %{changed: true})
    end
  end

  defp ensure_unique(content, text, key) do
    count =
      Regex.scan(Regex.compile!(Regex.escape(text)), content)
      |> length()

    case count do
      0 -> {:error, "#{key} was not found"}
      1 -> :ok
      _ -> {:error, "#{key} must match exactly one occurrence"}
    end
  end

  defp write_checked(path, target, spec, content, action, details) do
    content = String.trim_trailing(content) <> "\n"

    if String.length(content) > spec.max_chars do
      {:error,
       "#{spec.file} would exceed #{spec.max_chars} characters; keep compact memory curated"}
    else
      File.mkdir_p!(Path.dirname(path))

      case File.write(path, content) do
        :ok ->
          result(
            "#{spec.file} #{action} complete at #{path}",
            path,
            target,
            action,
            content,
            details
          )

        {:error, reason} ->
          {:error, "Unable to write #{spec.file}: #{reason}"}
      end
    end
  end

  defp result(message, path, target, action, content, details) do
    %AgentToolResult{
      content: [%TextContent{text: message <> "\n\n" <> content}],
      details:
        Map.merge(details, %{
          target: target,
          action: action,
          path: path,
          bytes: byte_size(content),
          chars: String.length(content)
        })
    }
  end

  defp load_or_init(path, target, spec) do
    case File.read(path) do
      {:ok, content} ->
        {:ok, content}

      {:error, :enoent} ->
        {:ok, template_for(target, spec)}

      {:error, reason} ->
        {:error, "Unable to read #{spec.file}: #{reason}"}
    end
  end

  defp template_for("user", _spec) do
    """
    ---
    summary: "User profile record"
    ---

    # USER.md - About Your Human

    ## Context
    """
    |> String.trim_trailing()
  end

  defp template_for("memory", _spec) do
    """
    ---
    summary: "Long-term memory (curated)"
    ---

    # MEMORY.md - Long-term memory

    ## Quick Facts
    """
    |> String.trim_trailing()
  end

  defp append_under_heading(content, heading, addition) do
    content = String.trim_trailing(content)

    if String.contains?(content, heading) do
      content <> "\n\n" <> addition
    else
      content <> "\n\n" <> heading <> "\n\n" <> addition
    end
  end
end
