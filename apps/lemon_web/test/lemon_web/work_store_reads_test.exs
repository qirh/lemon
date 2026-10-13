defmodule LemonWeb.WorkStoreReadsTest do
  use ExUnit.Case, async: false

  alias LemonAgent.Workspace.{GoalStore, KanbanStore}
  alias LemonAutomation.{CronManager, CronStore, GoalLoopManager}
  alias LemonCore.Store

  defmodule BusyBackend do
    @behaviour LemonCore.Store.Backend
    def init(_), do: {:ok, %{}}
    def put(_, _, _, _), do: {:error, :sqlite_busy}
    def put_new(_, _, _, _), do: {:error, :sqlite_busy}
    def get(_, _, _), do: {:error, :sqlite_busy}
    def delete(_, _, _), do: {:error, :sqlite_busy}
    def list(_, _), do: {:error, :sqlite_busy}
  end

  test "strict kanban reads preserve backend failure" do
    with_busy_backend(fn ->
      assert {:error, :store_unavailable} = KanbanStore.list_boards(strict: true)
      assert {:error, :store_unavailable} = KanbanStore.list_tasks("board_test", strict: true)
    end)
  end

  test "strict goal reads preserve backend failure" do
    with_busy_backend(fn ->
      assert {:error, :store_unavailable} = GoalStore.list(strict: true)
    end)
  end

  test "strict cron run reads preserve backend failure" do
    with_busy_backend(fn ->
      assert {:error, :store_unavailable} = CronStore.list_runs("cron_test", strict: true)
    end)
  end

  test "cron manager rejects stale job controls inside its serialized callback" do
    job = %{id: "cron_test", enabled: true, prompt: "private old prompt"}
    revision = CronManager.control_revision(job)
    state = %{jobs: %{"cron_test" => %{job | prompt: "private changed prompt"}}}

    assert {:reply, {:error, :stale}, ^state} =
             CronManager.handle_call({:update, job.id, %{enabled: false}, revision}, nil, state)

    assert {:reply, {:error, :stale}, ^state} =
             CronManager.handle_call({:run_now, job.id, revision}, nil, state)
  end

  test "goal manager refuses an old goal revision before start, stop or pause" do
    key = "agent:workguard#{System.unique_integer([:positive])}:main"
    on_exit(fn -> GoalStore.clear(key) end)
    {:ok, _} = GoalStore.set(key, "Original private objective")
    state = %{loops: %{}}

    {:reply, {:ok, %{control_revision: revision}}, ^state} =
      GoalLoopManager.handle_call({:status, key}, nil, state)

    {:ok, _} = GoalStore.set(key, "Changed private objective")

    assert {:reply, {:error, :stale}, ^state} =
             GoalLoopManager.handle_call({:start_loop, key, [max_ticks: 3], revision}, nil, state)

    assert {:reply, {:error, :stale}, ^state} =
             GoalLoopManager.handle_call({:stop_loop, key, :hard, revision}, nil, state)

    assert {:reply, {:error, :stale}, ^state} =
             GoalLoopManager.handle_call({:transition_goal, key, :pause, revision}, nil, state)

    assert GoalStore.get(key).status == "active"
  end

  defp with_busy_backend(fun) do
    original = :sys.get_state(Store)
    :sys.replace_state(Store, &%{&1 | backend: BusyBackend, backend_state: %{}})

    try do
      fun.()
    after
      :sys.replace_state(Store, fn _ -> original end)
    end
  end
end
