defmodule CodingAgent.SystemPrompt do
  @moduledoc """
  Builds Lemon system prompts: identity, coding-agent working rules, skills,
  memory workflow, and workspace context.

  Sections are ordered static-first so provider prompt caches keep the longest
  possible prefix: fixed guidance comes before workspace files, and the
  per-session environment block (`CodingAgent.SystemPrompt.Environment`) is
  appended last by `CodingAgent.Session.PromptComposer`.
  """

  require Logger

  alias CodingAgent.Workspace
  alias LemonAgent.ContextRegistry
  alias LemonSkills.PromptView

  @type opts :: %{
          optional(:workspace_dir) => String.t(),
          optional(:bootstrap_max_chars) => pos_integer(),
          optional(:session_scope) => :main | :subagent | String.t(),
          optional(:skill_context) => String.t(),
          optional(:max_relevant_skills) => pos_integer(),
          optional(:run_id) => String.t(),
          optional(:session_key) => String.t(),
          optional(:session_id) => String.t(),
          optional(:agent_id) => String.t(),
          optional(:contributed_sections) => [ContextRegistry.section()],
          optional(:tool_names) => [String.t()]
        }

  # Tool guidance assumes this set when the caller does not say which tools the
  # session actually has (one-shot builds outside a session).
  @default_tool_names ~w(read write edit patch bash grep find ls todo task)

  @doc """
  Build the system prompt for a Lemon coding agent session.

  Assembles workspace context files, skills, memory workflow guidance,
  and runtime metadata into a single prompt string.

  Sections contributed through `LemonAgent.ContextRegistry` are collected here
  and only the `:system` ones are rendered; the rest are the caller's to place
  in the user message. A caller that has already collected this turn's sections
  passes them as `:contributed_sections` and no collect happens here — see
  *Placement, and the prompt cache* in `LemonAgent.ContextRegistry` for why one
  collect per turn matters. Omit the option and the prompt collects for itself,
  as it always has.

  `:contributed_sections` must be a list when it is given at all: a value of any
  other type raises `ArgumentError` rather than falling back to collecting, since
  falling back would run every contributor a second time on a turn that had
  already collected. A section in that list that names no `:placement` is a
  `:system` section, the same default the registry documents for a spec; a
  section naming any other placement is left out of the prompt rather than
  defaulted into it.
  """
  @spec build(String.t(), opts()) :: String.t()
  def build(cwd, opts \\ %{}) do
    workspace_dir = Map.get(opts, :workspace_dir, Workspace.workspace_dir())
    max_chars = Map.get(opts, :bootstrap_max_chars, Workspace.default_max_chars())
    session_scope = normalize_session_scope(Map.get(opts, :session_scope, :main))
    skill_context = Map.get(opts, :skill_context, "")
    skill_trace_opts = skill_trace_opts(opts)

    bootstrap_files =
      Workspace.load_bootstrap_files(
        workspace_dir: workspace_dir,
        max_chars: max_chars,
        session_scope: session_scope
      )

    sections = [
      "You are a personal assistant running inside Lemon. You also work as a coding agent: " <>
        "you read, change, and run code in the project root with the tools you are given.",
      build_coding_section(Map.get(opts, :tool_names)),
      build_runtime_section(session_scope),
      build_skills_section(cwd, skill_trace_opts),
      build_memory_workflow_section(session_scope, Map.get(opts, :tool_names)),
      build_learning_workflow_section(session_scope),
      # Contributed context lands after the workflow sections and before the
      # boundaries: what a satellite contributes is background about the user and
      # their situation, which belongs next to the workspace context that follows
      # rather than in the middle of the tool guidance above.
      build_contributed_context_section(cwd, session_scope, skill_context, opts),
      build_workspace_section(cwd, workspace_dir),
      build_workspace_context_section(bootstrap_files)
    ]

    sections
    |> Enum.reject(&empty?/1)
    |> Enum.join("\n\n")
  end

  @doc """
  Extract tool names that the prompt explicitly instructs the agent to use.

  This is intentionally narrower than "all backticked lowercase words" so file
  names, XML tags, and parameter examples do not become false tool references.
  It powers prompt-contract tests that keep system-prompt tool guidance aligned
  with the default native Lemon tool set.
  """
  @spec referenced_tool_names(String.t()) :: [String.t()]
  def referenced_tool_names(prompt) when is_binary(prompt) do
    ~r/\b(?:Use|use|If)\s+`([a-z][a-z0-9_]*)`/
    |> Regex.scan(prompt, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
  end

  # ============================================================================
  # Sections
  # ============================================================================

  # Each rule names the tools it needs and is left out when the session lacks
  # any of them, so a restricted session is never told to use a tool it does
  # not have.
  @coding_rules [
    {~w(read edit),
     "Read before you edit: open the relevant part of a file with `read` before changing it, " <>
       "and read it again if `edit` reports that it changed on disk."},
    {~w(edit),
     "Use `edit` for changes to existing files. Keep each change as small as the task allows."},
    {~w(write),
     "Use `write` only to create new files or when replacing a whole file is genuinely simpler than editing it."},
    {~w(patch), "Use `patch` for coordinated multi-hunk or multi-file changes."},
    {~w(grep find),
     "Use `grep` to search file contents and `find` to locate files by name instead of shell grep/find; " <>
       "both respect .gitignore."},
    {~w(bash),
     "Use `bash` to build, test, lint, and run git. Prefer the dedicated file tools over shell commands for reading, searching, and editing files."},
    {~w(bash bash_output kill_process),
     "For long-running commands, raise the `bash` timeout or start them with `run_in_background: true`, " <>
       "then poll with `bash_output` and stop them with `kill_process`."},
    {[],
     "Independent reads and searches can go in parallel tool calls in one turn; run dependent steps in order."},
    {[],
     "Match the style and conventions of the surrounding code. Do not add unrelated refactors, " <>
       "and never leave stubs or TODO placeholders in place of the requested work."},
    {[],
     "Verify before you report success: run the relevant tests or build and read the output. " <>
       "If you could not verify something, say so plainly."},
    {[],
     "Git safety: do not commit, push, or run destructive commands (reset --hard, push --force, " <>
       "clean -fd, checkout of uncommitted files) unless the user asks. Treat existing uncommitted changes as the user's work."},
    {~w(todo), "Use `todo` to track multi-step work while it is in progress."},
    {~w(task), "Use `task` to delegate self-contained subtasks that can run on their own."},
    {[],
     "Be concise. When you finish, say what changed, how you verified it, and what is still open."}
  ]

  # Memory is two operations, one tool each. USER.md and MEMORY.md are loaded
  # into every main session as workspace files, and a few relevant past
  # conversations are attached to the user's message automatically
  # (`LemonSkills.MemoryRecall`), so the tools are for saving and for looking
  # further. A rule is left out when the session lacks its tool.
  @memory_rules [
    {"remember",
     "Remember: when the user tells you a lasting fact or preference, or a decision worth keeping is settled, " <>
       "use `remember` to save it as one short sentence (target `user` for who they are and how they like to work, " <>
       "`memory` for everything else). Saved facts are loaded into every future session."},
    {"recall",
     "Recall: before answering anything that depends on earlier conversations, prior work, or something the user told you before, " <>
       "use `recall` to search your past sessions and memory notes. Matching past conversations may already be attached " <>
       "to the user's message as \"Relevant memory\"; use `recall` to look further."}
  ]

  @default_memory_tool_names ~w(remember recall)

  defp build_coding_section(tool_names) do
    available = MapSet.new(tool_names || @default_tool_names)

    rules =
      for {required, rule} <- @coding_rules,
          Enum.all?(required, &MapSet.member?(available, &1)),
          do: "- " <> rule

    Enum.join(["## Working on code" | rules], "\n")
  end

  defp build_skills_section(cwd, trace_opts) do
    PromptView.render_for_prompt(cwd, trace_opts)
  end

  defp build_workspace_section(cwd, workspace_dir) do
    """
    ## Boundaries
    Assistant home: #{workspace_dir}
    Project root (cwd): #{cwd}
    Use the assistant home for persistent identity, memory, and operating notes.
    Use the project root for repo files, shell commands, and task execution.
    """
    |> String.trim()
  end

  defp build_runtime_section(session_scope) do
    """
    ## Runtime
    Session scope: #{session_scope}
    """
    |> String.trim()
  end

  defp build_memory_workflow_section(:subagent, _tool_names) do
    """
    ## Memory
    This is a subagent session. Leave USER.md and MEMORY.md unchanged unless the parent task explicitly asks you to update them.
    """
    |> String.trim()
  end

  defp build_memory_workflow_section(:main, tool_names) do
    available = MapSet.new(tool_names || @default_memory_tool_names)

    rules =
      for {tool, rule} <- @memory_rules, MapSet.member?(available, tool), do: "- " <> rule

    case rules do
      [] ->
        ""

      rules ->
        Enum.join(
          ["## Memory" | rules] ++
            ["If memory leaves you unsure about something the user expects you to know, say so."],
          "\n"
        )
    end
  end

  defp build_learning_workflow_section(:subagent), do: ""

  # `CodingAgent.Session.EventHandler` keys its missed-learning audit on the
  # `<learning-workflow>` tag, so the tag is part of the contract.
  defp build_learning_workflow_section(:main) do
    """
    <learning-workflow>
    Choose the right persistence surface:
    - Prefer dedicated memory and skill tools over shell commands for memory or skill work; use shell commands for project execution, not for bypassing these tools.
    - Use `read_skill` before following a relevant installed skill; skill hints are summaries, not the full procedure.
    - Use `skill_manage` when you discover a reusable workflow, recurring command sequence, API integration, debugging playbook, project convention, or verification checklist that will likely help future runs.
    - Use `todo` for the active run's task list and progress tracking; do not use todos as long-term memory.
    - At the end of substantial work, before the final answer, decide whether the run produced a durable fact (save it with `remember`) or a reusable workflow (save it with `skill_manage`); write it before finalizing when the lesson is clear.
    </learning-workflow>
    """
    |> String.trim()
  end

  # Sections contributed through `LemonAgent.ContextRegistry` are rendered as
  # ordinary markdown headings so they read like every other part of the prompt.
  # With nothing registered `collect/1` returns `[]`, this renders `""`, and
  # `empty?/1` drops it from the section list — a build with no contributors is
  # byte-for-byte the build it was before this section existed.
  #
  # Only the `:system` half of what was contributed is rendered here. The other
  # half is volatile by construction and belongs after the last prompt-cache
  # breakpoint, in the user message — the registry's moduledoc has the mechanism
  # and what ignoring it costs. A section that names some *other* placement is
  # dropped rather than defaulted into the prompt, because the failure mode this
  # split exists to prevent is exactly a volatile section quietly ending up in
  # the cached prefix.
  defp build_contributed_context_section(cwd, session_scope, skill_context, opts) do
    cwd
    |> contributed_sections(session_scope, skill_context, opts)
    |> Enum.filter(&system_section?/1)
    |> Enum.map_join("\n\n", fn %{title: title, body: body} -> "## #{title}\n\n#{body}" end)
  end

  # A section that names no placement is a `:system` section. That is not a
  # convenience: `:placement` is optional in `t:LemonAgent.ContextRegistry.section_spec/0`
  # and documented to default to `:system`, so a caller building this list by
  # hand — which the `:contributed_sections` option invites — has written a
  # system section and is entitled to see it in the prompt. Filtering on the key
  # instead dropped it silently, with the contributed context simply missing and
  # nothing anywhere saying why.
  #
  # A placement that is present and is *not* `:system` is left out, and that is
  # consistent with the registry refusing to coerce an unrecognised placement:
  # the direction that must never be taken on a guess is *into* the cached
  # prefix, because that is the one that bills every turn of the session. A
  # missing key is an absent statement and takes the documented default; a
  # wrong value is a statement that this is not a system section, and is
  # believed. Anything that is not a section at all cannot be rendered and is
  # dropped here rather than crashing the join below.
  defp system_section?(%{placement: placement}), do: placement == :system
  defp system_section?(%{title: _title, body: _body}), do: true
  defp system_section?(_section), do: false

  # A caller that has already collected this turn's sections passes them in, and
  # they are used as they are. Collecting a second time would pay every
  # contributor's budget twice over on the same turn and — since the whole point
  # of the `:user_message` half is that its text changes — could hand the system
  # prompt and the user message two different answers for one turn. A caller
  # that has not collected (a one-shot build outside a session, say) still gets
  # the collect it always did, so nothing outside the session path changes.
  #
  # No `:timeout_ms` is passed to `collect/1` on purpose. That option is an
  # absolute ceiling over every contributor, and imposing one here would override
  # the budget each contributor asks for — including the larger budget a
  # cold-cache contributor is entitled to on the first turn of a session, which
  # is the one turn where waiting buys anything. The registry already caps every
  # contributor at its own hard ceiling, so the turn is bounded without this
  # module naming a number of its own.
  #
  # The `Code.ensure_loaded?/1` guard is defensive rather than structural:
  # coding_agent already depends on lemon_agent, so the registry is present in
  # every normal build. It only matters in a stripped release or a test boot that
  # leaves the module out, where a missing registry should cost one section and
  # not the whole prompt.
  # A malformed `:contributed_sections` raises rather than falling back to
  # collecting, and the choice is between two kinds of loud. Falling back was
  # silent in both directions at once: the caller's sections vanished from the
  # prompt, *and* the turn ran every contributor a second time — the one thing
  # this option exists to prevent, and the one that can hand the system prompt
  # and the user message two different answers for a single turn. An explicit
  # `[]` would fix the second and keep the first, which is the worse half: a
  # user's recalled memory quietly missing from the prompt is exactly the class
  # of failure nobody reports because nobody can see it.
  #
  # Raising is safe here in a way it would not be for a contributor's return
  # value. This option is never third-party input — it is set by
  # `CodingAgent.Session` through `CodingAgent.Session.PromptComposer`, both in
  # this app, always from `LemonAgent.ContextRegistry.split/1`. Satellites reach
  # this prompt through the registry, which isolates every one of their failures
  # and still does. So a bad value here is a bug in Lemon's own caller, it is
  # deterministic, and it fires on the first prompt any build with that bug ever
  # assembles — in a test run, long before a release.
  defp contributed_sections(cwd, session_scope, skill_context, opts) do
    case Map.fetch(opts, :contributed_sections) do
      {:ok, sections} when is_list(sections) ->
        sections

      {:ok, other} ->
        raise ArgumentError,
              "CodingAgent.SystemPrompt.build/2 got :contributed_sections => #{inspect(other)}; " <>
                "it must be a list of LemonAgent.ContextRegistry sections. Pass [] for none, " <>
                "or omit the key entirely to collect them here."

      :error ->
        if Code.ensure_loaded?(ContextRegistry) do
          cwd
          |> context_request(session_scope, skill_context, opts)
          |> collect_contributed_sections()
        else
          []
        end
    end
  end

  # `collect/1` already isolates each contributor, so a broken satellite is
  # dropped there. This rescue covers the registry call itself, because a prompt
  # is built on the turn path and no failure here may ever reach the agent.
  defp collect_contributed_sections(request) do
    ContextRegistry.collect(request)
  rescue
    error ->
      Logger.debug(
        "[CodingAgent.SystemPrompt] contributed context unavailable: " <>
          Exception.message(error)
      )

      []
  end

  # Everything the turn knows about itself, in the shape contributors expect.
  # `:query` is the current user message: `CodingAgent.Session` passes that text
  # through as `:skill_context`, which is also what skill relevance ranks on.
  defp context_request(cwd, session_scope, skill_context, opts) do
    %{
      cwd: cwd,
      session_scope: session_scope,
      session_key: Map.get(opts, :session_key),
      session_id: Map.get(opts, :session_id),
      agent_id: Map.get(opts, :agent_id),
      run_id: Map.get(opts, :run_id),
      query: if(is_binary(skill_context), do: skill_context, else: "")
    }
  end

  defp skill_trace_opts(opts) do
    opts
    |> Map.take([:run_id, :session_key, :session_id, :agent_id])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp build_workspace_context_section([]), do: ""

  defp build_workspace_context_section(files) do
    has_soul =
      Enum.any?(files, fn file ->
        file.name |> String.downcase() == "soul.md"
      end)

    header = [
      "## Workspace Files (injected)",
      "These user-editable files are loaded by Lemon and included below.",
      "# Project Context",
      "The following workspace files have been loaded:"
    ]

    header =
      if has_soul do
        header ++
          [
            "If SOUL.md is present, embody its persona and tone. Avoid stiff, generic replies; follow its guidance unless higher-priority instructions override it."
          ]
      else
        header
      end

    body =
      files
      |> Enum.map(fn file ->
        [
          "## #{file.name}",
          file.content
        ]
        |> Enum.join("\n")
      end)
      |> Enum.join("\n\n")

    (header ++ ["", body])
    |> Enum.join("\n")
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp empty?(nil), do: true
  defp empty?(""), do: true
  defp empty?(s) when is_binary(s), do: String.trim(s) == ""
  defp empty?(_), do: false

  defp normalize_session_scope(scope) when scope in [:main, "main"], do: :main
  defp normalize_session_scope(scope) when scope in [:subagent, "subagent"], do: :subagent
  defp normalize_session_scope(_), do: :main
end
