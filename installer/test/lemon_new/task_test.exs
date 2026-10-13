defmodule Mix.Tasks.Lemon.NewTest do
  # Mix.shell/1 is global state.
  use ExUnit.Case, async: false

  alias Mix.Tasks.Lemon.New

  setup context do
    tmp = Path.join(System.tmp_dir!(), "lemon_new_task_test_#{:erlang.phash2(context.test)}")
    File.rm_rf!(tmp)
    File.mkdir_p!(tmp)

    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(previous_shell)
      File.rm_rf!(tmp)
    end)

    {:ok, project: Path.join(tmp, "my_agent")}
  end

  test "--hex writes a project that needs no checkout", %{project: project} do
    New.run(["--hex", "--no-install", project])

    mix_exs = File.read!(Path.join(project, "mix.exs"))

    assert mix_exs =~ ~s({:lemon_core, "~> 0.2"})
    assert mix_exs =~ ~s({:lemon_ai, "~> 0.2"})
    assert mix_exs =~ ~s({:lemon_agent, "~> 0.2"})
    refute mix_exs =~ "path:"
  end

  test "--hex ignores $LEMON_PATH", %{project: project} do
    System.put_env("LEMON_PATH", "/opt/lemon")
    on_exit(fn -> System.delete_env("LEMON_PATH") end)

    New.run(["--hex", "--no-install", project])

    refute File.read!(Path.join(project, "mix.exs")) =~ "/opt/lemon"
  end

  test "--hex --channel fails with an explanation and writes nothing", %{project: project} do
    error =
      assert_raise Mix.Error, fn ->
        New.run(["--hex", "--channel", "--no-install", project])
      end

    assert error.message =~ "lemon_channels"
    assert error.message =~ "--lemon-path"
    refute File.exists?(project)
  end

  test "--hex --lemon-path is refused", %{project: project} do
    error =
      assert_raise Mix.Error, fn ->
        New.run(["--hex", "--lemon-path", "/opt/lemon", "--no-install", project])
      end

    assert error.message =~ "mutually exclusive"
    refute File.exists?(project)
  end

  test "an explicit --lemon-path still generates path dependencies", %{project: project} do
    New.run(["--lemon-path", "/opt/lemon", "--no-install", project])

    assert File.read!(Path.join(project, "mix.exs")) =~
             ~s({:lemon_core, path: "/opt/lemon/apps/lemon_core"})
  end
end
