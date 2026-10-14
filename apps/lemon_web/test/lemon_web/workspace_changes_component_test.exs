defmodule LemonWeb.WorkspaceChangesComponentTest do
  use ExUnit.Case, async: false

  @endpoint LemonWeb.Endpoint

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import LemonWeb.Test.OperatorAuth

  alias LemonWeb.WorkspaceChangesComponent

  setup :configure_operator_token

  defmodule Host do
    use Phoenix.LiveView

    def mount(_params, session, socket) do
      {:ok, assign(socket, cwd: session["cwd"], key: session["key"])}
    end

    def handle_event("refresh", _params, socket) do
      send_update(WorkspaceChangesComponent, id: "changes", refresh: true)
      {:noreply, socket}
    end

    def render(assigns) do
      ~H"""
      <div>
        <.live_component module={WorkspaceChangesComponent} id="changes" session_key={@key} cwd={@cwd} />
      </div>
      """
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "lemon-web-changes-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  defp git!(dir, args) do
    {_, 0} =
      System.cmd(
        "git",
        [
          "-c",
          "user.email=t@example.com",
          "-c",
          "user.name=T",
          "-c",
          "init.defaultBranch=main" | args
        ],
        cd: dir,
        stderr_to_stdout: true
      )
  end

  defp repo!(root) do
    git!(root, ["init", "-q"])
    File.write!(Path.join(root, "lib.ex"), Enum.map_join(1..8, "\n", &"line #{&1}") <> "\n")
    File.write!(Path.join(root, "old.txt"), "old\n")
    git!(root, ["add", "-A"])
    git!(root, ["commit", "-q", "-m", "init"])
  end

  defp mount(root) do
    {:ok, view, _html} =
      live_isolated(build_conn(), Host, session: %{"cwd" => root, "key" => "agent:default:main"})

    render_async(view)
    view
  end

  test "lists changed files and opens unified and split diffs", %{root: root} do
    repo!(root)

    File.write!(
      Path.join(root, "lib.ex"),
      "line 1\nline two\nline 3\nline 4\nline 5\nline 6\nline 7\nline 8\nline 9\n"
    )

    File.rm!(Path.join(root, "old.txt"))
    File.mkdir_p!(Path.join(root, "src"))
    File.write!(Path.join(root, "src/new.js"), "export const a = 1\n")

    view = mount(root)
    html = render(view)

    assert html =~ "main"
    assert html =~ "3 files changed"
    assert has_element?(view, ~s(button[phx-value-path="lib.ex"]), "M")
    assert has_element?(view, ~s(button[phx-value-path="old.txt"]), "D")
    assert has_element?(view, ~s(button[phx-value-path="src/new.js"]), "U")
    refute html =~ root

    view |> element(~s(button[phx-value-path="lib.ex"])) |> render_click()
    html = render_async(view)

    assert html =~ "Unified diff"
    assert html =~ "diff-line-hunk"
    assert html =~ "diff-line-add"
    assert html =~ "diff-line-del"
    assert html =~ "line two"

    html = view |> element(~s(button[phx-value-view="split"])) |> render_click()
    assert html =~ "Side-by-side diff"

    html = view |> element(~s(button[aria-label="Back to all changes"])) |> render_click()
    assert html =~ "3 files changed"
  end

  test "refresh picks up new changes", %{root: root} do
    repo!(root)
    view = mount(root)
    assert render(view) =~ "No changes"

    File.write!(Path.join(root, "fresh.txt"), "x\n")
    view |> element(~s(button[aria-label="Refresh changes"])) |> render_click()
    assert render_async(view) =~ "fresh.txt"

    File.write!(Path.join(root, "another.txt"), "y\n")
    render_click(view, "refresh", %{})
    assert render_async(view) =~ "another.txt"
  end

  test "non-git cwd and unavailable states are explicit", %{root: root} do
    view = mount(root)
    assert render(view) =~ "Not a git repository"

    view = mount(Path.join(root, "missing"))
    html = render(view)
    assert html =~ "Workspace changes unavailable"
    assert html =~ "Workspace directory not found"
    refute html =~ root
  end

  test "binary files render without a text diff", %{root: root} do
    repo!(root)
    File.write!(Path.join(root, "blob.bin"), <<0, 1, 2, 0, 255>>)
    view = mount(root)

    view |> element(~s(button[phx-value-path="blob.bin"])) |> render_click()
    assert render_async(view) =~ "Binary file"
  end

  test "parse_patch numbers lines and split_rows pairs edits" do
    lines =
      WorkspaceChangesComponent.parse_patch(
        "@@ -3,3 +3,3 @@ ctx\n a\n-b\n+B\n+C\n c\n\\ No newline at end of file"
      )

    assert [
             %{type: :hunk},
             %{type: :ctx, old: 3, new: 3},
             %{type: :del, old: 4},
             %{type: :add, new: 4},
             %{type: :add, new: 5},
             %{type: :ctx, old: 5, new: 6},
             %{type: :meta}
           ] = lines

    assert [
             {:full, %{type: :hunk}},
             {%{type: :ctx}, %{type: :ctx}},
             {%{type: :del, text: "b"}, %{type: :add, text: "B"}},
             {nil, %{type: :add, text: "C"}},
             {%{type: :ctx}, %{type: :ctx}},
             {:full, %{type: :meta}}
           ] = WorkspaceChangesComponent.split_rows(lines)
  end
end
