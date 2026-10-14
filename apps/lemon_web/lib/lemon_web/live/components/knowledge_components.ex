defmodule LemonWeb.KnowledgeComponents do
  @moduledoc """
  Small presentational pieces shared by the Skills, MCP and Nodes pages.
  Everything renders through `LemonWeb.UI` tokens; nothing here holds state.
  """

  use Phoenix.Component

  import LemonWeb.UI

  @doc """
  Search field wired to the `/` shortcut (`SearchShortcut` hook): `/` focuses
  it from anywhere on the page, Esc blurs it. Emits `event` on change.
  """
  attr(:id, :string, required: true)
  attr(:value, :string, default: "")
  attr(:event, :string, required: true)
  attr(:placeholder, :string, default: "Search")
  attr(:label, :string, default: "Search")
  attr(:class, :any, default: nil)

  def search_field(assigns) do
    ~H"""
    <form
      id={"#{@id}-form"}
      phx-change={@event}
      phx-submit={@event}
      role="search"
      class={["relative min-w-0", @class]}
    >
      <label for={@id} class="sr-only">{@label}</label>
      <.icon
        name="search"
        class="pointer-events-none absolute left-2.5 top-1/2 h-3.5 w-3.5 -translate-y-1/2 text-subtle"
      />
      <input
        id={@id}
        name="q"
        type="search"
        value={@value}
        placeholder={@placeholder}
        autocomplete="off"
        spellcheck="false"
        phx-debounce="120"
        phx-hook="SearchShortcut"
        class="input h-8 pl-8 pr-9"
      />
      <.kbd keys="/" class="pointer-events-none absolute right-2 top-1/2 -translate-y-1/2" />
    </form>
    """
  end

  @doc "Segmented single-choice filter emitting `event` with `phx-value-value`."
  attr(:event, :string, required: true)
  attr(:value, :string, required: true)
  attr(:label, :string, required: true)
  attr(:options, :list, required: true, doc: "[{value, label, count | nil}]")

  def segmented_filter(assigns) do
    ~H"""
    <div class="segmented max-w-full overflow-x-auto" role="group" aria-label={@label}>
      <button
        :for={{value, label, count} <- @options}
        type="button"
        phx-click={@event}
        phx-value-value={value}
        aria-pressed={to_string(value == @value)}
      >
        {label}<span :if={count} class="tabular-nums text-subtle">{count}</span>
      </button>
    </div>
    """
  end

  @doc "Small labelled list of name chips (capabilities, missing requirements)."
  attr(:items, :list, required: true)
  attr(:tone, :string, default: "neutral")
  attr(:max, :integer, default: nil)
  attr(:empty, :string, default: "—")

  def chips(assigns) do
    shown = if assigns.max, do: Enum.take(assigns.items, assigns.max), else: assigns.items
    assigns = assign(assigns, shown: shown, hidden: length(assigns.items) - length(shown))

    ~H"""
    <span :if={@items == []} class="text-subtle">{@empty}</span>
    <span :if={@items != []} class="inline-flex flex-wrap items-center gap-1">
      <.badge :for={item <- @shown} tone={@tone} class="font-mono">{item}</.badge>
      <span :if={@hidden > 0} class="text-xs text-subtle">+{@hidden}</span>
    </span>
    """
  end

  @doc "Absolute timestamp tooltip + relative label for a millisecond epoch."
  attr(:ms, :any, required: true)

  def time_ago(assigns) do
    ~H"""
    <time
      :if={is_integer(@ms)}
      datetime={@ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()}
      title={@ms |> DateTime.from_unix!(:millisecond) |> Calendar.strftime("%Y-%m-%d %H:%M:%S UTC")}
    >
      {relative_time(@ms)}
    </time>
    <span :if={!is_integer(@ms)} class="text-subtle">—</span>
    """
  end
end
