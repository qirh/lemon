defmodule LemonWeb.WorkspaceChangesComponent do
  @moduledoc """
  Workspace changes viewer for a chat session: the `git status` of the
  session's cwd (bounded list with status codes and `+`/`-` counts) and a
  unified or side-by-side diff of one selected file, both from the read-only
  `sessions.changes` control-plane method.

      <.live_component
        module={LemonWeb.WorkspaceChangesComponent}
        id="inspector-changes"
        session_key={@session_key}
        cwd={@cwd}
      />

  Changing `session_key`/`cwd` reloads. `send_update(LemonWeb.WorkspaceChangesComponent,
  id: id, refresh: true)` reloads in place (for example after a run finishes),
  keeping the selected file when it is still changed. Git runs off the
  LiveView process (`start_async`); failures render as an explicit
  unavailable state, never as "no changes".
  """

  use LemonWeb, :live_component

  alias LemonWeb.Rpc

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       status: :loading,
       selected: nil,
       diff: nil,
       view: "unified",
       target: nil
     )}
  end

  @impl true
  def update(assigns, socket) do
    refresh? = Map.get(assigns, :refresh, false)
    assigns = Map.delete(assigns, :refresh)
    socket = assign(socket, assigns)
    target = {socket.assigns[:session_key], socket.assigns[:cwd]}

    cond do
      target != socket.assigns.target ->
        {:ok, socket |> assign(target: target, selected: nil, diff: nil) |> load_status()}

      refresh? ->
        {:ok, socket |> load_status() |> load_diff()}

      true ->
        {:ok, socket}
    end
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, socket |> load_status() |> load_diff()}
  end

  def handle_event("select", %{"path" => path}, socket) when is_binary(path) do
    {:noreply, socket |> assign(selected: path) |> load_diff()}
  end

  def handle_event("back", _params, socket) do
    {:noreply, assign(socket, selected: nil, diff: nil)}
  end

  def handle_event("view", %{"view" => view}, socket) when view in ["unified", "split"] do
    {:noreply, assign(socket, view: view)}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:status, {:ok, {target, result}}, socket) do
    if target == socket.assigns.target,
      do: {:noreply, assign(socket, status: status_result(result))},
      else: {:noreply, socket}
  end

  def handle_async(:status, {:exit, _reason}, socket) do
    {:noreply, assign(socket, status: {:error, "Workspace changes are unavailable."})}
  end

  def handle_async(:diff, {:ok, {target, path, result}}, socket) do
    if target == socket.assigns.target and path == socket.assigns.selected,
      do: {:noreply, assign(socket, diff: diff_result(result))},
      else: {:noreply, socket}
  end

  def handle_async(:diff, {:exit, _reason}, socket) do
    {:noreply, assign(socket, diff: {:error, "This diff is unavailable."})}
  end

  defp load_status(socket) do
    case socket.assigns.target do
      {key, cwd} when is_binary(key) and is_binary(cwd) ->
        target = socket.assigns.target

        socket
        |> assign(status: :loading)
        |> start_async(:status, fn ->
          {target, Rpc.call("sessions.changes", %{"sessionKey" => key, "cwd" => cwd})}
        end)

      _ ->
        assign(socket, status: {:error, "This session has no workspace directory."})
    end
  end

  defp load_diff(%{assigns: %{selected: nil}} = socket), do: socket

  defp load_diff(socket) do
    {key, cwd} = target = socket.assigns.target
    path = socket.assigns.selected

    socket
    |> assign(diff: :loading)
    |> start_async(:diff, fn ->
      {target, path,
       Rpc.call("sessions.changes", %{"sessionKey" => key, "cwd" => cwd, "path" => path})}
    end)
  end

  defp status_result({:ok, %{"repository" => false}}), do: :not_repository
  defp status_result({:ok, %{"files" => files} = payload}) when is_list(files), do: {:ok, payload}
  defp status_result({:ok, _}), do: {:error, "Workspace changes are unavailable."}
  defp status_result({:error, error}), do: {:error, Rpc.message(error)}

  defp diff_result({:ok, %{"diff" => %{} = diff}}),
    do: {:ok, Map.put(diff, "lines", parse_patch(diff["patch"]))}

  defp diff_result({:ok, _}), do: {:error, "This diff is unavailable."}
  defp diff_result({:error, error}), do: {:error, Rpc.message(error)}

  # ── Patch parsing ──────────────────────────────────────────────────────

  @doc """
  Parses unified-diff hunks into numbered lines:
  `%{type: :hunk | :add | :del | :ctx | :meta, old: n | nil, new: n | nil, text: s}`.
  """
  @spec parse_patch(String.t() | nil) :: [map()]
  def parse_patch(patch) when is_binary(patch) and patch != "" do
    {lines, _} =
      patch
      |> String.split("\n")
      |> Enum.map_reduce({0, 0}, fn line, {old, new} ->
        case line do
          "@@" <> _ ->
            {old_start, new_start} = hunk_starts(line)
            {%{type: :hunk, old: nil, new: nil, text: line}, {old_start, new_start}}

          "+" <> text ->
            {%{type: :add, old: nil, new: new, text: text}, {old, new + 1}}

          "-" <> text ->
            {%{type: :del, old: old, new: nil, text: text}, {old + 1, new}}

          "\\" <> _ ->
            {%{type: :meta, old: nil, new: nil, text: line}, {old, new}}

          " " <> text ->
            {%{type: :ctx, old: old, new: new, text: text}, {old + 1, new + 1}}

          text ->
            {%{type: :ctx, old: old, new: new, text: text}, {old + 1, new + 1}}
        end
      end)

    lines
  end

  def parse_patch(_patch), do: []

  defp hunk_starts(line) do
    case Regex.run(~r/^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/, line) do
      [_, old, new] -> {String.to_integer(old), String.to_integer(new)}
      _ -> {0, 0}
    end
  end

  @doc """
  Pairs unified lines into side-by-side rows `{left, right}`: runs of
  deletions sit beside the following additions; context spans both sides;
  hunk/meta lines are `{:full, line}`.
  """
  @spec split_rows([map()]) :: [{map() | nil, map() | nil} | {:full, map()}]
  def split_rows(lines), do: split_rows(lines, [], [], [])

  defp split_rows([], dels, adds, acc), do: Enum.reverse(flush(dels, adds, acc))

  defp split_rows([%{type: :del} = line | rest], dels, [], acc),
    do: split_rows(rest, [line | dels], [], acc)

  defp split_rows([%{type: :add} = line | rest], dels, adds, acc),
    do: split_rows(rest, dels, [line | adds], acc)

  defp split_rows([%{type: type} = line | rest], dels, adds, acc) when type in [:hunk, :meta],
    do: split_rows(rest, [], [], [{:full, line} | flush(dels, adds, acc)])

  defp split_rows([%{type: :del} = line | rest], dels, adds, acc),
    do: split_rows(rest, [line], [], flush(dels, adds, acc))

  defp split_rows([line | rest], dels, adds, acc),
    do: split_rows(rest, [], [], [{line, line} | flush(dels, adds, acc)])

  defp flush([], [], acc), do: acc

  defp flush(dels, adds, acc) do
    dels = Enum.reverse(dels)
    adds = Enum.reverse(adds)
    size = max(length(dels), length(adds))
    pad = fn list -> list ++ List.duplicate(nil, size - length(list)) end

    pad.(dels)
    |> Enum.zip(pad.(adds))
    |> Enum.reverse()
    |> Kernel.++(acc)
  end

  # ── Render ─────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <section id={@id} class="flex h-full min-h-0 flex-col" aria-label="Workspace changes">
      <header class="flex shrink-0 items-center gap-2 border-b border-line px-3 py-2">
        <%= if @selected do %>
          <button
            type="button"
            class="btn btn-ghost btn-icon btn-sm -ml-1.5"
            phx-click="back"
            phx-target={@myself}
            aria-label="Back to all changes"
            title="All changes"
          >
            <.icon name="chevron-left" />
          </button>
          <p class="min-w-0 flex-1 truncate font-mono text-xs text-fg" title={@selected}>
            <span class="text-subtle">{dirname(@selected)}</span>{basename(@selected)}
          </p>
          <div class="segmented shrink-0" role="group" aria-label="Diff layout">
            <button
              :for={{value, label} <- [{"unified", "Unified"}, {"split", "Split"}]}
              type="button"
              aria-pressed={to_string(@view == value)}
              phx-click="view"
              phx-value-view={value}
              phx-target={@myself}
            >
              {label}
            </button>
          </div>
        <% else %>
          <.icon name="git-branch" class="h-3.5 w-3.5 text-subtle" />
          <p class="min-w-0 flex-1 truncate text-[13px] font-medium text-fg">
            <%= case @status do %>
              <% {:ok, %{"branch" => branch}} when is_binary(branch) -> %>
                {branch}
              <% _ -> %>
                Changes
            <% end %>
          </p>
          <span :if={match?({:ok, _}, @status)} class="shrink-0 text-xs text-muted">
            <.counts additions={totals(@status)["additions"]} deletions={totals(@status)["deletions"]} />
          </span>
        <% end %>
        <button
          type="button"
          class="btn btn-ghost btn-icon btn-sm -mr-1.5"
          phx-click="refresh"
          phx-target={@myself}
          aria-label="Refresh changes"
          title="Refresh"
        >
          <.icon name="refresh" class={["h-3.5 w-3.5", loading?(@status, @diff, @selected) && "animate-spin"]} />
        </button>
      </header>

      <div class="min-h-0 flex-1 overflow-y-auto scroll-thin">
        <%= if @selected do %>
          <.diff_view id={@id} diff={@diff} view={@view} />
        <% else %>
          <.file_list id={@id} status={@status} myself={@myself} />
        <% end %>
      </div>
    </section>
    """
  end

  attr(:id, :string, required: true)
  attr(:status, :any, required: true)
  attr(:myself, :any, required: true)

  defp file_list(assigns) do
    ~H"""
    <%= case @status do %>
      <% :loading -> %>
        <div class="space-y-2 p-3" aria-busy="true">
          <.spinner label="Loading changes" />
          <div :for={_ <- 1..4} class="h-4 animate-pulse rounded bg-surface-2"></div>
        </div>
      <% {:error, message} -> %>
        <div class="p-3">
          <.callout tone="danger" title="Workspace changes unavailable" icon="alert-circle">{message}</.callout>
        </div>
      <% :not_repository -> %>
        <div class="p-3">
          <.empty_state
            icon="git-branch"
            title="Not a git repository"
            description="This session's working directory isn't inside a git work tree, so there are no changes to show."
          />
        </div>
      <% {:ok, %{"files" => []}} -> %>
        <div class="p-3">
          <.empty_state icon="check-circle" title="No changes" description="The working tree matches the last commit." />
        </div>
      <% {:ok, payload} -> %>
        <p class="px-3 pb-1 pt-2 text-2xs font-semibold uppercase tracking-wider text-subtle">
          {length(payload["files"])} {if length(payload["files"]) == 1, do: "file", else: "files"} changed
        </p>
        <ul id={"#{@id}-files"} class="px-1.5 pb-2" aria-label="Changed files">
          <li :for={file <- payload["files"]}>
            <button
              type="button"
              class="flex h-8 w-full items-center gap-2 rounded-md px-1.5 text-left hover:bg-surface-2 focus-visible:bg-surface-2 focus-visible:outline-none"
              phx-click="select"
              phx-value-path={file["path"]}
              phx-target={@myself}
              title={file_title(file)}
            >
              <span class={["w-4 shrink-0 text-center font-mono text-xs font-semibold", status_tone(file["status"])]} aria-label={file["status"]}>
                {status_letter(file["status"])}
              </span>
              <span class="min-w-0 flex-1 truncate font-mono text-xs">
                <span class="text-subtle">{dirname(file["path"])}</span><span class="text-fg">{basename(file["path"])}</span>
              </span>
              <span :if={file["staged"]} class="shrink-0 text-2xs text-subtle">staged</span>
              <span :if={file["binary"]} class="shrink-0 text-2xs text-subtle">binary</span>
              <span class="shrink-0 text-2xs">
                <.counts additions={file["additions"]} deletions={file["deletions"]} />
              </span>
            </button>
          </li>
        </ul>
        <p :if={payload["truncated"]} class="px-3 pb-3 text-xs text-muted">
          Showing {length(payload["files"])} of {payload["totals"]["files"]} changed files.
        </p>
    <% end %>
    """
  end

  attr(:additions, :any, required: true)
  attr(:deletions, :any, required: true)

  defp counts(assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1.5 font-mono tabular-nums">
      <span :if={is_integer(@additions) and @additions > 0} class="text-success">+{@additions}</span>
      <span :if={is_integer(@deletions) and @deletions > 0} class="text-danger">−{@deletions}</span>
    </span>
    """
  end

  attr(:id, :string, required: true)
  attr(:diff, :any, required: true)
  attr(:view, :string, required: true)

  defp diff_view(assigns) do
    ~H"""
    <%= case @diff do %>
      <% :loading -> %>
        <div class="p-3" aria-busy="true"><.spinner label="Loading diff" /></div>
      <% nil -> %>
        <div class="p-3"><.spinner label="Loading diff" /></div>
      <% {:error, message} -> %>
        <div class="p-3">
          <.callout tone="danger" title="Diff unavailable" icon="alert-circle">{message}</.callout>
        </div>
      <% {:ok, %{"directory" => true}} -> %>
        <div class="p-3">
          <.empty_state icon="folder" title="Untracked directory" description="Its files aren't tracked yet, so there is no line diff." />
        </div>
      <% {:ok, %{"binary" => true}} -> %>
        <div class="p-3">
          <.empty_state icon="file" title="Binary file" description="Binary changes have no text diff." />
        </div>
      <% {:ok, %{"lines" => []}} -> %>
        <div class="p-3">
          <.empty_state icon="file-diff" title="No line changes" description="Only the file mode or metadata changed." />
        </div>
      <% {:ok, diff} -> %>
        <div class="flex items-center gap-2 px-3 py-1.5 text-2xs text-muted">
          <span class="badge badge-neutral">{diff["status"]}</span>
          <span :if={diff["origPath"]} class="truncate font-mono">from {diff["origPath"]}</span>
          <span class="ml-auto"><.counts additions={diff["additions"]} deletions={diff["deletions"]} /></span>
        </div>
        <div :if={diff["truncated"]} class="px-3 pb-2">
          <.callout tone="warning" title="Diff truncated">
            Showing the first {diff["lineCount"]} lines; large diffs are capped at
            {diff["limits"]["lines"]} lines / {div(diff["limits"]["bytes"], 1000)} KB.
          </.callout>
        </div>
        <div id={"#{@id}-diff"} class="overflow-x-auto border-t border-line code-surface font-mono text-xs leading-5">
          <%= if @view == "split" do %>
            <%!-- Both sides always visible: fixed columns, long lines wrap. --%>
            <table class="w-full table-fixed border-collapse" aria-label="Side-by-side diff">
              <colgroup>
                <col class="w-9" />
                <col />
                <col class="w-9" />
                <col />
              </colgroup>
              <tbody>
                <%= for row <- split_rows(diff["lines"]) do %>
                  <%= case row do %>
                    <% {:full, line} -> %>
                      <tr class={line_class(line.type)}>
                        <td colspan="4" class="whitespace-pre-wrap break-all px-2">{line.text}</td>
                      </tr>
                    <% {left, right} -> %>
                      <tr>
                        <td class={["select-none px-1.5 text-right align-top text-subtle", left && line_class(left.type)]}>{left && left.old}</td>
                        <td class={["whitespace-pre-wrap break-all border-r border-line pr-2 align-top", left && line_class(left.type)]}>{left && marker(left.type)}{left && left.text}</td>
                        <td class={["select-none px-1.5 text-right align-top text-subtle", right && line_class(right.type)]}>{right && right.new}</td>
                        <td class={["whitespace-pre-wrap break-all pr-2 align-top", right && line_class(right.type)]}>{right && marker(right.type)}{right && right.text}</td>
                      </tr>
                  <% end %>
                <% end %>
              </tbody>
            </table>
          <% else %>
            <table class="w-full min-w-max border-collapse" aria-label="Unified diff">
              <tbody>
                <tr :for={line <- diff["lines"]} class={line_class(line.type)}>
                  <td class="w-10 select-none px-2 text-right text-subtle">{line.old}</td>
                  <td class="w-10 select-none px-2 text-right text-subtle">{line.new}</td>
                  <td class="whitespace-pre pr-4">{marker(line.type)}{line.text}</td>
                </tr>
              </tbody>
            </table>
          <% end %>
        </div>
    <% end %>
    """
  end

  defp line_class(:add), do: "diff-line-add"
  defp line_class(:del), do: "diff-line-del"
  defp line_class(:hunk), do: "diff-line-hunk"
  defp line_class(:meta), do: "text-subtle italic"
  defp line_class(_), do: nil

  defp marker(:add), do: "+"
  defp marker(:del), do: "-"
  defp marker(:ctx), do: " "
  defp marker(_), do: ""

  defp totals({:ok, %{"totals" => totals}}) when is_map(totals), do: totals
  defp totals(_), do: %{}

  defp loading?(:loading, _diff, _selected), do: true
  defp loading?(_status, :loading, selected) when is_binary(selected), do: true
  defp loading?(_status, _diff, _selected), do: false

  defp status_letter("modified"), do: "M"
  defp status_letter("added"), do: "A"
  defp status_letter("deleted"), do: "D"
  defp status_letter("renamed"), do: "R"
  defp status_letter("copied"), do: "C"
  defp status_letter("untracked"), do: "U"
  defp status_letter("conflicted"), do: "!"
  defp status_letter("type_changed"), do: "T"
  defp status_letter(_), do: "•"

  defp status_tone(status) when status in ["added", "untracked"], do: "text-success"
  defp status_tone("deleted"), do: "text-danger"
  defp status_tone("conflicted"), do: "text-warning"
  defp status_tone(status) when status in ["renamed", "copied"], do: "text-info"
  defp status_tone(_), do: "text-accent-text"

  defp file_title(%{"path" => path, "origPath" => orig, "status" => status}) when is_binary(orig),
    do: "#{path} (#{status} from #{orig})"

  defp file_title(%{"path" => path, "status" => status}), do: "#{path} (#{status})"

  defp dirname(path) do
    case Path.dirname(String.trim_trailing(path, "/")) do
      "." -> ""
      dir -> dir <> "/"
    end
  end

  defp basename(path) do
    base = Path.basename(path)
    if String.ends_with?(path, "/"), do: base <> "/", else: base
  end
end
