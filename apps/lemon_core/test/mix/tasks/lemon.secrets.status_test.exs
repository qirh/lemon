defmodule Mix.Tasks.Lemon.Secrets.StatusTest do
  @moduledoc """
  Tests for the lemon.secrets.status mix task.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Lemon.Secrets.Status

  setup do
    # Create a temporary directory for test
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "lemon_secrets_status_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    # Create a mock HOME directory
    mock_home = Path.join(tmp_dir, "home")
    File.mkdir_p!(mock_home)

    # Store original HOME
    original_home = System.get_env("HOME")

    # Set HOME to mock directory
    System.put_env("HOME", mock_home)

    on_exit(fn ->
      # Restore original HOME
      if original_home do
        System.put_env("HOME", original_home)
      else
        System.delete_env("HOME")
      end

      # Clean up temp directory
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir, mock_home: mock_home}
  end

  describe "status output" do
    test "displays status when configured" do
      # Set up a temporary master key
      master_key = :crypto.strong_rand_bytes(32) |> Base.encode64()
      System.put_env("LEMON_SECRETS_MASTER_KEY", master_key)

      on_exit(fn ->
        System.delete_env("LEMON_SECRETS_MASTER_KEY")
      end)

      output =
        capture_io(fn ->
          Status.run([])
        end)

      assert output =~ "configured:"
      assert output =~ "source:"
      assert output =~ "keychain_available:"
      assert output =~ "env_fallback:"
      assert output =~ "owner:"
      assert output =~ "count:"
    end

    test "displays status when not configured" do
      # Ensure no master key is set
      System.delete_env("LEMON_SECRETS_MASTER_KEY")

      output =
        capture_io(fn ->
          Status.run([])
        end)

      assert output =~ "configured:"
      assert output =~ "source:"
      assert output =~ "count:"
    end
  end

  describe "output format" do
    test "displays source as 'none' when not configured" do
      System.delete_env("LEMON_SECRETS_MASTER_KEY")

      output =
        capture_io(fn ->
          Status.run([])
        end)

      assert output =~ "source: none"
    end
  end
end
