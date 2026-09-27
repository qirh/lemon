defmodule LemonWeb.Live.Components.ApprovalComponent do
  @moduledoc false

  use Phoenix.Component

  alias LemonWeb.Live.Components.Payload

  # Same choices, in the same order, as the TUI approval panel. Each value is
  # the `LemonCore.ExecApprovals.resolve/2` decision it maps to.
  @decisions [
    {"approve_once", "Approve once", :primary},
    {"approve_session", "Approve for this session", :secondary},
    {"approve_global", "Always approve", :secondary},
    {"deny", "Deny", :danger}
  ]

  @doc "Parse a browser decision into the `ExecApprovals.resolve/2` decision atom."
  @spec decision(term()) :: {:ok, atom()} | :error
  def decision("approve_once"), do: {:ok, :approve_once}
  def decision("approve_session"), do: {:ok, :approve_session}
  def decision("approve_global"), do: {:ok, :approve_global}
  def decision("deny"), do: {:ok, :deny}
  def decision(_value), do: :error

  @doc """
  Build the display record for one pending approval (`LemonCore.Events.ApprovalPending`
  or its map form). Credential-looking action fields are masked.
  """
  @spec view(map()) :: map()
  def view(pending) when is_map(pending) do
    action = Payload.fetch(pending, :action)

    %{
      id: Payload.fetch(pending, :id),
      tool: Payload.fetch(pending, :tool) || "tool",
      action: action_summary(action),
      rationale: Payload.format(Payload.fetch(pending, :rationale)),
      requested_at_ms: Payload.fetch(pending, :requested_at_ms) || 0
    }
  end

  attr(:approvals, :list, required: true)
  attr(:notice, :string, default: nil)

  def panel(assigns) do
    assigns = assign(assigns, :decisions, @decisions)

    ~H"""
    <section
      :if={@approvals != [] or is_binary(@notice)}
      id="approval-panel"
      aria-labelledby="approval-panel-title"
      class="mt-4 rounded-2xl border border-amber-300 bg-amber-50 p-3 shadow-sm sm:p-4"
    >
      <h2 id="approval-panel-title" class="text-sm font-semibold text-amber-950">
        {if @approvals == [], do: "Approvals", else: "Lemon is waiting for your approval"}
      </h2>
      <p
        :if={is_binary(@notice)}
        id="approval-notice"
        role="status"
        aria-live="polite"
        class="mt-1 text-xs text-amber-900"
      >
        {@notice}
      </p>
      <article
        :for={approval <- @approvals}
        id={"approval-#{approval.id}"}
        class="mt-3 rounded-xl border border-amber-200 bg-white p-3"
      >
        <p class="text-sm text-slate-900">
          Run <code class="rounded bg-slate-100 px-1 py-0.5 font-mono text-xs">{approval.tool}</code>
        </p>
        <pre
          :if={approval.action}
          class="mt-2 max-h-48 overflow-auto whitespace-pre-wrap break-words rounded-lg bg-slate-900 p-2 font-mono text-xs text-slate-100"
        >{approval.action}</pre>
        <p :if={approval.rationale} class="mt-2 text-xs text-slate-600">
          Why: {approval.rationale}
        </p>
        <div class="mt-3 flex flex-wrap gap-2">
          <button
            :for={{value, label, tone} <- @decisions}
            type="button"
            phx-click="resolve-approval"
            phx-value-id={approval.id}
            phx-value-decision={value}
            class={decision_class(tone)}
          >
            {label}
          </button>
        </div>
      </article>
    </section>
    """
  end

  defp action_summary(action) when is_map(action) do
    case command(action) do
      command when is_binary(command) and command != "" -> command
      _ -> action |> Payload.redact() |> Payload.format()
    end
  end

  defp action_summary(action), do: Payload.format(action)

  defp command(action) do
    Enum.find_value([:command, :cmd], fn key ->
      case Payload.fetch(action, key) do
        value when is_binary(value) -> value
        _ -> nil
      end
    end)
  end

  defp decision_class(:primary),
    do:
      "rounded-lg bg-slate-900 px-3 py-1.5 text-xs font-medium text-white transition hover:bg-slate-700 focus:outline-none focus:ring"

  defp decision_class(:secondary),
    do:
      "rounded-lg border border-slate-300 bg-white px-3 py-1.5 text-xs font-medium text-slate-800 transition hover:bg-slate-50 focus:outline-none focus:ring"

  defp decision_class(:danger),
    do:
      "rounded-lg border border-rose-300 bg-white px-3 py-1.5 text-xs font-medium text-rose-700 transition hover:bg-rose-50 focus:outline-none focus:ring"
end
