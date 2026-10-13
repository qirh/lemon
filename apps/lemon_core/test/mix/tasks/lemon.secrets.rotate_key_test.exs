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
    original_port = System.get_env("LEMON_CONTROL_PLANE_PORT")

    # Only the key file under the temporary HOME; never the real Keychain, and
    # a control port no real runtime answers on.
    System.put_env("HOME", home)
    System.delete_env("LEMON_SECRETS_MASTER_KEY")
    System.put_env("LEMON_CONTROL_PLANE_PORT", Integer.to_string(closed_port()))
    Application.put_env(:lemon_core, LemonCore.Secrets, key_providers: [:file])

    on_exit(fn ->
      clear_secrets_table()
      restore_env("HOME", original_home)
      restore_env("LEMON_SECRETS_MASTER_KEY", original_master_key)
      restore_env("LEMON_CONTROL_PLANE_PORT", original_port)

      if original_config,
        do: Application.put_env(:lemon_core, LemonCore.Secrets, original_config),
        else: Application.delete_env(:lemon_core, LemonCore.Secrets)

      File.rm_rf!(home)
    end)

    {:ok, %{source: :file, key_file: key_file}} = MasterKey.init()
    {:ok, key_file: key_file}
  end

  test "refuses to rotate while a Lemon runtime is running", %{key_file: key_file} do
    assert {:ok, _} = Secrets.set("TASK_SECRET", "task-value")
    original_key = File.read!(key_file)
    [_, token] = Regex.run(~r/confirmation token: ([0-9a-f]{64})/, capture_io(fn -> RotateKey.run([]) end))

    System.put_env("LEMON_CONTROL_PLANE_PORT", Integer.to_string(fake_runtime_port()))

    assert_raise Mix.Error, ~r/runtime is running/, fn ->
      RotateKey.run(["--confirm", token])
    end

    assert File.read!(key_file) == original_key
    assert {:ok, "task-value"} = Secrets.get("TASK_SECRET")
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

  defp closed_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  # Answers /healthz like a live Lemon control plane until the test exits.
  defp fake_runtime_port do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)
    spawn_link(fn -> serve_health(listen) end)
    port
  end

  defp serve_health(listen) do
    with {:ok, socket} <- :gen_tcp.accept(listen) do
      _ = :gen_tcp.recv(socket, 0, 1_000)
      body = ~s({"ok":true})
      :gen_tcp.send(socket, "HTTP/1.0 200 OK\r\ncontent-length: #{byte_size(body)}\r\n\r\n" <> body)
      :gen_tcp.close(socket)
      serve_health(listen)
    end
  end

  defp clear_secrets_table do
    Secrets.table()
    |> Store.list()
    |> Enum.each(fn {key, _value} -> Store.delete(Secrets.table(), key) end)
  end
end
