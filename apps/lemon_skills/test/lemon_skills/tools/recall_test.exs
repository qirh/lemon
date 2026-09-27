defmodule LemonSkills.Tools.RecallTest do
  use ExUnit.Case, async: true

  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.TextContent
  alias LemonMemory.{Document, Store}
  alias LemonSkills.Tools.Recall

  @moduletag :tmp_dir

  defp text(%AgentToolResult{content: [%TextContent{text: text}]}), do: text

  setup %{tmp_dir: tmp_dir} do
    store = :"recall_tool_store_#{System.unique_integer([:positive])}"
    start_supervised!({Store, name: store, path: Path.join(tmp_dir, "store")})

    for {agent, workspace, fact} <- [
          {"main", tmp_dir, "Priya's birthday is March 14th."},
          {"main", tmp_dir <> "-other", "Priya prefers wooden gifts."},
          {"other", tmp_dir <> "-other", "Priya's private unrelated note."}
        ] do
      Store.put_sync(
        store,
        Document.new(
          session_key: "agent:#{agent}:telegram:1",
          agent_id: agent,
          workspace_key: workspace,
          prompt_summary: "Priya birthday",
          answer_summary: fact
        )
      )
    end

    %{search_fn: fn query, opts -> Store.search(store, query, opts) end}
  end

  test "agent scope recalls this agent across projects without another agent's facts", %{
    tmp_dir: tmp_dir,
    search_fn: search_fn
  } do
    tool = Recall.tool(tmp_dir, session_key: "agent:main:telegram:1", search_fn: search_fn)
    result = tool.execute.("call", %{"query" => "Priya birthday"}, nil, nil)

    assert text(result) =~ "March 14th."
    assert text(result) =~ "wooden gifts."
    refute text(result) =~ "private unrelated"
  end

  test "project scope excludes facts from other projects", %{
    tmp_dir: tmp_dir,
    search_fn: search_fn
  } do
    tool = Recall.tool(tmp_dir, agent_id: "main", search_fn: search_fn)
    result = tool.execute.("call", %{"query" => "Priya birthday", "scope" => "project"}, nil, nil)

    assert text(result) =~ "March 14th."
    refute text(result) =~ "wooden gifts."
    refute text(result) =~ "private unrelated"
  end

  test "also finds matching lines in memory notes, skipping the template", %{
    tmp_dir: tmp_dir,
    search_fn: search_fn
  } do
    workspace_dir = Path.join(tmp_dir, "home")
    File.mkdir_p!(Path.join(workspace_dir, "memory/topics"))

    File.write!(
      Path.join(workspace_dir, "memory/topics/deploys.md"),
      "# Ops notes\n\nStaging deploys need the VPN.\nUnrelated line.\n"
    )

    template = Path.join(workspace_dir, "memory/topics/TEMPLATE.md")
    File.write!(template, "staging deploy template\n")

    tool =
      Recall.tool(tmp_dir,
        agent_id: "main",
        workspace_dir: workspace_dir,
        search_fn: search_fn
      )

    result = tool.execute.("call", %{"query" => "staging deploy"}, nil, nil)

    assert result.details.notes == 1
    assert text(result) =~ "memory/topics/deploys.md:3: Staging deploys need the VPN."
    refute text(result) =~ "TEMPLATE"
  end

  test "rejects an empty query, an unknown scope, and a missing agent", %{
    tmp_dir: tmp_dir,
    search_fn: search_fn
  } do
    tool = Recall.tool(tmp_dir, agent_id: "main", search_fn: search_fn)

    assert {:error, "query must be a non-empty string"} =
             tool.execute.("call", %{"query" => "  "}, nil, nil)

    assert {:error, "scope must be agent or project"} =
             tool.execute.("call", %{"query" => "x", "scope" => "all"}, nil, nil)

    agentless = Recall.tool(tmp_dir, search_fn: search_fn)

    assert {:error, message} = agentless.execute.("call", %{"query" => "x"}, nil, nil)
    assert message =~ "try scope project"
  end
end
