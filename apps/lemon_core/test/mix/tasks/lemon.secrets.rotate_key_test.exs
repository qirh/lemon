defmodule Mix.Tasks.Lemon.Secrets.RotateKeyTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias LemonCore.Secrets
  alias LemonCore.Secrets.MasterKey
  alias LemonCore.Store
  alias Mix.Tasks.Lemon.Secrets.RotateKey

  setup do
    clear_secrets_table()

    home =
      Path.join(System.tmp_dir!(), "lemon-rotate-key-task-#{System.unique_integer([:positive])}")

    File.mkdir_p!(home)

    original_home = System.get_env("HOME")
    original_master_key = System.get_env("LEMON_SECRETS_MASTER_KEY")
    original_config = Application.get_env(:lemon_core, LemonCore.Secrets)

    # Only the key file under the temporary HOME; never the real Keychain.
    System.put_env("HOME", home)
    System.delete_env("LEMON_SECRETS_MASTER_KEY")
    Application.put_env(:lemon_core, LemonCore.Secrets, key_providers: [:file])

    on_exit(fn ->
      clear_secrets_table()
      restore_env("HOME", original_home)
      restore_env("LEMON_SECRETS_MASTER_KEY", original_master_key)

      if original_config,
        do: Application.put_env(:lemon_core, LemonCore.Secrets, original_config),
        else: Application.delete_env(:lemon_core, LemonCore.Secrets)

      File.rm_rf!(home)
    end)

    {:ok, %{source: :file, key_file: key_file}} = MasterKey.init()
    {:ok, key_file: key_file}
  end

  test "previews by default and rotates only with the preview token", %{key_file: key_file} do
    assert {:ok, _} = Secrets.set("TASK_SECRET", "task-value")
    original_key = File.read!(key_file)

    preview = capture_io(fn -> RotateKey.run([]) end)
    assert preview =~ "secrets to re-encrypt: 1"
    assert File.read!(key_file) == original_key
    [_, token] = Regex.run(~r/confirmation token: ([0-9a-f]{64})/, preview)

    assert_raise Mix.Error, ~r/does not match/, fn ->
      RotateKey.run(["--confirm", String.duplicate("f", 64)])
    end

    output = capture_io(fn -> RotateKey.run(["--confirm", token]) end)
    assert output =~ "1 secrets re-encrypted"
    refute File.read!(key_file) == original_key
    assert {:ok, "task-value"} = Secrets.get("TASK_SECRET")
    refute preview <> output =~ "task-value"
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  defp clear_secrets_table do
    Secrets.table()
    |> Store.list()
    |> Enum.each(fn {key, _value} -> Store.delete(Secrets.table(), key) end)
  end
end
