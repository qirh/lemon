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
      "plugins" => false,
      "plugins_disabled" => ["lemon", "other"],
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
    assert settings["plugins"] == false
    assert settings["plugins_disabled"] == ["lemon", "other"]
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
    refute File.exists?(Path.join(directory, "plugins"))
    File.write!(path, ~s({"agents":{"custom":{"lemon":{}}}}))
    assert {:error, _message} = LemonCli.TernCommand.install(directory, "/lemon")
    assert File.read!(path) == ~s({"agents":{"custom":{"lemon":{}}}})
  end

  test "installs a real manifest and packaged entry with JSON launcher data", %{
    directory: directory
  } do
    assert :ok = LemonCli.TernCommand.install(directory, "/a launcher/lemon")
    plugin = Path.join(directory, "plugins/lemon")
    manifest = plugin |> Path.join("plugin.toml") |> File.read!() |> Toml.decode!()
    assert manifest["schema"] == 1
    assert manifest["id"] == "lemon"
    assert manifest["window"] == "window.luau"

    for name <- ["plugin.toml", manifest["window"]] do
      assert File.read!(Path.join(plugin, name)) ==
               File.read!(Application.app_dir(:lemon_cli, "priv/tern/" <> name))
    end

    config = plugin |> Path.join("launcher.json") |> File.read!() |> Jason.decode!()
    assert config["launcher"] == "/a launcher/lemon"
    receipt = plugin |> Path.join(".lemon-install.json") |> File.read!() |> Jason.decode!()
    assert receipt["owner"] == "lemon tern install"

    for {name, hash} <- receipt["files"] do
      assert hash ==
               :crypto.hash(:sha256, File.read!(Path.join(plugin, name)))
               |> Base.encode16(case: :lower)
    end
  end

  test "launcher metacharacters stay a single shell argument and cwd stays data", %{
    directory: directory
  } do
    cwd = Path.join(directory, "project ' $(touch cwd-injected)")
    File.mkdir_p!(cwd)
    launcher = Path.join(directory, "lemon' $(touch launcher-injected) \"\nλ")
    File.write!(launcher, "#!/bin/sh\nprintf '%s\\n' \"$PWD\" \"$#\" \"$1\"\n")
    File.chmod!(launcher, 0o700)
    assert :ok = LemonCli.TernCommand.install(directory, launcher)

    config =
      directory
      |> Path.join("plugins/lemon/launcher.json")
      |> File.read!()
      |> Jason.decode!()

    assert config["launcher"] == launcher
    assert {cwd <> "\n1\ntui\n", 0} == System.cmd("/bin/sh", ["-c", config["command"]], cd: cwd)
    refute File.exists?(Path.join(cwd, "launcher-injected"))
    refute File.exists?(Path.join(cwd, "cwd-injected"))

    refute String.contains?(
             File.read!(Path.join(directory, "plugins/lemon/window.luau")),
             launcher
           )
  end

  test "reinstallation updates owned launcher data and preserves unrelated files", %{
    directory: directory
  } do
    assert :ok = LemonCli.TernCommand.install(directory, "/old/lemon")
    plugin = Path.join(directory, "plugins/lemon")
    File.write!(Path.join(plugin, "notes.txt"), "user file\n")
    File.mkdir_p!(Path.join(directory, "plugins/other"))
    File.write!(Path.join(directory, "plugins/other/plugin.toml"), "unrelated\n")

    assert :ok = LemonCli.TernCommand.install(directory, "/new/lemon")
    before = Map.new(File.ls!(plugin), fn name -> {name, File.read!(Path.join(plugin, name))} end)
    assert :ok = LemonCli.TernCommand.install(directory, "/new/lemon")

    assert before ==
             Map.new(File.ls!(plugin), fn name -> {name, File.read!(Path.join(plugin, name))} end)

    assert Jason.decode!(before["launcher.json"])["launcher"] == "/new/lemon"
    assert before["notes.txt"] == "user file\n"
    assert File.read!(Path.join(directory, "plugins/other/plugin.toml")) == "unrelated\n"
    assert Enum.sort(File.ls!(Path.join(directory, "plugins"))) == ["lemon", "other"]
  end

  test "unmanaged or modified plugin assets are not overwritten", %{
    directory: directory,
    path: path
  } do
    plugin = Path.join(directory, "plugins/lemon")
    File.mkdir_p!(plugin)
    File.write!(Path.join(plugin, "window.luau"), "-- user plugin\n")
    original = ~s({"font_size":19})
    File.write!(path, original)

    assert {:error, _} = LemonCli.TernCommand.install(directory, "/lemon")
    assert File.read!(Path.join(plugin, "window.luau")) == "-- user plugin\n"
    assert File.read!(path) == original

    File.rm_rf!(plugin)
    assert :ok = LemonCli.TernCommand.install(directory, "/lemon")
    settings = File.read!(path)
    File.write!(Path.join(plugin, "window.luau"), "-- custom edit\n")
    assert {:error, _} = LemonCli.TernCommand.install(directory, "/new/lemon")
    assert File.read!(Path.join(plugin, "window.luau")) == "-- custom edit\n"
    assert File.read!(path) == settings
  end

  test "linked plugins and symlinked owned assets are never overwritten", %{directory: directory} do
    plugins = Path.join(directory, "plugins")
    File.mkdir_p!(plugins)
    link = Path.join(plugins, "lemon.path")
    File.write!(link, "/some/user/plugin\n")
    assert {:error, _} = LemonCli.TernCommand.install(directory, "/lemon")
    assert File.read!(link) == "/some/user/plugin\n"
    refute File.exists?(Path.join(directory, "settings.json"))

    File.rm!(link)
    assert :ok = LemonCli.TernCommand.install(directory, "/lemon")
    asset = Path.join(plugins, "lemon/window.luau")
    target = Path.join(directory, "user.luau")
    File.write!(target, File.read!(asset))
    File.rm!(asset)
    File.ln_s!(target, asset)
    assert {:error, _} = LemonCli.TernCommand.install(directory, "/new/lemon")
    assert {:ok, %{type: :symlink}} = File.lstat(asset)

    assert File.read!(target) ==
             File.read!(Application.app_dir(:lemon_cli, "priv/tern/window.luau"))
  end

  test "invalid plugin destination leaves settings intact without staging files", %{
    directory: directory,
    path: path
  } do
    original = ~s({"font_size":19})
    File.write!(path, original)
    File.write!(Path.join(directory, "plugins"), "not a directory\n")

    assert {:error, _} = LemonCli.TernCommand.install(directory, "/lemon")
    assert File.read!(path) == original
    assert File.read!(Path.join(directory, "plugins")) == "not a directory\n"
    assert Enum.sort(File.ls!(directory)) == ["plugins", "settings.json"]
  end
end
