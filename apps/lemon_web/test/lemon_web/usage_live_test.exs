defmodule LemonWeb.UsageLiveTest do
  use ExUnit.Case, async: false

  @endpoint LemonWeb.Endpoint

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import LemonWeb.Test.OperatorAuth

  alias LemonControlPlane.Methods.Registry
  alias LemonCore.{UsageLedger, UsageStore}

  setup :configure_operator_token

  setup do
    today = Date.utc_today() |> Date.to_iso8601()
    previous_today = UsageStore.get_record(today)
    previous_summary = UsageStore.get_summary(:current)
    LemonCore.Store.delete(:usage_records, today)
    LemonCore.Store.delete(:usage_data, :current)

    on_exit(fn ->
      if previous_today,
        do: UsageStore.put_record(today, previous_today),
        else: LemonCore.Store.delete(:usage_records, today)

      if previous_summary,
        do: UsageStore.put_summary(:current, previous_summary),
        else: LemonCore.Store.delete(:usage_data, :current)
    end)

    :ok
  end

  defp record(run_id, session_key, model, usage) do
    :ok =
      UsageLedger.record(
        UsageLedger.entry(run_id, session_key, %{
          completed: %{ok: true, usage: usage, answer: "private answer text"},
          meta: %{model: model},
          prompt: "private prompt text"
        })
      )
  end

  test "requires operator auth" do
    assert redirected_to(get(build_conn(), "/usage"), 302) =~ "/login"
  end

  test "empty period shows an empty state, not an error", %{conn: conn} do
    {:ok, view, html} = live(conn, "/usage?range=today")
    assert html =~ "No usage recorded in this period"
    refute has_element?(view, "#usage-unavailable")
    assert has_element?(view, "#range-today[aria-pressed=true]")
  end

  test "renders totals, chart, model, provider and session breakdowns", %{conn: conn} do
    record("run-1", "agent:usage:alpha", "openai:gpt-5", %{
      input_tokens: 12_000,
      output_tokens: 3_000,
      cost: %{total: 1.5}
    })

    record("run-2", "agent:usage:beta", "anthropic:claude-x", %{
      input: 500,
      output: 100,
      cost: 0.25
    })

    {:ok, view, html} = live(conn, "/usage")
    assert html =~ "$1.75"
    assert html =~ "13k"
    assert html =~ "3.1k"
    assert has_element?(view, "#usage-daily-chart")
    assert has_element?(view, "#usage-models", "gpt-5")
    assert has_element?(view, "#usage-models", "claude-x")
    assert has_element?(view, "#usage-providers", "openai")
    assert has_element?(view, ~s(#usage-sessions a[href^="/sessions/agent"]), "agent:usage:alpha")
    assert has_element?(view, "#usage-quota", "No quotas")
    refute html =~ "private"

    html = view |> element("#range-today") |> render_click()
    assert html =~ "Today by model"
    assert has_element?(view, "#usage-today-models", "openai:gpt-5")

    html = render_patch(view, "/usage?range=30d&metric=tokens")
    assert html =~ "Daily tokens"
    assert html =~ "16k tokens"
  end

  test "an unavailable usage method is reported, not shown as empty", %{conn: conn} do
    :ok = Registry.unregister("usage.cost")
    on_exit(fn -> Registry.register(LemonControlPlane.Methods.UsageCost) end)

    {:ok, view, html} = live(conn, "/usage")
    assert has_element?(view, "#usage-unavailable")
    assert html =~ "Usage data is unavailable"
    refute html =~ "No usage recorded in this period"
  end
end
