defmodule LemonWeb.Live.Components.ToolCallComponent do
  @moduledoc false

  use Phoenix.Component

  import LemonWeb.Live.Components.Payload, only: [fetch: 2]

  alias LemonWeb.Live.Components.Payload
  alias Phoenix.LiveView.JS

  @summary_limit 120

  @doc """
  A collapsed card for one engine action: tool name, a one-line argument
  summary, and its status. Expanding it shows the arguments and the result.
  The card is upserted in place as the action moves from started to completed;
  the browser keeps it open or closed across those updates.
  """
  attr(:id, :string, required: true)
  attr(:event, :map, required: true)

  def tool_call(assigns) do
    action = fetch(assigns.event, :action) || %{}
    detail = fetch(action, :detail)
    detail = if is_map(detail), do: detail, else: %{}
    status = status(fetch(assigns.event, :phase), fetch(assigns.event, :ok))
    name = tool_name(action, detail)

    assigns =
      assigns
      |> assign(:name, name)
      |> assign(:summary, summary(fetch(action, :title), name))
      |> assign(:status, status)
      |> assign(:args, Payload.format(LemonCore.Redact.map(fetch(detail, :args))))
      |> assign(:result, Payload.format(fetch(detail, :result)))
      |> assign(:message, Payload.format(fetch(assigns.event, :message)))

    ~H"""
    <details
      id={@id}
      phx-mounted={JS.ignore_attributes("open")}
      data-status={@status}
      class="tool-call-card w-full max-w-[90%] rounded-xl border border-slate-200 bg-white text-sm text-slate-800 shadow-sm sm:max-w-[75%]"
    >
      <summary class="flex cursor-pointer list-none items-center gap-2 rounded-xl px-3 py-2 hover:bg-slate-50 focus:outline-none focus:ring">
        <span class={status_dot_class(@status)} aria-hidden="true"></span>
        <span class="shrink-0 font-mono text-xs font-semibold text-slate-900">{@name}</span>
        <span :if={@summary} class="min-w-0 flex-1 truncate font-mono text-xs text-slate-500">
          {@summary}
        </span>
        <span class={status_badge_class(@status)}>{status_label(@status)}</span>
      </summary>
      <div class="space-y-2 border-t border-slate-100 px-3 py-2">
        <div :if={@args}>
          <p class="text-[11px] font-medium uppercase tracking-wide text-slate-400">Arguments</p>
          <pre class="mt-1 max-h-64 overflow-auto whitespace-pre-wrap break-words rounded-lg bg-slate-50 p-2 font-mono text-xs text-slate-800">{@args}</pre>
        </div>
        <div :if={@result}>
          <p class="text-[11px] font-medium uppercase tracking-wide text-slate-400">Result</p>
          <pre class="mt-1 max-h-64 overflow-auto whitespace-pre-wrap break-words rounded-lg bg-slate-50 p-2 font-mono text-xs text-slate-800">{@result}</pre>
        </div>
        <p :if={@message} class="whitespace-pre-wrap break-words text-xs text-slate-600">{@message}</p>
        <p :if={!@args and !@result and !@message} class="text-xs text-slate-500">
          No details reported yet.
        </p>
      </div>
    </details>
    """
  end

  defp tool_name(action, detail) do
    case fetch(detail, :name) do
      name when is_binary(name) and name != "" ->
        name

      _ ->
        case fetch(action, :kind) do
          kind when is_atom(kind) and not is_nil(kind) -> Atom.to_string(kind)
          kind when is_binary(kind) and kind != "" -> kind
          _ -> "tool"
        end
    end
  end

  defp summary(title, name) when is_binary(title) do
    title = title |> String.replace("`", "") |> String.trim()

    cond do
      title == "" or title == name -> nil
      String.length(title) > @summary_limit -> String.slice(title, 0, @summary_limit) <> "…"
      true -> title
    end
  end

  defp summary(_title, _name), do: nil

  defp status(phase, ok) when phase in [:completed, "completed"] do
    if ok == false, do: :failed, else: :done
  end

  defp status(_phase, _ok), do: :running

  defp status_label(:running), do: "running"
  defp status_label(:done), do: "done"
  defp status_label(:failed), do: "failed"

  defp status_dot_class(:running), do: "h-2 w-2 shrink-0 animate-pulse rounded-full bg-amber-500"
  defp status_dot_class(:done), do: "h-2 w-2 shrink-0 rounded-full bg-emerald-500"
  defp status_dot_class(:failed), do: "h-2 w-2 shrink-0 rounded-full bg-rose-500"

  defp status_badge_class(:running),
    do:
      "ml-auto shrink-0 rounded-full bg-amber-50 px-2 py-0.5 text-[11px] font-medium text-amber-800"

  defp status_badge_class(:done),
    do:
      "ml-auto shrink-0 rounded-full bg-emerald-50 px-2 py-0.5 text-[11px] font-medium text-emerald-800"

  defp status_badge_class(:failed),
    do:
      "ml-auto shrink-0 rounded-full bg-rose-50 px-2 py-0.5 text-[11px] font-medium text-rose-800"
end
