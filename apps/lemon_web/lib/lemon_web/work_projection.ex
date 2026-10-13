defmodule LemonWeb.WorkProjection do
  @moduledoc """
  Bounded, allowlisted operator projections over the canonical automation services.

  Private records exist only during a service call. Socket state contains safe IDs,
  labels, counters, validated session keys and opaque revisions, never objectives,
  prompts, execution options or result bodies. A failed lookup is not empty state.
  """

  alias LemonAgent.Workspace.{GoalStore, KanbanStore}
  alias LemonAutomation.{CronManager, GoalLoopManager, KanbanDispatcher}
  alias LemonMemory.Safety

  @limits %{boards: 12, goals: 25, cron: 25}

  def snapshot(previous \\ %{}) do
    %{
      boards:
        section(fn ->
          call(KanbanStore, :list_boards, [[limit: 12, strict: true]])
          |> strict_rows(12, &board/1)
        end),
      goals:
        section(fn ->
          call(GoalStore, :list, [[limit: 25, strict: true]]) |> strict_rows(25, &goal/1)
        end),
      cron: section(fn -> call(CronManager, :list, []) |> rows(25, &cron/1) end)
    }
    |> Map.new(fn {kind, current} ->
      old = Map.get(previous, kind, %{items: []})

      items =
        if current.state == :unavailable do
          Enum.map(old.items, &unavailable/1)
        else
          Enum.map(current.items, fn row ->
            if row.runtime == "unavailable" do
              unavailable(Enum.find(old.items, row, &(&1.id == row.id)))
            else
              row
            end
          end)
        end

      {kind, %{current | items: items}}
    end)
  end

  defp unavailable(row) do
    row = Map.put(row, :last_runtime, Map.get(row, :last_runtime) || row.runtime)
    row = %{row | runtime: "unavailable"}

    if row.kind == :cron,
      do: %{row | runs: Enum.map(row.runs, &%{&1 | abortable: false})},
      else: row
  end

  def limit(kind), do: Map.fetch!(@limits, kind)

  def target(snapshot, kind, id) when kind in [:boards, :goals, :cron] do
    case snapshot[kind] do
      %{state: :ready, items: items} -> Enum.find(items, &(&1.id == id))
      _ -> nil
    end
  end

  def actions(%{kind: :boards, status: "active", runtime: "idle"}), do: ["start"]
  def actions(%{kind: :boards, runtime: "running"}), do: ["stop"]
  def actions(%{kind: :goals, runtime: "running"}), do: ["stop"]
  def actions(%{kind: :goals, runtime: "stopping"}), do: ["stop"]
  def actions(%{kind: :goals, runtime: "scheduled"}), do: ["stop"]
  def actions(%{kind: :goals, runtime: "idle", status: "active"}), do: ["start", "pause"]
  def actions(%{kind: :goals, runtime: "idle", status: "paused"}), do: ["resume"]
  def actions(%{kind: :cron, runtime: "unavailable"}), do: []

  def actions(%{kind: :cron, status: status, runs: runs}) do
    schedule = if status == "enabled", do: ["pause"], else: ["resume"]

    if Enum.any?(runs, &(&1.status in ["pending", "running", "reconciling"])),
      do: schedule,
      else: ["run" | schedule]
  end

  def actions(_), do: []

  def execute(row, action, run_id \\ nil) do
    result =
      try do
        mutate(row, action, run_id)
      rescue
        _ -> {:error, :outcome_unknown}
      catch
        _, _ -> {:error, :outcome_unknown}
      end

    case result do
      {:ok, value} -> if unknown?(value), do: {:error, :outcome_unknown}, else: :ok
      :ok -> :ok
      {:error, :stale} -> {:error, :stale}
      {:error, :outcome_unknown} -> {:error, :outcome_unknown}
      {:error, _} -> {:error, :refused}
      _ -> {:error, :outcome_unknown}
    end
  end

  defp mutate(%{kind: :boards} = row, "start", _),
    do:
      call(KanbanDispatcher, :start_board, [
        row.id,
        [max_concurrency: 1, expected_revision: row.revision]
      ])

  defp mutate(%{kind: :boards} = row, "stop", _),
    do: call(KanbanDispatcher, :stop_board, [row.id, [expected_revision: row.revision]])

  defp mutate(%{kind: :goals} = row, "start", _),
    do:
      call(GoalLoopManager, :start_loop, [
        row.session,
        [max_ticks: 3, auto: false, expected_revision: row.revision]
      ])

  defp mutate(%{kind: :goals} = row, "stop", _),
    do: call(GoalLoopManager, :stop_loop, [row.session, [expected_revision: row.revision]])

  defp mutate(%{kind: :goals} = row, action, _) when action in ["pause", "resume"],
    do:
      call(GoalLoopManager, :transition_goal, [
        row.session,
        if(action == "pause", do: :pause, else: :resume),
        row.revision
      ])

  defp mutate(%{kind: :cron} = row, "run", _),
    do: call(CronManager, :run_now, [row.id, row.revision])

  defp mutate(%{kind: :cron} = row, action, _) when action in ["pause", "resume"],
    do: call(CronManager, :update, [row.id, %{enabled: action == "resume"}, row.revision])

  defp mutate(%{kind: :cron} = row, "abort", run_id) do
    run = Enum.find(row.runs, &(&1.id == run_id and &1.abortable))
    if run, do: call(CronManager, :abort_run, [run.id, run.revision]), else: {:error, :stale}
  end

  defp mutate(_, _, _), do: {:error, :refused}

  defp board(raw) do
    id = required_id(raw.id)

    tasks =
      call(KanbanStore, :list_tasks, [id, [limit: 30, strict: true]]) |> strict_rows(30, &card/1)

    runtime = runtime(fn -> call(KanbanDispatcher, :status, [id]) end, :dispatcher)

    %{
      kind: :boards,
      id: id,
      label: label(raw[:name]),
      status: enum(raw[:status], ~w(active archived)),
      runtime: runtime.status,
      revision: runtime.revision,
      running_count: runtime.count,
      cards: tasks,
      columns:
        Enum.uniq(Enum.map(Enum.take(raw.columns, 30), &label/1) ++ Enum.map(tasks, & &1.status))
    }
  end

  defp outcome(value) when value in ~w(running reconciling completed failed outcome_unknown),
    do: value

  defp outcome(_), do: nil

  defp card(raw) do
    %{
      id: required_id(raw.id),
      label: label(raw[:title]),
      status: label(raw[:status]),
      session: session(raw[:session_key]),
      result: outcome(get_in(raw, [:meta, "kanbanRun", "status"])),
      workflow: workflow(get_in(raw, [:meta, "codingWorkflow"]))
    }
  end

  defp workflow(raw) when is_map(raw) do
    commit = raw["commitSha"]
    branch = raw["branch"]

    %{
      phase:
        enum(
          raw["phase"],
          ~w(coding coding_complete review review_rejected commit_pending committed publish_pending completed)
        ),
      approved: get_in(raw, ["review", "approved"]) == true,
      commit:
        if(is_binary(commit) and Regex.match?(~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/, commit),
          do: commit
        ),
      branch:
        if(is_binary(branch) and Regex.match?(~r/\Alemon-kanban\/[A-Za-z0-9_-]{1,160}\z/, branch),
          do: branch
        ),
      review_session: session(raw["reviewSessionKey"]),
      pr_url: pull_request_url(raw["prUrl"])
    }
  end

  defp workflow(_), do: nil

  defp pull_request_url(value) when is_binary(value) and byte_size(value) <= 256 do
    case URI.parse(value) do
      %URI{
        scheme: "https",
        host: host,
        port: 443,
        userinfo: nil,
        query: nil,
        fragment: nil,
        path: path
      }
      when is_binary(host) and host != "" and is_binary(path) ->
        if Regex.match?(~r/\A\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/pull\/[1-9][0-9]*\z/, path) and
             Regex.match?(~r/\A[A-Za-z0-9.-]+\z/, host),
           do: value

      _ ->
        nil
    end
  end

  defp pull_request_url(_), do: nil

  defp goal(raw) do
    key = session(raw[:session_key])
    if is_nil(key), do: throw(:invalid_projection)
    runtime = runtime(fn -> call(GoalLoopManager, :status, [key]) end, :loop)

    %{
      kind: :goals,
      id: required_id(raw.id),
      label: "Goal",
      session: key,
      status: enum(raw[:status], ~w(active paused completed)),
      runtime: runtime.status,
      revision: runtime.revision,
      continuation_count: count(raw[:continuation_count]),
      running_count: runtime.count,
      result: outcome(get_in(raw, [:meta, "lastResult", "status"]))
    }
  end

  defp cron(raw) do
    id = required_id(raw.id)

    runs =
      section(fn ->
        call(CronManager, :runs, [id, [limit: 5, strict: true]]) |> strict_rows(5, &run/1)
      end)

    %{
      kind: :cron,
      id: id,
      label: label(raw.name),
      status: if(raw.enabled, do: "enabled", else: "paused"),
      runtime: if(runs.state == :ready, do: "ready", else: "unavailable"),
      revision: CronManager.control_revision(raw),
      runs: runs.items,
      session: session(raw.session_key),
      schedule: schedule(raw.schedule),
      model: model(Map.get(raw, :model) || Map.get(raw, :captured_default_model)),
      next_run: if(raw.enabled, do: timestamp(raw.next_run_at_ms), else: "Paused")
    }
  end

  defp run(raw) do
    meta = raw.meta || %{}
    unknown = meta[:outcome_unknown] == true or meta["outcome_unknown"] == true
    active = raw.status in [:pending, :running]

    %{
      id: required_id(raw.id),
      revision: CronManager.control_revision(raw),
      status:
        if(unknown and active,
          do: "reconciling",
          else: enum(raw.status, ~w(pending running completed failed timeout aborted))
        ),
      abortable:
        active and not unknown and meta[:abort_requested] != true and
          meta["abort_requested"] != true,
      duration_ms: count(raw.duration_ms),
      retry_attempt: count(meta[:retry_attempt] || meta["retry_attempt"]),
      session:
        session(
          meta[:router_session_key] || meta["router_session_key"] || meta[:session_key] ||
            meta["session_key"]
        )
    }
  end

  defp runtime(fun, key) do
    case section(fn ->
           case fun.() do
             {:ok, %{running: running, control_revision: revision} = raw}
             when is_boolean(running) ->
               details = raw[key] || %{}

               status =
                 cond do
                   count(raw[:reconciling_count]) > 0 -> "reconciling"
                   running -> enum(details[:status], ~w(running stopping reconciling))
                   key == :loop and get_in(raw, [:auto, "enabled"]) == true -> "scheduled"
                   true -> "idle"
                 end

               %{
                 status: status,
                 revision: required_id(revision),
                 count: count(details[:running_count])
               }

             _ ->
               throw(:unavailable)
           end
         end) do
      %{state: :ready, items: value} -> value
      _ -> %{status: "unavailable", revision: nil, count: 0}
    end
  end

  defp section(fun) do
    %{state: :ready, items: fun.()}
  rescue
    _ -> %{state: :unavailable, items: []}
  catch
    _, _ -> %{state: :unavailable, items: []}
  end

  defp strict_rows({:ok, items}, limit, project), do: rows(items, limit, project)
  defp strict_rows(_, _, _), do: throw(:unavailable)

  defp rows(items, limit, project) when is_list(items),
    do: items |> Enum.take(limit) |> Enum.map(project)

  defp rows(_, _, _), do: throw(:unavailable)

  defp call(module, function, args) do
    case Application.get_env(:lemon_web, :work_service_fun) do
      fun when is_function(fun, 3) -> fun.(module, function, args)
      _ -> apply(module, function, args)
    end
  end

  defp required_id(value) do
    if is_binary(value) and byte_size(value) in 1..128 and
         Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, value) and safe?(value),
       do: value,
       else: throw(:invalid_projection)
  end

  defp session(value) when is_binary(value) do
    if byte_size(value) <= 256 and Regex.match?(~r/\A[A-Za-z0-9_:-]+\z/, value) and
         LemonCore.SessionKey.valid?(value) and safe?(value), do: value, else: nil
  end

  defp session(_), do: nil

  defp safe?(value), do: Safety.redact_for_operator(value, max_bytes: 256) == {value, 0}

  defp label(value) when is_binary(value) do
    value
    |> LemonWeb.ManagementText.text(max_bytes: 96)
    |> String.replace(~r/\s+/u, " ")
  end

  defp label(_), do: "Untitled"
  defp enum(value, allowed) when is_atom(value), do: enum(Atom.to_string(value), allowed)
  defp enum(value, allowed), do: if(value in allowed, do: value, else: "unknown")
  defp count(value) when is_integer(value) and value >= 0, do: value
  defp count(_), do: 0

  defp model(value) when is_binary(value) do
    if byte_size(value) in 1..96 and Regex.match?(~r/\A[A-Za-z0-9_.:-]+\z/, value) and
         safe?(value),
       do: value,
       else: nil
  end

  defp model(_), do: nil

  defp schedule(value) when is_binary(value) do
    if byte_size(value) <= 96 and Regex.match?(~r/\A[0-9*,\/\-\s]+\z/, value),
      do: value,
      else: "Custom schedule"
  end

  defp schedule(_), do: "Custom schedule"

  defp timestamp(value) when is_integer(value) do
    case DateTime.from_unix(value, :millisecond) do
      {:ok, time} -> Calendar.strftime(time, "%b %d, %H:%M UTC")
      _ -> "Not scheduled"
    end
  end

  defp timestamp(_), do: "Not scheduled"
  defp unknown?(:outcome_unknown), do: true
  defp unknown?("outcome_unknown"), do: true
  defp unknown?(%{router_abort: status}) when status in [:unavailable, :rejected], do: true
  defp unknown?(value) when is_map(value), do: value |> Map.values() |> Enum.any?(&unknown?/1)
  defp unknown?(value) when is_list(value), do: Enum.any?(value, &unknown?/1)
  defp unknown?(_), do: false
end
