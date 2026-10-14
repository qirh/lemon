defmodule LemonCli.OmpCommandTestClient do
  # Runs in the test process (capture_io executes in the caller), so scripted
  # responses live in the process dictionary and requests are sent to self().

  def request(method, params, opts) do
    send(self(), {:omp_request, method, params, opts})

    case Process.get({:omp_response, method}) do
      nil -> response(method, params)
      result -> result
    end
  end

  def open(_opts) do
    send(self(), :omp_open)
    Process.get(:omp_open_result, {:ok, :conn})
  end

  def call(:conn, method, params) do
    send(self(), {:omp_call, method, params})

    case Process.get(:omp_calls, []) do
      [next | rest] ->
        Process.put(:omp_calls, rest)
        next

      [] ->
        {:error, %{"code" => "INTERNAL_ERROR", "message" => "unscripted"}}
    end
  end

  def next_event(:conn, timeout_ms) do
    send(self(), {:omp_next_event, timeout_ms})

    case Process.get(:omp_events, []) do
      [next | rest] ->
        Process.put(:omp_events, rest)
        next

      [] ->
        {:error, :disconnected}
    end
  end

  def close(:conn), do: send(self(), :omp_closed)

  def session(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "omp_3f9a1c2b7d4e",
        "ompSessionId" => "01a137e9-0000-0000-0000-000000000000",
        "title" => "Fix the flaky test",
        "cwd" => "/work/project",
        "status" => "running",
        "lastTurn" => nil,
        "activity" => "Thinking",
        "turns" => 2,
        "updatedAt" => 1_791_939_415_158,
        "result" => nil,
        "error" => nil
      },
      overrides
    )
  end

  defp response("omp.status", _params) do
    {:ok,
     %{
       "available" => true,
       "version" => "omp 14.2.0",
       "reason" => nil,
       "live" => 1,
       "maxSessions" => 4
     }}
  end

  defp response("omp.sessions.list", _params), do: {:ok, %{"sessions" => [session()]}}

  defp response("omp.sessions.get", %{"id" => "omp_3f9a1c2b7d4e"}) do
    {:ok, %{"session" => session(), "summary" => "omp_3f9a1c2b7d4e running\n\e[31mThinking\e[0m"}}
  end

  defp response("omp.sessions.discover", %{"cwd" => cwd}) do
    {:ok,
     %{
       "sessions" => [
         %{
           "ompSessionId" => "01a1",
           "title" => "Earlier work",
           "cwd" => cwd,
           "updatedAt" => 1_791_939_420_122,
           "lastStatus" => "completed",
           "activeElsewhere" => false,
           "liveId" => nil
         }
       ]
     }}
  end

  defp response(method, _params) when method in ["omp.sessions.start", "omp.sessions.resume"],
    do: {:ok, %{"session" => session()}}

  defp response("omp.sessions.send", %{"mode" => "followUp"}),
    do: {:ok, %{"accepted" => true, "delivery" => "followUp"}}

  defp response("omp.sessions.send", _params),
    do: {:ok, %{"accepted" => true, "delivery" => "steer"}}

  defp response("omp.sessions.cancel", _params), do: {:ok, %{"cancelled" => true}}

  defp response("omp.sessions.close", _params),
    do: {:ok, %{"session" => session(%{"status" => "closed"})}}
end

