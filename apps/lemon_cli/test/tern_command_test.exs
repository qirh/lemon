defmodule LemonCli.TernCommandTest do
  use ExUnit.Case, async: true

  setup do
    directory = Path.join(File.cwd!(), ".tern-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    %{directory: directory, path: Path.join(directory, "settings.json")}
  end

  test "registration preserves preferences and other agents and replaces only Lemon", %{
    directory: directory,
    path: path
  } do
    original = %{
      "font_size" => 17,
      "agents" => %{
        "custom" => [
          %{"id" => "other", "command" => "/other", "args" => ["--acp"]},
          %{"id" => "lemon", "command" => "/old"}
        ],
        "keep_tui" => ["codex"]
      }
    }

    File.write!(path, Jason.encode!(original))
    assert :ok = LemonCli.TernCommand.install(directory, "/new/lemon")
    assert :ok = LemonCli.TernCommand.install(directory, "/new/lemon")
    settings = path |> File.read!() |> Jason.decode!()
    assert settings["font_size"] == 17
    assert settings["agents"]["keep_tui"] == ["codex"]
    assert settings["agents"]["auto_acp"]

    assert settings["agents"]["custom"] == [
             %{"id" => "other", "command" => "/other", "args" => ["--acp"]},
             %{
               "id" => "lemon",
               "name" => "Lemon",
               "command" => "/new/lemon",
               "args" => ["acp"],
               "env" => %{}
             }
           ]
  end

  test "invalid existing settings are never overwritten", %{directory: directory, path: path} do
    encoded = "{invalid-json}\n"
    File.write!(path, encoded)
    assert {:error, _message} = LemonCli.TernCommand.install(directory, "/lemon")
    assert File.read!(path) == encoded
    File.write!(path, ~s({"agents":{"custom":{"lemon":{}}}}))
    assert {:error, _message} = LemonCli.TernCommand.install(directory, "/lemon")
    assert File.read!(path) == ~s({"agents":{"custom":{"lemon":{}}}})
  end
end
