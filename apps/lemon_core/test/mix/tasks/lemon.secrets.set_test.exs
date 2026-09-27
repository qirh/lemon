defmodule Mix.Tasks.Lemon.Secrets.SetTest do
  @moduledoc """
  Tests for the lemon.secrets.set mix task.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Lemon.Secrets.Set

  setup do
    # Create a temporary directory for test
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "lemon_secrets_set_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    # Create a mock HOME directory
    mock_home = Path.join(tmp_dir, "home")
    File.mkdir_p!(mock_home)

    # Store original HOME and LEMON_SECRETS_MASTER_KEY
    original_home = System.get_env("HOME")
    original_master_key = System.get_env("LEMON_SECRETS_MASTER_KEY")

    # Set HOME to mock directory
    System.put_env("HOME", mock_home)

    on_exit(fn ->
      # Restore original HOME
      if original_home do
        System.put_env("HOME", original_home)
      else
        System.delete_env("HOME")
      end

      # Restore original master key
      if original_master_key do
        System.put_env("LEMON_SECRETS_MASTER_KEY", original_master_key)
      else
        System.delete_env("LEMON_SECRETS_MASTER_KEY")
      end

      # Clean up temp directory
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir, mock_home: mock_home}
  end

  describe "argument parsing" do
    test "raises error when name and value are missing" do
      System.delete_env("LEMON_SECRETS_MASTER_KEY")

      error =
        assert_raise Mix.Error, fn ->
          capture_io(fn ->
            Set.run([])
          end)
        end

      assert error.message =~ "Usage: mix lemon.secrets.set <name> <value>"
    end

    test "raises error when only name is provided via positional arg" do
      System.delete_env("LEMON_SECRETS_MASTER_KEY")

      error =
        assert_raise Mix.Error, fn ->
          capture_io(fn ->
            Set.run(["my_secret"])
          end)
        end

      assert error.message =~ "Usage: mix lemon.secrets.set <name> <value>"
    end

    test "raises error when only --name is provided without --value" do
      System.delete_env("LEMON_SECRETS_MASTER_KEY")

      error =
        assert_raise Mix.Error, fn ->
          capture_io(fn ->
            Set.run(["--name", "my_secret"])
          end)
        end

      assert error.message =~ "Usage: mix lemon.secrets.set <name> <value>"
    end

    test "raises error when only --value is provided without --name" do
      System.delete_env("LEMON_SECRETS_MASTER_KEY")

      error =
        assert_raise Mix.Error, fn ->
          capture_io(fn ->
            Set.run(["--value", "secret_value"])
          end)
        end

      assert error.message =~ "Usage: mix lemon.secrets.set <name> <value>"
    end

    test "accepts positional arguments [name, value]" do
      # With positional args, it will try to store but fail due to missing master key
      System.delete_env("LEMON_SECRETS_MASTER_KEY")

      error =
        assert_raise Mix.Error, fn ->
          capture_io(fn ->
            Set.run(["my_secret", "my_value"])
          end)
        end

      # Should fail on master key check, not argument parsing
      assert_storage_attempt_failed(error)
    end

    test "accepts named arguments --name and --value" do
      System.delete_env("LEMON_SECRETS_MASTER_KEY")

      error =
        assert_raise Mix.Error, fn ->
          capture_io(fn ->
            Set.run(["--name", "my_secret", "--value", "my_value"])
          end)
        end

      # Should fail on master key check, not argument parsing
      assert_storage_attempt_failed(error)
    end

    test "accepts short aliases -n and -v" do
      System.delete_env("LEMON_SECRETS_MASTER_KEY")

      error =
        assert_raise Mix.Error, fn ->
          capture_io(fn ->
            Set.run(["-n", "my_secret", "-v", "my_value"])
          end)
        end

      # Should fail on master key check, not argument parsing
      assert_storage_attempt_failed(error)
    end

    test "accepts --provider option" do
      System.delete_env("LEMON_SECRETS_MASTER_KEY")

      error =
        assert_raise Mix.Error, fn ->
          capture_io(fn ->
            Set.run(["my_secret", "my_value", "--provider", "manual"])
          end)
        end

      # Should fail on master key check, not argument parsing
      assert_storage_attempt_failed(error)
    end

    test "accepts --expires-at option" do
      System.delete_env("LEMON_SECRETS_MASTER_KEY")

      error =
        assert_raise Mix.Error, fn ->
          capture_io(fn ->
            Set.run(["my_secret", "my_value", "--expires-at", "1735689600000"])
          end)
        end

      # Should fail on master key check, not argument parsing
      assert_storage_attempt_failed(error)
    end
  end

  describe "error handling for missing master key" do
    test "raises Mix.Error with missing_master_key message" do
      System.delete_env("LEMON_SECRETS_MASTER_KEY")

      error =
        assert_raise Mix.Error, fn ->
          capture_io(fn ->
            Set.run(["test_key", "test_value"])
          end)
        end

      # Should indicate missing master key or startup failure
      assert_storage_attempt_failed(error)
    end

    test "error message suggests running lemon.secrets.init" do
      System.delete_env("LEMON_SECRETS_MASTER_KEY")

      error =
        assert_raise Mix.Error, fn ->
          capture_io(fn ->
            Set.run(["test_key", "test_value"])
          end)
        end

      # Error should mention init command or setting env var
      assert error.message =~ "lemon.secrets.init" or
               error.message =~ "LEMON_SECRETS_MASTER_KEY" or
               error.message =~ "Failed to start"
    end
  end

  defp assert_storage_attempt_failed(error) do
    assert error.message =~ "Missing secrets master key" or
             error.message =~ "Failed to read secrets master key from keychain" or
             error.message =~ "Failed to start" or
             error.message =~ "Failed to store secret"
  end
end