defmodule LemonCli.OmpCommandTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias LemonCli.CLI
  alias LemonCli.OmpCommandTestClient, as: Client

  @id "omp_3f9a1c2b7d4e"

  setup do
    previous_client = Application.get_env(:lemon_cli, :control_plane_client)
    previous_launcher = System.get_env("LEMON_LAUNCHER")
    Application.put_env(:lemon_cli, :control_plane_client, Client)
    System.delete_env("LEMON_LAUNCHER")

    on_exit(fn ->
      if previous_client,
        do: Application.put_env(:lemon_cli, :control_plane_client, previous_client),
        else: Application.delete_env(:lemon_cli, :control_plane_client)

      if previous_launcher, do: System.put_env("LEMON_LAUNCHER", previous_launcher)
    end)

    :ok
  end

  test "status reports availability, and not-installed guidance" do
    output = capture_io(fn -> assert CLI.run(["omp", "status"]) == 0 end)
    assert output =~ "omp: available (omp 14.2.0)"
    assert output =~ "Live sessions: 1/4"
    assert_received {:omp_request, "omp.status", %{}, [timeout_ms: 10_000]}

    Process.put(
      {:omp_response, "omp.status"},
      {:ok, %{"available" => false, "reason" => "not_installed", "live" => 0, "maxSessions" => 4}}
    )

    output = capture_io(fn -> assert CLI.run(["omp", "status"]) == 0 end)
    assert output =~ "omp: not installed"
    assert output =~ "LEMON_OMP_BIN"

    json = capture_io(fn -> assert CLI.run(["omp", "status", "--json"]) == 0 end)
    assert %{"available" => false, "reason" => "not_installed"} = Jason.decode!(json)
  end

  test "list shows live sessions by default and ended ones with --all" do
    output = capture_io(fn -> assert CLI.run(["omp", "list"]) == 0 end)
    assert output =~ ~r/ID\s+STATUS\s+TURNS\s+UPDATED\s+TITLE/
    assert output =~ ~r/#{@id}\s+running\s+2\s+\d\d:\d\d:\d\d\s+Fix the flaky test/
    assert_received {:omp_request, "omp.sessions.list", %{"includeEnded" => false}, _}

    capture_io(fn -> assert CLI.run(["omp"]) == 0 end)
    assert_received {:omp_request, "omp.sessions.list", %{"includeEnded" => false}, _}

    capture_io(fn -> assert CLI.run(["omp", "list", "--all", "--limit", "10"]) == 0 end)

    assert_received {:omp_request, "omp.sessions.list", %{"includeEnded" => true, "limit" => 10},
                     _}

    Process.put({:omp_response, "omp.sessions.list"}, {:ok, %{"sessions" => []}})
    output = capture_io(fn -> assert CLI.run(["omp", "list"]) == 0 end)
    assert output =~ "No live omp sessions"
  end

  test "show prints the bounded summary with terminal escapes removed" do
    output = capture_io(fn -> assert CLI.run(["omp", "show", @id]) == 0 end)
    assert output == "#{@id} running\nThinking\n"
    assert_received {:omp_request, "omp.sessions.get", %{"id" => @id}, _}

    json = capture_io(fn -> assert CLI.run(["omp", "show", @id, "--json"]) == 0 end)
    assert %{"session" => %{"id" => @id}, "summary" => _} = Jason.decode!(json)
  end

  test "discover defaults to the current directory and expands --cwd" do
    cwd = File.cwd!()
    output = capture_io(fn -> assert CLI.run(["omp", "discover"]) == 0 end)
    assert output =~ ~r/01a1\s+completed\s+2026-\S+\s+-\s+Earlier work/
    assert output =~ "lemon omp resume"
    assert_received {:omp_request, "omp.sessions.discover", %{"cwd" => ^cwd}, _}

    capture_io(fn ->
      assert CLI.run(["omp", "discover", "--cwd", "sub/dir", "--limit", "3"]) == 0
    end)

    expected = Path.expand("sub/dir")

    assert_received {:omp_request, "omp.sessions.discover", %{"cwd" => ^expected, "limit" => 3},
                     _}
  end

  test "start sends the joined prompt, workspace and options with a long timeout" do
    output =
      capture_io(fn ->
        assert CLI.run([
                 "omp",
                 "start",
                 "--cwd",
                 "/work/project",
                 "--model",
                 "deepseek/deepseek-v4-flash",
                 "--thinking",
                 "low",
                 "fix",
                 "the",
                 "flaky test"
               ]) == 0
      end)

    assert output =~ "Started omp session #{@id} (running) in /work/project"
    assert output =~ "lemon omp watch #{@id}"

    assert_received {:omp_request, "omp.sessions.start", params, [timeout_ms: 60_000]}

    assert params == %{
             "cwd" => "/work/project",
             "prompt" => "fix the flaky test",
             "model" => "deepseek/deepseek-v4-flash",
             "thinking" => "low"
           }
  end

  test "resume takes an omp session id and an optional prompt" do
    capture_io(fn -> assert CLI.run(["omp", "resume", "01a1", "--cwd", "/work"]) == 0 end)

    assert_received {:omp_request, "omp.sessions.resume",
                     %{"ompSessionId" => "01a1", "cwd" => "/work"} = params, _}

    refute Map.has_key?(params, "prompt")

    output =
      capture_io(fn -> assert CLI.run(["omp", "resume", "01a1", "keep", "going"]) == 0 end)

    assert output =~ "Resumed omp session"

    assert_received {:omp_request, "omp.sessions.resume",
                     %{"ompSessionId" => "01a1", "prompt" => "keep going"}, _}
  end

  test "send steers by default and queues with --follow-up" do
    output =
      capture_io(fn -> assert CLI.run(["omp", "send", @id, "focus", "on", "tests"]) == 0 end)

    assert output =~ "Delivered to #{@id} as steer."

    assert_received {:omp_request, "omp.sessions.send",
                     %{"id" => @id, "message" => "focus on tests", "mode" => "steer"},
                     [timeout_ms: 20_000]}

    output =
      capture_io(fn -> assert CLI.run(["omp", "send", @id, "--follow-up", "then docs"]) == 0 end)

    assert output =~ "as followUp."
    assert_received {:omp_request, "omp.sessions.send", %{"mode" => "followUp"}, _}
  end

  test "cancel and close report their result" do
    output = capture_io(fn -> assert CLI.run(["omp", "cancel", @id]) == 0 end)
    assert output =~ "Cancelled the running turn of #{@id}"
    assert_received {:omp_request, "omp.sessions.cancel", %{"id" => @id}, _}

    output = capture_io(fn -> assert CLI.run(["omp", "close", @id]) == 0 end)
    assert output =~ "Closed #{@id}"
    assert_received {:omp_request, "omp.sessions.close", %{"id" => @id}, _}
  end

  test "invalid arguments are usage errors and never reach the control plane" do
    for args <- [
          ["omp", "start"],
          ["omp", "start", "--cwd", "/work"],
          ["omp", "send", @id],
          ["omp", "send", @id, String.duplicate("a", 16_385)],
          ["omp", "show"],
          ["omp", "cancel", @id, "extra"],
          ["omp", "list", "--limit", "101"],
          ["omp", "list", "--bogus"],
          ["omp", "resume"],
          ["omp", "explode"]
        ] do
      error = capture_io(:stderr, fn -> assert CLI.run(args) == 2 end)
      assert error =~ "Usage: lemon omp"
    end

    refute_received {:omp_request, _, _, _}

    help = capture_io(fn -> assert CLI.run(["omp", "--help"]) == 0 end)
    assert help =~ "Usage: lemon omp <command>"
    assert help =~ "watch"
    assert help =~ "--follow-up"
  end

  test "control-plane errors exit 1 with a safe code and message" do
    Process.put(
      {:omp_response, "omp.sessions.cancel"},
      {:error,
       {:control_plane,
        %{
          "code" => "NOT_FOUND",
          "message" => "no such omp session.",
          "details" => %{"code" => "OMP_SESSION_NOT_FOUND"}
        }}}
    )

    error = capture_io(:stderr, fn -> assert CLI.run(["omp", "cancel", "omp_missing"]) == 1 end)
    assert error =~ "omp request failed [NOT_FOUND]: no such omp session."

    Process.put(
      {:omp_response, "omp.sessions.send"},
      {:error,
       {:control_plane,
        %{
          "code" => "UNAVAILABLE",
          "message" => "omp did not confirm the request in time.",
          "details" => %{"code" => "OMP_OUTCOME_UNKNOWN", "retrySafe" => false, "id" => @id}
        }}}
    )

    error = capture_io(:stderr, fn -> assert CLI.run(["omp", "send", @id, "hi"]) == 1 end)
    assert error =~ "[UNAVAILABLE]"
    assert error =~ "Not retry-safe: check `lemon omp show #{@id}`"

    error =
      capture_io(:stderr, fn -> assert CLI.run(["omp", "send", @id, "hi", "--json"]) == 1 end)

    assert %{
             "ok" => false,
             "error" => %{
               "code" => "UNAVAILABLE",
               "details" => %{"code" => "OMP_OUTCOME_UNKNOWN", "retrySafe" => false}
             }
           } = Jason.decode!(error)

    Process.put(
      {:omp_response, "omp.status"},
      {:error, {:control_plane_unavailable, :econnrefused}}
    )

    error = capture_io(:stderr, fn -> assert CLI.run(["omp", "status"]) == 1 end)
    assert error =~ "[CONTROL_PLANE_UNAVAILABLE]"
    refute error =~ "econnrefused"
  end

  test "watch follows events, polls when quiet, and stops at idle without cancelling" do
    running = Client.session(%{"activity" => "Thinking"})
    tool = Client.session(%{"activity" => "Running bash — Appending \e[2Jline"})

    idle =
      Client.session(%{
        "status" => "idle",
        "lastTurn" => "completed",
        "activity" => nil,
        "result" => "All tests pass."
      })

    Process.put(:omp_calls, [
      {:ok, %{"session" => running, "summary" => "s"}},
      {:ok, %{"session" => idle, "summary" => "s"}}
    ])

    Process.put(:omp_events, [
      {:ok,
       %{
         "event" => "omp.session",
         "payload" => %{
           "reason" => "updated",
           "session" => Client.session(%{"id" => "omp_other"})
         }
       }},
      {:ok, %{"event" => "agent", "payload" => %{}}},
      {:ok,
       %{"event" => "omp.session", "payload" => %{"reason" => "updated", "session" => tool}}},
      {:ok,
       %{"event" => "omp.session", "payload" => %{"reason" => "updated", "session" => tool}}},
      {:error, :control_plane_timeout}
    ])

    {output, error} =
      with_stderr(fn -> assert CLI.run(["omp", "watch", @id]) == 0 end)

    assert error =~ "Ctrl-C stops watching without cancelling"

    lines = String.split(output, "\n", trim: true)

    assert [
             "[" <> running_line,
             "[" <> tool_line,
             "[" <> idle_line,
             "Turn completed.",
             "All tests pass."
           ] = lines

    assert running_line =~ "] running — Thinking"
    assert tool_line =~ "] running — Running bash — Appending line"
    assert idle_line =~ "] idle"

    assert_received :omp_open
    assert_received {:omp_call, "omp.sessions.get", %{"id" => @id}}
    assert_received {:omp_next_event, 2_000}
    assert_received :omp_closed
    refute_received {:omp_request, "omp.sessions.cancel", _, _}
  end

  test "watch exits at once for a settled session and reports a missing one" do
    Process.put(:omp_calls, [
      {:ok, %{"session" => Client.session(%{"status" => "closed", "error" => "boom"})}}
    ])

    output = capture_io(fn -> assert CLI.run(["omp", "watch", @id, "--json"]) == 0 end)
    assert [snapshot] = String.split(output, "\n", trim: true)
    assert %{"status" => "closed"} = Jason.decode!(snapshot)
    refute_received {:omp_next_event, _}

    Process.put(:omp_calls, [
      {:error, %{"code" => "NOT_FOUND", "message" => "no such omp session."}}
    ])

    error = capture_io(:stderr, fn -> assert CLI.run(["omp", "watch", "omp_missing"]) == 1 end)
    assert error =~ "[NOT_FOUND]"
  end

  defp with_stderr(fun) do
    parent = self()

    error =
      capture_io(:stderr, fn ->
        send(parent, {:stdout, capture_io(fun)})
      end)

    assert_received {:stdout, output}
    {output, error}
  end
