defmodule CodingAgent.SystemPromptEnvironmentTest do
  use ExUnit.Case, async: true

  alias CodingAgent.SystemPrompt
  alias CodingAgent.SystemPrompt.Environment

  @moduletag :tmp_dir

  describe "Environment.capture/2" do
    test "reports branch and a status snapshot for a git repository", %{tmp_dir: tmp_dir} do
      git = System.find_executable("git")

      if git do
        {_, 0} = System.cmd(git, ["init", "-q", "-b", "feature-x", tmp_dir])
        File.write!(Path.join(tmp_dir, "untracked.ex"), "x")

        block = Environment.capture(tmp_dir, date: ~D[2026-01-02])

        assert block =~ "Git repository: yes (branch: No commits yet on feature-x)"
        assert block =~ "Git status at session start (a snapshot"
        assert block =~ "?? untracked.ex"
        assert String.ends_with?(block, "Today's date: 2026-01-02")
      end
    end

    test "marks a plain directory as not a repository" do
      dir = Path.join(System.tmp_dir!(), "lemon-env-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      block = Environment.capture(dir, date: ~D[2026-01-02])

      assert block =~ "Working directory: #{dir}"
      assert block =~ "Git repository: no"
    end
  end

  describe "coding guidance" do
    test "only names tools the session has", %{tmp_dir: tmp_dir} do
      workspace_dir = Path.join(tmp_dir, "workspace")
      File.mkdir_p!(workspace_dir)

      read_only =
        SystemPrompt.build(tmp_dir, %{
          workspace_dir: workspace_dir,
          session_scope: :subagent,
          tool_names: ["read", "grep", "find"]
        })

      assert read_only =~ "## Working on code"
      assert read_only =~ "Use `grep` to search file contents"
      refute read_only =~ "Use `edit`"
      refute read_only =~ "Use `bash`"
      refute read_only =~ "`bash_output`"

      with_background =
        SystemPrompt.build(tmp_dir, %{
          workspace_dir: workspace_dir,
          session_scope: :subagent,
          tool_names: ["read", "edit", "bash", "bash_output", "kill_process"]
        })

      assert with_background =~ "Read before you edit"
      assert with_background =~ "poll with `bash_output`"
    end
  end
end
