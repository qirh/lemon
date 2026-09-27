defmodule LemonCli.CommandRegistryTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias LemonCli.{CLI, CommandRegistry, CompletionCommand}

  @runtime_families ~w(setup model gateway doctor config secrets channels providers blueprints profile backup context sessions learn update completion migrate node version)
  @source_only ~w(send media models policy skill usage)
  @lifecycle ~w(tui web start run daemon stop restart status)
  @release_only ~w(remote eval rpc)

  test "registry is the complete unique family source for dispatch and help" do
    assert CommandRegistry.names() == @runtime_families ++ @source_only
    assert length(Enum.uniq(CommandRegistry.names())) == length(CommandRegistry.names())

    Enum.each(CommandRegistry.commands(), fn command ->
      assert is_binary(command.summary) and command.summary != ""
      assert is_binary(command.usage) and String.starts_with?(command.usage, "lemon ")
      assert is_list(command.subcommands)
      assert is_list(command.options)
      assert CommandRegistry.help(command.name) =~ "Usage: #{command.usage}"
    end)

    Enum.each(@lifecycle ++ @release_only, fn name ->
      assert CommandRegistry.lifecycle?(name)
      refute CommandRegistry.command?(name)
      assert CommandRegistry.help(name) =~ "Usage: lemon #{name}"
    end)
  end

  test "help lists exactly the commands the invoking launcher can run" do
    for {launcher, present, absent} <- [
          {:source, @runtime_families ++ @source_only ++ @lifecycle, @release_only},
          {:release, @runtime_families ++ @lifecycle ++ @release_only, @source_only}
        ] do
      help = CommandRegistry.overview(launcher)

      for name <- present, do: assert(help =~ ~r/^  #{name} /m, "#{launcher} help lacks #{name}")
      for name <- absent, do: refute(help =~ ~r/^  #{name} /m, "#{launcher} help lists #{name}")
    end
  end

  test "source and release completion never advertise the other launcher's commands" do
    source = Enum.map(CommandRegistry.completion_commands(:source), & &1.name)
    release = Enum.map(CommandRegistry.completion_commands(:release), & &1.name)

    for name <- @runtime_families ++ @lifecycle do
      assert name in source
      assert name in release
    end

    for name <- @source_only do
      assert name in source
      refute name in release
    end

    for name <- @release_only do
      assert name in release
      refute name in source
    end
  end

  test "generated shell scripts are deterministic and structurally complete" do
    for shell <- ~w(bash zsh fish), launcher <- [:source, :release] do
      first = CompletionCommand.render(shell, launcher)
      assert first == CompletionCommand.render(shell, launcher)
      assert first =~ "sessions"
      assert first =~ "blueprints"
      assert first =~ "learn"
      assert first =~ "activate"
      assert first =~ "completion"
      assert first =~ "prune"
      assert first =~ "rollback"
      assert first =~ "confirm"
      refute first =~ "LEMON_SECRETS_MASTER_KEY"
    end
  end

  test "bash and available shell parsers accept generated scripts" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "lemon_completion_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    Enum.each(~w(bash zsh fish), fn shell ->
      script = CompletionCommand.render(shell, :release)
      path = Path.join(tmp_dir, "lemon.#{shell}")
      File.write!(path, script)

      case System.find_executable(shell) do
        nil ->
          if shell == "bash", do: flunk("bash is required for completion validation")

        executable ->
          {output, status} = System.cmd(executable, ["-n", path], stderr_to_stdout: true)
          assert status == 0, "#{shell} rejected completion script:\n#{output}"
      end
    end)
  end

  test "completion dispatch has stable help and usage exits" do
    output =
      capture_io(fn ->
        assert CLI.run(["completion", "bash"]) == 0
      end)

    assert output =~ "complete -F _lemon_completion"

    error =
      capture_io(:stderr, fn ->
        assert CLI.run(["completion", "powershell"]) == 2
      end)

    assert error == "Usage: lemon completion <bash|zsh|fish>\n"
  end
end
