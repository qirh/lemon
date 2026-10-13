defmodule LemonWeb.WorkManagementLiveTest do
  use ExUnit.Case, async: false

  @endpoint LemonWeb.Endpoint
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Plug.Conn, only: [put_req_header: 3]

  alias LemonAgent.Workspace.{GoalStore, KanbanStore}
  alias LemonAutomation.{CronManager, GoalLoopManager, KanbanDispatcher}

  setup do
    old = Map.new([:access_token, :work_service_fun], &{&1, Application.get_env(:lemon_web, &1)})
    Application.put_env(:lemon_web, :access_token, "work-test-token")
    state = start_supervised!({Agent, fn -> fixture() end})

    Application.put_env(:lemon_web, :work_service_fun, fn module, function, args ->
      service(state, module, function, args)
    end)

    on_exit(fn ->
      Enum.each(old, fn
        {key, nil} -> Application.delete_env(:lemon_web, key)
        {key, value} -> Application.put_env(:lemon_web, key, value)
      end)
    end)

    %{state: state}
  end

  test "management route requires configured token and removes query credentials" do
    Application.delete_env(:lemon_web, :access_token)

    assert get(build_conn(), "/manage/work") |> response(503) ==
             "Management access token is not configured"

    Application.put_env(:lemon_web, :access_token, "work-test-token")
    assert get(build_conn(), "/manage/work") |> response(401) == "Unauthorized"
    conn = get(build_conn(), "/manage/work?token=work-test-token")
    assert redirected_to(conn, 302) == "/manage/work"
    refute response(conn, 302) =~ "work-test-token"
  end

  test "connected refresh updates bounded cards and excludes private data from socket state", %{
    state: state
  } do
    {:ok, view, html} = live(auth_conn(), "/manage/work")
    assert html =~ "Safe board"
    assert has_element?(view, "#work-card-task_demo")
    assert has_element?(view, "a[href='/sessions/#{URI.encode_www_form("agent:default:main")}']")
    refute_private(html)
    refute_private(inspect(:sys.get_state(view.pid), limit: :infinity))

    Agent.update(state, &put_in(&1.card.title, "Updated card"))
    send(view.pid, :work_tick)
    assert render(view) =~ "Updated card"
    render_click(view, "tab", %{"tab" => "goals"})
    assert has_element?(view, "#work-goal-goal_demo")
    refute_private(render(view))
    render_click(view, "tab", %{"tab" => "cron"})
    assert has_element?(view, "#work-run-run_demo")
    refute_private(render(view))
    refute_private(inspect(:sys.get_state(view.pid), limit: :infinity))
  end

  test "board columns keep configured workflow order and safe custom status labels", %{
    state: state
  } do
    Agent.update(state, fn data ->
      data
      |> put_in([:board, :columns], ["backlog", "shipping", "done", "/private/work"])
      |> put_in([:card, :status], "shipping")
    end)

    {:ok, view, _} = live(auth_conn(), "/manage/work")

    columns =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#work-board-board_demo section")
      |> LazyHTML.attribute("aria-label")

    assert Enum.take(columns, 3) == ["backlog", "shipping", "done"]
    assert has_element?(view, "section[aria-label=shipping] #work-card-task_demo")
    refute_private(render(view))
    refute_private(inspect(:sys.get_state(view.pid), limit: :infinity))
  end

  test "terminal failures and retry transcript links survive the content-free projection", %{
    state: state
  } do
    run_session = "agent:default:web:browser:unknown:cron_run_demo"

    Agent.update(state, fn data ->
      data
      |> Map.update!(
        :card,
        &Map.put(&1, :meta, %{
          "kanbanRun" => %{"status" => "failed", "output" => "PRIVATE_RESULT"}
        })
      )
      |> Map.update!(
        :goal,
        &Map.put(&1, :meta, %{
          "lastResult" => %{"status" => "failed", "output" => "PRIVATE_RESULT"}
        })
      )
      |> Map.update!(:run, &%{&1 | meta: %{router_session_key: run_session, retry_attempt: 2}})
    end)

    {:ok, view, _} = live(auth_conn(), "/manage/work")
    assert has_element?(view, "#work-card-task_demo", "failed")
    render_click(view, "tab", %{"tab" => "goals"})
    assert has_element?(view, "#work-goal-goal_demo", "failed")
    render_click(view, "tab", %{"tab" => "cron"})
    assert has_element?(view, "#work-run-run_demo", "Retry 2")

    assert has_element?(
             view,
             ~s|#work-run-run_demo a[href="/sessions/#{URI.encode_www_form(run_session)}"]|
           )

    refute_private(render(view))
    refute_private(inspect(:sys.get_state(view.pid), limit: :infinity))
  end

  test "owned ambiguous board runs remain visibly reconciling instead of idle", %{state: state} do
    Application.put_env(:lemon_web, :work_service_fun, fn
      KanbanDispatcher, :status, _ ->
        {:ok,
         %{
           running: false,
           control_revision: "held_revision",
           dispatcher: nil,
           reconciling_count: 1
         }}

      module, function, args ->
        service(state, module, function, args)
    end)

    {:ok, view, _} = live(auth_conn(), "/manage/work")
    assert has_element?(view, "#work-board-board_demo", "reconciling")
    refute has_element?(view, "#work-boards-board_demo-start")
    refute has_element?(view, "#work-boards-board_demo-stop")
  end

  test "all controls use exact service targets and bounded goal settings", %{state: state} do
    {:ok, view, _} = live(auth_conn(), "/manage/work")
    preview(view, "boards", "board_demo", "start")
    assert Agent.get(state, & &1.calls) == []
    render_click(view, "confirm")
    assert has_element?(view, "#work-boards-board_demo-stop")
    preview(view, "boards", "board_demo", "stop")
    render_click(view, "confirm")
    assert has_element?(view, "#work-boards-board_demo-start")

    render_click(view, "tab", %{"tab" => "goals"})
    preview(view, "goals", "goal_demo", "start")
    render_click(view, "confirm")

    assert {GoalLoopManager, :start_loop, ["agent:default:main", opts]} =
             Agent.get(state, &Enum.find(&1.calls, fn {_, fun, _} -> fun == :start_loop end))

    assert opts[:max_ticks] == 3
    assert opts[:auto] == false
    preview(view, "goals", "goal_demo", "stop")
    render_click(view, "confirm")
    preview(view, "goals", "goal_demo", "pause")
    render_click(view, "confirm")
    assert has_element?(view, "#work-goals-goal_demo-resume")
    preview(view, "goals", "goal_demo", "resume")
    render_click(view, "confirm")

    render_click(view, "tab", %{"tab" => "cron"})
    preview(view, "cron", "cron_demo", "pause")
    render_click(view, "confirm")
    assert has_element?(view, "#work-cron-cron_demo-resume")
    preview(view, "cron", "cron_demo", "resume")
    render_click(view, "confirm")

    render_click(view, "preview", %{
      "kind" => "cron",
      "id" => "cron_demo",
      "action" => "abort",
      "run" => "run_demo"
    })

    render_click(view, "confirm")

    assert {CronManager, :abort_run, ["run_demo", revision]} =
             Agent.get(state, &List.last(&1.calls))

    assert byte_size(revision) == 64
    preview(view, "cron", "cron_demo", "run")
    render_click(view, "confirm")
    assert {CronManager, :run_now, ["cron_demo", _]} = Agent.get(state, &List.last(&1.calls))
  end

  test "stale preview and forged targets never reach mutation", %{state: state} do
    {:ok, view, _} = live(auth_conn(), "/manage/work")
    assert render_click(view, "confirm") =~ "Preview the exact action"
    preview(view, "boards", "missing", "start")
    assert Agent.get(state, & &1.calls) == []
    preview(view, "boards", "board_demo", "start")
    Agent.update(state, &Map.put(&1, :revision, "changed"))
    assert render_click(view, "confirm") =~ "State changed since preview"
    assert Agent.get(state, & &1.calls) == []

    render_click(view, "tab", %{"tab" => "cron"})

    render_click(view, "preview", %{
      "kind" => "cron",
      "id" => "cron_demo",
      "action" => "abort",
      "run" => "run_demo"
    })

    Agent.update(state, &put_in(&1.run.id, "run_replacement"))
    assert render_click(view, "confirm") =~ "State changed since preview"
    assert Agent.get(state, & &1.calls) == []
  end

  test "initial and live lookup failures are unavailable, not idle", %{state: state} do
    Agent.update(state, &Map.put(&1, :unavailable, true))
    {:ok, view, html} = live(auth_conn(), "/manage/work")
    assert html =~ "Service unavailable"
    refute has_element?(view, "#work-empty")
    Agent.update(state, &Map.put(&1, :unavailable, false))
    render_click(view, "refresh")
    assert render(view) =~ "Safe board"
    Agent.update(state, &Map.put(&1, :runtime_unavailable, true))
    render_click(view, "refresh")
    assert render(view) =~ "unavailable"
    assert has_element?(view, "#work-card-task_demo")
    assert render(view) =~ "Last known dispatcher: idle"
    refute has_element?(view, "#work-boards-board_demo-start")
    preview(view, "boards", "board_demo", "start")
    assert Agent.get(state, & &1.calls) == []
    Agent.update(state, &Map.put(&1, :unavailable, true))
    render_click(view, "refresh")
    assert render(view) =~ "Service unavailable"
    assert has_element?(view, "#work-card-task_demo")
  end

  test "unknown mutation outcomes are honest and not repeated", %{state: state} do
    {:ok, view, _} = live(auth_conn(), "/manage/work")
    Agent.update(state, &Map.put(&1, :unknown, true))
    preview(view, "boards", "board_demo", "start")
    assert render_click(view, "confirm") =~ "Outcome unknown"
    preview(view, "boards", "board_demo", "start")
    render_click(view, "confirm")
    assert length(Agent.get(state, & &1.calls)) == 1
    assert has_element?(view, "#work-boards-board_demo-start[disabled]")
  end

  test "real dispatcher starts and stops only the previewed invocation" do
    {:ok, board} = KanbanStore.create_board("Web controlled empty board")
    dispatcher = start_supervised!({KanbanDispatcher, name: __MODULE__.Dispatcher})
    on_exit(fn -> KanbanStore.clear_board(board.id) end)

    Application.put_env(:lemon_web, :work_service_fun, fn
      KanbanStore, :list_boards, _ ->
        {:ok, [KanbanStore.get_board(board.id)]}

      KanbanStore, :list_tasks, args ->
        apply(KanbanStore, :list_tasks, args)

      GoalStore, :list, _ ->
        {:ok, []}

      CronManager, :list, _ ->
        []

      KanbanDispatcher, :status, [id] ->
        KanbanDispatcher.status(id, name: dispatcher)

      KanbanDispatcher, fun, [id, opts] ->
        apply(KanbanDispatcher, fun, [id, Keyword.put(opts, :name, dispatcher)])
    end)

    {:ok, view, _} = live(auth_conn(), "/manage/work")
    preview(view, "boards", board.id, "start")
    render_click(view, "confirm")

    assert {:ok, %{running: true, control_revision: revision}} =
             KanbanDispatcher.status(board.id, name: dispatcher)

    preview(view, "boards", board.id, "stop")
    render_click(view, "confirm")
    assert {:ok, %{running: false}} = KanbanDispatcher.status(board.id, name: dispatcher)

    assert {:error, :stale} =
             KanbanDispatcher.stop_board(board.id, name: dispatcher, expected_revision: revision)

    {:ok, _} = KanbanDispatcher.start_board(board.id, name: dispatcher)

    assert {:error, :stale} =
             KanbanDispatcher.stop_board(board.id, name: dispatcher, expected_revision: revision)

    assert {:ok, %{running: true}} = KanbanDispatcher.status(board.id, name: dispatcher)
    KanbanDispatcher.stop_board(board.id, name: dispatcher)
  end

  defp auth_conn do
    build_conn()
    |> init_test_session(%{})
    |> put_req_header("authorization", "Bearer work-test-token")
  end

  defp preview(view, kind, id, action),
    do: render_click(view, "preview", %{"kind" => kind, "id" => id, "action" => action})

  defp refute_private(text) do
    for secret <- [
          "PRIVATE_OBJECTIVE",
          "PRIVATE_PROMPT",
          "PRIVATE_RESULT",
          "/private/work",
          "relative/private.txt",
          "supersecretvalue",
          "PRIVATE_ENV"
        ] do
      refute text =~ secret
    end
  end

  defp fixture do
    %{
      board: %{
        id: "board_demo",
        name: "Safe board /private/work token=supersecretvalue",
        status: "active",
        columns: ~w(todo doing review done),
        workspace: "/private/work"
      },
      card: %{
        id: "task_demo",
        title: "Safe card relative/private.txt",
        status: "todo",
        description: "PRIVATE_PROMPT",
        session_key: "agent:default:main"
      },
      goal: %{
        id: "goal_demo",
        session_key: "agent:default:main",
        status: "active",
        objective: "PRIVATE_OBJECTIVE",
        cwd: "/private/work",
        continuation_count: 2
      },
      job:
        struct(LemonAutomation.CronJob, %{
          id: "cron_demo",
          name: "Safe cron /private/work",
          enabled: true,
          session_key: "agent:default:main",
          schedule: "0 * * * *",
          next_run_at_ms: nil,
          prompt: "PRIVATE_PROMPT",
          env: %{"PRIVATE_ENV" => "supersecretvalue"}
        }),
      run:
        struct(LemonAutomation.CronRun, %{
          id: "run_demo",
          job_id: "cron_demo",
          status: :running,
          duration_ms: nil,
          output: "PRIVATE_RESULT",
          meta: %{}
        }),
      board_running: false,
      goal_running: false,
      revision: "initial",
      calls: [],
      unavailable: false,
      runtime_unavailable: false,
      unknown: false
    }
  end

  defp service(pid, module, function, args) do
    state = Agent.get(pid, & &1)
    if state.unavailable, do: exit({:service_unavailable, "/private/work"})

    case {module, function, args} do
      {KanbanStore, :list_boards, _} ->
        {:ok, [state.board]}

      {KanbanStore, :list_tasks, _} ->
        {:ok, [state.card]}

      {GoalStore, :list, _} ->
        {:ok, [state.goal]}

      {CronManager, :list, _} ->
        [state.job]

      {CronManager, :runs, _} ->
        {:ok, [state.run]}

      {KanbanDispatcher, :status, _} ->
        runtime(state, :board_running, :dispatcher)

      {GoalLoopManager, :status, _} ->
        runtime(state, :goal_running, :loop)

      _ ->
        Agent.update(
          pid,
          &Map.update!(&1, :calls, fn calls -> calls ++ [{module, function, args}] end)
        )

        if state.unknown do
          {:error, :outcome_unknown}
        else
          Agent.update(pid, &mutate(&1, function, args))
          {:ok, %{}}
        end
    end
  end

  defp runtime(%{runtime_unavailable: true}, _, _), do: {:error, :unavailable}

  defp runtime(state, field, key) do
    {:ok,
     %{
       key => %{status: "running", running_count: 0},
       :running => state[field],
       :control_revision => state.revision
     }}
  end

  defp mutate(state, :start_board, _),
    do: %{state | board_running: true, revision: "board_started"}

  defp mutate(state, :stop_board, _),
    do: %{state | board_running: false, revision: "board_stopped"}

  defp mutate(state, :start_loop, _), do: %{state | goal_running: true, revision: "goal_started"}
  defp mutate(state, :stop_loop, _), do: %{state | goal_running: false, revision: "goal_stopped"}

  defp mutate(state, :transition_goal, [_, action, _]),
    do: put_in(state.goal.status, if(action == :pause, do: "paused", else: "active"))

  defp mutate(state, :update, [_, attrs, _]), do: put_in(state.job.enabled, attrs.enabled)
  defp mutate(state, :abort_run, _), do: put_in(state.run.status, :aborted)
  defp mutate(state, :run_now, _), do: put_in(state.run.status, :running)
end
