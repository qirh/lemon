defmodule Mix.Tasks.Lemon.Secrets.InitTest do
  @moduledoc """
  Tests for the lemon.secrets.init mix task.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Lemon.Secrets.Init

  setup do
    # Create a temporary directory for test
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "lemon_secrets_init_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    # Create a mock HOME directory
    mock_home = Path.join(tmp_dir, "home")
    File.mkdir_p!(mock_home)

    # Store original HOME
    original_home = System.get_env("HOME")
    original_secrets_config = Application.get_env(:lemon_core, LemonCore.Secrets)

    # Set HOME to mock directory
    System.put_env("HOME", mock_home)

    # Mix-task tests must never touch the developer's real macOS Keychain.
    # MasterKey provider tests exercise that selection contract with doubles;
    # this suite verifies CLI behavior against an isolated file provider.
    Application.put_env(:lemon_core, LemonCore.Secrets, key_providers: [:file])

    on_exit(fn ->
      # Restore original HOME
      if original_home do
        System.put_env("HOME", original_home)
      else
        System.delete_env("HOME")
      end

      if original_secrets_config do
        Application.put_env(:lemon_core, LemonCore.Secrets, original_secrets_config)
      else
        Application.delete_env(:lemon_core, LemonCore.Secrets)
      end

      # Clean up temp directory
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir, mock_home: mock_home}
  end

  describe "run/1 provisioning" do
    test "writes a 0600 key file when no keychain is available", %{mock_home: mock_home} do
      System.delete_env("LEMON_SECRETS_MASTER_KEY")
      key_path = Path.join([mock_home, ".lemon", "secrets_master_key"])

      output = capture_io(fn -> Init.run([]) end)

      assert output =~ key_path
      assert {:ok, stat} = File.stat(key_path)
      assert rem(stat.mode, 0o1000) == 0o600
      assert {:ok, decoded} = key_path |> File.read!() |> String.trim() |> Base.decode64()
      assert byte_size(decoded) == 32
    end

    test "--target file provisions the key file on any platform", %{mock_home: mock_home} do
      System.delete_env("LEMON_SECRETS_MASTER_KEY")
      key_path = Path.join([mock_home, ".lemon", "secrets_master_key"])

      capture_io(fn -> Init.run(["--target", "file"]) end)

      assert File.exists?(key_path)
    end

    test "refuses to clobber an existing key file", %{mock_home: mock_home} do
      System.delete_env("LEMON_SECRETS_MASTER_KEY")
      key_path = Path.join([mock_home, ".lemon", "secrets_master_key"])

      capture_io(fn -> Init.run(["--target", "file"]) end)
      original = File.read!(key_path)

      error =
        assert_raise Mix.Error, fn ->
          capture_io(fn -> Init.run(["--target", "file"]) end)
        end

      assert error.message =~ "already exists"
      assert File.read!(key_path) == original

      capture_io(fn -> Init.run(["--target", "file", "--force"]) end)
      refute File.read!(key_path) == original
    end
  end
end
