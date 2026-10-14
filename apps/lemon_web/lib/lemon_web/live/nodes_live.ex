defmodule LemonWeb.NodesLive do
  @moduledoc """
  Nodes: paired execution nodes (live presence, last seen, capabilities,
  session state), pending pairing requests with approve, pairing instructions
  and credential revocation.

  Reads use `nodes.list`; pairing events arrive on the `nodes` bus topic and
  presence is re-read every few seconds. Approve calls `node.pair.approve` and
  discards the credentials it returns (they belong to the joining node).
  Revoke is preview → typed confirmation: the dialog binds the node ID taken
  from the server-side list and `nodes.revoke` re-checks the typed name against
  the durable record.
  """

  use LemonWeb, :live_view

  import LemonWeb.KnowledgeComponents

  alias LemonWeb.Rpc

  @poll_ms 5_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      LemonCore.Bus.subscribe("nodes")
      Process.send_after(self(), :poll, @poll_ms)
    end

    {:ok,
     socket
     |> assign(
       nav: :nodes,
       page_title: "Nodes · Lemon",
       query: "",
       revoke: nil,
       approving: nil
     )
     |> load()}
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket),
    do: {:noreply, assign(socket, query: String.slice(q, 0, 200))}

  def handle_event("reload", _params, socket), do: {:noreply, load(socket)}

  def handle_event("approve", %{"id" => id}, socket) do
    if Enum.any?(socket.assigns.pairings, &(&1["pairingId"] == id)) do
      # The response carries the node's challenge/session credentials; they are
      # intentionally dropped here and never reach assigns or HTML.
      case Rpc.call("node.pair.approve", %{"pairingId" => id}) do
        {:ok, _credentials} ->
          {:noreply,
           socket
           |> load()
           |> put_flash(:info, "Pairing approved. The node finishes joining on its next attempt.")}

        {:error, error} ->
          {:noreply, socket |> load() |> put_flash(:error, Rpc.message(error))}
      end
    else
      {:noreply,
       socket |> load() |> put_flash(:error, "That pairing request is no longer pending.")}
    end
  end

  def handle_event("revoke_preview", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.nodes, &(&1["id"] == id)) do
      %{"name" => name} = node when is_binary(name) and name != "" ->
        {:noreply,
         assign(socket, revoke: %{id: node["id"], name: name, online: node["status"] == "online"})}

      _ ->
        {:noreply, put_flash(socket, :error, "That node is no longer paired.")}
    end
  end

  def handle_event("revoke_cancel", _params, socket), do: {:noreply, assign(socket, revoke: nil)}

  def handle_event(
        "revoke_confirm",
        %{"confirmation" => typed},
        %{assigns: %{revoke: %{} = preview}} = socket
      ) do
    if typed != preview.name do
      {:noreply, put_flash(socket, :error, "Type the exact node name to confirm.")}
    else
      case Rpc.call("nodes.revoke", %{"nodeId" => preview.id, "confirmName" => typed}) do
        {:ok, _} ->
          {:noreply,
           socket
           |> assign(revoke: nil)
           |> load()
           |> put_flash(:info, "Revoked #{preview.name}. It must pair again to reconnect.")}

        {:error, error} ->
          {:noreply,
           socket |> assign(revoke: nil) |> load() |> put_flash(:error, Rpc.message(error))}
      end
    end
  end

  def handle_event("revoke_confirm", _params, socket), do: {:noreply, assign(socket, revoke: nil)}

  @impl true
  def handle_info(:poll, socket) do
    Process.send_after(self(), :poll, @poll_ms)
    {:noreply, load(socket)}
  end

  def handle_info(%LemonCore.Event{type: type}, socket)
      when type in [:node_pair_requested, :node_pair_resolved],
      do: {:noreply, load(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  defp load(socket) do
    case Rpc.call("nodes.list", %{}) do
      {:ok, %{"nodes" => nodes, "pairings" => pairings} = payload} ->
        assign(socket,
          error: nil,
          nodes: List.wrap(nodes),
          pairings: List.wrap(pairings),
          summary: payload["summary"] || %{},
          now: System.system_time(:millisecond)
        )

      {:ok, _} ->
        assign(socket,
          error: "Unexpected response from the node registry.",
          nodes: [],
          pairings: [],
          summary: %{},
          now: 0
        )

      {:error, error} ->
        assign(socket, error: Rpc.message(error), nodes: [], pairings: [], summary: %{}, now: 0)
    end
  end

  # ── View helpers ─────────────────────────────────────────────────────────

  defp visible(nodes, query) do
    q = String.downcase(String.trim(query))

    if q == "",
      do: nodes,
      else:
        Enum.filter(nodes, fn node ->
          Enum.any?([node["name"], node["type"], node["id"] | node["capabilities"] || []], fn v ->
            is_binary(v) and String.contains?(String.downcase(v), q)
          end)
        end)
  end

  defp status_tone("online"), do: "success"
  defp status_tone("offline"), do: "neutral"
  defp status_tone(_), do: "warning"

  defp session_badge(assigns) do
    {tone, label} =
      case assigns.session do
        "active" -> {"success", "Session active"}
        "expired" -> {"warning", "Session expired"}
        "revoked" -> {"danger", "Revoked"}
        "none" -> {"neutral", "No session"}
        _ -> {"neutral", "Unknown"}
      end

    assigns = assign(assigns, tone: tone, label: label)

    ~H"""
    <.badge tone={@tone}>{@label}</.badge>
    """
  end

  defp expires_in(ms, now) when is_integer(ms) and is_integer(now) do
    seconds = max(div(ms - now, 1000), 0)
    if seconds >= 60, do: "#{div(seconds, 60)}m #{rem(seconds, 60)}s", else: "#{seconds}s"
  end

  defp expires_in(_ms, _now), do: "—"

  # ── Render ───────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    assigns = assign(assigns, shown: visible(assigns.nodes, assigns.query))

    ~H"""
    <.page>
      <.page_header title="Nodes" icon="server" subtitle="Machines that run delegated agent work for this runtime.">
        <:meta :if={@error == nil}>
          <.badge tone="success">{@summary["online"] || 0} online</.badge>
          <.badge>{@summary["count"] || 0} paired</.badge>
          <.badge :if={(@summary["pending"] || 0) > 0} tone="warning">{@summary["pending"]} pending</.badge>
        </:meta>
        <:actions>
          <.button size="sm" icon="refresh" phx-click="reload">Refresh</.button>
        </:actions>
      </.page_header>

      <.callout :if={@error} tone="danger" title="Nodes are unavailable" class="mb-4">
        {@error}
        <:actions><.button size="sm" phx-click="reload">Retry</.button></:actions>
      </.callout>

      <.callout :if={@error == nil and @summary["presenceAvailable"] == false} tone="warning" class="mb-4">
        Live presence is unavailable, so online state is unknown.
      </.callout>

      <section :if={@pairings != []} aria-labelledby="pairings-heading" class="mb-6">
        <h2 id="pairings-heading" class="mb-2 text-[13px] font-semibold text-fg">Pending pairing requests</h2>
        <ul role="list" class="grid gap-2 md:grid-cols-2">
          <li :for={pairing <- @pairings} id={"pairing-#{pairing["pairingId"]}"} class="card flex items-center gap-4 p-3">
            <div class="min-w-0 flex-1">
              <p class="truncate text-[13px] font-medium text-fg">
                {pairing["nodeName"] || "Unnamed node"}
                <span :if={pairing["recovery"]} class="ml-1 align-middle"><.badge tone="info">re-pair</.badge></span>
              </p>
              <p class="text-xs text-muted">
                {pairing["nodeType"] || "generic"} · expires in {expires_in(pairing["expiresAtMs"], @now)}
              </p>
            </div>
            <div class="text-right">
              <p class="text-2xs uppercase tracking-wide text-subtle">Code</p>
              <p class="font-mono text-base font-semibold tracking-[0.2em] text-fg">{pairing["code"]}</p>
            </div>
            <.button
              size="sm"
              variant="primary"
              icon="check"
              mutation
              phx-click="approve"
              phx-value-id={pairing["pairingId"]}
              aria-label={"Approve pairing for #{pairing["nodeName"]}"}
            >
              Approve
            </.button>
          </li>
        </ul>
        <p class="mt-2 text-xs text-subtle">
          Approve only if the code matches the one printed by the joining node.
        </p>
      </section>

      <div :if={@error == nil and @nodes == []} class="space-y-4">
        <.empty_state
          icon="server"
          title="No execution nodes paired"
          description="Pair another machine to let agents run work there with the agent tool's node parameter."
        />
      </div>

      <div :if={@nodes != []} class="mb-6">
        <div class="mb-3 flex flex-wrap items-center gap-2">
          <.search_field
            id="nodes-search"
            event="search"
            value={@query}
            placeholder="Search nodes"
            label="Search nodes"
            class="w-full sm:w-72"
          />
          <span class="ml-auto text-xs text-subtle">Presence refreshes every 5s</span>
        </div>

        <div class="card overflow-hidden">
          <ul id="nodes-list" role="list" class="divide-y divide-line">
            <li :if={@shown == []} class="px-4 py-8 text-center text-[13px] text-muted">No nodes match.</li>
            <li :for={node <- @shown} id={"node-#{node["id"]}"} class="flex flex-wrap items-center gap-x-4 gap-y-2 px-4 py-3">
              <div class="flex min-w-0 flex-1 basis-full items-center gap-3 sm:basis-0">
                <span class="flex h-8 w-8 shrink-0 items-center justify-center rounded-md border border-line bg-surface-2 text-muted">
                  <.icon name="server" class="h-4 w-4" />
                </span>
                <div class="min-w-0">
                  <p class="flex items-center gap-2">
                    <.status_dot tone={status_tone(node["status"])} pulse={node["status"] == "online"} />
                    <span class="truncate text-[13px] font-medium text-fg">{node["name"] || "Unnamed"}</span>
                    <span class="text-xs text-subtle">{node["type"]}</span>
                  </p>
                  <p class="mt-0.5 text-xs text-muted">
                    <span :if={node["status"] == "online"}>
                      Connected <.time_ago ms={node["connectedAtMs"]} />
                    </span>
                    <span :if={node["status"] != "online"}>
                      {String.capitalize(node["status"] || "unknown")} · last seen <.time_ago ms={node["lastSeenMs"]} />
                    </span>
                  </p>
                </div>
              </div>
              <div class="hidden min-w-0 lg:block lg:max-w-xs">
                <.chips items={node["capabilities"] || []} max={3} empty="No capabilities" />
              </div>
              <.session_badge session={node["session"]} />
              <.button
                size="sm"
                variant="danger-soft"
                icon="key"
                mutation
                disabled={node["session"] == "revoked"}
                phx-click="revoke_preview"
                phx-value-id={node["id"]}
                aria-label={"Revoke #{node["name"]}"}
              >
                Revoke
              </.button>
            </li>
          </ul>
        </div>
      </div>

      <.card id="pairing-instructions">
        <:header>Pair a node</:header>
        <div class="space-y-3 text-[13px] text-fg">
          <p>
            On the machine that should run work, start a node with pairing authority from an operator token.
            It requests pairing, approves with that authority and stores its own session credential.
          </p>
          <.code_block
            id="node-join-example"
            language="bash"
            code={"LEMON_NODE_OPERATOR_TOKEN=… lemon node join \\\n  --name worker-1 \\\n  --controller wss://<this-host>/ws \\\n  --pair \\\n  --cwd /srv/project"}
          />
          <ul class="list-disc space-y-1 pl-4 text-xs text-muted">
            <li>Later starts omit <code class="font-mono">--pair</code>. Re-run with it after the 7-day session expires or after a revoke.</li>
            <li>Non-loopback controllers require <code class="font-mono">wss://</code>.</li>
            <li>Route work with the agent tool's <code class="font-mono">node</code> parameter, e.g. <code class="font-mono">"node": "worker-1"</code>.</li>
          </ul>
        </div>
      </.card>

      <.confirm_dialog
        :if={@revoke}
        id="revoke-node"
        title={"Revoke #{@revoke.name}?"}
        description="Invalidates every session credential of this node."
        confirm_label="Revoke node"
        confirm_event="revoke_confirm"
        cancel_event="revoke_cancel"
        confirm_text={@revoke.name}
      >
        <ul class="list-disc space-y-1 pl-4 text-[13px]">
          <li :if={@revoke.online}>Its live connection closes now and in-flight work on it is cancelled.</li>
          <li>It cannot reconnect until it pairs again with operator authority.</li>
          <li>Its identity and name are kept, so re-pairing restores the same node.</li>
        </ul>
      </.confirm_dialog>
    </.page>
    """
  end
end
