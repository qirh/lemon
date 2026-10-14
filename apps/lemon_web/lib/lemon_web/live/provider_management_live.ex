defmodule LemonWeb.ProviderManagementLive do
  @moduledoc """
  `/models`: providers, the model catalog and provider routing.

  * Catalog — `models.list` (bounded, allowlisted fields), searchable and
    filterable; "Set as default" previews and applies a `defaults.model`
    change through `LemonAgent.ModelRuntime.ProviderConfiguration`.
  * Providers — `ProviderStatus.snapshot/1`: configured/credential readiness as
    booleans only, never key names, secret names, env var names or base URLs.
  * Routing — fallbacks and credential pools through `ProviderConfiguration`.

  Every write is preview-first: the preview's opaque `configRevision` stays in
  the socket and apply passes it back as `expectedRevision`, so a config edited
  in between fails closed. Destructive changes require the exact confirmation
  value. Credential references are typed into password fields, validated,
  hashed for the re-entry check and never kept in assigns or rendered.
  """

  use LemonWeb, :live_view

  alias LemonAgent.ModelRuntime.ProviderStatus
  alias LemonWeb.{ProviderConfig, Rpc}

  @safe_identifier ~r/^[a-z0-9][a-z0-9._-]{0,63}$/
  @model_id ~r/^[A-Za-z0-9][A-Za-z0-9._:\/@+-]{0,127}$/
  @max_provider_count 16
  @max_catalog_models 2_000
  @max_rendered_models 200
  @max_status_providers 48
  @tabs ~w(catalog providers routing)

  @empty_routing %{
    "enabled" => true,
    "requireCredentials" => true,
    "fallbackProviders" => [],
    "defaultPool" => nil,
    "defaultProfile" => nil,
    "credentialPools" => [],
    "credentialPoolCount" => 0,
    "credentialReferenceCount" => 0
  }

  @empty_defaults %{"provider" => nil, "model" => nil, "thinkingLevel" => nil}

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(nav: :models, page_title: "Models · Lemon", page_heading: "Models")
      |> assign(:tab, "catalog")
      |> assign(:routing, @empty_routing)
      |> assign(:routing_available?, false)
      |> assign(:defaults, @empty_defaults)
      |> assign(:providers, [])
      |> assign(:providers_state, :loading)
      |> assign(:models, [])
      |> assign(:models_state, :loading)
      |> assign(:catalog_filter, %{"q" => "", "provider" => "", "capability" => "all"})
      |> assign(:fallback_draft, %{"provider" => ""})
      |> assign(:pool_draft, %{
        "pool" => "",
        "providers" => "",
        "strategy" => "priority",
        "activate" => false
      })
      |> assign(:credential_draft, %{"pool" => "", "provider" => "", "operation" => "add"})
      |> assign(:pending_change, nil)
      |> assign(:notice, nil)
      |> assign(:error, nil)
      |> refresh_routing()

    socket =
      if connected?(socket),
        do: socket |> load_models() |> load_providers(),
        else: socket

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = if params["tab"] in @tabs, do: params["tab"], else: "catalog"
    {:noreply, assign(socket, :tab, tab)}
  end

  @impl true
  def handle_async(:models, {:ok, {:ok, models}}, socket),
    do: {:noreply, assign(socket, models: models, models_state: :ok)}

  def handle_async(:models, _result, socket),
    do: {:noreply, assign(socket, models: [], models_state: :unavailable)}

  def handle_async(:providers, {:ok, {:ok, providers}}, socket),
    do: {:noreply, assign(socket, providers: providers, providers_state: :ok)}

  def handle_async(:providers, _result, socket),
    do: {:noreply, assign(socket, providers: [], providers_state: :unavailable)}

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply,
     socket
     |> assign(:pending_change, nil)
     |> assign(:notice, "Provider and model state refreshed.")
     |> assign(:error, nil)
     |> refresh_routing()
     |> load_models()
     |> load_providers()}
  end

  def handle_event("filter-catalog", %{"catalog" => params}, socket) do
    filter = %{
      "q" => params |> Map.get("q", "") |> to_string() |> String.slice(0, 80),
      "provider" => safe_draft_identifier(params["provider"]),
      "capability" =>
        if(params["capability"] in ~w(thinking vision), do: params["capability"], else: "all")
    }

    {:noreply, assign(socket, :catalog_filter, filter)}
  end

  def handle_event("preview-default-model", %{"provider" => provider, "model" => model}, socket) do
    with provider when is_binary(provider) <- safe_optional_identifier(provider),
         model when is_binary(model) <- safe_model_id(model),
         true <- Enum.any?(socket.assigns.models, &(&1.provider == provider and &1.id == model)) do
      {:noreply,
       preview_change(socket, %{
         "action" => "defaults.model",
         "provider" => provider,
         "model" => model
       })}
    else
      _ -> {:noreply, reject_preview(socket, "That model is not in the current catalog.")}
    end
  end

  def handle_event("preview-fallback-add", %{"fallback" => params}, socket) do
    provider = safe_draft_identifier(params["provider"])
    socket = assign(socket, :fallback_draft, %{"provider" => provider})

    if provider == "" do
      {:noreply, reject_preview(socket, "Choose a known provider name.")}
    else
      {:noreply, preview_change(socket, %{"action" => "fallback.add", "provider" => provider})}
    end
  end

  def handle_event("preview-fallback-remove", %{"provider" => provider}, socket) do
    provider = safe_draft_identifier(provider)

    if provider == "" do
      {:noreply, reject_preview(socket, "That fallback provider is not available.")}
    else
      {:noreply, preview_change(socket, %{"action" => "fallback.remove", "provider" => provider})}
    end
  end

  def handle_event("preview-fallback-clear", _params, socket) do
    {:noreply, preview_change(socket, %{"action" => "fallback.clear"})}
  end

  def handle_event("preview-pool-upsert", %{"pool" => params}, socket) do
    draft = normalize_pool_draft(params)
    socket = assign(socket, :pool_draft, draft)

    with {:ok, pool} <- required_identifier(draft["pool"], "Enter a valid pool name."),
         {:ok, providers} <- parse_provider_list(draft["providers"]),
         {:ok, strategy} <- normalize_strategy(draft["strategy"]) do
      {:noreply,
       preview_change(socket, %{
         "action" => "pool.upsert",
         "pool" => pool,
         "providers" => providers,
         "strategy" => strategy,
         "activate" => draft["activate"]
       })}
    else
      {:error, message} -> {:noreply, reject_preview(socket, message)}
    end
  end

  def handle_event("preview-pool-activate", %{"pool" => pool_name}, socket) do
    with {:ok, pool_name} <- required_identifier(pool_name, "That pool is not available."),
         %{} = pool <- find_pool(socket.assigns.routing, pool_name) do
      {:noreply,
       preview_change(socket, %{
         "action" => "pool.upsert",
         "pool" => pool_name,
         "providers" => pool["providers"],
         "strategy" => pool["strategy"],
         "activate" => true
       })}
    else
      _ -> {:noreply, reject_preview(socket, "That pool is not available.")}
    end
  end

  def handle_event("preview-pool-delete", %{"pool" => pool}, socket) do
    pool = safe_draft_identifier(pool)

    if pool == "" or is_nil(find_pool(socket.assigns.routing, pool)) do
      {:noreply, reject_preview(socket, "That pool is not available.")}
    else
      {:noreply, preview_change(socket, %{"action" => "pool.delete", "pool" => pool})}
    end
  end

  def handle_event("preview-credential", %{"credential" => params}, socket) do
    draft = normalize_credential_draft(params)
    socket = assign(socket, :credential_draft, draft)

    with {:ok, pool} <- required_identifier(draft["pool"], "Choose a credential pool."),
         true <- not is_nil(find_pool(socket.assigns.routing, pool)),
         {:ok, provider} <- required_identifier(draft["provider"], "Enter a provider name."),
         {:ok, action} <- credential_action(draft["operation"]),
         {:ok, credential_ref} <- credential_ref(action, params["credential_ref"]) do
      change = %{"action" => action, "pool" => pool, "provider" => provider}

      change =
        if credential_ref, do: Map.put(change, "credentialRef", credential_ref), else: change

      {:noreply, preview_change(socket, change, credential_ref)}
    else
      false -> {:noreply, reject_preview(socket, "Choose an existing credential pool.")}
      {:error, message} -> {:noreply, reject_preview(socket, message)}
    end
  end

  def handle_event("cancel-preview", _params, socket) do
    {:noreply,
     socket
     |> assign(:pending_change, nil)
     |> assign(:notice, "Preview dismissed. Your non-secret drafts were kept.")
     |> assign(:error, nil)}
  end

  def handle_event("apply-preview", event_params, socket) do
    params = Map.get(event_params, "apply", %{})

    case socket.assigns.pending_change do
      nil ->
        {:noreply, assign(socket, :error, "Preview an exact provider change before applying it.")}

      pending ->
        apply_preview(socket, pending, params)
    end
  end

  # ── Render ──────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:visible_models, filter_models(assigns.models, assigns.catalog_filter))
      |> assign(:catalog_providers, assigns.models |> Enum.map(& &1.provider) |> Enum.uniq())

    ~H"""
    <.page>
      <.page_header
        title="Models"
        icon="cpu"
        subtitle="Model catalog, provider credentials and routing. Every change is previewed before it is written."
      >
        <:actions>
          <.button icon="refresh" phx-click="refresh" id="models-refresh">Refresh</.button>
        </:actions>
      </.page_header>

      <section aria-label="Model status" class="mb-5 grid grid-cols-2 gap-3 lg:grid-cols-4">
        <.stat label="Default model" icon="sparkles" value={default_label(@defaults)} hint={thinking_hint(@defaults)} />
        <.stat
          label="Providers ready"
          icon="key"
          value={providers_ready_label(@providers_state, @providers)}
          hint="Usable credentials"
        />
        <.stat label="Catalog" icon="layers" value={catalog_count_label(@models_state, @models)} hint="Models you can pick" />
        <.stat
          label="Routing"
          icon="network"
          value={"#{length(@routing["fallbackProviders"])} ordered"}
          hint={"#{@routing["credentialPoolCount"]} credential pool(s)"}
        />
      </section>

      <div id="provider-feedback" aria-live="polite" class="space-y-2 empty:hidden">
        <.callout :if={@notice} tone="success" class="mb-3">{@notice}</.callout>
        <.callout :if={@error} tone="danger" class="mb-3">{@error}</.callout>
      </div>

      <.pending_preview :if={@pending_change} pending={@pending_change} />

      <.tabs active={@tab} label="Models sections" class="mb-4">
        <:tab id="catalog" label="Catalog" icon="layers" patch={~p"/models?tab=catalog"} count={length(@models)} />
        <:tab id="providers" label="Providers" icon="key" patch={~p"/models?tab=providers"} count={length(@providers)} />
        <:tab id="routing" label="Routing" icon="network" patch={~p"/models?tab=routing"} />
      </.tabs>

      <.catalog
        :if={@tab == "catalog"}
        state={@models_state}
        models={@visible_models}
        total={length(@models)}
        filter={@catalog_filter}
        providers={@catalog_providers}
        defaults={@defaults}
      />
      <.provider_status :if={@tab == "providers"} state={@providers_state} providers={@providers} defaults={@defaults} />
      <.routing_panel
        :if={@tab == "routing"}
        routing={@routing}
        available={@routing_available?}
        fallback_draft={@fallback_draft}
        pool_draft={@pool_draft}
        credential_draft={@credential_draft}
      />
    </.page>
    """
  end

  attr(:pending, :map, required: true)

  defp pending_preview(assigns) do
    ~H"""
    <section
      id="provider-change-preview"
      aria-labelledby="preview-title"
      class="card mb-5 border-warning/40 shadow-pop animate-scale-in"
    >
      <div class="card-header">
        <div class="flex min-w-0 items-center gap-2">
          <.badge tone={if @pending.destructive, do: "danger", else: "warning"} icon="eye">Preview</.badge>
          <h2 id="preview-title" class="truncate text-[13px] font-semibold text-fg">{@pending.label}</h2>
        </div>
        <.badge :if={not @pending.changed} tone="neutral">Already configured</.badge>
      </div>
      <div class="card-body space-y-3">
        <p class="text-[13px] text-muted">{@pending.summary}</p>
        <.callout :if={@pending.destructive} tone="danger" title="Destructive change">
          Type <code class="font-mono text-fg">{@pending.confirmation}</code> exactly to apply.
        </.callout>
        <p :if={@pending.credential_required} class="text-xs text-muted">
          Re-enter the same credential reference. It was validated but never retained or rendered.
        </p>
        <.form
          for={to_form(%{"confirmation" => "", "credential_ref" => ""}, as: :apply)}
          id="provider-apply-form"
          phx-submit="apply-preview"
          class="grid gap-3 sm:grid-cols-2"
        >
          <.input
            :if={@pending.destructive}
            id="apply_confirmation"
            name="apply[confirmation]"
            label="Exact confirmation"
            autocomplete="off"
            maxlength="64"
            spellcheck="false"
          />
          <.input
            :if={@pending.credential_required}
            id="apply_credential_ref"
            name="apply[credential_ref]"
            type="password"
            label="Credential reference"
            autocomplete="new-password"
            spellcheck="false"
            maxlength="160"
            placeholder="secret:… or env:…"
          />
          <div class="flex flex-wrap items-center gap-2 sm:col-span-2">
            <.button
              type="submit"
              variant={if @pending.destructive, do: "danger", else: "primary"}
              icon="check"
              mutation
              disabled={not @pending.changed}
            >
              Apply exact change
            </.button>
            <.button variant="ghost" phx-click="cancel-preview">Keep draft, cancel preview</.button>
            <span class="text-xs text-subtle">Nothing is written until you apply.</span>
          </div>
        </.form>
      </div>
    </section>
    """
  end

  attr(:state, :atom, required: true)
  attr(:models, :list, required: true)
  attr(:total, :integer, required: true)
  attr(:filter, :map, required: true)
  attr(:providers, :list, required: true)
  attr(:defaults, :map, required: true)

  defp catalog(assigns) do
    assigns =
      assign(assigns,
        shown: Enum.take(assigns.models, @max_rendered_models),
        shown_limit: @max_rendered_models
      )

    ~H"""
    <section id="model-catalog" aria-label="Model catalog" class="space-y-3">
      <.form
        for={to_form(@filter, as: :catalog)}
        id="catalog-filter"
        phx-change="filter-catalog"
        phx-submit="filter-catalog"
        class="flex flex-wrap items-end gap-2"
      >
        <div class="relative min-w-[14rem] flex-1">
          <label for="catalog_q" class="sr-only">Search models</label>
          <.icon name="search" class="pointer-events-none absolute left-2.5 top-1/2 h-3.5 w-3.5 -translate-y-1/2 text-subtle" />
          <input
            id="catalog_q"
            name="catalog[q]"
            type="search"
            value={@filter["q"]}
            placeholder="Search models"
            autocomplete="off"
            phx-debounce="150"
            class="input pl-8"
          />
        </div>
        <.input
          type="select"
          id="catalog_provider"
          name="catalog[provider]"
          value={@filter["provider"]}
          prompt="All providers"
          options={@providers}
          class="w-44"
          input_class="h-8"
        />
        <div class="segmented" role="radiogroup" aria-label="Capability">
          <label
            :for={{value, label} <- [{"all", "All"}, {"thinking", "Thinking"}, {"vision", "Vision"}]}
            class={[
              "inline-flex h-7 cursor-pointer items-center rounded px-2.5 text-xs font-medium text-muted hover:text-fg has-[:checked]:bg-surface has-[:checked]:text-fg has-[:checked]:shadow-sm has-[:focus-visible]:ring-2 has-[:focus-visible]:ring-ring"
            ]}
          >
            <input type="radio" name="catalog[capability]" value={value} checked={@filter["capability"] == value} class="sr-only" />
            {label}
          </label>
        </div>
      </.form>

      <.callout :if={@state == :unavailable} tone="warning" title="Model catalog unavailable">
        The runtime could not list models right now. Provider and routing settings still work; refresh to retry.
      </.callout>

      <div :if={@state == :loading} class="card flex items-center gap-2 px-4 py-6 text-[13px] text-muted">
        <.spinner /> Loading the model catalog…
      </div>

      <.empty_state
        :if={@state == :ok and @total == 0}
        icon="cpu"
        title="No models available"
        description="Models appear once a provider has a usable credential. Run `lemon setup provider` to add one."
      />

      <div :if={@state == :ok and @total > 0} class="card overflow-hidden">
        <.table id="catalog-table" rows={@shown} row_id={&"model-#{dom_id(&1)}"} empty="No models match these filters.">
          <:col :let={model} label="Model">
            <div class="flex min-w-0 items-center gap-2">
              <div class="min-w-0">
                <p class="truncate font-medium text-fg">{model.name}</p>
                <p class="truncate font-mono text-2xs text-subtle">{model.id}</p>
              </div>
              <.badge :if={default_model?(model, @defaults)} tone="accent" icon="check">Default</.badge>
            </div>
          </:col>
          <:col :let={model} label="Provider"><.badge>{model.provider}</.badge></:col>
          <:col :let={model} label="Context" class="hidden text-right tabular-nums sm:table-cell">
            {format_tokens(model.context_window)}
          </:col>
          <:col :let={model} label="Max out" class="hidden text-right tabular-nums lg:table-cell">
            {format_tokens(model.max_output)}
          </:col>
          <:col :let={model} label="Capabilities" class="hidden md:table-cell">
            <div class="flex flex-wrap gap-1">
              <.badge :if={model.thinking} tone="plan" icon="brain">Thinking</.badge>
              <.badge :if={model.vision} tone="info" icon="image">Vision</.badge>
              <span :if={not model.thinking and not model.vision} class="text-subtle">Text</span>
            </div>
          </:col>
          <:col :let={model} label="Price / 1M in · out" class="hidden whitespace-nowrap text-right tabular-nums md:table-cell">
            <span :if={model.pricing} class="text-fg">{price(model.pricing.input)} · {price(model.pricing.output)}</span>
            <span :if={is_nil(model.pricing)} class="text-subtle">—</span>
          </:col>
          <:action :let={model}>
            <.button
              :if={not default_model?(model, @defaults)}
              size="sm"
              variant="ghost"
              phx-click="preview-default-model"
              phx-value-provider={model.provider}
              phx-value-model={model.id}
              aria-label={"Preview setting #{model.provider}:#{model.id} as the default model"}
            >
              Set default
            </.button>
          </:action>
        </.table>
        <p :if={length(@models) > @shown_limit} class="border-t border-line px-3 py-2 text-xs text-subtle">
          Showing {@shown_limit} of {length(@models)} matching models. Refine the search to see more.
        </p>
        <p :if={length(@models) <= @shown_limit and @total > 0} class="border-t border-line px-3 py-2 text-xs text-subtle">
          {length(@models)} of {@total} models
        </p>
      </div>
    </section>
    """
  end

  attr(:state, :atom, required: true)
  attr(:providers, :list, required: true)
  attr(:defaults, :map, required: true)

  defp provider_status(assigns) do
    ~H"""
    <section id="provider-status" aria-label="Provider credentials" class="space-y-3">
      <.callout tone="neutral" icon="shield-check">
        Credentials are added with <code class="font-mono text-fg">lemon setup provider</code>
        and stored in Lemon's encrypted secret store. This page only shows whether one is usable — never key, secret or environment variable names.
      </.callout>
      <.callout :if={@state == :unavailable} tone="warning" title="Provider status unavailable">
        Credential readiness could not be read. Refresh to retry.
      </.callout>
      <div :if={@state == :loading} class="card flex items-center gap-2 px-4 py-6 text-[13px] text-muted">
        <.spinner /> Checking provider credentials…
      </div>
      <div :if={@state == :ok} class="card overflow-hidden">
        <.table id="provider-table" rows={@providers} row_id={&"provider-#{&1.provider}"} empty="No providers configured.">
          <:col :let={provider} label="Provider">
            <div class="flex items-center gap-2">
              <span class="font-medium text-fg">{provider.provider}</span>
              <.badge :if={provider.provider == provider_key(@defaults["provider"])} tone="accent">Default</.badge>
            </div>
          </:col>
          <:col :let={provider} label="Credential">
            <span class="inline-flex items-center gap-1.5">
              <.status_dot tone={if provider.ready, do: "success", else: "neutral"} />
              {if provider.ready, do: "Ready", else: "Not set up"}
            </span>
          </:col>
          <:col :let={provider} label="Source" class="hidden sm:table-cell">
            <span class="text-muted">{credential_source(provider)}</span>
          </:col>
          <:col :let={provider} label="Config" class="hidden md:table-cell">
            <div class="flex flex-wrap gap-1">
              <.badge :if={provider.configured} tone="neutral">Configured</.badge>
              <.badge :if={provider.base_url} tone="info">Custom endpoint</.badge>
              <span :if={not provider.configured and not provider.base_url} class="text-subtle">Defaults</span>
            </div>
          </:col>
        </.table>
      </div>
    </section>
    """
  end

  attr(:routing, :map, required: true)
  attr(:available, :boolean, required: true)
  attr(:fallback_draft, :map, required: true)
  attr(:pool_draft, :map, required: true)
  attr(:credential_draft, :map, required: true)

  defp routing_panel(assigns) do
    ~H"""
    <section id="provider-routing" aria-label="Provider routing" class="space-y-4">
      <.callout :if={not @available} tone="warning" title="Routing unavailable">
        Provider routing status is temporarily unavailable.
      </.callout>
      <div class="flex flex-wrap items-center gap-2 text-xs text-muted">
        <.status_dot tone={if @available and @routing["enabled"], do: "success", else: "warning"} />
        Routing {routing_status_label(@available, @routing["enabled"])} · credential checks
        {if @routing["requireCredentials"], do: "required", else: "optional"}
      </div>

      <div class="grid gap-4 lg:grid-cols-2">
        <.card id="fallback-card">
          <:header>Ordered fallbacks</:header>
          <:actions>
            <.button
              size="sm"
              variant="danger-soft"
              phx-click="preview-fallback-clear"
              disabled={@routing["fallbackProviders"] == []}
            >
              Preview clear
            </.button>
          </:actions>
          <p class="mb-3 text-xs text-muted">Used in order after the primary provider fails. New providers append.</p>
          <ol id="fallback-list" class="mb-3 space-y-1.5">
            <li :if={@routing["fallbackProviders"] == []} class="rounded-md border border-dashed border-line px-3 py-3 text-center text-xs text-muted">
              No fallback providers configured.
            </li>
            <li
              :for={{provider, index} <- Enum.with_index(@routing["fallbackProviders"], 1)}
              class="flex items-center gap-2 rounded-md border border-line bg-surface-2/50 px-2.5 py-1.5"
            >
              <span class="flex h-5 w-5 items-center justify-center rounded bg-surface text-2xs font-semibold tabular-nums text-muted">
                {index}
              </span>
              <strong class="flex-1 text-[13px] font-medium">{provider}</strong>
              <.button
                size="sm"
                variant="ghost"
                icon="x"
                phx-click="preview-fallback-remove"
                phx-value-provider={provider}
                aria-label={"Preview removal of #{provider}"}
              >
                Preview remove
              </.button>
            </li>
          </ol>
          <.form for={to_form(@fallback_draft, as: :fallback)} id="fallback-add-form" phx-submit="preview-fallback-add" class="flex items-end gap-2">
            <.input
              id="fallback_provider"
              name="fallback[provider]"
              value={@fallback_draft["provider"]}
              label="Provider to append"
              maxlength="64"
              autocomplete="off"
              placeholder="anthropic"
              class="flex-1"
            />
            <.button type="submit" icon="plus">Preview add</.button>
          </.form>
        </.card>

        <.card id="pool-card">
          <:header>Credential pools</:header>
          <p class="mb-3 text-xs text-muted">Counts are visible; credential references and secret names are not.</p>
          <div id="credential-pool-list" class="mb-4 space-y-2">
            <p :if={@routing["credentialPools"] == []} class="rounded-md border border-dashed border-line px-3 py-3 text-center text-xs text-muted">
              No credential pools configured.
            </p>
            <article
              :for={pool <- @routing["credentialPools"]}
              id={"pool-#{pool["name"]}"}
              class="rounded-lg border border-line bg-surface-2/40 p-3"
            >
              <header class="flex items-start justify-between gap-2">
                <div class="min-w-0">
                  <h3 class="flex items-center gap-2 text-[13px] font-semibold text-fg">
                    {pool["name"]}
                    <.badge :if={@routing["defaultPool"] == pool["name"]} tone="success">Active</.badge>
                  </h3>
                  <p class="text-xs text-muted">
                    {strategy_label(pool["strategy"])} · {pool["credentialReferenceCount"]} opaque reference(s)
                  </p>
                </div>
                <div class="flex shrink-0 gap-1">
                  <.button
                    size="sm"
                    variant="ghost"
                    phx-click="preview-pool-activate"
                    phx-value-pool={pool["name"]}
                    disabled={@routing["defaultPool"] == pool["name"]}
                  >
                    Preview activate
                  </.button>
                  <.button size="sm" variant="danger-soft" phx-click="preview-pool-delete" phx-value-pool={pool["name"]}>
                    Preview delete
                  </.button>
                </div>
              </header>
              <p class="mt-2 font-mono text-xs text-fg">{Enum.join(pool["providers"], " → ")}</p>
              <dl :if={pool["credentialCounts"] != %{}} class="mt-2 flex flex-wrap gap-1.5">
                <div :for={{provider, count} <- pool["credentialCounts"]} class="badge badge-neutral">
                  <dt>{provider}</dt>
                  <dd class="tabular-nums">{count}</dd>
                </div>
              </dl>
            </article>
          </div>
          <.form for={to_form(@pool_draft, as: :pool)} id="pool-upsert-form" phx-submit="preview-pool-upsert" class="grid gap-3 sm:grid-cols-2">
            <.input id="pool_pool" name="pool[pool]" value={@pool_draft["pool"]} label="Pool name" maxlength="64" autocomplete="off" placeholder="primary" />
            <.input
              type="select"
              id="pool_strategy"
              name="pool[strategy]"
              label="Strategy"
              value={@pool_draft["strategy"]}
              options={[{"Priority", "priority"}, {"Round robin", "round_robin"}]}
            />
            <.input
              id="pool_providers"
              name="pool[providers]"
              value={@pool_draft["providers"]}
              label="Providers in order"
              maxlength="512"
              autocomplete="off"
              placeholder="openai, anthropic"
              class="sm:col-span-2"
            />
            <.input
              type="checkbox"
              id="pool_activate"
              name="pool[activate]"
              value={@pool_draft["activate"]}
              label="Make this the active credential pool"
              class="sm:col-span-2"
            />
            <div class="sm:col-span-2">
              <.button type="submit" icon="eye">Preview create or update</.button>
            </div>
          </.form>
        </.card>
      </div>

      <.card id="credential-card">
        <:header>Credential references</:header>
        <p class="mb-3 text-xs text-muted">
          Add, remove or clear pool references. Values are password-masked, never echoed and never kept after preview.
        </p>
        <.form
          for={to_form(@credential_draft, as: :credential)}
          id="credential-reference-form"
          phx-submit="preview-credential"
          class="grid gap-3 sm:grid-cols-2 lg:grid-cols-4"
        >
          <.input
            type="select"
            id="credential_pool"
            name="credential[pool]"
            label="Pool"
            value={@credential_draft["pool"]}
            prompt="Choose a pool"
            options={Enum.map(@routing["credentialPools"], & &1["name"])}
          />
          <.input
            id="credential_provider"
            name="credential[provider]"
            value={@credential_draft["provider"]}
            label="Provider"
            maxlength="64"
            autocomplete="off"
            placeholder="openai"
          />
          <.input
            type="select"
            id="credential_operation"
            name="credential[operation]"
            label="Operation"
            value={@credential_draft["operation"]}
            options={[{"Add one", "add"}, {"Remove one", "remove"}, {"Clear provider", "clear"}]}
          />
          <.input
            id="credential_credential_ref"
            name="credential[credential_ref]"
            type="password"
            label="Reference for add/remove"
            autocomplete="new-password"
            spellcheck="false"
            maxlength="160"
            placeholder="secret:… or env:…"
          />
          <div class="sm:col-span-2 lg:col-span-4">
            <.button type="submit" icon="eye">Preview credential change</.button>
          </div>
        </.form>
      </.card>
    </section>
    """
  end

  # ── Loading ─────────────────────────────────────────────────────────────

  defp load_models(socket) do
    socket
    |> assign(:models_state, :loading)
    |> start_async(:models, fn -> fetch_models() end)
  end

  defp load_providers(socket) do
    project_dir = ProviderConfig.project_dir()

    socket
    |> assign(:providers_state, :loading)
    |> start_async(:providers, fn -> fetch_providers(project_dir) end)
  end

  defp fetch_models do
    case Rpc.call("models.list", %{"discoverOpenAI" => false}) do
      {:ok, %{"models" => models}} when is_list(models) ->
        {:ok,
         models
         |> Enum.take(@max_catalog_models)
         |> Enum.flat_map(&sanitize_model/1)
         |> Enum.uniq_by(&{&1.provider, &1.id})
         |> Enum.sort_by(&{&1.provider, &1.name})}

      _ ->
        :error
    end
  end

  defp fetch_providers(project_dir) do
    fun = Application.get_env(:lemon_web, :provider_status_fun)

    snapshot =
      if is_function(fun, 0),
        do: fun.(),
        else: ProviderStatus.snapshot(%{"projectDir" => project_dir})

    case snapshot do
      %{"providers" => providers} when is_list(providers) ->
        {:ok,
         providers
         |> Enum.take(@max_status_providers)
         |> Enum.flat_map(&sanitize_provider_status/1)
         |> Enum.sort_by(&{not &1.ready, &1.provider})}

      _ ->
        :error
    end
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end

  defp sanitize_model(%{} = model) do
    with provider when is_binary(provider) <- safe_optional_identifier(model["provider"]),
         id when is_binary(id) <- safe_model_id(model["id"]) do
      [
        %{
          provider: provider,
          id: id,
          name: safe_name(model["name"]) || id,
          context_window: positive_integer(model["contextWindow"]),
          max_output: positive_integer(model["maxOutput"]),
          thinking: model["supportsThinking"] == true,
          vision: model["supportsVision"] == true,
          pricing: sanitize_pricing(model["pricing"])
        }
      ]
    else
      _ -> []
    end
  end

  defp sanitize_model(_model), do: []

  defp sanitize_pricing(%{} = pricing) do
    input = non_negative_number(pricing["inputPerMillion"])
    output = non_negative_number(pricing["outputPerMillion"])
    if input || output, do: %{input: input, output: output}
  end

  defp sanitize_pricing(_pricing), do: nil

  defp sanitize_provider_status(%{} = status) do
    case safe_optional_identifier(status["provider"]) do
      provider when is_binary(provider) ->
        config = if is_map(status["config"]), do: status["config"], else: %{}
        ambient = if is_map(status["ambient"]), do: status["ambient"], else: %{}

        [
          %{
            provider: provider,
            ready: status["credentialReady"] == true,
            configured: status["configured"] == true,
            api_key:
              config["apiKeyConfigured"] == true or config["apiKeySecretConfigured"] == true,
            oauth: config["oauthSecretConfigured"] == true or config["authSource"] == "oauth",
            env: ambient["envConfigured"] == true,
            base_url: config["baseUrlConfigured"] == true
          }
        ]

      _ ->
        []
    end
  end

  defp sanitize_provider_status(_status), do: []

  # ── Preview / apply ─────────────────────────────────────────────────────

  defp preview_change(socket, params, credential_ref \\ nil) do
    socket = assign(socket, notice: nil, error: nil, pending_change: nil)

    case ProviderConfig.configure(params) do
      {:ok, result} ->
        proposed = sanitize_routing(result["proposedRoutingConfig"])
        proposed_defaults = sanitize_defaults(result["proposedDefaults"])
        confirmation = sanitize_confirmation(get_in(result, ["confirmation", "value"]))

        pending = %{
          label: action_label(params),
          summary: preview_summary(params, proposed, socket.assigns.defaults, proposed_defaults),
          action: params["action"],
          params: Map.drop(params, ["credentialRef"]),
          credential_digest: credential_digest(credential_ref),
          credential_required: is_binary(credential_ref),
          config_revision: result["configRevision"],
          destructive: result["destructive"] == true,
          confirmation: confirmation,
          changed: result["changed"] == true
        }

        notice =
          if pending.changed,
            do: "Preview ready. No provider configuration was written.",
            else: "Preview complete. The requested state is already configured."

        assign(socket, pending_change: pending, notice: notice)

      {:error, code, _message} ->
        assign(socket, :error, provider_error(code))
    end
  end

  defp apply_preview(socket, pending, params) do
    confirmation = normalize_confirmation(params["confirmation"])
    credential_ref = normalize_credential_ref(params["credential_ref"])

    cond do
      pending.destructive and confirmation != pending.confirmation ->
        {:noreply,
         assign(
           socket,
           :error,
           "Exact confirmation did not match. Your draft and preview were kept."
         )}

      pending.credential_required and not credential_matches?(pending, credential_ref) ->
        {:noreply,
         assign(socket, :error, "Re-enter the same credential reference used for this preview.")}

      true ->
        change =
          pending.params
          |> Map.put("apply", true)
          |> Map.put("expectedRevision", pending.config_revision)
          |> maybe_put("confirm", if(pending.destructive, do: confirmation, else: nil))
          |> maybe_put(
            "credentialRef",
            if(pending.credential_required, do: credential_ref, else: nil)
          )

        case ProviderConfig.configure(change) do
          {:ok, result} ->
            {:noreply,
             socket
             |> assign(:routing, sanitize_routing(result["proposedRoutingConfig"]))
             |> assign(:routing_available?, true)
             |> assign(:defaults, sanitize_defaults(result["defaults"]))
             |> assign(:pending_change, nil)
             |> assign(:notice, applied_notice(pending.action))
             |> assign(:error, nil)}

          {:error, :stale_configuration, _message} ->
            {:noreply,
             socket
             |> assign(:pending_change, nil)
             |> assign(
               :error,
               "Provider configuration changed after preview. Your non-secret drafts were kept; preview again."
             )
             |> refresh_routing()}

          {:error, code, _message} ->
            {:noreply, assign(socket, :error, provider_error(code))}
        end
    end
  end

  defp applied_notice("defaults.model"),
    do: "Default model change applied and configuration reloaded. New sessions start on it."

  defp applied_notice(_action), do: "Provider routing change applied and configuration reloaded."

  defp refresh_routing(socket) do
    case ProviderConfig.snapshot() do
      {:ok, routing, defaults} ->
        assign(socket,
          routing: sanitize_routing(routing),
          routing_available?: true,
          defaults: sanitize_defaults(defaults)
        )

      {:error, _reason} ->
        socket
        |> assign(routing: @empty_routing, routing_available?: false)
        |> assign(
          :error,
          socket.assigns.error || "Provider routing status is temporarily unavailable."
        )
    end
  end

  # ── Sanitizing ──────────────────────────────────────────────────────────

  defp sanitize_routing(routing) when is_map(routing) do
    fallbacks = safe_identifier_list(routing["fallbackProviders"])

    pools =
      routing
      |> Map.get("credentialPools", [])
      |> List.wrap()
      |> Enum.flat_map(&sanitize_pool/1)
      |> Enum.sort_by(& &1["name"])

    %{
      "enabled" => routing["enabled"] != false,
      "requireCredentials" => routing["requireCredentials"] != false,
      "fallbackProviders" => fallbacks,
      "defaultPool" => safe_optional_identifier(routing["defaultPool"]),
      "defaultProfile" => safe_optional_identifier(routing["defaultProfile"]),
      "credentialPools" => pools,
      "credentialPoolCount" => length(pools),
      "credentialReferenceCount" =>
        pools |> Enum.map(& &1["credentialReferenceCount"]) |> Enum.sum()
    }
  end

  defp sanitize_routing(_routing), do: @empty_routing

  defp sanitize_defaults(%{} = defaults) do
    %{
      "provider" => safe_optional_identifier(defaults["provider"]),
      "model" => safe_model_id(defaults["model"]),
      "thinkingLevel" => safe_optional_identifier(defaults["thinkingLevel"])
    }
  end

  defp sanitize_defaults(_defaults), do: @empty_defaults

  defp sanitize_pool(pool) when is_map(pool) do
    case safe_optional_identifier(pool["name"]) do
      name when is_binary(name) ->
        counts =
          pool
          |> Map.get("credentialCounts", %{})
          |> Enum.flat_map(fn {provider, count} ->
            case {safe_optional_identifier(provider), safe_count(count)} do
              {provider, count} when is_binary(provider) -> [{provider, count}]
              _ -> []
            end
          end)
          |> Enum.sort()
          |> Map.new()

        [
          %{
            "name" => name,
            "providers" => safe_identifier_list(pool["providers"]),
            "strategy" =>
              if(pool["strategy"] == "round_robin", do: "round_robin", else: "priority"),
            "credentialCounts" => counts,
            "credentialReferenceCount" => counts |> Map.values() |> Enum.sum()
          }
        ]

      _ ->
        []
    end
  end

  defp sanitize_pool(_pool), do: []

  defp safe_identifier_list(values) do
    values
    |> List.wrap()
    |> Enum.map(&safe_optional_identifier/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.take(@max_provider_count)
  end

  defp safe_optional_identifier(value) when is_binary(value) do
    value = value |> String.trim() |> String.downcase()
    if Regex.match?(@safe_identifier, value), do: value, else: nil
  end

  defp safe_optional_identifier(_value), do: nil

  defp safe_model_id(value) when is_binary(value) do
    value = String.trim(value)
    if Regex.match?(@model_id, value), do: value, else: nil
  end

  defp safe_model_id(_value), do: nil

  defp safe_name(value) when is_binary(value) do
    value = value |> String.trim() |> String.slice(0, 96)
    if value != "" and String.printable?(value), do: value
  end

  defp safe_name(_value), do: nil

  defp safe_draft_identifier(value), do: safe_optional_identifier(value) || ""

  defp required_identifier(value, message) do
    case safe_optional_identifier(value) do
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, message}
    end
  end

  defp normalize_pool_draft(params) do
    providers = params |> Map.get("providers", "") |> to_string() |> String.slice(0, 512)

    %{
      "pool" => safe_draft_identifier(params["pool"]),
      "providers" => safe_provider_draft(providers),
      "strategy" => if(params["strategy"] == "round_robin", do: "round_robin", else: "priority"),
      "activate" => params["activate"] in [true, "true", "1", "on"]
    }
  end

  defp safe_provider_draft(value) do
    values = value |> String.split(",") |> Enum.map(&String.trim/1)

    if Enum.all?(values, &(&1 == "" or not is_nil(safe_optional_identifier(&1)))),
      do: Enum.join(values, ", "),
      else: ""
  end

  defp parse_provider_list(value) do
    providers =
      value
      |> String.split(",")
      |> Enum.map(&safe_optional_identifier/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    cond do
      providers == [] -> {:error, "Enter at least one known provider."}
      length(providers) > @max_provider_count -> {:error, "Use at most 16 providers in one pool."}
      true -> {:ok, providers}
    end
  end

  defp normalize_strategy(value) when value in ["priority", "round_robin"], do: {:ok, value}
  defp normalize_strategy(_value), do: {:error, "Choose priority or round robin."}

  defp normalize_credential_draft(params) do
    %{
      "pool" => safe_draft_identifier(params["pool"]),
      "provider" => safe_draft_identifier(params["provider"]),
      "operation" =>
        if(params["operation"] in ["add", "remove", "clear"],
          do: params["operation"],
          else: "add"
        )
    }
  end

  defp credential_action("add"), do: {:ok, "pool.credential.add"}
  defp credential_action("remove"), do: {:ok, "pool.credential.remove"}
  defp credential_action("clear"), do: {:ok, "pool.credential.clear"}
  defp credential_action(_operation), do: {:error, "Choose a supported credential operation."}

  defp credential_ref("pool.credential.clear", _value), do: {:ok, nil}

  defp credential_ref(_action, value) do
    case normalize_credential_ref(value) do
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, "Enter a secret: or env: credential reference."}
    end
  end

  defp normalize_credential_ref(value) when is_binary(value) do
    value = String.trim(value)

    if byte_size(value) <= 160 and
         (Regex.match?(~r/^secret:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$/, value) or
            Regex.match?(~r/^env:[A-Za-z_][A-Za-z0-9_]{0,127}$/, value)),
       do: value,
       else: nil
  end

  defp normalize_credential_ref(_value), do: nil

  defp credential_digest(nil), do: nil
  defp credential_digest(value), do: :crypto.hash(:sha256, value)

  defp credential_matches?(%{credential_digest: expected}, value)
       when is_binary(expected) and is_binary(value) do
    actual = credential_digest(value)
    byte_size(expected) == byte_size(actual) and :crypto.hash_equals(expected, actual)
  rescue
    _ -> false
  end

  defp credential_matches?(_pending, _value), do: false

  defp sanitize_confirmation(value), do: safe_optional_identifier(value) || "clear"
  defp normalize_confirmation(value), do: safe_optional_identifier(value) || ""

  defp find_pool(routing, name), do: Enum.find(routing["credentialPools"], &(&1["name"] == name))

  defp safe_count(value) when is_integer(value) and value >= 0, do: min(value, 10_000)
  defp safe_count(_value), do: 0

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value), do: nil

  defp non_negative_number(value) when is_number(value) and value >= 0, do: value
  defp non_negative_number(_value), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp reject_preview(socket, message),
    do: assign(socket, pending_change: nil, notice: nil, error: message)

  defp provider_error(:confirmation_required),
    do: "Exact confirmation was refused. Your draft and preview were kept."

  defp provider_error(:stale_configuration),
    do: "Provider configuration changed after preview. Preview the draft again."

  defp provider_error(code)
       when code in [
              :invalid_action,
              :invalid_credential_reference,
              :invalid_model,
              :invalid_name,
              :invalid_provider,
              :invalid_providers,
              :invalid_revision,
              :invalid_scope,
              :invalid_strategy,
              :invalid_thinking_level,
              :missing_parameter
            ],
       do: "The provider change is not valid. Review the fields and preview again."

  defp provider_error(:invalid_config),
    do: "The current Lemon configuration is not valid, so no provider change was written."

  defp provider_error(_code), do: "Provider configuration is temporarily unavailable."

  # ── Labels / formatting ─────────────────────────────────────────────────

  defp action_label(%{"action" => "defaults.model", "provider" => provider, "model" => model}),
    do: "Set default model to #{provider}:#{model}"

  defp action_label(%{"action" => "fallback.add", "provider" => provider}),
    do: "Append fallback #{provider}"

  defp action_label(%{"action" => "fallback.remove", "provider" => provider}),
    do: "Remove fallback #{provider}"

  defp action_label(%{"action" => "fallback.clear"}), do: "Clear every fallback provider"

  defp action_label(%{"action" => "pool.upsert", "pool" => pool}),
    do: "Create or update pool #{pool}"

  defp action_label(%{"action" => "pool.delete", "pool" => pool}), do: "Delete pool #{pool}"

  defp action_label(%{"action" => action, "pool" => pool, "provider" => provider})
       when action in ["pool.credential.add", "pool.credential.remove", "pool.credential.clear"],
       do: "Update credential-reference count for #{pool} / #{provider}"

  defp action_label(_params), do: "Provider routing change"

  defp preview_summary(%{"action" => "defaults.model"}, _routing, current, proposed) do
    "New sessions default to #{default_label(proposed)} (currently #{default_label(current)}). " <>
      "Existing sessions keep their model."
  end

  defp preview_summary(_params, routing, _current, _proposed) do
    "Result: #{length(routing["fallbackProviders"])} fallback(s), " <>
      "#{routing["credentialPoolCount"]} pool(s), " <>
      "#{routing["credentialReferenceCount"]} opaque credential reference(s)."
  end

  defp default_label(%{"model" => model, "provider" => provider}) when is_binary(model) do
    cond do
      String.contains?(model, ":") -> model
      is_binary(provider) -> "#{provider}:#{model}"
      true -> model
    end
  end

  defp default_label(_defaults), do: "Not set"

  defp thinking_hint(%{"thinkingLevel" => level}) when is_binary(level), do: "Thinking: #{level}"
  defp thinking_hint(_defaults), do: "For new sessions"

  defp default_model?(model, defaults) do
    default_label(defaults) == "#{model.provider}:#{model.id}"
  end

  defp provider_key(nil), do: nil
  defp provider_key(provider), do: provider

  defp providers_ready_label(:ok, providers),
    do: "#{Enum.count(providers, & &1.ready)} of #{length(providers)}"

  defp providers_ready_label(:loading, _providers), do: "…"
  defp providers_ready_label(_state, _providers), do: "Unavailable"

  defp catalog_count_label(:ok, models), do: "#{length(models)} models"
  defp catalog_count_label(:loading, _models), do: "…"
  defp catalog_count_label(_state, _models), do: "Unavailable"

  defp credential_source(provider) do
    [
      provider.api_key && "API key",
      provider.oauth && "OAuth",
      provider.env && "Environment"
    ]
    |> Enum.filter(& &1)
    |> case do
      [] -> "—"
      sources -> Enum.join(sources, " · ")
    end
  end

  defp filter_models(models, filter) do
    query = filter["q"] |> String.trim() |> String.downcase()

    Enum.filter(models, fn model ->
      (query == "" or
         String.contains?(String.downcase(model.id), query) or
         String.contains?(String.downcase(model.name), query) or
         String.contains?(model.provider, query)) and
        (filter["provider"] in ["", nil] or model.provider == filter["provider"]) and
        case filter["capability"] do
          "thinking" -> model.thinking
          "vision" -> model.vision
          _ -> true
        end
    end)
  end

  defp dom_id(model) do
    :crypto.hash(:sha256, "#{model.provider}:#{model.id}")
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 12)
  end

  defp format_tokens(nil), do: "—"
  defp format_tokens(value), do: compact_number(value)

  defp price(nil), do: "—"
  defp price(value) when value < 0.1, do: "$" <> :erlang.float_to_binary(value * 1.0, decimals: 3)
  defp price(value), do: "$" <> :erlang.float_to_binary(value * 1.0, decimals: 2)

  defp strategy_label("round_robin"), do: "Round robin"
  defp strategy_label(_strategy), do: "Priority"

  defp routing_status_label(false, _enabled), do: "unavailable"
  defp routing_status_label(true, true), do: "enabled"
  defp routing_status_label(true, false), do: "disabled"
end
