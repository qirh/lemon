defmodule CodingAgent.SubagentsTest do
  use ExUnit.Case, async: false

  alias CodingAgent.{Subagents, ToolPolicy}

  @moduletag :tmp_dir
  @builtin_ids ~w(reviewer scout task-executor)
  @read_tools ~w(read grep find ls agent_message)

  setup %{tmp_dir: tmp_dir} do
    original_home = System.get_env("HOME")
    home = Path.join(tmp_dir, "home")
    cwd = Path.join(tmp_dir, "project")
    global = Path.join([home, ".lemon", "agents"])
    project = Path.join([cwd, ".lemon", "agents"])
    File.mkdir_p!(global)
    File.mkdir_p!(project)
    System.put_env("HOME", home)

    on_exit(fn ->
      if original_home,
        do: System.put_env("HOME", original_home),
        else: System.delete_env("HOME")
    end)

    {:ok, cwd: cwd, home: home, global: global, project: project}
  end

  test "ships precisely three Markdown builtins from the application priv directory", %{cwd: cwd} do
    assert Enum.map(Subagents.list(cwd), & &1.id) == @builtin_ids

    for id <- @builtin_ids do
      assert File.regular?(
               Path.join([to_string(:code.priv_dir(:coding_agent)), "agents", id <> ".md"])
             )

      assert {:ok, persona} = Subagents.fetch(cwd, id)
      assert persona.source == :builtin
      assert persona.description != ""
      assert persona.prompt != ""
      refute String.starts_with?(persona.prompt, "---")
      assert persona.model == nil
      assert persona.role == nil

      assert Map.keys(persona) |> Enum.sort() ==
               Enum.sort([:id, :description, :prompt, :model, :role, :tools, :read_only, :source])
    end

    for id <- ~w(scout reviewer) do
      persona = Subagents.get(cwd, id)
      assert persona.read_only
      assert persona.tools == @read_tools
    end

    executor = Subagents.get(cwd, "task-executor")
    refute executor.read_only
    assert executor.tools == nil
  end

  test "project overrides global, which overrides builtin", context do
    %{cwd: cwd, global: global, project: project} = context
    define(global, "scout", "description: Global scout", "Global instruction")
    define(global, "global-only", "description: Global custom", "Global custom instruction")

    assert Subagents.get(cwd, "scout").source == :global
    assert Subagents.get(cwd, "scout").prompt == "Global instruction"
    assert Subagents.get(cwd, "global-only").source == :global

    define(project, "scout", "description: Project scout", "Project instruction")
    define(project, "project-only", "description: Project custom", "Project custom instruction")

    assert Subagents.get(cwd, "scout").source == :project
    assert Subagents.get(cwd, "scout").prompt == "Project instruction"
    assert Subagents.get(cwd, "project-only").source == :project

    assert Enum.map(Subagents.list(cwd), & &1.id) ==
             ~w(global-only project-only reviewer scout task-executor)
  end

  test "reads YAML scalars, lists and body while keeping role separate from identity", context do
    %{cwd: cwd, project: project} = context

    define(
      project,
      "specialist",
      """
      name: specialist
      description: >-
        A focused
        specialist
      model: provider/model-name
      role: coding
      tools:
        - read
        - grep
        - mcp__server__lookup
      read_only: true
      """,
      "  # Instructions\n\nUse exact evidence.\n---\nKeep this body separator.  "
    )

    assert {:ok, persona} = Subagents.fetch(cwd, "specialist")
    assert persona.id == "specialist"
    assert persona.description == "A focused specialist"
    assert persona.model == "provider/model-name"
    assert persona.role == "coding"
    assert persona.tools == ["read", "grep", "mcp__server__lookup"]
    assert persona.read_only

    assert persona.prompt ==
             "# Instructions\n\nUse exact evidence.\n---\nKeep this body separator."
  end

  test "optional fields default and explicit null model, role and tools are accepted", context do
    %{cwd: cwd, project: project} = context
    define(project, "defaults", "description: Defaults")
    define(project, "nulls", "description: Nulls\nmodel: null\nrole: null\ntools: null")

    for id <- ~w(defaults nulls) do
      persona = Subagents.get(cwd, id)
      assert persona.model == nil
      assert persona.role == nil
      assert persona.tools == nil
      assert persona.read_only == false
    end

    define(project, "no-tools", "description: No tools\ntools: []")
    assert Subagents.get(cwd, "no-tools").tools == []
  end

  test "accepts CRLF delimiters and quoted YAML values", %{cwd: cwd, project: project} do
    File.write!(
      Path.join(project, "crlf.md"),
      "---\r\nname: crlf\r\ndescription: 'Review: carefully'\r\n---\r\nInstructions\r\n"
    )

    assert {:ok, persona} = Subagents.fetch(cwd, "crlf")
    assert persona.description == "Review: carefully"
    assert persona.prompt == "Instructions"
  end

  test "invalid project override never exposes global or builtin fallback", context do
    %{cwd: cwd, global: global, project: project} = context
    define(global, "scout", "description: Valid global")
    File.write!(Path.join(project, "scout.md"), "---\ndescription: [broken\n---\nInstructions")

    assert {:error, error} = Subagents.fetch(cwd, "scout")
    assert error =~ "Invalid project subagent 'scout'"
    assert Subagents.get(cwd, "scout") == nil
    refute Enum.any?(Subagents.list(cwd), &(&1.id == "scout"))
    refute Subagents.format_for_description(cwd) =~ "- scout:"
    assert Subagents.get(cwd, "reviewer") != nil
  end

  test "invalid global override shadows builtin but a valid project override wins", context do
    %{cwd: cwd, global: global, project: project} = context
    define(global, "reviewer", "description: Invalid\nread_only: perhaps")
    assert {:error, error} = Subagents.fetch(cwd, "reviewer")
    assert error =~ "Invalid global subagent"
    assert Subagents.get(cwd, "reviewer") == nil

    define(project, "reviewer", "description: Valid project")
    assert Subagents.get(cwd, "reviewer").source == :project
  end

  test "unreadable matching definitions fail closed", %{cwd: cwd, project: project} do
    File.mkdir_p!(Path.join(project, "scout.md"))
    assert {:error, _} = Subagents.fetch(cwd, "scout")
    assert Subagents.get(cwd, "scout") == nil

    File.ln_s!(Path.join(project, "missing-target"), Path.join(project, "reviewer.md"))
    assert {:error, _} = Subagents.fetch(cwd, "reviewer")
    assert Subagents.get(cwd, "reviewer") == nil
  end

  test "rejects malformed headers, duplicate fields and non-mapping YAML", context do
    %{cwd: cwd, project: project} = context

    for content <- [
          "Instructions without frontmatter",
          "---\ndescription: Unclosed\nInstructions",
          "---\n- description\n---\nInstructions",
          "---\n42\n---\nInstructions",
          "---\ndescription: [broken\n---\nInstructions",
          "---\ndescription: One\ndescription: Two\n---\nInstructions",
          "---\ndescription: Valid\nread_only: true\nread_only: false\n---\nInstructions",
          "---\n---\nInstructions",
          "---\ndescription: Valid\n---",
          "",
          <<255, 254>>
        ] do
      File.write!(Path.join(project, "invalid.md"), content)
      assert {:error, _} = Subagents.fetch(cwd, "invalid"), inspect(content)
      assert Subagents.get(cwd, "invalid") == nil
    end
  end

  test "rejects invalid field types, unknown fields and bounds", context do
    %{cwd: cwd, project: project} = context

    for fields <- [
          "name: another",
          "name: null",
          "description: 42",
          "description: ''",
          "description: #{String.duplicate("d", 1025)}",
          "model: 42",
          "model: ''",
          "model: with spaces",
          "model: #{String.duplicate("m", 257)}",
          "role: []",
          "role: '@coding'",
          "role: #{String.duplicate("r", 65)}",
          "tools: read,grep",
          "tools: [read, 12]",
          "tools: [read, read]",
          "tools: ['*']",
          "tools: ['bad name']",
          "tools: [#{String.duplicate("t", 129)}]",
          "tools: [#{Enum.map_join(1..129, ",", &"tool_#{&1}")}]",
          "read_only: 'true'",
          "read_only: null",
          "prompt: Not the body",
          "unexpected: value"
        ] do
      header =
        if String.starts_with?(fields, "description:"),
          do: fields,
          else: "description: Valid\n" <> fields

      define(project, "invalid", header)
      assert {:error, _} = Subagents.fetch(cwd, "invalid"), fields
    end

    define(project, "invalid", "description: Valid", String.duplicate("p", 65_537))
    assert {:error, error} = Subagents.fetch(cwd, "invalid")
    assert error =~ "64 KiB"

    define(project, "invalid", "description: Valid\n# " <> String.duplicate("x", 16_384))
    assert {:error, error} = Subagents.fetch(cwd, "invalid")
    assert error =~ "16 KiB"

    File.write!(Path.join(project, "invalid.md"), String.duplicate("x", 131_073))
    assert {:error, error} = Subagents.fetch(cwd, "invalid")
    assert error =~ "128 KiB"
  end

  test "rejects unsafe IDs before path lookup and ignores unsafe filenames", context do
    %{cwd: cwd, project: project} = context

    for id <- [
          nil,
          42,
          "",
          "../scout",
          "/scout",
          "a/b",
          "a\\b",
          ".hidden",
          "@scout",
          "Uppercase",
          "with space",
          "name\n",
          String.duplicate("a", 65)
        ] do
      assert {:error, error} = Subagents.fetch(cwd, id)
      assert error =~ "Invalid subagent ID"
      assert Subagents.get(cwd, id) == nil
    end

    define(project, "Uppercase", "description: Invalid filename")
    assert Enum.map(Subagents.list(cwd), & &1.id) == @builtin_ids
    assert {:error, "Unknown subagent: missing"} = Subagents.fetch(cwd, "missing")
  end

  test "ignores obsolete JSON definitions and non-Markdown files", context do
    %{cwd: cwd, home: home, project: project} = context
    File.mkdir_p!(Path.join([home, ".lemon", "agent"]))
    File.write!(Path.join([cwd, ".lemon", "subagents.json"]), "not valid JSON")
    File.write!(Path.join([home, ".lemon", "agent", "subagents.json"]), "not valid JSON")
    File.write!(Path.join(project, "old.json"), "[]")
    assert Enum.map(Subagents.list(cwd), & &1.id) == @builtin_ids
  end

  test "formats sorted valid descriptions and handles missing project directories", context do
    %{cwd: cwd, project: project} = context
    define(project, "aaa", "description: First")
    description = Subagents.format_for_description(cwd)
    assert String.starts_with?(description, "- aaa: First\n- reviewer:")
    assert description =~ "- scout:"
    assert description =~ "- task-executor:"
    assert Enum.map(Subagents.list(Path.join(cwd, "missing")), & &1.id) == @builtin_ids
  end

  describe "tool_policy/2" do
    test "defaults to leaf worker and normalizes caller maps" do
      assert Subagents.tool_policy(nil, nil) == ToolPolicy.from_profile(:leaf_worker)

      assert Subagents.tool_policy(nil, %{"allow" => ["read"], "no_reply" => true}) ==
               ToolPolicy.from_map(%{"allow" => ["read"], "no_reply" => true})
    end

    test "intersects persona tools and preserves policy restrictions" do
      requested = %{
        "allow" => ["read", "grep", "find", "ls"],
        "deny" => ["grep"],
        "blocked_tools" => ["find"],
        "require_approval" => ["read"],
        "approvals" => %{"read" => "always", "ls" => "never"},
        "no_reply" => true
      }

      policy = Subagents.tool_policy(%{tools: ["read", "grep", "find", "bash"]}, requested)
      assert policy.allow == ["read"]
      assert Map.delete(policy, :allow) == Map.delete(ToolPolicy.from_map(requested), :allow)
      assert ToolPolicy.requires_approval?(policy, "read")
      assert policy.no_reply
      assert Subagents.tool_policy(%{tools: []}, requested).allow == []
    end

    test "read-only identities cannot be relaxed by overrides or caller full access", context do
      %{cwd: cwd, project: project} = context
      broad = ToolPolicy.from_profile(:full_access)

      for id <- ~w(scout reviewer) do
        builtin_policy = Subagents.tool_policy(Subagents.get(cwd, id), broad)
        assert builtin_policy.allow == @read_tools

        define(project, id, "description: Custom\nread_only: false\ntools: [bash, write, read]")
        persona = Subagents.get(cwd, id)
        assert persona.read_only
        assert Subagents.tool_policy(persona, broad).allow == ["read"]
        assert Subagents.tool_policy(%{persona | read_only: false}, broad).allow == ["read"]
      end

      policy = Subagents.tool_policy(%{id: "custom", read_only: true, tools: nil}, broad)
      assert policy.allow == @read_tools

      for tool <- ~w(bash write edit task agent mcp__server__lookup) do
        refute ToolPolicy.allowed?(policy, tool)
      end
    end

    test "readonly still honors caller denies, blocked tools and narrower allow" do
      requested = %{allow: ["read", "grep", "find"], deny: ["grep"], blocked_tools: ["find"]}
      assert Subagents.tool_policy(%{id: "scout"}, requested).allow == ["read"]
    end
  end

  defp define(dir, id, fields, body \\ "Follow the assigned task.") do
    File.write!(Path.join(dir, id <> ".md"), "---\n" <> String.trim(fields) <> "\n---\n" <> body)
  end
end
