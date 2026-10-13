defmodule LemonWeb.Live.Components.SubagentTreeComponent do
  @moduledoc false
  use Phoenix.Component

  attr(:tree, :map, required: true)

  def tree(assigns) do
    ~H"""
    <section id="subagent-tree" aria-labelledby="subagent-tree-title" class="mt-4 rounded-2xl border border-slate-200 bg-white p-4 shadow-sm">
      <div class="flex flex-wrap items-center justify-between gap-2">
        <h2 id="subagent-tree-title" class="text-sm font-semibold text-slate-900">Subagents</h2>
        <span :if={@tree.status == :available} id="subagent-tree-count" class="text-xs text-slate-500">
          {length(@tree.nodes)} shown · {@tree.active_count} active
        </span>
      </div>
      <p :if={@tree.status == :unavailable} id="subagent-tree-unavailable" role="status" class="mt-2 text-sm text-amber-800">
        Subagent status unavailable. Lemon will check again automatically.
      </p>
      <p :if={@tree.status == :available and @tree.nodes == []} id="subagent-tree-empty" class="mt-2 text-sm text-slate-500">
        No linked subagents for this session's selected run.
      </p>
      <ol :if={@tree.nodes != []} class="mt-3 max-h-64 space-y-2 overflow-y-auto" aria-label="Subagent relationships">
        <li :for={node <- @tree.nodes} id={node.dom_id} data-depth={node.depth} data-parent-id={node.parent_id} data-status={node.status}
          class="rounded-lg border-l-2 border-slate-200 bg-slate-50 p-3" style={"margin-left: #{min(node.depth, 4) * 8}px"}>
          <div class="flex flex-wrap items-center justify-between gap-2">
            <span class="text-xs font-semibold text-slate-800">{node.label}</span>
            <span class={status_class(node.status)}>{String.replace(node.status, "_", " ")}</span>
          </div>
          <p class="mt-1 break-all font-mono text-xs text-slate-600">{node.id}</p>
          <p :if={node.parent_id} class="mt-1 break-all text-xs text-slate-500">↳ Child of {node.parent_id}</p>
          <div class="mt-2 flex flex-wrap items-center gap-3 text-xs text-slate-500">
            <span>{node.event_count} recent updates</span>
            <span :if={node.tools != []}>Tools: {Enum.join(node.tools, ", ")}</span>
            <.link :if={node.session_path} href={node.session_path} class="font-medium text-slate-700 underline">Open child session</.link>
          </div>
        </li>
      </ol>
      <p :if={@tree.truncated?} id="subagent-tree-truncated" class="mt-3 text-xs text-slate-500">
        Showing at most 50 subagents across eight levels. Additional descendants are omitted.
      </p>
    </section>
    """
  end

  defp status_class(status) when status in ["running", "queued"],
    do: "rounded-full bg-amber-50 px-2 py-1 text-xs font-medium text-amber-800"

  defp status_class("completed"),
    do: "rounded-full bg-emerald-50 px-2 py-1 text-xs font-medium text-emerald-800"

  defp status_class(_),
    do: "rounded-full bg-slate-200 px-2 py-1 text-xs font-medium text-slate-700"
end
