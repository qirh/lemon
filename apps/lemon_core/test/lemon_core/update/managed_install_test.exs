defmodule LemonCore.Update.ManagedInstallTest do
  use ExUnit.Case, async: false

  alias LemonCore.Update.ManagedInstall

  @moduletag :tmp_dir

  test "current resolves the managed current symlink without accepting a stale version", %{
    tmp_dir: tmp_dir
  } do
    versions = Path.join([tmp_dir, "actual", ".lemon", "versions"])
    root = Path.join(versions, "2026.10.0")
    File.mkdir_p!(Path.join(root, "bin"))
    launcher = Path.join(root, "bin/lemon")
    File.write!(launcher, "#!/bin/sh\necho 2026.10.0\n")
    File.chmod!(launcher, 0o755)
    File.ln_s!("2026.10.0", Path.join(versions, "current"))

    File.ln_s!("actual", Path.join(tmp_dir, "home"))

    opts = [
      release_root: Path.join(versions, "current"),
      paths_opts: [home_dir: Path.join(tmp_dir, "home")],
      current_version: "2026.10.0"
    ]

    assert {:ok, "2026.10.0"} = ManagedInstall.current(opts)

    assert {:error, :running_version_mismatch} =
             ManagedInstall.current(Keyword.put(opts, :current_version, "2026.09.0"))
  end

  test "version subprocess clears the old release selection but retains external config and port",
       %{
         tmp_dir: tmp_dir
       } do
    names =
      ~w(RELEASE_ROOT RELEASE_VSN RELEASE_NAME RELEASE_SYS_CONFIG RELEASE_VM_ARGS RELEASE_REMOTE_VM_ARGS RELEASE_TMP LEMON_CONTROL_PLANE_PORT)

    previous = Map.take(System.get_env(), names)
    old_root = Path.join(tmp_dir, "old")
    external_config = Path.join(tmp_dir, "operator.config")

    on_exit(fn ->
      Enum.each(names, &System.delete_env/1)
      System.put_env(previous)
    end)

    System.put_env(%{
      "RELEASE_ROOT" => old_root,
      "RELEASE_VSN" => "2026.09.0",
      "RELEASE_NAME" => "lemon_runtime_min",
      "RELEASE_SYS_CONFIG" => external_config,
      "RELEASE_VM_ARGS" => Path.join(old_root, "releases/2026.09.0/vm.args"),
      "RELEASE_REMOTE_VM_ARGS" => Path.join(old_root, "releases/2026.09.0/remote.vm.args"),
      "RELEASE_TMP" => Path.join(old_root, "tmp"),
      "LEMON_CONTROL_PLANE_PORT" => "4220"
    })

    launcher = Path.join(tmp_dir, "lemon")

    File.write!(launcher, """
    #!/bin/sh
    [ "$1" = version ] || exit 1
    [ -z "${RELEASE_ROOT:-}${RELEASE_VSN:-}${RELEASE_NAME:-}${RELEASE_VM_ARGS:-}${RELEASE_REMOTE_VM_ARGS:-}${RELEASE_TMP:-}" ] || exit 2
    [ "$RELEASE_SYS_CONFIG" = "$(dirname "$0")/operator.config" ] || exit 3
    [ "$LEMON_CONTROL_PLANE_PORT" = 4220 ] || exit 4
    echo 2026.10.0
    """)

    File.chmod!(launcher, 0o755)
    assert :ok = ManagedInstall.verify_launcher_version(launcher, "2026.10.0", [])

    System.put_env("RELEASE_SYS_CONFIG", Path.join(old_root, "releases/2026.09.0/sys"))
    assert {"RELEASE_SYS_CONFIG", nil} in ManagedInstall.command_env()
    assert System.get_env("RELEASE_ROOT") == old_root
  end
end
