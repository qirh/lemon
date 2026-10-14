defmodule LemonWeb.SettingsLiveTest do
  use ExUnit.Case, async: false

  @endpoint LemonWeb.Endpoint

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import LemonWeb.Test.OperatorAuth

  setup :configure_operator_token

  setup do
    root =
      Path.join(System.tmp_dir!(), "settings_live_test_#{System.unique_integer([:positive])}")

    project = Path.join(root, "project")
    config_path = Path.join(root, "config.toml")
    File.mkdir_p!(project)

    File.write!(config_path, """
    # keep me
    [defaults]
    provider = "openai"
    model = "openai:gpt-5-mini"
    thinking_level = "medium"
    """)

    keys = [
      :provider_configuration_project_dir,
      :provider_configuration_fun,
      :provider_snapshot_fun
    ]

    previous = Map.new(keys, &{&1, Application.fetch_env(:lemon_web, &1)})
    previous_paths = Application.get_env(:lemon_core, :paths)
    previous_thinking = System.get_env("LEMON_DEFAULT_THINKING_LEVEL")
    System.delete_env("LEMON_DEFAULT_THINKING_LEVEL")

    Application.put_env(:lemon_web, :provider_configuration_project_dir, project)
    Application.delete_env(:lemon_web, :provider_configuration_fun)
    Application.delete_env(:lemon_web, :provider_snapshot_fun)
    Application.put_env(:lemon_core, :paths, global_config: config_path)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:lemon_web, key, value)
        {key, :error} -> Application.delete_env(:lemon_web, key)
      end)

      if previous_paths,
        do: Application.put_env(:lemon_core, :paths, previous_paths),
        else: Application.delete_env(:lemon_core, :paths)

      if previous_thinking, do: System.put_env("LEMON_DEFAULT_THINKING_LEVEL", previous_thinking)
      File.rm_rf!(root)
    end)

    %{config_path: config_path, root: root}
  end

  test "requires operator auth" do
    assert redirected_to(get(build_conn(), "/settings"), 302) =~ "/login"
  end

  test "renders appearance, notification, defaults, shortcuts and operator sections", ctx do
    {:ok, view, html} = live(ctx.conn, "/settings")

    assert has_element?(view, "#settings-theme[phx-hook=ThemeSwitcher] [data-theme-choice=dark]")

    assert has_element?(
             view,
             "#notification-prefs[phx-hook=NotificationPrefs] [data-pref=runs][role=switch]"
           )

    assert has_element?(view, "#notification-prefs [data-pref=approvals]")
    assert has_element?(view, "#default-model", "openai:gpt-5-mini")
    assert has_element?(view, "#keyboard", "Go to Chat")
    assert has_element?(view, "#keyboard", "Open command palette")
    assert has_element?(view, "#sign-out[data-method=delete]")
    assert html =~ "Signed in with the operator token"
    refute html =~ ctx.token
    refute html =~ ctx.root
  end

  test "thinking level change is previewed, then applied with the server-held revision", ctx do
    original = File.read!(ctx.config_path)
    {:ok, view, _html} = live(ctx.conn, "/settings")

    html = view |> form("#thinking-form", defaults: %{thinking_level: "high"}) |> render_submit()
    assert has_element?(view, "#defaults-preview", "high")
    assert html =~ "Nothing has been written yet"
    assert File.read!(ctx.config_path) == original

    html = view |> element("#apply-defaults") |> render_click()
    assert html =~ "Default thinking level saved"
    assert File.read!(ctx.config_path) =~ ~s(thinking_level = "high")
    assert File.read!(ctx.config_path) =~ "# keep me"
    refute has_element?(view, "#defaults-preview")
  end

  test "a config edited after preview is refused and nothing is written", ctx do
    {:ok, view, _html} = live(ctx.conn, "/settings")
    view |> form("#thinking-form", defaults: %{thinking_level: "low"}) |> render_submit()

    File.write!(ctx.config_path, File.read!(ctx.config_path) <> "\n# edited elsewhere\n")
    html = view |> element("#apply-defaults") |> render_click()

    assert html =~ "changed after the preview"
    refute File.read!(ctx.config_path) =~ ~s(thinking_level = "low")
    refute has_element?(view, "#defaults-preview")
  end

  test "unsupported levels and unreadable config are refused", ctx do
    {:ok, view, _html} = live(ctx.conn, "/settings")

    assert render_submit(view, "preview-thinking", %{"defaults" => %{"thinking_level" => "max"}}) =~
             "Choose a supported thinking level."

    Application.put_env(:lemon_web, :provider_snapshot_fun, fn -> :error end)
    {:ok, view, _html} = live(ctx.conn, "/settings")
    assert has_element?(view, "#defaults-unavailable")
  end

  test "tokenless loopback access is labelled and has no sign out", _ctx do
    clear_operator_token()
    Application.put_env(:lemon_control_plane, :allow_unauthenticated_loopback_operator, true)

    {:ok, view, html} = live(build_conn(), "/settings")
    assert html =~ "Tokenless loopback access"
    refute has_element?(view, "#sign-out")
  end
end