end

defmodule LemonCli.OmpCommandWireTest do
  # End to end: the real `LemonCli.ControlPlaneClient` against the control
  # plane's WebSocket, driving a fake `omp` executable (never the real one).
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias LemonCli.CLI

  @fake_omp Path.expand("../../../lemon_control_plane/test/support/fake_omp", __DIR__)
  @omp_env_keys [:executable, :agent_dir, :command_timeout_ms]

  setup do
    suffix = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "lemon-omp-cli-#{suffix}")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)
    File.mkdir_p!(Path.join(root, "agent"))

    system_keys = ~w(LEMON_CONTROL_PLANE_PORT LEMON_CONTROL_PLANE_OPERATOR_TOKEN LEMON_WS_TOKEN
                     LEMON_LAUNCHER LEMON_OMP_BIN)

    previous_system = Map.new(system_keys, &{&1, System.get_env(&1)})
    cp_keys = [:operator_token, :allow_unauthenticated_loopback_operator]
    previous_cp = Map.new(cp_keys, &{&1, Application.get_env(:lemon_control_plane, &1)})
    previous_omp = Map.new(@omp_env_keys, &{&1, Application.get_env(:lemon_omp, &1)})
    previous_client = Application.get_env(:lemon_cli, :control_plane_client)

    token = "omp-cli-wire-operator"
    Application.put_env(:lemon_control_plane, :operator_token, token)
    Application.put_env(:lemon_control_plane, :allow_unauthenticated_loopback_operator, false)
    Application.put_env(:lemon_omp, :executable, @fake_omp)
    Application.put_env(:lemon_omp, :agent_dir, Path.join(root, "agent"))
    Application.put_env(:lemon_omp, :command_timeout_ms, 2_000)
    Application.delete_env(:lemon_cli, :control_plane_client)

    bandit =
      start_supervised!(
        Supervisor.child_spec(
          {Bandit,
           plug: LemonControlPlane.HTTP.Router, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
          id: {:omp_cli_wire, suffix}
        )
      )

    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(bandit)
    System.put_env("LEMON_CONTROL_PLANE_PORT", Integer.to_string(port))
    System.put_env("LEMON_CONTROL_PLANE_OPERATOR_TOKEN", token)
    Enum.each(~w(LEMON_WS_TOKEN LEMON_LAUNCHER LEMON_OMP_BIN), &System.delete_env/1)

    on_exit(fn ->
      for session <- LemonOmp.list(include_ended: false, limit: 100) do
        LemonOmp.close(session["id"])
      end

      restore(previous_system, &System.delete_env/1, &System.put_env/2)

      restore(
        previous_cp,
        &Application.delete_env(:lemon_control_plane, &1),
        &Application.put_env(:lemon_control_plane, &1, &2)
      )

      restore(
        previous_omp,
        &Application.delete_env(:lemon_omp, &1),
        &Application.put_env(:lemon_omp, &1, &2)
      )

      if previous_client,
        do: Application.put_env(:lemon_cli, :control_plane_client, previous_client)

      File.rm_rf!(root)
    end)

    {:ok, workspace: workspace}
  end

  test "start, watch, follow up, close and fail closed over the real control plane",
       %{workspace: workspace} do
    status = run_json(["omp", "status", "--json"])
    assert %{"available" => true, "version" => "omp 9.9.9-test"} = status

    started = run_json(["omp", "start", "--cwd", workspace, "--json", "HOLD", "the", "turn"])
    assert %{"session" => %{"id" => id, "owner" => %{"kind" => "operator"}}} = started

    # Something else ends the turn while the CLI is watching it.
    cancel = Task.async(fn -> Process.sleep(300) && LemonOmp.cancel(id) end)

    output =
      capture_io(:stderr, fn ->
        send(self(), {:watch, capture_io(fn -> assert CLI.run(["omp", "watch", id]) == 0 end)})
      end)

    assert output =~ "Ctrl-C stops watching"
    assert_received {:watch, watched}
    assert watched =~ "running"
    assert watched =~ "Turn aborted."
    assert {:ok, %{"cancelled" => true}} = Task.await(cancel)

    sent = capture_io(fn -> assert CLI.run(["omp", "send", id, "--follow-up", "again"]) == 0 end)
    assert sent =~ "Delivered to #{id} as prompt."

    shown = capture_io(fn -> assert CLI.run(["omp", "show", id]) == 0 end)
    assert shown =~ id

    listed = capture_io(fn -> assert CLI.run(["omp", "list"]) == 0 end)
    assert listed =~ id

    closed = capture_io(fn -> assert CLI.run(["omp", "close", id]) == 0 end)
    assert closed =~ "Closed #{id}"

    error = capture_io(:stderr, fn -> assert CLI.run(["omp", "send", id, "late"]) == 1 end)
    assert error =~ "[CONFLICT]"
    assert error =~ "no longer running"

    error =
      capture_io(:stderr, fn -> assert CLI.run(["omp", "show", "omp_000000000000"]) == 1 end)

    assert error =~ "[NOT_FOUND]"
  end

  defp run_json(argv) do
    output = capture_io(fn -> assert CLI.run(argv) == 0 end)
    Jason.decode!(output)
  end

  defp restore(previous, delete, put) do
    Enum.each(previous, fn
      {key, nil} -> delete.(key)
      {key, value} -> put.(key, value)
    end)
  end
end
