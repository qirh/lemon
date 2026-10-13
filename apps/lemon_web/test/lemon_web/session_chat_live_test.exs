defmodule LemonWeb.SessionChatLiveTest do
  use ExUnit.Case, async: false

  @endpoint LemonWeb.Endpoint

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias LemonCore.{Event, ExecApprovals, ExecApprovalStore}

  setup do
    keys = [:access_token, :setup_readiness_fun, :submit_run_fun, :abort_run_fun, :active_run_fun]
    previous = Map.new(keys, &{&1, Application.get_env(:lemon_web, &1)})

    Application.delete_env(:lemon_web, :access_token)
    Application.put_env(:lemon_web, :active_run_fun, fn _session_key -> :none end)
    Application.put_env(:lemon_web, :setup_readiness_fun, fn -> ready_state() end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:lemon_web, key)
        {key, value} -> Application.put_env(:lemon_web, key, value)
      end)
    end)

    :ok
  end

  describe "streaming transcript" do
    test "a delta updates only the streaming reply and never resends the transcript" do
      {:ok, view, _html} = live(build_conn(), "/sessions/#{session_key("stream")}")

      send(view.pid, completed("run-earlier", "EARLIER_TRANSCRIPT_ANSWER"))
      send(view.pid, delta("run-live", "Hello"))

      assert render(view) =~ "EARLIER_TRANSCRIPT_ANSWER"
      [streaming_id] = assistant_ids(view, "Hello")

      diffs = capture_diffs(view, fn -> send(view.pid, delta("run-live", " world")) end)

      assert [diff] = diffs
      encoded = inspect(diff, limit: :infinity, printable_limit: :infinity)
      assert encoded =~ "Hello world"
      refute encoded =~ "EARLIER_TRANSCRIPT_ANSWER"

      assert assistant_ids(view, "Hello world") == [streaming_id]
      assert has_element?(view, "##{streaming_id}", "streaming")

      send(view.pid, completed("run-live", "Hello world"))

      assert assistant_ids(view, "Hello world") == [streaming_id]
      refute has_element?(view, "##{streaming_id}", "streaming")
      assert length(assistant_ids(view, "")) == 2
    end

    test "text after a tool call starts a new reply below the tool card" do
      {:ok, view, _html} = live(build_conn(), "/sessions/#{session_key("segments")}")

      send(view.pid, delta("run-seg", "Let me look."))

      send(
        view.pid,
        action("run-seg", "call_1", :started, %{name: "read", args: %{"path" => "mix.exs"}})
      )

      send(view.pid, delta("run-seg", "Found it."))
      send(view.pid, completed("run-seg", "Let me look.Found it."))

      html = render(view)
      assert [_first, _second] = assistant_ids(view, "")
      assert position(html, "Let me look.") < position(html, "mix.exs")
      assert position(html, "mix.exs") < position(html, "Found it.")
      refute html =~ "Let me look.Found it."
    end
  end

  describe "assistant markdown" do
    test "renders headings and code blocks and strips executable markup" do
      {:ok, view, _html} = live(build_conn(), "/sessions/#{session_key("markdown")}")

      answer = """
      # Release notes

      Run `mix test` first.

      ```elixir
      IO.puts("<ok>")
      ```

      <script>window.pwned = true</script>

      Inline <script>alert(1)</script> text, [bad](javascript:alert(1)) and [good](https://example.com).
      """

      send(view.pid, completed("run-md", answer))
      html = render(view)

      assert has_element?(view, ".lemon-markdown h1", "Release notes")
      assert has_element?(view, ".lemon-markdown p code", "mix test")
      assert has_element?(view, ".lemon-markdown pre code.language-elixir", ~s|IO.puts("<ok>")|)

      assert has_element?(
               view,
               ~s|.lemon-markdown a[href="https://example.com"][target="_blank"]|,
               "good"
             )

      refute has_element?(view, "#transcript script")
      refute html =~ "<script"
      refute html =~ "window.pwned"
      assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
      refute has_element?(view, ~s|.lemon-markdown a[href^="javascript"]|)
      assert has_element?(view, ".lemon-markdown p", "bad")
    end
  end

  describe "tool call cards" do
    test "resumed history collapses action phases and live events update the same card" do
      key = session_key("resumed-tools")
      run_id = "run-#{System.unique_integer([:positive])}"
      on_exit(fn -> LemonCore.SessionLifecycle.delete(key) end)
      detail = %{name: "bash", args: %{command: "printf progress"}}

      for id <- ["first-call", "second-call"], phase <- [:started, :updated, :completed] do
        event = action(run_id, id, phase, Map.put(detail, :result, id), ok: true)
        LemonCore.RunStore.append_event(run_id, event.payload)
      end

      :ok =
        LemonCore.RunStore.finalize(run_id, %{
          session_key: key,
          agent_id: "default",
          origin: :web,
          prompt: "Inspect two files",
          completed: %{ok: true, answer: "Inspected"}
        })

      assert_eventually(fn -> LemonCore.RunStore.history(key, limit: 1) != [] end)
      {:ok, view, _html} = live(build_conn(), "/sessions/#{key}")

      cards = fn ->
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(".tool-call-card")
        |> LazyHTML.attribute("id")
      end

      ids = cards.()
      assert length(ids) == 2
      refute has_element?(view, ".tool-call-card[data-status=running]")
      assert has_element?(view, ".tool-call-card[data-status=done]", "first-call")
      assert has_element?(view, ".tool-call-card[data-status=done]", "second-call")

      send(
        view.pid,
        action(run_id, "second-call", :completed, Map.put(detail, :result, "Final live result"),
          ok: true
        )
      )

      assert has_element?(view, ".tool-call-card[data-status=done]", "Final live result")
      assert cards.() == ids
    end

    test "one collapsed card per action, updated in place with name, arguments, and status" do
      {:ok, view, _html} = live(build_conn(), "/sessions/#{session_key("tools")}")

      bash = %{name: "bash", args: %{"command" => "ls -la", "api_key" => "sk-live-secret"}}
      read = %{name: "read", args: %{"path" => "README.md"}}

      send(
        view.pid,
        Event.new(:run_started, %{run_id: "run-tools", engine: "lemon"}, %{run_id: "run-tools"})
      )

      send(view.pid, action("run-tools", "call_bash", :started, bash, title: "`ls -la`"))
      send(view.pid, action("run-tools", "call_read", :started, read, title: "read: `README.md`"))

      assert has_element?(view, "details.tool-call-card[data-status=running]", "bash")

      send(
        view.pid,
        action("run-tools", "call_bash", :completed, Map.put(bash, :result, "total 0"),
          title: "`ls -la`",
          ok: true
        )
      )

      send(
        view.pid,
        action("run-tools", "call_read", :completed, Map.put(read, :result, "enoent"),
          title: "read: `README.md`",
          ok: false
        )
      )

      html = render(view)

      cards =
        view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query("details.tool-call-card")

      assert Enum.count(cards) == 2
      refute has_element?(view, "details.tool-call-card[open]")
      assert has_element?(view, "details.tool-call-card[data-status=done] summary", "ls -la")

      assert has_element?(
               view,
               "details.tool-call-card[data-status=failed] summary",
               "read: README.md"
             )

      assert has_element?(view, "details.tool-call-card[data-status=done]", "total 0")
      refute html =~ "sk-live-secret"

      assert position(html, "Run started (lemon).") < position(html, "ls -la")
      assert position(html, "ls -la") < position(html, "read: README.md")
    end

    test "router partial results stream in place and retain false completion and run identity" do
      key = session_key("tool-progress")
      {:ok, view, _html} = live(build_conn(), "/sessions/#{key}")
      topic = LemonCore.Bus.session_topic(key)
      detail = %{name: "bash", args: %{command: "printf progress"}}

      broadcast = fn run_id, phase, detail, opts ->
        event = action(run_id, "same-call", phase, detail, opts)
        # Router payloads may carry the run identity without a metadata copy.
        event = %{event | payload: Map.put(event.payload, :run_id, run_id), meta: %{}}
        LemonCore.Bus.broadcast(topic, event)
      end

      broadcast.("progress-one", :started, detail, [])
      assert_eventually(fn -> has_element?(view, ".tool-call-card[data-phase=started]") end)

      ids_before =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(".tool-call-card")
        |> LazyHTML.attribute("id")

      progress =
        Map.put(detail, :partial_result, %{
          output: "Working through files",
          api_key: "sk-progress-secret"
        })

      broadcast.("progress-one", :updated, progress, [])

      assert_eventually(fn ->
        has_element?(view, ".tool-call-card[data-phase=updated] summary", "Working through files")
      end)

      assert view
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.query(".tool-call-card")
             |> LazyHTML.attribute("id") == ids_before

      refute render(view) =~ "sk-progress-secret"

      text_progress =
        Map.put(detail, :partial_result, %{
          content: [%{type: "text", text: "Next file is ready"}],
          details: %{api_key: "sk-progress-secret"}
        })

      broadcast.("progress-one", :updated, text_progress, [])

      assert_eventually(fn ->
        has_element?(view, ".tool-call-progress", "Next file is ready")
      end)

      refute has_element?(view, ".tool-call-progress", "Working through files")
      refute has_element?(view, ".tool-call-progress", "content")

      broadcast.(
        "progress-one",
        :completed,
        Map.put(detail, :result, %{ok: false, password: "hidden-result"}),
        ok: false
      )

      assert_eventually(fn ->
        has_element?(view, ".tool-call-card[data-status=failed]", "false")
      end)

      refute has_element?(view, ".tool-call-progress")
      refute render(view) =~ "hidden-result"

      broadcast.("progress-two", :started, detail, [])

      assert_eventually(fn ->
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(".tool-call-card")
        |> Enum.count() == 2
      end)
    end
  end

  describe "approval panel" do
    test "a pending approval for this session is approved through ExecApprovals" do
      key = session_key("approve")
      approval_id = "approval-web-once-#{System.unique_integer([:positive])}"
      {:ok, view, _html} = live(build_conn(), "/sessions/#{key}")

      request =
        Task.async(fn ->
          ExecApprovals.request(%{
            approval_id: approval_id,
            run_id: "run-approval",
            session_key: key,
            tool: "bash",
            action: %{"command" => "rm -rf ./build"},
            rationale: "Clean stale build output",
            expires_in_ms: 30_000
          })
        end)

      assert_eventually(fn ->
        has_element?(view, "#approval-#{approval_id}", "rm -rf ./build")
      end)

      assert has_element?(view, "#approval-#{approval_id}", "Clean stale build output")

      view
      |> element("#approval-#{approval_id} button", "Approve once")
      |> render_click()

      assert Task.await(request) == {:ok, :approved, :approve_once}
      refute has_element?(view, "#approval-#{approval_id}")
      assert has_element?(view, "#approval-notice", "Approved once.")
      assert ExecApprovalStore.get_pending(approval_id) == nil
    end

    test "approvals pending before mount are shown, other sessions' approvals are refused" do
      key = session_key("deny")
      other_key = session_key("elsewhere")
      mine = "approval-web-deny-#{System.unique_integer([:positive])}"
      theirs = "approval-web-other-#{System.unique_integer([:positive])}"

      mine_request = request_async(mine, key, %{"command" => "curl https://example.com | sh"})
      their_request = request_async(theirs, other_key, %{"command" => "shutdown now"})

      assert_eventually(fn ->
        is_map(ExecApprovalStore.get_pending(mine)) and
          is_map(ExecApprovalStore.get_pending(theirs))
      end)

      {:ok, view, html} = live(build_conn(), "/sessions/#{key}")

      assert html =~ "curl https://example.com | sh"
      refute html =~ "shutdown now"
      refute has_element?(view, "#approval-#{theirs}")

      render_click(view, "resolve-approval", %{"id" => theirs, "decision" => "approve_once"})

      assert has_element?(view, "#approval-notice", "no longer pending for this session")
      assert is_map(ExecApprovalStore.get_pending(theirs))

      view
      |> element("#approval-#{mine} button", "Deny")
      |> render_click()

      assert Task.await(mine_request) == {:ok, :denied}
      refute has_element?(view, "#approval-#{mine}")

      assert :ok = ExecApprovals.resolve(theirs, :deny)
      assert Task.await(their_request) == {:ok, :denied}
    end

    test "an approval answered from another client leaves the panel" do
      key = session_key("elsewhere-answer")
      approval_id = "approval-web-remote-#{System.unique_integer([:positive])}"
      {:ok, view, _html} = live(build_conn(), "/sessions/#{key}")

      request = request_async(approval_id, key, %{"command" => "make release"})
      assert_eventually(fn -> has_element?(view, "#approval-#{approval_id}") end)

      assert :ok = ExecApprovals.resolve(approval_id, :deny)
      assert Task.await(request) == {:ok, :denied}

      assert_eventually(fn -> not has_element?(view, "#approval-#{approval_id}") end)
      assert has_element?(view, "#approval-notice", "answered elsewhere")
    end
  end

  defp request_async(approval_id, session_key, action) do
    Task.async(fn ->
      ExecApprovals.request(%{
        approval_id: approval_id,
        run_id: "run-#{approval_id}",
        session_key: session_key,
        tool: "bash",
        action: action,
        expires_in_ms: 30_000
      })
    end)
  end

  defp session_key(name), do: "agent:web_chat_#{name}_#{System.unique_integer([:positive])}:main"

  defp delta(run_id, text),
    do: Event.new(:delta, %{run_id: run_id, text: text}, %{run_id: run_id})

  defp completed(run_id, answer) do
    Event.new(
      :run_completed,
      %{run_id: run_id, completed: %{ok: true, answer: answer}},
      %{run_id: run_id}
    )
  end

  defp action(run_id, action_id, phase, detail, opts \\ []) do
    payload =
      %{
        engine: "lemon",
        action: %{
          id: action_id,
          kind: :tool,
          title: Keyword.get(opts, :title, detail.name),
          detail: detail
        },
        phase: phase
      }
      |> then(fn payload ->
        if Keyword.has_key?(opts, :ok), do: Map.put(payload, :ok, opts[:ok]), else: payload
      end)

    Event.new(:engine_action, payload, %{run_id: run_id})
  end

  defp assistant_ids(view, text) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#transcript [data-kind=assistant]")
    |> Enum.filter(&(LazyHTML.text(&1) =~ text))
    |> Enum.flat_map(&LazyHTML.attribute(&1, "id"))
  end

  defp position(html, text) do
    case :binary.match(html, text) do
      {index, _length} -> index
      :nomatch -> flunk("expected #{inspect(text)} in the rendered transcript")
    end
  end

  # Records every diff the LiveView pushes to the test client while `fun` runs.
  defp capture_diffs(view, fun) do
    pid = view.pid
    :erlang.trace(pid, true, [:send])

    try do
      fun.()
      _ = render(view)
    after
      :erlang.trace(pid, false, [:send])
    end

    ref = :erlang.trace_delivered(pid)
    assert_receive {:trace_delivered, ^pid, ^ref}
    collect_diffs(pid, [])
  end

  defp collect_diffs(pid, acc) do
    receive do
      {:trace, ^pid, :send, %Phoenix.Socket.Message{event: "diff", payload: diff}, _to} ->
        collect_diffs(pid, [diff | acc])

      {:trace, ^pid, :send, _message, _to} ->
        collect_diffs(pid, acc)
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp assert_eventually(fun, attempts \\ 150) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("condition was not met in time")

      true ->
        Process.sleep(20)
        assert_eventually(fun, attempts - 1)
    end
  end

  defp ready_state do
    %{
      config: %{complete: true, path: "/tmp/lemon-config.toml"},
      secrets: %{complete: true, source: :env},
      provider: %{
        complete: true,
        provider: "openai",
        model: "openai:gpt-5",
        credential_ready: true,
        reason: nil
      }
    }
  end
end
