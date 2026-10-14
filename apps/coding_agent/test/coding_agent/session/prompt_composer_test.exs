defmodule CodingAgent.Session.PromptComposerTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Session.PromptComposer

  @moduletag :tmp_dir

  test "compose_system_prompt/6 keeps turn-specific skill relevance out of the prompt", %{
    tmp_dir: tmp_dir
  } do
    workspace_dir = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(workspace_dir)
    File.write!(Path.join(workspace_dir, "AGENTS.md"), "workspace agents")

    skill_dir = Path.join([tmp_dir, ".lemon", "skill", "github-pr-workflow"])
    File.mkdir_p!(skill_dir)

    File.write!(
      Path.join(skill_dir, "SKILL.md"),
      """
      ---
      name: github-pr-workflow
      description: GitHub pull request lifecycle, CI checks, branches, commits, PR creation
      keywords:
        - github
        - pull request
        - ci
      ---

      Full body should stay behind read_skill.
      """
    )

    github_prompt =
      PromptComposer.compose_system_prompt(
        tmp_dir,
        nil,
        nil,
        workspace_dir,
        :main,
        "please open a GitHub pull request and monitor CI"
      )

    unrelated_prompt =
      PromptComposer.compose_system_prompt(
        tmp_dir,
        nil,
        nil,
        workspace_dir,
        :main,
        "explain an unrelated algorithm"
      )

    assert github_prompt == unrelated_prompt
    refute String.contains?(github_prompt, "<relevant-skills>")
    assert String.contains?(github_prompt, "<key>github-pr-workflow</key>")
    refute String.contains?(github_prompt, "Full body should stay behind read_skill.")
  end

  test "compose_system_prompt/7 puts the environment block after every static section", %{
    tmp_dir: tmp_dir
  } do
    workspace_dir = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(workspace_dir)
    File.write!(Path.join(tmp_dir, "AGENTS.md"), "project instructions marker")

    environment =
      CodingAgent.SystemPrompt.Environment.capture(tmp_dir,
        date: ~D[2026-09-27],
        shell: "/bin/zsh"
      )

    prompt =
      PromptComposer.compose_system_prompt(
        tmp_dir,
        "explicit prompt marker",
        nil,
        workspace_dir,
        :main,
        "",
        %{environment: environment, tool_names: ["read", "edit", "bash"]}
      )

    assert String.ends_with?(prompt, environment)
    assert environment =~ "Working directory: #{tmp_dir}"
    assert environment =~ "Shell: /bin/zsh"
    assert environment =~ "Today's date: 2026-09-27"

    positions =
      Enum.map(
        [
          "explicit prompt marker",
          "## Working on code",
          "project instructions marker",
          "## Environment"
        ],
        fn marker -> prompt |> :binary.match(marker) |> elem(0) end
      )

    assert positions == Enum.sort(positions)
  end

  test "compose_sections/7 labels every prompt piece and joins to the exact prompt", %{
    tmp_dir: tmp_dir
  } do
    workspace_dir = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(workspace_dir)
    File.write!(Path.join(workspace_dir, "SOUL.md"), "soul marker")
    File.write!(Path.join(workspace_dir, "USER.md"), "user memory marker")
    File.write!(Path.join(tmp_dir, "AGENTS.md"), "project instructions marker")

    args = [
      tmp_dir,
      "explicit prompt marker",
      nil,
      workspace_dir,
      :main,
      "",
      %{
        environment: "## Environment\nToday",
        tool_names: ["read", "read_skill", "remember"],
        contributed_sections: [
          %{title: "Honcho\nprofile", body: "contributed body", placement: :system},
          %{title: "Volatile", body: "never in the prompt", placement: :user_message}
        ]
      }
    ]

    sections = apply(PromptComposer, :compose_sections, args)
    prompt = apply(PromptComposer, :compose_system_prompt, args)

    assert CodingAgent.SystemPrompt.join_sections(sections) == prompt
    refute prompt =~ "never in the prompt"

    by_label = Map.new(sections, &{&1.label, &1})

    assert %{category: :system_prompt} = by_label["Custom system prompt"]
    assert %{category: :system_prompt} = by_label["Environment"]
    assert %{category: :skills} = by_label["Available skills"]
    assert %{category: :memory, text: "## Honcho\nprofile\n\ncontributed body"} = by_label["Honcho profile"]
    assert %{category: :memory, text: "## USER.md\nuser memory marker"} = by_label["USER.md (assistant home)"]
    assert %{category: :context_files} = by_label["SOUL.md (assistant home)"]
    assert %{category: :context_files, text: text} = by_label["AGENTS.md (project)"]
    assert text =~ "project instructions marker"

    for section <- sections do
      refute section.label =~ tmp_dir
      assert section.category in [:system_prompt, :skills, :context_files, :memory]
    end
  end
end
