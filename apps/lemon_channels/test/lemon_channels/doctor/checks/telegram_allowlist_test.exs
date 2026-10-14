defmodule LemonChannels.Doctor.Checks.TelegramAllowlistTest do
  use ExUnit.Case, async: true

  alias LemonChannels.Doctor.Checks.Channels

  test "an enabled but unpaired Telegram adapter is a doctor failure" do
    checks = run_with_telegram_config("allowed_chat_ids = []\nallow_all_chats = false")

    allowlist = find_check(checks, "channels.telegram.allowlist")
    assert allowlist.status == :fail
    assert allowlist.message =~ "Telegram allowlist is empty"
    assert allowlist.remediation =~ "lemon gateway setup telegram"
  end

  test "a paired Telegram adapter passes without exposing chat ids" do
    checks = run_with_telegram_config("allowed_chat_ids = [424242]")

    allowlist = find_check(checks, "channels.telegram.allowlist")
    assert allowlist.status == :pass
    refute inspect(checks) =~ "424242"
  end

  test "an explicit allow_all_chats opt-in is a warning, not a failure" do
    checks = run_with_telegram_config("allowed_chat_ids = []\nallow_all_chats = true")

    assert find_check(checks, "channels.telegram.allowlist").status == :warn
  end

  test "a disabled Telegram adapter skips the allowlist check" do
    tmp_dir = write_project_config!("[gateway]\nenable_telegram = false\n")

    assert find_check(Channels.run(project_dir: tmp_dir), "channels.telegram.allowlist").status ==
             :skip
  end

  defp run_with_telegram_config(telegram_lines) do
    tmp_dir =
      write_project_config!("""
      [gateway]
      enable_telegram = true

      [gateway.telegram]
      bot_token_secret = "telegram_bot_token"
      #{telegram_lines}
      """)

    Channels.run(project_dir: tmp_dir)
  end

  defp write_project_config!(content) do
    tmp_dir =
      Path.join(System.tmp_dir!(), "telegram_allowlist_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(tmp_dir, ".lemon"))
    File.write!(Path.join([tmp_dir, ".lemon", "config.toml"]), content)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    tmp_dir
  end

  defp find_check(checks, name) do
    Enum.find(checks, &(&1.name == name)) || flunk("missing check #{name}: #{inspect(checks)}")
  end
end
