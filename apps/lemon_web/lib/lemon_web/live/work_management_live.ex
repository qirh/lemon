defmodule LemonWeb.WorkManagementLive do
  @moduledoc """
  Token-required live automation dashboard. All controls use canonical services;
  confirmation retains only exact safe targets and opaque revisions server-side.
  A connected-only, single three-second timer refreshes bounded projections.
  """
  use LemonWeb, :live_view

  alias LemonWeb.WorkProjection

  @tabs [{:boards, "Kanban"}, {:goals, "Goals"}, {:cron, "Cron"}]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :work_tick, 3_000)

    {:ok,
     assign(socket,
       page_title: "Lemon Work",
       tab: :boards,
       tabs: @tabs,
       work: WorkProjection.snapshot(),
       preview: nil,
       uncertain: MapSet.new(),
       notice: nil,
       error: nil
     )}
  end

  @impl true
  def handle_info(:work_tick, socket) do
    Process.send_after(self(), :work_tick, 3_000)
    {:noreply, refresh(socket)}
  end

  @impl true
  def handle_event("tab", %{"tab" => tab}, socket) do
    case Enum.find(@tabs, fn {key, _} -> Atom.to_string(key) == tab end) do
      {key, _} -> {:noreply, assign(socket, tab: key, preview: nil)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("refresh", _, socket), do: {:noreply, refresh(socket)}
  def handle_event("cancel-preview", _, socket), do: {:noreply, assign(socket, preview: nil)}

  def handle_event("preview", %{"kind" => kind, "id" => id, "action" => action} = params, socket) do
    previous = socket.assigns.work
    socket = refresh(socket)
    kind = parse_kind(kind)
    old = kind && WorkProjection.target(previous, kind, id)
    row = kind && WorkProjection.target(socket.assigns.work, kind, id)
    run_id = params["run"]

    if old && row && allowed?(row, action, run_id) &&
         not MapSet.member?(socket.assigns.uncertain, {kind, id}) do
      {:noreply,
       assign(socket,
         preview: %{row: row, action: action, run_id: run_id},
         error: nil,
         notice: nil
       )}
    else
      {:noreply,
       assign(socket,
         preview: nil,
         error: "This control is unavailable. Refresh and inspect the current state."
       )}
    end
  end

  def handle_event("confirm", _, %{assigns: %{preview: nil}} = socket) do
    {:noreply, assign(socket, error: "Preview the exact action before confirming.")}
  end

  def handle_event("confirm", _, socket) do
    preview = socket.assigns.preview
    socket = refresh(socket) |> assign(preview: nil, notice: nil, error: nil)
    row = WorkProjection.target(socket.assigns.work, preview.row.kind, preview.row.id)

    if row && row.revision == preview.row.revision && row == preview.row &&
         allowed?(row, preview.action, preview.run_id) do
      case WorkProjection.execute(row, preview.action, preview.run_id) do
        :ok ->
          {:noreply,
           socket
           |> refresh()
           |> assign(notice: "Action accepted by the shared service. Live state is shown below.")}

        {:error, :outcome_unknown} ->
          {:noreply,
           socket
           |> refresh()
           |> assign(
             uncertain: MapSet.put(socket.assigns.uncertain, {row.kind, row.id}),
             error:
               "Outcome unknown. The action may have taken effect; it was not retried. Controls for this target are locked on this page. Inspect live state before taking further action."
           )}

        {:error, :stale} ->
          {:noreply, assign(socket, error: stale_message())}

        {:error, _} ->
          {:noreply,
           assign(socket,
             error: "The shared service refused this action. No automatic retry was made."
           )}
      end
    else
      {:noreply, assign(socket, error: stale_message())}
    end
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <main id="main-content" class="management-page">
      <div id="work-dashboard" class="management-container">
        <header class="management-header">
          <div>
            <p class="text-xs font-medium uppercase tracking-wide text-slate-500">Lemon · Automation</p>
            <h1 class="mt-1 text-xl font-semibold text-slate-900">Work in motion</h1>
            <p class="mt-1 text-sm text-slate-600">Boards, bounded goal loops, and scheduled work — from the shared runtime.</p>
          </div>
          <div class="management-header-actions">
            <.link href={~p"/manage"} class="management-secondary-link">Sessions</.link>
            <.link href={~p"/manage/blueprints"} class="management-secondary-link">Blueprints</.link>
            <button id="work-refresh" type="button" phx-click="refresh" class="management-primary-button">Refresh</button>
          </div>
        </header>

        <p class="mb-4 text-xs text-slate-500">Live refresh every 3 seconds while connected. Private instructions and execution output are never shown here.</p>
        <div id="work-feedback" class="management-feedback" aria-live="polite">
          <p :if={@notice} class="management-notice">{@notice}</p>
          <p :if={@error} role="alert" class="management-error">{@error}</p>
        </div>

        <nav class="mb-5 flex flex-wrap gap-2" aria-label="Work categories">
          <button :for={{key, label} <- @tabs} id={"work-tab-#{key}"} type="button"
            phx-click="tab" phx-value-tab={key} aria-pressed={@tab == key}
            class={if @tab == key, do: "management-primary-button", else: "management-secondary-button"}>
            {label} · {if @work[key].state == :ready, do: length(@work[key].items), else: "Unavailable"}
          </button>
        </nav>

        <section :if={@preview} id="work-preview" class="management-panel mb-5 p-5" aria-labelledby="work-preview-title">
          <h2 id="work-preview-title" class="font-semibold text-slate-900">Confirm exact action</h2>
          <p class="mt-2 text-sm text-slate-700">
            {action_label(@preview.action)} on <code>{@preview.row.id}</code>
            <span :if={@preview.run_id}> · invocation <code>{@preview.run_id}</code></span>
          </p>
          <p class="mt-2 text-sm text-slate-600">{effect(@preview.row.kind, @preview.action)}</p>
          <p class="mt-2 text-xs text-slate-500">Nothing has changed yet. Any target or invocation drift rejects this confirmation.</p>
          <div class="mt-4 flex flex-wrap gap-2">
            <button id="work-confirm" type="button" phx-click="confirm" class="management-primary-button">Confirm {action_label(@preview.action)}</button>
            <button id="work-cancel-preview" type="button" phx-click="cancel-preview" class="management-secondary-button">Cancel</button>
          </div>
        </section>

        <section id={"work-panel-#{@tab}"} aria-label={tab_label(@tab)}>
          <div :if={@work[@tab].state == :unavailable} id="work-unavailable" role="status" class="management-panel p-6">
            <h2 class="font-semibold text-slate-900">Service unavailable</h2>
            <p class="mt-2 text-sm text-slate-600">The shared service could not be read. This is not an empty or idle state. Controls are disabled until a successful refresh.</p>
          </div>
          <div :if={@work[@tab].state == :ready && @work[@tab].items == []} id="work-empty" class="management-panel p-8 text-center">
            <h2 class="font-semibold text-slate-900">No {String.downcase(tab_label(@tab))} yet</h2>
            <p class="mt-2 text-sm text-slate-600">Create work with the {tool_label(@tab)} agent tools in a private session. This dashboard observes and controls existing work; it does not create or delete records.</p>
            <.link href={~p"/"} class="management-secondary-link mt-4 inline-block">Open assistant</.link>
          </div>

          <div :if={@tab == :boards} class="space-y-5">
            <article :for={board <- @work.boards.items} id={"work-board-#{board.id}"} class="management-panel p-4 sm:p-5">
              <div class="flex flex-wrap items-start justify-between gap-3">
                <div><h2 class="font-semibold text-slate-900">{board.label}</h2><p class="mt-1 break-all text-xs text-slate-500">{board.id}</p></div>
                <div class="flex flex-wrap items-center gap-2"><.badge status={board.runtime} /><span class="text-xs text-slate-500">{board.running_count} workers</span><.controls row={board} uncertain={@uncertain} /></div>
              </div>
              <p :if={Map.get(board, :last_runtime)} class="mt-2 text-xs text-amber-700">Last known dispatcher: {board.last_runtime}. Showing retained state; controls disabled.</p>
              <p class="my-3 text-xs text-slate-500">Up to 30 most recently updated cards · {board.status}</p>
              <div class="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
                <section :for={column <- board.columns} class="min-w-0 rounded-lg bg-slate-50 p-3" aria-label={column}>
                  <h3 class="mb-3 flex justify-between text-xs font-semibold uppercase tracking-wide text-slate-600"><span>{column}</span><span>{Enum.count(board.cards, &(&1.status == column))}</span></h3>
                  <div class="space-y-2">
                    <article :for={card <- Enum.filter(board.cards, &(&1.status == column))} id={"work-card-#{card.id}"} class="rounded-lg border border-slate-200 bg-white p-3 shadow-sm">
                      <p class="break-words text-sm font-medium text-slate-800">{card.label}</p><p class="mt-2 break-all text-xs text-slate-500">{card.id}</p>
                      <p :if={card.result} class="mt-2 text-xs text-slate-600">Last run: <.badge status={card.result} /></p>
                      <.session_link session={card.session} />
                      <div :if={card.workflow} class="mt-3 space-y-2 border-t border-slate-100 pt-2 text-xs text-slate-600">
                        <p>Workflow: {String.replace(card.workflow.phase, "_", " ")}</p>
                        <p :if={card.workflow.approved}>Independent review approved</p>
                        <p :if={card.workflow.branch} class="break-all">Branch: <code>{card.workflow.branch}</code></p>
                        <p :if={card.workflow.commit} class="break-all">Commit: <code>{String.slice(card.workflow.commit, 0, 12)}</code></p>
                        <div :if={card.workflow.review_session}><p>Independent review</p><.session_link session={card.workflow.review_session} /></div>
                        <a :if={card.workflow.pr_url} href={card.workflow.pr_url} rel="noopener noreferrer" class="inline-block font-medium text-blue-700 underline">Open pull request</a>
                      </div>
                    </article>
                    <p :if={not Enum.any?(board.cards, &(&1.status == column))} class="py-3 text-xs text-slate-400">No cards</p>
                  </div>
                </section>
              </div>
            </article>
          </div>

          <div :if={@tab == :goals} class="grid gap-4 md:grid-cols-2">
            <article :for={goal <- @work.goals.items} id={"work-goal-#{goal.id}"} class="management-panel p-5">
              <div class="flex flex-wrap justify-between gap-2"><h2 class="break-all font-semibold text-slate-900">{goal.id}</h2><.badge status={goal.status} /></div>
              <div class="my-4 flex flex-wrap items-center gap-3"><.badge status={goal.runtime} /><span class="text-sm text-slate-600">{goal.continuation_count} continuations</span></div>
              <p :if={goal.result} class="mb-3 text-xs text-slate-600">Last run: <.badge status={goal.result} /></p>
              <p :if={Map.get(goal, :last_runtime)} class="mb-3 text-xs text-amber-700">Last known loop: {goal.last_runtime}. Showing retained state; controls disabled.</p>
              <p class="mb-4 text-xs text-slate-500">Objective stays private. Start runs at most 3 loop ticks, without enabling automatic restart.</p>
              <.controls row={goal} uncertain={@uncertain} /><.session_link session={goal.session} />
            </article>
          </div>

          <div :if={@tab == :cron} class="grid gap-4 lg:grid-cols-2">
            <article :for={job <- @work.cron.items} id={"work-cron-#{job.id}"} class="management-panel p-5">
              <div class="flex flex-wrap justify-between gap-2"><div><h2 class="font-semibold text-slate-900">{job.label}</h2><p class="mt-1 break-all text-xs text-slate-500">{job.id}</p></div><.badge status={job.status} /></div>
              <p class="mt-3 text-sm text-slate-700"><code>{job.schedule}</code></p><p class="mb-4 mt-1 text-xs text-slate-500">Next: {job.next_run}</p>
              <p :if={job.model} class="mb-3 text-xs text-slate-500">Model: {job.model}</p>
              <.controls row={job} uncertain={@uncertain} />
              <p :if={job.runtime == "unavailable"} class="mt-3 text-sm text-amber-700">Run status unavailable; controls disabled.</p>
              <ul class="mt-4 divide-y divide-slate-100" aria-label="Recent runs">
                <li :for={run <- job.runs} id={"work-run-#{run.id}"} class="flex flex-wrap items-center justify-between gap-2 py-3">
                  <div class="min-w-0">
                    <p class="break-all text-xs text-slate-500">{run.id}</p>
                    <span class="text-xs text-slate-500">{run.duration_ms} ms · Retry {run.retry_attempt}</span>
                    <.session_link session={run.session} />
                  </div>
                  <div class="flex items-center gap-2"><.badge status={run.status} />
                    <button :if={run.abortable} id={"work-abort-#{run.id}"} type="button" phx-click="preview" phx-value-kind="cron" phx-value-id={job.id} phx-value-action="abort" phx-value-run={run.id} disabled={MapSet.member?(@uncertain, {:cron, job.id})} class="management-secondary-button">Abort run…</button>
                  </div>
                </li>
              </ul>
              <p :if={job.runtime != "unavailable" && job.runs == []} class="mt-4 text-xs text-slate-500">No runs yet.</p>
              <.session_link session={job.session} />
            </article>
          </div>
          <p :if={@work[@tab].state == :ready} class="mt-5 text-xs text-slate-500">Bounded view: up to {WorkProjection.limit(@tab)} records{if @tab == :cron, do: " and 5 recent runs per job", else: ""}.</p>
        </section>
      </div>
    </main>
    """
  end

  defp controls(assigns) do
    ~H"""
    <div class="flex flex-wrap gap-2">
      <button :for={action <- WorkProjection.actions(@row)} id={"work-#{@row.kind}-#{@row.id}-#{action}"} type="button"
        phx-click="preview" phx-value-kind={@row.kind} phx-value-id={@row.id} phx-value-action={action}
        disabled={MapSet.member?(@uncertain, {@row.kind, @row.id})} class="management-secondary-button">{action_label(action)}…</button>
    </div>
    """
  end

  defp badge(assigns) do
    ~H"""
    <span class={"inline-flex rounded-full px-2 py-1 text-xs font-medium #{badge_class(@status)}"}>{@status}</span>
    """
  end

  defp session_link(assigns) do
    ~H"""
    <.link :if={@session} href={~p"/sessions/#{@session}"} class="management-secondary-link mt-3 inline-block text-xs">Private transcript →</.link>
    """
  end

  defp refresh(socket), do: assign(socket, work: WorkProjection.snapshot(socket.assigns.work))
  defp parse_kind(value), do: Enum.find([:boards, :goals, :cron], &(Atom.to_string(&1) == value))

  defp allowed?(%{kind: :cron, runtime: "ready"} = row, "abort", id),
    do: Enum.any?(row.runs, &(&1.id == id and &1.abortable))

  defp allowed?(row, action, nil), do: action in WorkProjection.actions(row)
  defp allowed?(_, _, _), do: false

  defp stale_message,
    do:
      "State changed since preview. Nothing was changed by this confirmation. Preview the current target again."

  defp tab_label(key), do: @tabs |> Keyword.fetch!(key)
  defp tool_label(:boards), do: "kanban"
  defp tool_label(:goals), do: "goal"
  defp tool_label(:cron), do: "cron"
  defp action_label("start"), do: "Start"
  defp action_label("stop"), do: "Stop"
  defp action_label("pause"), do: "Pause"
  defp action_label("resume"), do: "Resume"
  defp action_label("run"), do: "Run now"
  defp action_label("abort"), do: "Abort run"

  defp effect(:boards, "stop"),
    do:
      "Stops this dispatcher and requests cancellation of its exact owned runs. Ambiguous cancellations remain reconciling."

  defp effect(:boards, "start"),
    do: "Starts this board with one concurrent worker using the shared dispatcher."

  defp effect(:goals, "start"),
    do: "Starts at most 3 loop ticks. Does not enable automatic restart."

  defp effect(:goals, "stop"),
    do: "Disables automatic restart and requests a hard stop of this exact goal invocation."

  defp effect(:cron, "pause"),
    do: "Disables future scheduled runs. An already active run is not aborted."

  defp effect(:cron, "abort"),
    do: "Requests cancellation of only the displayed cron run, not a later invocation."

  defp effect(:cron, "run"), do: "Submits one immediate run through the shared scheduler."
  defp effect(_, "pause"), do: "Pauses this idle goal. Stop an active loop first."
  defp effect(_, "resume"), do: "Re-enables the existing work using its stored configuration."

  defp badge_class(status) when status in ~w(running active enabled completed done),
    do: "bg-emerald-50 text-emerald-700"

  defp badge_class(status) when status in ~w(unavailable unknown failed timeout reconciling),
    do: "bg-amber-50 text-amber-700"

  defp badge_class(_), do: "bg-slate-100 text-slate-600"
end
