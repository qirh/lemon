defmodule LemonWeb.MemoryManagementLive do
  @moduledoc """
  Operator browser for canonical durable memory (`LemonMemory.Lifecycle`).

  Only bounded Safety-redacted summaries, allowlisted provenance, counts and
  digests reach socket state. Deletion previews bind the exact document and
  revision; the operator retypes the digest and the lifecycle service refuses
  stale or mismatched confirmations.
  """

  use LemonWeb, :live_view

  alias LemonMemory.Lifecycle
  alias Phoenix.LiveView.JS

  @default_filters %{
    "query" => "",
    "scope" => "all",
    "kind" => "all",
    "agent" => "",
    "workspace_digest" => "",
    "limit" => "25"
  }

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:nav, :memory)
     |> assign(:page_title, "Memory · Lemon")
     |> assign(:filters, @default_filters)
     |> assign(:items, [])
     |> assign(:list_available?, true)
     |> assign(:result_count, 0)
     |> assign(:truncated, false)
     |> assign(:selected, nil)
     |> assign(:delete_preview, nil)
     |> assign(:confirmation, "")
     |> assign(:notice, nil)
     |> assign(:error, nil)
     |> refresh_list()}
  end

  @impl true
  def handle_event("search", %{"filters" => params}, socket) do
    filters = normalized_form_filters(params)

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:notice, nil)
     |> assign(:error, nil)
     |> refresh_list()}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply,
     socket
     |> assign(:notice, "Memory index refreshed.")
     |> assign(:error, nil)
     |> refresh_list()
     |> refresh_selected()}
  end

  def handle_event("inspect", %{"id" => doc_id}, socket) do
    case lifecycle_call(:inspect_document, [doc_id]) do
      {:ok, selected} ->
        {:noreply,
         socket
         |> assign(:selected, selected)
         |> assign(:delete_preview, nil)
         |> assign(:confirmation, "")
         |> assign(:notice, nil)
         |> assign(:error, nil)}

      {:error, reason} ->
        {:noreply, assign(socket, :error, safe_error(reason))}
    end
  end

  def handle_event("preview-delete", %{"id" => doc_id}, socket) do
    case lifecycle_call(:preview_delete, [doc_id]) do
      {:ok, preview} ->
        {:noreply,
         socket
         |> assign(:selected, preview.document)
         |> assign(:delete_preview, preview)
         |> assign(:confirmation, "")
         |> assign(:notice, "Deletion preview is ready. Retype the exact digest to continue.")
         |> assign(:error, nil)}

      {:error, reason} ->
        {:noreply, assign(socket, :error, safe_error(reason))}
    end
  end

  def handle_event("validate-confirmation", %{"delete" => %{"confirmation" => value}}, socket) do
    {:noreply, assign(socket, :confirmation, normalize_confirmation(value))}
  end

  def handle_event("cancel-delete", _params, socket),
    do: {:noreply, assign(socket, delete_preview: nil, confirmation: "", notice: nil)}

  def handle_event("dismiss", _params, socket),
    do: {:noreply, assign(socket, notice: nil, error: nil)}

  def handle_event("confirm-delete", _params, %{assigns: %{delete_preview: nil}} = socket) do
    {:noreply, assign(socket, :error, "Preview this exact record before deleting it.")}
  end

  def handle_event("confirm-delete", %{"delete" => params}, socket) do
    preview = socket.assigns.delete_preview
    confirmation = normalize_confirmation(params["confirmation"])

    case lifecycle_call(:delete, [preview.document.id, confirmation]) do
      {:ok, %{status: :deleted}} ->
        {:noreply,
         socket
         |> assign(:selected, nil)
         |> assign(:delete_preview, nil)
         |> assign(:confirmation, "")
         |> assign(:notice, "The exact memory record was deleted and verified.")
         |> assign(:error, nil)
         |> refresh_list()}

      {:error, reason} when reason in [:stale, :confirmation_mismatch, :not_found] ->
        {:noreply,
         socket
         |> assign(:delete_preview, nil)
         |> assign(:confirmation, "")
         |> assign(:notice, nil)
         |> assign(:error, safe_error(reason))
         |> refresh_list()
         |> refresh_selected()}

      {:error, reason} ->
        {:noreply, assign(socket, notice: nil, error: safe_error(reason))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page wide>
      <div id="memory-page" phx-hook="PageKeys" data-search="memory-query" data-group="Memory">
        <.page_header
          title="Memory"
          icon="brain"
          subtitle="Search redacted run memory and reviewed learning provenance in the canonical store."
        >
          <:actions>
            <.button icon="refresh" phx-click="refresh">Refresh</.button>
          </:actions>
        </.page_header>

        <div id="memory-feedback" aria-live="polite" class="empty:hidden">
          <.callout :if={@notice} tone="success" class="mb-4">
            {@notice}
            <:actions>
              <.button size="sm" variant="ghost" icon="x" icon_only aria-label="Dismiss" phx-click="dismiss" />
            </:actions>
          </.callout>
          <.callout :if={@error} tone="danger" class="mb-4">
            {@error}
            <:actions>
              <.button size="sm" variant="ghost" icon="x" icon_only aria-label="Dismiss" phx-click="dismiss" />
            </:actions>
          </.callout>
        </div>

        <.form
          for={to_form(@filters, as: :filters)}
          id="memory-filters"
          phx-change="search"
          phx-submit="search"
          class="card mb-4 grid gap-3 p-3 sm:grid-cols-2 lg:grid-cols-[minmax(0,2fr)_repeat(4,minmax(0,1fr))_6rem]"
          role="search"
        >
          <div class="sm:col-span-2 lg:col-span-1">
            <label for="memory-query" class="field-label">Search</label>
            <div class="relative">
              <.icon
                name="search"
                class="pointer-events-none absolute left-2.5 top-1/2 h-3.5 w-3.5 -translate-y-1/2 text-subtle"
              />
              <input
                id="memory-query"
                type="search"
                name="filters[query]"
                value={@filters["query"]}
                maxlength="256"
                phx-debounce="250"
                placeholder="Search redacted summaries"
                autocomplete="off"
                class="input pl-8 pr-8"
              />
              <.kbd keys="/" class="pointer-events-none absolute right-2 top-1/2 -translate-y-1/2" />
            </div>
          </div>
          <.input
            id="memory-scope"
            name="filters[scope]"
            type="select"
            label="Scope"
            value={@filters["scope"]}
            options={Enum.map(~w(all session workspace agent global), &{label(&1), &1})}
          />
          <.input
            id="memory-kind"
            name="filters[kind]"
            type="select"
            label="Kind"
            value={@filters["kind"]}
            options={[
              {"All memory", "all"},
              {"Run memory", "run"},
              {"Reviewed learning", "learned_source"},
              {"Project learnings", "project_learning"}
            ]}
          />
          <.input
            id="memory-agent"
            name="filters[agent]"
            label="Agent"
            value={@filters["agent"]}
            maxlength="64"
            placeholder="default"
            autocomplete="off"
          />
          <.input
            id="memory-workspace"
            name="filters[workspace_digest]"
            label="Workspace digest"
            value={@filters["workspace_digest"]}
            maxlength="64"
            pattern="[a-f0-9]{12}([a-f0-9]{52})?"
            placeholder="12 hex characters"
            autocomplete="off"
            input_class="font-mono"
          />
          <.input
            id="memory-limit"
            name="filters[limit]"
            type="select"
            label="Limit"
            value={@filters["limit"]}
            options={~w(10 25 50)}
          />
        </.form>

        <div class="grid gap-4 lg:grid-cols-[minmax(0,1fr)_minmax(22rem,30rem)]">
          <.card body_class="p-0">
            <:header>Records</:header>
            <:actions>
              <span class="text-xs font-normal text-muted">
                {@result_count} shown{if @truncated, do: "; refine filters for more"}
              </span>
            </:actions>
            <div id="memory-list" class="divide-y divide-line">
              <div :if={@items == []} class="p-4">
                <.empty_state
                  icon="brain"
                  title={
                    if @list_available?,
                      do: "No memory records match these filters.",
                      else: "Memory unavailable"
                  }
                  description={
                    if @list_available?,
                      do: "Up to 50 results from a bounded 200-record window. Workspaces are digest-only.",
                      else: "The memory store could not be read. This is not an empty result."
                  }
                />
              </div>
              <article
                :for={item <- @items}
                id={"memory-#{item.id}"}
                class={["px-4 py-3 transition-colors", selected?(@selected, item.id) && "bg-accent/10"]}
              >
                <div class="flex items-start justify-between gap-3">
                  <button
                    type="button"
                    phx-click="inspect"
                    phx-value-id={item.id}
                    class="min-w-0 flex-1 text-left"
                    aria-label={"Inspect #{item.id}"}
                  >
                    <span class="flex flex-wrap items-center gap-1.5">
                      <.badge tone={kind_tone(item.kind)}>{kind_label(item.kind)}</.badge>
                      <.badge tone="neutral">{label(item.scope)}</.badge>
                      <.badge :if={item.outcome != "success"} tone={outcome_tone(item.outcome)}>
                        {label(item.outcome)}
                      </.badge>
                      <code class="truncate font-mono text-2xs text-subtle">{item.id}</code>
                    </span>
                    <span class="mt-1.5 line-clamp-2 block text-[13px] text-fg">{item.excerpt}</span>
                    <span class="mt-1 flex flex-wrap gap-x-3 text-2xs text-muted">
                      <span>Agent {item.agent}</span>
                      <span>Workspace <span class="font-mono">{item.workspace_digest || "none"}</span></span>
                      <span :if={is_integer(item[:ingested_at_ms])}>{relative_time(item.ingested_at_ms)}</span>
                    </span>
                  </button>
                  <.button
                    size="sm"
                    variant="ghost"
                    icon="trash"
                    icon_only
                    mutation
                    phx-click="preview-delete"
                    phx-value-id={item.id}
                    aria-label={"Delete #{item.id}"}
                    class="text-muted hover:text-danger"
                  />
                </div>
              </article>
            </div>
          </.card>

          <.card id="memory-detail-card" class="lg:self-start" body_class="card-body">
            <:header>Redacted preview</:header>
            <article :if={@selected} id="memory-detail" class="space-y-4">
              <.key_value class="text-xs">
                <:item label="Document"><code class="break-all font-mono">{@selected.id}</code></:item>
                <:item label="Record digest">
                  <code class="break-all font-mono">{@selected.record_digest}</code>
                </:item>
                <:item label="Kind">{kind_label(@selected.kind)}</:item>
                <:item label="Scope">{label(@selected.scope)}</:item>
                <:item label="Agent">{@selected.agent}</:item>
                <:item label="Workspace">
                  <span class="font-mono">{@selected.workspace_digest || "none"}</span>
                </:item>
                <:item label="Redactions">{@selected.redaction_count}</:item>
              </.key_value>
              <section aria-labelledby="prompt-preview-title">
                <h3 id="prompt-preview-title" class="mb-1 text-xs font-semibold uppercase tracking-wider text-subtle">
                  Prompt summary
                </h3>
                <pre class="code-surface max-h-48 overflow-auto whitespace-pre-wrap break-words rounded-md border border-line p-2.5 font-mono text-xs scroll-thin">{@selected.prompt_preview}</pre>
              </section>
              <section aria-labelledby="answer-preview-title">
                <h3 id="answer-preview-title" class="mb-1 text-xs font-semibold uppercase tracking-wider text-subtle">
                  Answer summary
                </h3>
                <pre class="code-surface max-h-64 overflow-auto whitespace-pre-wrap break-words rounded-md border border-line p-2.5 font-mono text-xs scroll-thin">{@selected.answer_preview}</pre>
              </section>
              <section
                :if={@selected.provenance}
                id="memory-provenance"
                aria-labelledby="memory-provenance-title"
                class="space-y-2"
              >
                <h3 id="memory-provenance-title" class="text-xs font-semibold uppercase tracking-wider text-subtle">
                  Reviewed source provenance
                </h3>
                <p class="text-xs text-muted">
                  Source digest
                  <code class="break-all font-mono text-fg">{@selected.provenance.source_digest || "unavailable"}</code>
                </p>
                <p class="text-xs text-muted">
                  {@selected.provenance.source_count} source(s); source text redacted: {yes_no(@selected.provenance.source_text_redacted)}
                </p>
                <ul class="space-y-2">
                  <li
                    :for={source <- @selected.provenance.sources}
                    class="rounded-md border border-line bg-surface-2/50 p-2.5 text-xs"
                  >
                    <p class="font-medium text-fg">{label(source.type)}</p>
                    <p class="mt-1 text-muted">
                      reference <code class="break-all font-mono">{source.reference_digest || "unavailable"}</code>
                    </p>
                    <p class="text-muted">
                      content <code class="break-all font-mono">{source.content_digest || "unavailable"}</code>
                    </p>
                    <p class="mt-1 text-subtle">
                      {source.selected_items} item(s), {source.selected_bytes} bytes, {source.redaction_count} redaction(s)
                    </p>
                  </li>
                </ul>
              </section>
              <div class="flex justify-end border-t border-line pt-3">
                <.button
                  variant="danger-soft"
                  size="sm"
                  icon="trash"
                  mutation
                  phx-click="preview-delete"
                  phx-value-id={@selected.id}
                >
                  Delete record…
                </.button>
              </div>
            </article>
            <.empty_state
              :if={!@selected}
              icon="eye"
              title="Nothing selected"
              description="Select a record to inspect its redacted summary and provenance."
            />
          </.card>
        </div>
      </div>

      <.modal
        :if={@delete_preview}
        id="memory-delete-modal"
        show
        title="Delete memory record"
        description="Exact-revision delete: any change to the record after this preview refuses it."
        on_cancel={JS.push("cancel-delete")}
      >
        <section id="memory-delete-preview" class="space-y-3 text-[13px]">
          <p>
            Only <code class="font-mono text-xs">{@delete_preview.document.id}</code>
            is in scope. This cannot be undone.
          </p>
          <div>
            <p class="field-label">Confirmation digest</p>
            <code
              id="memory-confirmation-digest"
              class="block select-all break-all rounded-md border border-line bg-surface-2 px-2.5 py-2 font-mono text-xs text-fg"
            >{@delete_preview.confirmation_digest}</code>
          </div>
          <.form
            for={to_form(%{"confirmation" => @confirmation}, as: :delete)}
            id="memory-delete-form"
            phx-change="validate-confirmation"
            phx-submit="confirm-delete"
            class="space-y-3"
          >
            <div>
              <label for="memory-delete-confirmation" class="field-label">Retype the digest</label>
              <input
                id="memory-delete-confirmation"
                type="text"
                name="delete[confirmation]"
                value={@confirmation}
                minlength="64"
                maxlength="64"
                pattern="[a-f0-9]{64}"
                autocomplete="off"
                spellcheck="false"
                required
                class="input font-mono text-xs"
              />
            </div>
            <div class="flex justify-end gap-2">
              <.button phx-click="cancel-delete">Cancel</.button>
              <.button
                type="submit"
                variant="danger"
                icon="trash"
                mutation
                disabled={@confirmation != @delete_preview.confirmation_digest}
                phx-disable-with="Deleting…"
              >
                Delete exact record
              </.button>
            </div>
          </.form>
        </section>
      </.modal>
    </.page>
    """
  end

  defp refresh_list(socket) do
    case lifecycle_call(:list, [socket.assigns.filters]) do
      {:ok, result} ->
        safe_filters = stringify_filters(result.filters, socket.assigns.filters)

        socket
        |> assign(:filters, safe_filters)
        |> assign(:items, result.items)
        |> assign(:list_available?, true)
        |> assign(:result_count, result.count)
        |> assign(:truncated, result.truncated)

      {:error, reason} ->
        socket
        |> assign(:items, [])
        |> assign(:list_available?, reason in [:invalid_query, :invalid_filter, :invalid_limit])
        |> assign(:result_count, 0)
        |> assign(:truncated, false)
        |> assign(:error, safe_error(reason))
    end
  end

  defp refresh_selected(%{assigns: %{selected: nil}} = socket), do: socket

  defp refresh_selected(socket) do
    case lifecycle_call(:inspect_document, [socket.assigns.selected.id]) do
      {:ok, selected} -> assign(socket, :selected, selected)
      _ -> assign(socket, :selected, nil)
    end
  end

  defp lifecycle_call(action, args) do
    case Application.get_env(:lemon_web, :memory_lifecycle_fun) do
      fun when is_function(fun, 2) -> fun.(action, args)
      _ -> apply(Lifecycle, action, args)
    end
  rescue
    _ -> {:error, :memory_unavailable}
  catch
    _, _ -> {:error, :memory_unavailable}
  end

  defp normalized_form_filters(params) do
    Map.new(@default_filters, fn {key, default} -> {key, Map.get(params, key, default)} end)
  end

  defp stringify_filters(filters, fallback) do
    %{
      "query" => filters.query,
      "scope" => filters.scope,
      "kind" => filters.kind,
      "agent" => filters.agent,
      "workspace_digest" => filters.workspace_digest,
      "limit" => Map.get(fallback, "limit", "25")
    }
  end

  defp normalize_confirmation(value) when is_binary(value),
    do: value |> String.trim() |> String.slice(0, 64)

  defp normalize_confirmation(_), do: ""

  defp safe_error(:invalid_query), do: "Search text is invalid or too long."
  defp safe_error(:invalid_filter), do: "A memory filter is invalid."
  defp safe_error(:invalid_limit), do: "The result limit is invalid."
  defp safe_error(:not_found), do: "That memory record no longer exists."
  defp safe_error(:stale), do: "The record changed. Preview it again before deleting."

  defp safe_error(:confirmation_mismatch),
    do: "The confirmation is stale or incorrect. Preview again."

  defp safe_error(:invalid_confirmation), do: "The confirmation digest is invalid."
  defp safe_error(_), do: "Durable memory is temporarily unavailable."

  defp label(value) when is_binary(value),
    do: value |> String.replace("_", " ") |> String.capitalize()

  defp label(_), do: "Unknown"

  defp kind_label("learned_source"), do: "Reviewed learning"
  defp kind_label("project_learning"), do: "Project learnings"
  defp kind_label(_), do: "Run memory"

  defp kind_tone("learned_source"), do: "plan"
  defp kind_tone("project_learning"), do: "info"
  defp kind_tone(_), do: "accent"

  defp outcome_tone("failure"), do: "danger"
  defp outcome_tone("aborted"), do: "warning"
  defp outcome_tone("partial"), do: "warning"
  defp outcome_tone(_), do: "neutral"

  defp selected?(%{id: id}, id), do: true
  defp selected?(_, _), do: false

  defp yes_no(true), do: "yes"
  defp yes_no(_), do: "no"
end
