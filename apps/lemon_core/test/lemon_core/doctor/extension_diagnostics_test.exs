defmodule LemonCore.Doctor.ExtensionDiagnosticsTest do
  use ExUnit.Case, async: true

  alias LemonCore.Doctor.ExtensionDiagnostics

  test "reports disabled extension execution policy without loading code" do
    System.put_env("LEMON_EXTENSIONS_ENABLED", "false")
    on_exit(fn -> System.delete_env("LEMON_EXTENSIONS_ENABLED") end)

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "extension_diagnostics_disabled_test_#{System.unique_integer([:positive])}"
      )

    extension_dir = Path.join([tmp_dir, ".lemon", "extensions"])
    File.mkdir_p!(extension_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    File.write!(
      Path.join([tmp_dir, ".lemon", "config.toml"]),
      """
      [runtime.extensions]
      enabled = false
      auto_load_default_paths = true
      """
    )

    File.write!(
      Path.join(extension_dir, "lemon_extension.json"),
      Jason.encode!(%{
        schema_version: 1,
        name: "disabled-private-extension",
        version: "1.0.0",
        hosts: [%{type: "beam"}]
      })
    )

    status = ExtensionDiagnostics.status(project_dir: tmp_dir)

    assert status.execution.enabled == false
    assert status.host_runtime.hosts["beam"].status == "disabled"
    assert status.cleanup.loads_extension_code == false
    refute inspect(status) =~ "disabled-private-extension"
  end
end
