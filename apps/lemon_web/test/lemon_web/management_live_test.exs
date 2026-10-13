defmodule LemonWeb.ManagementLiveTest do
  use ExUnit.Case, async: false

  @endpoint LemonWeb.Endpoint

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Plug.Conn, only: [get_resp_header: 2, put_req_header: 3]

  import ExUnit.CaptureLog

  alias LemonCore.{RunStore, SessionLifecycle, Store}

  setup do
    keys = [:access_token, :setup_readiness_fun, :active_runs_fun]
    previous = Map.new(keys, &{&1, Application.get_env(:lemon_web, &1)})

    Application.put_env(:lemon_web, :setup_readiness_fun, fn -> readiness_state() end)
    Application.put_env(:lemon_web, :active_runs_fun, fn -> {:ok, []} end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:lemon_web, key)
        {key, value} -> Application.put_env(:lemon_web, key, value)
      end)
    end)

    {:ok, token: "management-test-#{System.unique_integer([:positive, :monotonic])}"}
  end

  test "management routes fail closed without a configured token" do
    Application.delete_env(:lemon_web, :access_token)

    conn = get(build_conn(), "/manage")
    assert response(conn, 503) == "Management access token is not configured"

    # Local chat keeps the backwards-compatible optional token behavior.
    assert get(build_conn(), "/") |> html_response(200) =~ "Your local agent workspace"
  end

  test "query bootstrap redirects cleanly and retains a valid browser session", %{
    token: token
  } do
    Application.put_env(:lemon_web, :access_token, token)

    assert get(build_conn(), "/manage?token=wrong") |> response(401) == "Unauthorized"

    log =
      capture_log(fn ->
        conn = get(build_conn(), "/manage?view=all&token=#{token}")
        assert redirected_to(conn, 302) == "/manage?view=all"
        refute response(conn, 302) =~ token

        conn = conn |> recycle() |> get("/manage?view=all")
        html = html_response(conn, 200)
        refute html =~ token
        refute html =~ "token="
      end)

    refute log =~ token
    assert log =~ ~s|"token" => "[FILTERED]"|

    conn = authenticated_conn(token)
    html_response(conn, 200)

    conn = conn |> recycle() |> get("/manage")
    html_response(conn, 200)
  end

  test "bearer authentication does not redirect and establishes the browser session", %{
    token: token
  } do
    Application.put_env(:lemon_web, :access_token, token)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> get("/manage")

    html_response(conn, 200)
    assert get_resp_header(conn, "location") == []

    conn = conn |> recycle() |> get("/manage")
    html_response(conn, 200)
  end

  test "live work appears before durable history and moves into history without a refresh click",
       %{
         token: token
       } do
    suffix = unique_suffix()
    session_key = "agent:web_live_#{suffix}:main"
    run_id = "run_web_live_#{suffix}"
    private = "/private/repo-#{suffix}"
    secret = "live-secret-#{suffix}"

    {:ok, state} =
      Agent.start_link(fn ->
        {:ok,
         [
           %{
             run_id: run_id,
             session_key: session_key,
             agent_id: secret,
             started_at_ms: System.system_time(:millisecond),
             cwd: private,
             prompt: secret
           }
         ]}
      end)

    Application.put_env(:lemon_web, :access_token, token)
    Application.put_env(:lemon_web, :active_runs_fun, fn -> Agent.get(state, & &1) end)
    on_exit(fn -> SessionLifecycle.delete(session_key) end)

    {:ok, view, html} = live(authenticated_conn(token), "/manage")

    assert has_element?(
             view,
             ~s|#active-work a[href="/sessions/#{URI.encode_www_form(session_key)}"]|
           )

    refute html =~ private
    refute html =~ secret
    assert SessionLifecycle.get(session_key) == nil

    seed_session(session_key, run_id, "Build a useful feature", "Finished")
    Agent.update(state, fn _ -> {:ok, []} end)
    send(view.pid, :refresh_live_work)
    render(view)

    refute has_element?(
             view,
             ~s|#active-work a[href="/sessions/#{URI.encode_www_form(session_key)}"]|
           )

    assert has_element?(
             view,
             ~s|#session-list a[href="/sessions/#{URI.encode_www_form(session_key)}"]|
           )
  end

  test "a failed live lookup preserves the last known run without exposing failure payloads", %{
    token: token
  } do
    suffix = unique_suffix()
    session_key = "agent:web_unavailable_#{suffix}:main"
    run_id = "run_web_unavailable_#{suffix}"

    {:ok, state} =
      Agent.start_link(fn -> {:ok, [%{run_id: run_id, session_key: session_key}]} end)

    Application.put_env(:lemon_web, :access_token, token)
    Application.put_env(:lemon_web, :active_runs_fun, fn -> Agent.get(state, & &1) end)
    {:ok, view, _} = live(authenticated_conn(token), "/manage")

    Agent.update(state, fn _ -> {:error, %{secret: "hidden-secret", path: "/private/repo"}} end)
    send(view.pid, :refresh_live_work)
    html = render(view)

    assert has_element?(
             view,
             ~s|#active-work a[href="/sessions/#{URI.encode_www_form(session_key)}"]|
           )

    assert has_element?(view, "#active-work", "Unavailable")
    refute html =~ "hidden-secret"
    refute html =~ "/private/repo"

    Agent.update(state, fn _ -> {:ok, []} end)
    send(view.pid, :refresh_live_work)
    render(view)

    refute has_element?(
             view,
             ~s|#active-work a[href="/sessions/#{URI.encode_www_form(session_key)}"]|
           )
  end

  test "the live work projection is bounded and rejects malformed run targets", %{token: token} do
    runs =
      for index <- 1..45 do
        %{
          run_id: "run_bounded_#{index}",
          session_key: "agent:web_bounded:main",
          started_at_ms: index
        }
      end

    invalid = %{
      run_id: "/private/repo",
      session_key: "agent:web_bounded:main",
      started_at_ms: 100
    }

    Application.put_env(:lemon_web, :access_token, token)
    Application.put_env(:lemon_web, :active_runs_fun, fn -> {:ok, [invalid | runs]} end)
    {:ok, view, html} = live(authenticated_conn(token), "/manage")

    assert has_element?(view, "#active-work", "40 active")
    assert has_element?(view, "#active-work", "run_bounded_45")
    refute has_element?(view, "#active-work p.management-session-key", "run_bounded_5")
    refute html =~ "/private/repo"
  end

  test "operator can search, inspect, title, pin, archive, and resume a durable session", %{
    token: token
  } do
    suffix = unique_suffix()
    session_key = "agent:web_admin_#{suffix}:main"
    run_id = "run-web-admin-#{suffix}"
    secret = "browser-secret-#{suffix}"
    private_path = "/private/session-repo-#{suffix}"

    on_exit(fn -> SessionLifecycle.delete(session_key) end)

    seed_session(session_key, run_id, "api_key=#{secret} launch checklist", "Bearer #{secret}", [
      %{
        __event__: :action_event,
        action: %{
          title: "Inspect repository",
          kind: :shell,
          detail: %{token: secret, cwd: private_path}
        },
        phase: :completed,
        ok: true,
        message: "token=#{secret}"
      }
    ])

    assert {:ok, _session} =
             SessionLifecycle.patch(session_key, %{
               title: "Launch room #{private_path} api_key=#{secret}"
             })

    Application.put_env(:lemon_web, :access_token, token)

    {:ok, view, html} = live(authenticated_conn(token), "/manage/sessions/#{session_key}")

    assert html =~ "Launch room"
    assert html =~ "Inspect repository"
    refute html =~ secret
    refute html =~ private_path
    assert has_element?(view, "#run-history details")
    assert has_element?(view, ~s|a[href^="/sessions/"]|, "Resume chat")

    rendered =
      render_submit(view, "update-title", %{"metadata" => %{"title" => "Release triage"}})

    assert rendered =~ "Session title updated"
    assert rendered =~ "Release triage"
    assert SessionLifecycle.get(session_key).title == "Release triage"

    rendered =
      render_click(view, "patch", %{
        "session-key" => session_key,
        "field" => "pinned"
      })

    assert rendered =~ "Session pin state updated"
    assert SessionLifecycle.get(session_key).pinned

    rendered =
      render_change(view, "search", %{
        "filters" => %{"query" => "Release triage", "archive_filter" => "all"}
      })

    assert rendered =~ "1 match current filters"
    assert rendered =~ "Release triage"

    render_click(view, "patch", %{
      "session-key" => session_key,
      "field" => "archived"
    })

    assert SessionLifecycle.get(session_key).archived

    # Chat resume is an internal trusted surface and intentionally reconstructs
    # the unredacted durable transcript; operator RPC/export paths never do.
    {:ok, resumed, resume_html} =
      live(authenticated_conn(token), "/sessions/#{session_key}")

    assert resume_html =~ "api_key=#{secret} launch checklist"
    assert resume_html =~ "Bearer #{secret}"
    assert resume_html =~ "Inspect repository"
    assert has_element?(resumed, "#messages details")
  end

  test "redacted downloads omit secrets and unsupported formats fail safely", %{token: token} do
    suffix = unique_suffix()
    session_key = "agent:web_export_#{suffix}:main"
    secret = "export-secret-#{suffix}"

    on_exit(fn -> SessionLifecycle.delete(session_key) end)

    seed_session(session_key, "run-web-export-#{suffix}", "token=#{secret}", "Bearer #{secret}")
    Application.put_env(:lemon_web, :access_token, token)

    conn = authenticated_conn(token)
    conn = conn |> recycle() |> get("/manage/sessions/#{session_key}/export/json")

    body = response(conn, 200)
    assert get_resp_header(conn, "content-type") |> hd() =~ "application/json"
    assert get_resp_header(conn, "content-disposition") |> hd() =~ "attachment"
    assert Jason.decode!(body)["redacted"] == true
    refute body =~ secret
    refute body =~ "rawEvents"

    conn = conn |> recycle() |> get("/manage/sessions/#{session_key}/export/html")
    assert response(conn, 400) == "Unsupported export format"
  end

  test "prune requires an exact preview and deletes only the previewed archived session", %{
    token: token
  } do
    suffix = unique_suffix()
    stale = "agent:web_prune_#{suffix}:main"
    fresh = "agent:web_prune_fresh_#{suffix}:main"
    now = System.system_time(:millisecond)

    on_exit(fn -> Enum.each([stale, fresh], &SessionLifecycle.delete/1) end)

    seed_session(stale, "run-web-prune-#{suffix}", "old", "done", [], now - 40 * 86_400_000)
    seed_session(fresh, "run-web-fresh-#{suffix}", "new", "done", [], now)
    assert {:ok, _} = SessionLifecycle.patch(stale, %{archived: true})
    assert {:ok, _} = SessionLifecycle.patch(fresh, %{archived: true})

    Application.put_env(:lemon_web, :access_token, token)
    {:ok, view, _html} = live(authenticated_conn(token), "/manage")

    assert render_click(view, "confirm-prune") =~ "Preview the exact candidate set"

    rendered = render_submit(view, "preview-prune", %{"prune" => %{"days" => "30"}})
    assert rendered =~ "1 exact candidate"
    assert rendered =~ stale
    refute rendered =~ fresh

    rendered = render_click(view, "confirm-prune")
    assert rendered =~ "Pruned 1 archived session"
    assert SessionLifecycle.get(stale) == nil
    assert SessionLifecycle.get(fresh)
  end

  defp seed_session(session_key, run_id, prompt, answer, events \\ [], updated_at_ms \\ nil) do
    Enum.each(events, &RunStore.append_event(run_id, &1))

    :ok =
      RunStore.finalize(run_id, %{
        session_key: session_key,
        agent_id: session_key |> String.split(":") |> Enum.at(1),
        origin: :web,
        engine: "test-engine",
        prompt: prompt,
        completed: %{ok: true, answer: answer}
      })

    assert eventually(fn -> SessionLifecycle.get(session_key) != nil end)

    if is_integer(updated_at_ms) do
      row = SessionLifecycle.get(session_key)

      :ok =
        Store.put(:sessions_index, session_key, %{
          session_key: session_key,
          agent_id: row.agent_id,
          origin: row.origin,
          created_at_ms: updated_at_ms,
          updated_at_ms: updated_at_ms,
          run_count: row.run_count
        })
    end

    :ok
  end

  defp readiness_state do
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
  end

  defp authenticated_conn(token) do
    Application.put_env(:lemon_web, :access_token, token)
    conn = get(build_conn(), "/manage?token=#{token}")
    assert redirected_to(conn, 302) == "/manage"
    conn |> recycle() |> get("/manage")
  end

  defp unique_suffix, do: System.unique_integer([:positive, :monotonic])

  defp eventually(fun, attempts \\ 100)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(5)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false
end
