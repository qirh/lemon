defmodule LemonWeb.SessionSubagentLiveTest do
  use ExUnit.Case, async: false

  @endpoint LemonWeb.Endpoint
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias CodingAgent.{RunGraph, TaskStore}
  alias LemonCore.{Bus, Event}

  setup do
    settings = [
      {:lemon_web, :access_token},
      {:lemon_web, :setup_readiness_fun},
      {:lemon_web, :active_run_fun},
      {:lemon_control_plane, :agent_runtime_provider}
    ]

    previous =
      Enum.map(settings, fn {app, key} -> {app, key, Application.fetch_env(app, key)} end)

    Application.delete_env(:lemon_web, :access_token)
    Application.put_env(:lemon_web, :active_run_fun, fn _ -> :none end)

    Application.put_env(
      :lemon_control_plane,
      :agent_runtime_provider,
      CodingAgent.ControlPlaneProvider
    )

    Application.put_env(:lemon_web, :setup_readiness_fun, fn ->
      %{
        config: %{complete: true},
        secrets: %{complete: true},
        provider: %{complete: true, credential_ready: true}
      }
    end)

    on_exit(fn ->
      Enum.each(previous, fn
        {app, key, {:ok, value}} -> Application.put_env(app, key, value)
        {app, key, :error} -> Application.delete_env(app, key)
      end)
    end)

    :ok
  end

  test "connected refresh follows real task status and nested graph without retaining private content" do
    key = session_key("tree")
    child_key = session_key("child")
    root = graph_run()
    Application.put_env(:lemon_web, :active_run_fun, fn _ -> {:ok, root} end)
    {child, child_task} = task(key, root, %{delegated_session_key: child_key})
    {grandchild, _} = task(key, child)
    {foreign, _} = task(session_key("foreign"), root)
    {other_run, _} = task(key, "different-run")
    TaskStore.mark_running(child_task)

    TaskStore.append_event(child_task, %{
      details: %{
        action_detail: %{name: "bash", command: "/private/workspace", api_key: "sk-tree-secret"}
      },
      content: [%{text: "PRIVATE_RESULT"}]
    })

    {:ok, view, _} = live(build_conn(), "/sessions/#{key}")
    assert has_element?(view, "#subagent-tree [data-depth='0'][data-status=running]", child)

    assert has_element?(
             view,
             "#subagent-tree [data-depth='1'][data-parent-id='#{child}']",
             grandchild
           )

    assert has_element?(
             view,
             "#subagent-tree a[href='/sessions/#{URI.encode_www_form(child_key)}']",
             "Open child session"
           )

    assert has_element?(view, "#subagent-tree", "bash")
    refute has_element?(view, "#subagent-tree", foreign)
    refute has_element?(view, "#subagent-tree", other_run)

    state = :sys.get_state(view.pid)
    projection = inspect(state.socket.assigns.subagent_tree, limit: :infinity)

    for private <- [
          "PRIVATE_PROMPT",
          "PRIVATE_RESULT",
          "/private/workspace",
          "sk-tree-secret",
          "PRIVATE_DESCRIPTION"
        ] do
      refute render(view) =~ private
      refute projection =~ private
    end

    TaskStore.finish(child_task, %{answer: "PRIVATE_RESULT"})
    # Do not send the refresh ourselves: this proves the connected-only timer.
    eventually(fn ->
      has_element?(view, "#subagent-tree [data-depth='0'][data-status=completed]", child)
    end)
  end

  test "run changes isolate the tree and foreign session bus events cannot change it" do
    key = session_key("run-switch")
    first = graph_run()
    second = graph_run()
    {first_child, _} = task(key, first)
    {second_child, _} = task(key, second)
    Application.put_env(:lemon_web, :active_run_fun, fn _ -> {:ok, first} end)
    {:ok, view, _} = live(build_conn(), "/sessions/#{key}")
    assert has_element?(view, "#subagent-tree", first_child)
    refute has_element?(view, "#subagent-tree", second_child)

    Bus.broadcast(
      Bus.session_topic(session_key("foreign")),
      Event.new(:run_started, %{run_id: second})
    )

    assert has_element?(view, "#subagent-tree", first_child)

    Bus.broadcast(Bus.session_topic(key), Event.new(:run_started, %{run_id: second}))
    eventually(fn -> has_element?(view, "#subagent-tree", second_child) end)
    refute has_element?(view, "#subagent-tree", first_child)
  end

  test "node and depth limits bound connected trees including graph cycles" do
    key = session_key("bounded")
    root = graph_run()
    Application.put_env(:lemon_web, :active_run_fun, fn _ -> {:ok, root} end)
    for _ <- 1..55, do: task(key, root)
    {:ok, view, _} = live(build_conn(), "/sessions/#{key}")

    assert view
           |> render()
           |> LazyHTML.from_fragment()
           |> LazyHTML.query("#subagent-tree li")
           |> Enum.count() == 50

    assert has_element?(view, "#subagent-tree-truncated")

    deep_root = graph_run()
    {first, _} = task(key, deep_root)
    last = Enum.reduce(1..12, first, fn _, parent -> elem(task(key, parent), 0) end)
    RunGraph.add_child(last, first)
    Bus.broadcast(Bus.session_topic(key), Event.new(:run_started, %{run_id: deep_root}))
    eventually(fn -> has_element?(view, "#subagent-tree [data-depth='7']") end)
    refute has_element?(view, "#subagent-tree [data-depth='8']")

    assert view
           |> render()
           |> LazyHTML.from_fragment()
           |> LazyHTML.query("#subagent-tree li")
           |> Enum.count() == 8

    assert has_element?(view, "#subagent-tree-truncated")
  end

  test "unavailable runtime stays distinct from empty and recovers on connected refresh" do
    Application.delete_env(:lemon_control_plane, :agent_runtime_provider)
    {:ok, view, _} = live(build_conn(), "/sessions/#{session_key("unavailable")}")
    assert has_element?(view, "#subagent-tree-unavailable")
    refute has_element?(view, "#subagent-tree-empty")

    Application.put_env(
      :lemon_control_plane,
      :agent_runtime_provider,
      CodingAgent.ControlPlaneProvider
    )

    send(view.pid, :refresh_subagents)
    assert has_element?(view, "#subagent-tree-empty")
    refute has_element?(view, "#subagent-tree-unavailable")
  end

  defp graph_run do
    run = RunGraph.new_run(%{})
    on_exit(fn -> RunGraph.delete_run(run) end)
    run
  end

  defp task(key, parent, extra \\ %{}) do
    run = RunGraph.new_run(%{parent: parent, type: :task})
    RunGraph.add_child(parent, run)

    id =
      TaskStore.new_task(
        Map.merge(
          %{
            session_key: key,
            run_id: run,
            parent_run_id: parent,
            description: "PRIVATE_DESCRIPTION",
            prompt: "PRIVATE_PROMPT",
            cwd: "/private/workspace",
            meta: %{api_key: "sk-tree-secret"}
          },
          extra
        )
      )

    on_exit(fn ->
      TaskStore.delete_task(id)
      RunGraph.delete_run(run)
    end)

    {run, id}
  end

  defp session_key(label),
    do: "agent:web_tree_#{label}_#{System.unique_integer([:positive])}:main"

  defp eventually(fun, attempts \\ 150) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("connected tree did not refresh")

      true ->
        Process.sleep(20)
        eventually(fun, attempts - 1)
    end
  end
end
