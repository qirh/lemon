defmodule CodingAgent.SystemPromptTest do
  use ExUnit.Case, async: false

  alias CodingAgent.SystemPrompt
  alias CodingAgent.ToolRegistry

  @tag :tmp_dir
  test "injects workspace files into prompt", %{tmp_dir: tmp_dir} do
    workspace_dir = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(workspace_dir)
    File.write!(Path.join(workspace_dir, "AGENTS.md"), "AGENTS content here")
    File.write!(Path.join(workspace_dir, "SOUL.md"), "SOUL content here")

    prompt =
      SystemPrompt.build(tmp_dir, %{
        workspace_dir: workspace_dir,
        bootstrap_max_chars: 10_000
      })

    assert String.contains?(prompt, "You are a personal assistant running inside Lemon.")
    assert String.contains?(prompt, "## Workspace Files (injected)")
    assert String.contains?(prompt, "AGENTS content here")
    assert String.contains?(prompt, "SOUL content here")
  end

  @removed_memory_tools ~w(search_memory session_search memory_topic memory)

  # The `## Memory` section, up to the next top-level section.
  defp memory_section(prompt) do
    [_before, rest] = String.split(prompt, "## Memory\n", parts: 2)
    rest |> String.split(~r/\n\n(?=## |<)/, parts: 2) |> hd()
  end

  @tag :tmp_dir
  test "main-session memory guidance names only remember and recall", %{tmp_dir: tmp_dir} do
    workspace_dir = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(workspace_dir)
    File.write!(Path.join(workspace_dir, "AGENTS.md"), "agents")

    prompt =
      SystemPrompt.build(tmp_dir, %{
        workspace_dir: workspace_dir,
        session_scope: :main
      })

    section = memory_section(prompt)

    referenced = section |> SystemPrompt.referenced_tool_names() |> Enum.sort()
    assert referenced == ["recall", "remember"]

    for removed <- @removed_memory_tools do
      refute removed in SystemPrompt.referenced_tool_names(prompt)
    end

    refute prompt =~ "Hermes"
  end

  @tag :tmp_dir
  test "memory guidance leaves out a tool the session lacks", %{tmp_dir: tmp_dir} do
    workspace_dir = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(workspace_dir)

    recall_only =
      SystemPrompt.build(tmp_dir, %{
        workspace_dir: workspace_dir,
        session_scope: :main,
        tool_names: ~w(read recall)
      })

    assert recall_only |> memory_section() |> SystemPrompt.referenced_tool_names() == ["recall"]

    neither =
      SystemPrompt.build(tmp_dir, %{
        workspace_dir: workspace_dir,
        session_scope: :main,
        tool_names: ~w(read)
      })

    refute neither =~ "## Memory\n"
  end

  @tag :tmp_dir
  test "tool names referenced by the system prompt are available in default coding tools", %{
    tmp_dir: tmp_dir
  } do
    workspace_dir = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(workspace_dir)
    File.write!(Path.join(workspace_dir, "AGENTS.md"), "agents")

    prompt =
      SystemPrompt.build(tmp_dir, %{
        workspace_dir: workspace_dir,
        session_scope: :main
      })

    referenced_tools = SystemPrompt.referenced_tool_names(prompt)

    default_tool_names =
      tmp_dir
      |> ToolRegistry.get_tools(include_extensions: false, include_mcp: false)
      |> Enum.map(& &1.name)
      |> MapSet.new()

    assert "read_skill" in referenced_tools
    assert "remember" in referenced_tools
    assert "recall" in referenced_tools
    assert "skill_manage" in referenced_tools

    missing_tools = Enum.reject(referenced_tools, &MapSet.member?(default_tool_names, &1))

    assert missing_tools == []
  end

  @tag :tmp_dir
  test "keeps the system prompt stable across unrelated skill contexts", %{tmp_dir: tmp_dir} do
    workspace_dir = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(workspace_dir)
    File.write!(Path.join(workspace_dir, "AGENTS.md"), "agents")

    skill_dir = Path.join([tmp_dir, ".lemon", "skill", "github-pr-workflow"])
    File.mkdir_p!(skill_dir)

    skill_body = "Follow the complete GitHub PR lifecycle details."

    File.write!(
      Path.join(skill_dir, "SKILL.md"),
      """
      ---
      name: github-pr-workflow
      description: GitHub pull request lifecycle, CI checks, branches, commits, PR creation, merge readiness
      keywords:
        - github
        - pull request
        - pr
        - ci
      ---

      #{skill_body}
      """
    )

    github_prompt =
      SystemPrompt.build(tmp_dir, %{
        workspace_dir: workspace_dir,
        session_scope: :main,
        skill_context: "please create a GitHub pull request and watch CI"
      })

    unrelated_prompt =
      SystemPrompt.build(tmp_dir, %{
        workspace_dir: workspace_dir,
        session_scope: :main,
        skill_context: "explain an unrelated database migration"
      })

    assert github_prompt == unrelated_prompt
    refute String.contains?(github_prompt, "<relevant-skills>")
    assert String.contains?(github_prompt, "<available_skills>")
    assert String.contains?(github_prompt, "github-pr-workflow")
    refute String.contains?(github_prompt, skill_body)
  end

  @tag :tmp_dir
  test "omits relevance-selected skill hints without skill context", %{tmp_dir: tmp_dir} do
    workspace_dir = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(workspace_dir)
    File.write!(Path.join(workspace_dir, "AGENTS.md"), "agents")

    skill_dir = Path.join([tmp_dir, ".lemon", "skill", "github-pr-workflow"])
    File.mkdir_p!(skill_dir)

    File.write!(
      Path.join(skill_dir, "SKILL.md"),
      """
      ---
      name: github-pr-workflow
      description: GitHub pull request lifecycle
      ---

      Follow the full workflow.
      """
    )

    prompt =
      SystemPrompt.build(tmp_dir, %{
        workspace_dir: workspace_dir,
        session_scope: :main
      })

    refute String.contains?(prompt, "<relevant-skills>")
    assert String.contains?(prompt, "<available_skills>")
    assert String.contains?(prompt, "github-pr-workflow")
  end

  @tag :tmp_dir
  test "subagent scope excludes memory and soul context", %{tmp_dir: tmp_dir} do
    workspace_dir = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(workspace_dir)
    File.write!(Path.join(workspace_dir, "AGENTS.md"), "AGENTS content here")
    File.write!(Path.join(workspace_dir, "TOOLS.md"), "TOOLS content here")
    File.write!(Path.join(workspace_dir, "SOUL.md"), "SOUL content here")
    File.write!(Path.join(workspace_dir, "MEMORY.md"), "MEMORY content here")
    File.write!(Path.join(workspace_dir, "USER.md"), "Private user preferences")

    for scope <- [:subagent, "subagent"] do
      prompt =
        SystemPrompt.build(tmp_dir, %{
          workspace_dir: workspace_dir,
          session_scope: scope
        })

      assert String.contains?(prompt, "AGENTS content here")
      assert String.contains?(prompt, "TOOLS content here")
      refute String.contains?(prompt, "SOUL content here")
      refute String.contains?(prompt, "MEMORY content here")
      refute String.contains?(prompt, "Private user preferences")
    end
  end

  @tag :tmp_dir
  test "empty workspace produces no workspace context section", %{tmp_dir: tmp_dir} do
    workspace_dir = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(workspace_dir)

    # Use subagent scope so the bootstrap filter strips out all required files
    # except AGENTS.md and TOOLS.md (which are missing). This leaves only [MISSING]
    # stubs, so the workspace context section is still present but contains no
    # real file content.
    prompt =
      SystemPrompt.build(tmp_dir, %{
        workspace_dir: workspace_dir,
        session_scope: :subagent
      })

    assert String.contains?(prompt, "You are a personal assistant running inside Lemon.")
    assert String.contains?(prompt, "## Boundaries")
    # SOUL.md is filtered out by subagent scope, so no persona instruction
    refute String.contains?(prompt, "embody its persona")
    # No real file content was written, so all entries are [MISSING] stubs
    assert String.contains?(prompt, "[MISSING]")
  end

  @tag :tmp_dir
  test "SOUL.md triggers persona instruction", %{tmp_dir: tmp_dir} do
    workspace_dir = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(workspace_dir)
    File.write!(Path.join(workspace_dir, "SOUL.md"), "Be quirky and fun.")

    prompt =
      SystemPrompt.build(tmp_dir, %{
        workspace_dir: workspace_dir,
        session_scope: :main
      })

    assert String.contains?(prompt, "## Workspace Files (injected)")
    assert String.contains?(prompt, "embody its persona and tone")
    assert String.contains?(prompt, "Be quirky and fun.")
  end

  @tag :tmp_dir
  test "SOUL.md absent does not have persona instruction", %{tmp_dir: tmp_dir} do
    workspace_dir = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(workspace_dir)
    File.write!(Path.join(workspace_dir, "AGENTS.md"), "agents content")
    File.write!(Path.join(workspace_dir, "TOOLS.md"), "tools content")

    # Use subagent scope so SOUL.md is filtered out of workspace context entirely.
    # This is the scenario where the persona instruction should NOT appear.
    prompt =
      SystemPrompt.build(tmp_dir, %{
        workspace_dir: workspace_dir,
        session_scope: :subagent
      })

    refute String.contains?(prompt, "embody its persona and tone")
    refute String.contains?(prompt, "embody")
    # The workspace context section is still present with the allowed files
    assert String.contains?(prompt, "## Workspace Files (injected)")
    assert String.contains?(prompt, "agents content")
    assert String.contains?(prompt, "tools content")
  end

  @tag :tmp_dir
  test "session scope defaults to main for invalid values", %{tmp_dir: tmp_dir} do
    workspace_dir = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(workspace_dir)
    File.write!(Path.join(workspace_dir, "AGENTS.md"), "agents")

    for invalid_scope <- [:invalid, "random", :foo, "bar", nil, 42] do
      prompt =
        SystemPrompt.build(tmp_dir, %{
          workspace_dir: workspace_dir,
          session_scope: invalid_scope
        })

      assert String.contains?(prompt, "Session scope: main"),
             "Expected scope: main for invalid input #{inspect(invalid_scope)}"

      # Main sessions get the full memory workflow, not the subagent restriction
      assert String.contains?(prompt, "use `recall`"),
             "Expected main memory workflow for invalid input #{inspect(invalid_scope)}"

      refute String.contains?(prompt, "This is a subagent session."),
             "Should not contain subagent notice for invalid input #{inspect(invalid_scope)}"
    end
  end

  @tag :tmp_dir
  test "runtime section shows session scope", %{tmp_dir: tmp_dir} do
    workspace_dir = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(workspace_dir)
    File.write!(Path.join(workspace_dir, "AGENTS.md"), "agents")

    main_prompt =
      SystemPrompt.build(tmp_dir, %{
        workspace_dir: workspace_dir,
        session_scope: :main
      })

    assert String.contains?(main_prompt, "## Runtime")
    assert String.contains?(main_prompt, "Session scope: main")

    subagent_prompt =
      SystemPrompt.build(tmp_dir, %{
        workspace_dir: workspace_dir,
        session_scope: :subagent
      })

    assert String.contains?(subagent_prompt, "## Runtime")
    assert String.contains?(subagent_prompt, "Session scope: subagent")
  end

  @tag :tmp_dir
  test "boundaries section shows assistant home and project root", %{tmp_dir: tmp_dir} do
    workspace_dir = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(workspace_dir)
    File.write!(Path.join(workspace_dir, "AGENTS.md"), "agents")

    prompt =
      SystemPrompt.build(tmp_dir, %{
        workspace_dir: workspace_dir,
        session_scope: :main
      })

    assert String.contains?(prompt, "## Boundaries")
    assert String.contains?(prompt, "Assistant home: #{workspace_dir}")
    assert String.contains?(prompt, "Project root (cwd): #{tmp_dir}")

    assert String.contains?(
             prompt,
             "Use the assistant home for persistent identity, memory, and operating notes."
           )

    assert String.contains?(
             prompt,
             "Use the project root for repo files, shell commands, and task execution."
           )
  end
end
