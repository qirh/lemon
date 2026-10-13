defmodule LemonWeb.SessionCancelledToolsLiveTest do
  use ExUnit.Case, async: false

  @endpoint LemonWeb.Endpoint

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias LemonCore.{Bus, Event, RunStore, SessionLifecycle}

  setup do
    keys = [:access_token, :setup_readiness_fun, :active_run_fun]
    previous = Map.new(keys, &{&1, Application.get_env(:lemon_web, &1)})

    Application.delete_env(:lemon_web, :access_token)
    Application.put_env(:lemon_web, :active_run_fun, fn _key -> :none end)

    Application.put_env(:lemon_web, :setup_readiness_fun, fn ->
      %{
        config: %{complete: true, path: "/tmp/lemon-config.toml"},
        secrets: %{complete: true, source: :env},
        provider: %{
          complete: true,
          provider: "openai",
          model: "openai:gpt-5",
          credential_ready: true,
          reason: nil
        }
      }
    end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:lemon_web, key)
        {key, value} -> Application.put_env(:lemon_web, key, value)
      end)
    end)

    suffix = System.unique_integer([:positive])
    {:ok, key: "agent:web_cancelled_#{suffix}:main", run_id: "web-cancelled-#{suffix}"}
  end

  test "live cancellation and reload retain one terminal receipt and full real output", ctx do
    {:ok, view, _html} = live(build_conn(), "/sessions/#{ctx.key}")

    detail = %{
      name: "bash",
      tool_call_id: "native_bash",
      args: %{command: "printf STARTED; sleep 30"}
    }

    started = action("call_bash", :started, detail)
    publish(ctx, started)
    assert_eventually(fn -> has_element?(view, "details[data-status=running]", "bash") end)

    output = "STARTED\n" <> String.duplicate("real output\n", 60)

    terminal =
      action(
        "call_bash",
        :completed,
        Map.merge(detail, %{
          result: "preview only",
          result_full: output,
          details: %{cancelled: true, outcome: "unknown", started: true, partial: true}
        }),
        false
      )

    publish(ctx, terminal)
    assert_eventually(fn -> has_element?(view, "details[data-status=cancelled]", "STARTED") end)
    completion = %{ok: false, answer: "", error: "Cancelled by user"}
    persist(ctx, [started, terminal], completion)

    Bus.broadcast(
      Bus.session_topic(ctx.key),
      Event.new(:run_completed, %{completed: completion}, %{run_id: ctx.run_id})
    )

    assert_eventually(fn -> has_element?(view, "#transcript", "Run stopped.") end)
    assert_cancelled_receipt(view, output)
    [card_id] = card_ids(view)

    # Both disconnected history mount and the new connected mount use the
    # durable lifecycle projection, not the old LiveView's state.
    html = build_conn() |> get("/sessions/#{ctx.key}") |> html_response(200)
    assert html =~ "data-status=\"cancelled\""
    refute html =~ "data-status=\"running\""
    assert html =~ "STARTED"

    {:ok, reloaded, _html} = live(build_conn(), "/sessions/#{ctx.key}")
    assert_cancelled_receipt(reloaded, output)
    assert card_ids(reloaded) == [card_id]

    # Replayed terminal events update the hydrated card rather than duplicate it.
    publish(ctx, terminal)
    assert_cancelled_receipt(reloaded, output)
    assert card_ids(reloaded) == [card_id]
  end

  test "partial results expose visible text only and respect real aborted details", ctx do
    {:ok, view, _html} = live(build_conn(), "/sessions/#{ctx.key}")

    terminal =
      action(
        "call_partial",
        "completed",
        %{
          "name" => "bash",
          "result" => "cancelled preview",
          "partial_result" => %{
            "content" => [
              %{"type" => "text", "text" => "STARTED partial"},
              %{"type" => "thinking", "thinking" => "PRIVATE_REASONING", "text" => "HIDDEN_TEXT"}
            ],
            "details" => %{"private" => "HIDDEN_METADATA"}
          },
          "details" => %{"error_type" => "aborted", "outcome" => "unknown"}
        },
        false
      )

    publish(ctx, terminal)

    assert_eventually(fn ->
      has_element?(view, "details[data-status=cancelled]", "STARTED partial")
    end)

    persist(ctx, [terminal], %{ok: false, error: %{reason: :acp_cancel}})
    {:ok, reloaded, _html} = live(build_conn(), "/sessions/#{ctx.key}")
    assert has_element?(reloaded, "#transcript", "Run stopped.")

    for receipt <- [view, reloaded] do
      assert has_element?(receipt, "details[data-status=cancelled] pre", "STARTED partial")
      refute render(receipt) =~ "PRIVATE_REASONING"
      refute render(receipt) =~ "HIDDEN_TEXT"
      refute render(receipt) =~ "HIDDEN_METADATA"
      refute render(receipt) =~ "cancelled preview"
      refute has_element?(receipt, "details .animate-pulse")
    end
  end

  test "stopped run does not infer a terminal result for a bare call", ctx do
    started = action("call_unfinished", :started, %{name: "bash", args: %{command: "work"}})
    persist(ctx, [started], %{ok: false, error: :aborted})
    {:ok, view, _html} = live(build_conn(), "/sessions/#{ctx.key}")

    assert has_element?(view, "details[data-status=running]", "bash")
    refute has_element?(view, "details[data-status=cancelled]")
    refute has_element?(view, "details[data-status=done]")
    assert has_element?(view, "#transcript", "Run stopped.")
  end

  test "success, failure, unknown completion and cancelled-before-start remain distinct", ctx do
    events = [
      action("call_ok", :completed, %{name: "read", result: "READ_OK"}, true),
      action("call_error", :completed, %{name: "read", result: "ENOENT"}, false),
      action("call_unknown", :completed, %{name: "unknown"}),
      action(
        "call_not_started",
        :completed,
        %{
          name: "write",
          details: %{cancelled: true, outcome: "not_started", started: false, partial: false}
        },
        false
      )
    ]

    {:ok, view, _html} = live(build_conn(), "/sessions/#{ctx.key}")
    Enum.each(events, &publish(ctx, &1))
    assert_eventually(fn -> length(card_ids(view)) == 4 end)
    persist(ctx, events, %{ok: false, error: "Provider failed while handling cancelled request"})
    {:ok, reloaded, _html} = live(build_conn(), "/sessions/#{ctx.key}")

    for receipt <- [view, reloaded] do
      assert has_element?(receipt, "details[data-status=done]", "READ_OK")
      assert has_element?(receipt, "details[data-status=failed]", "ENOENT")
      assert has_element?(receipt, "details[data-status=completed]", "unknown")

      assert has_element?(
               receipt,
               "details[data-status=cancelled]",
               "Cancelled before the tool started."
             )

      refute has_element?(receipt, "details[data-status=cancelled] pre")
      refute has_element?(receipt, "details .animate-pulse")
    end

    assert has_element?(reloaded, "#transcript", "The run did not finish.")
    refute has_element?(reloaded, "#transcript", "Run stopped.")
  end

  defp action(id, phase, detail, ok \\ nil) do
    %{
      engine: "lemon",
      action: %{id: id, kind: :tool, title: "bash", detail: detail},
      phase: phase,
      ok: ok
    }
  end

  defp publish(ctx, payload) do
    Bus.broadcast(
      Bus.session_topic(ctx.key),
      Event.new(:engine_action, payload, %{run_id: ctx.run_id})
    )
  end

  defp persist(ctx, events, completion) do
    Enum.each(events, &RunStore.append_event(ctx.run_id, &1))

    :ok =
      RunStore.finalize(ctx.run_id, %{
        session_key: ctx.key,
        agent_id: ctx.key |> String.split(":") |> Enum.at(1),
        origin: :web,
        engine: "lemon",
        prompt: "Run the tool",
        completed: completion
      })

    assert_eventually(fn -> SessionLifecycle.history(ctx.key, redact: false) != [] end)
  end

  defp assert_cancelled_receipt(view, output) do
    visible =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("details[data-status=cancelled] pre")
      |> LazyHTML.text()

    assert visible =~ String.trim(output)
    assert has_element?(view, "details[data-status=cancelled]", "its final outcome is unknown")
    assert has_element?(view, "#transcript", "Run stopped.")
    assert length(card_ids(view)) == 1
    refute has_element?(view, "details[data-status=running]")
    refute has_element?(view, "details[data-status=failed]")
    refute has_element?(view, "details .animate-pulse")
    refute render(view) =~ "preview only"
  end

  defp card_ids(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("details.tool-call-card")
    |> LazyHTML.attribute("id")
  end

  defp assert_eventually(fun, attempts \\ 150) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("condition was not met in time")

      true ->
        Process.sleep(20)
        assert_eventually(fun, attempts - 1)
    end
  end
end
