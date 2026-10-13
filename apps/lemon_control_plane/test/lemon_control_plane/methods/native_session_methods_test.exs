defmodule LemonControlPlane.Methods.NativeSessionMethodsTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Auth.Authorize

  alias LemonControlPlane.Methods.{
    Registry,
    SessionsFork,
    SessionsList,
    SessionsMetadataPatch,
    SessionsRewind,
    SessionsTree
  }

  alias LemonCore.{RunStore, SessionKey, SessionLifecycle, SessionMetadataStore}

  defmodule Provider do
    @behaviour LemonControlPlane.AgentRuntime.Provider

    @impl true
    def session_tree(key, cwd, opts) do
      send(self(), {:tree, key, cwd, opts})
      Process.get(:tree_result)
    end

    @impl true
    def session_rewind(key, cwd, entry, opts) do
      send(self(), {:rewind, key, cwd, entry, opts})
      Process.get(:rewind_result)
    end

    @impl true
    def session_fork(key, cwd, destination) do
      send(self(), {:fork, key, cwd, destination})
      Process.get(:fork_result, :ok)
    end

    @impl true
    def session_history(key, cwd) do
      send(self(), {:history, key, cwd})
      Process.get(:history_result, {:error, :session_not_found})
    end
  end

  setup do
    original = Application.get_env(:lemon_control_plane, :agent_runtime_provider)
    Application.put_env(:lemon_control_plane, :agent_runtime_provider, Provider)

    on_exit(fn ->
      if original,
        do: Application.put_env(:lemon_control_plane, :agent_runtime_provider, original),
        else: Application.delete_env(:lemon_control_plane, :agent_runtime_provider)
    end)

    if Process.whereis(Registry) == nil, do: start_supervised!(Registry)
    :ok
  end

  test "registered tree delegates pagination and projects only native tree fields" do
    entry = %{
      "id" => "u1",
      "parentId" => nil,
      "type" => "message",
      "role" => "user",
      "text" => "hello",
      "timestamp" => 1,
      "isActive" => true,
      "isLeaf" => true,
      "rewindable" => true,
      "raw" => "private"
    }

    Process.put(
      :tree_result,
      {:ok,
       %{
         "sessionId" => "native",
         "leafId" => "u1",
         "entries" => [entry],
         "branches" => [%{"leafId" => "u1", "active" => true}],
         "totalEntries" => 1,
         "offset" => 0,
         "hasMore" => false,
         "private" => "hidden"
       }}
    )

    assert {:ok, tree} = Registry.dispatch("sessions.tree", target(), ctx([:read]))
    assert_receive {:tree, "agent:native_methods:main", "/workspace", [limit: 100, offset: 0]}
    assert tree["entries"] == [Map.delete(entry, "raw")]
    assert tree["sessionKey"] == target()["sessionKey"]
    refute Map.has_key?(tree, "private")
    assert tree["branches"] == [%{"leafId" => "u1", "active" => true}]

    assert {:ok, _} =
             SessionsTree.handle(Map.merge(target(), %{"limit" => 5, "offset" => 9}), %{})

    assert_receive {:tree, _, _, [limit: 5, offset: 9]}
  end

  test "tree and rewind reject unbounded or malformed parameters before delegation" do
    for {field, value} <- [
          {"sessionKey", String.duplicate("x", 1025)},
          {"cwd", ""},
          {"cwd", String.duplicate("x", 4097)},
          {"limit", 501},
          {"offset", -1}
        ] do
      assert {:error, {:invalid_params, _, nil}} =
               SessionsTree.handle(Map.put(target(), field, value), %{})
    end

    for {field, value} <- [
          {"entryId", String.duplicate("x", 257)},
          {"restoreFiles", "false"},
          {"dryRun", nil},
          {"confirmationToken", ""},
          {"confirmationToken", String.duplicate("x", 257)}
        ] do
      assert {:error, {:invalid_params, _, nil}} =
               SessionsRewind.handle(Map.put(rewind_target(), field, value), %{})
    end

    refute_received {:tree, _, _, _}
    refute_received {:rewind, _, _, _, _}
  end

  test "rewind defaults to preview and requires a bounded confirmation for execution" do
    preview = %{
      "confirmationToken" => "preview-token",
      "prompt" => "edit this",
      "discardedMessages" => 2,
      "restorePaths" => [],
      "unrestorableTools" => [],
      "entryId" => "u1",
      "sessionId" => "native"
    }

    Process.put(:rewind_result, {:ok, Map.put(preview, "private", "hidden")})

    preview = Map.put(preview, "sessionKey", target()["sessionKey"])
    assert {:ok, ^preview} = Registry.dispatch("sessions.rewind", rewind_target(), ctx([:write]))

    assert_receive {:rewind, _, _, "u1",
                    [restore_files: false, dry_run: true, confirmation_token: nil]}

    execute = Map.put(rewind_target(), "dryRun", false)

    assert {:error, {:conflict, _, %{"reason" => "confirmation_required"}}} =
             SessionsRewind.handle(execute, %{})

    refute_received {:rewind, _, _, _, _}

    Process.put(:rewind_result, {:error, :stale_confirmation})

    assert {:error, {:conflict, _, %{"reason" => "stale_confirmation"}}} =
             SessionsRewind.handle(Map.put(execute, "confirmationToken", "stale"), %{})

    assert_receive {:rewind, _, _, "u1",
                    [restore_files: false, dry_run: false, confirmation_token: "stale"]}

    result = %{
      "prompt" => "edit this",
      "leafId" => "previous",
      "restoredPaths" => ["a.txt"],
      "entryId" => "u1",
      "sessionId" => "native"
    }

    Process.put(:rewind_result, {:ok, result})
    result = Map.put(result, "sessionKey", target()["sessionKey"])

    assert {:ok, ^result} =
             SessionsRewind.handle(
               Map.merge(
                 execute,
                 %{"confirmationToken" => "preview-token", "restoreFiles" => true}
               ),
               %{}
             )

    assert_receive {:rewind, _, _, _,
                    [restore_files: true, dry_run: false, confirmation_token: "preview-token"]}
  end

  test "read scope cannot mutate native sessions and errors never echo arbitrary reasons" do
    assert Authorize.required_scopes("sessions.tree") == [:read]
    assert Authorize.required_scopes("sessions.rewind") == [:write]
    assert Authorize.required_scopes("sessions.fork") == [:write]

    for {method, params} <- [{"sessions.rewind", rewind_target()}, {"sessions.fork", target()}] do
      assert {:error, {:forbidden, _}} = Registry.dispatch(method, params, ctx([:read]))
    end

    Process.put(:tree_result, {:error, {:file_error, "/private/token=secret"}})
    assert {:error, {:internal_error, _, nil}} = SessionsTree.handle(target(), %{})
    Process.put(:rewind_result, {:error, :checkpoint_scope_mismatch})

    assert {:error, {:conflict, _, %{"reason" => "checkpoint_scope_mismatch"}}} =
             SessionsRewind.handle(rewind_target(), %{})
  end

  test "fork creates an independent discoverable zero-run child supporting existing naming and search" do
    assert {:ok, %{"sessionKey" => child, "sourceSessionKey" => source}} =
             Registry.dispatch("sessions.fork", target(), ctx([:write]))

    on_exit(fn -> SessionLifecycle.delete(child) end)

    assert source == target()["sessionKey"]
    assert_receive {:fork, ^source, "/workspace", ^child}
    assert child != source
    assert SessionKey.valid?(child)
    assert SessionKey.agent_id(child) == "native_methods"
    assert SessionMetadataStore.fetch(child).title == nil
    assert RunStore.history(child) == []

    assert {:ok, listed} = SessionsList.handle(%{"query" => child}, %{})
    assert [%{"sessionKey" => ^child, "runCount" => 0}] = listed["sessions"]

    title = "Fork naming #{System.unique_integer([:positive, :monotonic])}"

    assert {:ok, _} =
             SessionsMetadataPatch.handle(%{"sessionKey" => child, "title" => title}, %{})

    assert {:ok, named} = SessionsList.handle(%{"query" => String.upcase(title)}, %{})
    assert [%{"sessionKey" => ^child, "title" => ^title}] = named["sessions"]

    assert {:ok, _} = SessionsMetadataPatch.handle(%{"sessionKey" => child, "title" => nil}, %{})
    assert {:ok, cleared} = SessionsList.handle(%{"query" => title}, %{})
    assert cleared["sessions"] == []
  end

  test "plain TUI session keys fork with their durable source agent identity" do
    source = "tui-#{System.unique_integer([:positive])}"
    assert :ok = RunStore.create_session_index(source, "native_methods", :tui)
    on_exit(fn -> SessionLifecycle.delete(source) end)

    assert {:ok, %{"sessionKey" => child, "sourceSessionKey" => ^source}} =
             SessionsFork.handle(Map.put(target(), "sessionKey", source), %{})

    on_exit(fn -> SessionLifecycle.delete(child) end)
    assert_receive {:fork, ^source, "/workspace", ^child}
    assert SessionKey.agent_id(child) == "native_methods"
    assert SessionLifecycle.get(child).agent_id == "native_methods"
  end

  test "unknown plain keys do not fork under a guessed default agent" do
    assert {:error, {:not_found, _, %{"reason" => "session_not_found"}}} =
             SessionsFork.handle(Map.put(target(), "sessionKey", "tui-unknown-source"), %{})

    refute_received {:fork, _, _, _}
  end

  test "uncertain forks retain their generated identity and disallow automatic retries" do
    Process.put(:fork_result, {:error, :outcome_unknown})

    assert {:error, {:unavailable, _, %{"sessionKey" => child, "retrySafe" => false}}} =
             SessionsFork.handle(target(), %{})

    assert_receive {:fork, _, _, ^child}
    assert SessionKey.valid?(child)
    assert SessionLifecycle.get(child) == nil
  end

  test "native history is authoritative after rewind, including an empty active branch" do
    key = "agent:history_rewind_#{System.unique_integer([:positive])}:main"
    params = Map.put(target(), "sessionKey", key)
    on_exit(fn -> SessionLifecycle.delete(key) end)

    assert :ok =
             RunStore.finalize("history-run-#{key}", %{
               session_key: key,
               agent_id: SessionKey.agent_id(key),
               origin: :control_plane,
               prompt: "abandoned prompt",
               completed: %{ok: true, answer: "abandoned answer"}
             })

    assert eventually(fn -> RunStore.history(key, limit: 1) != [] end)

    entries = [
      %{type: :model_change, id: "model", timestamp: 1},
      %{
        type: :message,
        id: "u1",
        timestamp: 2,
        message: %{"role" => "user", "content" => "retained prompt"}
      },
      %{
        type: :message,
        id: "a1",
        timestamp: 3,
        message: %{
          "role" => "assistant",
          "content" => [
            %{"type" => "thinking", "thinking" => "private thought"},
            %{"type" => "text", "text" => "retained answer"}
          ]
        }
      },
      %{
        type: :message,
        id: "tool",
        timestamp: 4,
        message: %{"role" => "tool_result", "content" => "private tool result"}
      }
    ]

    Process.put(:history_result, {:ok, entries})
    assert {:ok, before_rewind} = Registry.dispatch("chat.history", params, ctx([:read]))
    assert Enum.map(before_rewind["messages"], & &1["id"]) == ["u1", "a1"]

    assert Enum.map(before_rewind["messages"], & &1["content"]) ==
             ["retained prompt", "retained answer"]

    refute inspect(before_rewind) =~ "private"
    refute inspect(before_rewind) =~ "abandoned"
    assert_receive {:history, ^key, "/workspace"}

    assert {:ok, page} =
             Registry.dispatch("chat.history", Map.put(params, "limit", 1), ctx([:read]))

    assert [%{"id" => "a1", "timestampMs" => 3}] = page["messages"]

    assert {:ok, after_user} =
             Registry.dispatch("chat.history", Map.put(params, "beforeId", "u1"), ctx([:read]))

    assert [%{"id" => "a1"}] = after_user["messages"]

    Process.put(
      :rewind_result,
      {:ok,
       %{
         "prompt" => "retained prompt",
         "leafId" => nil,
         "restoredPaths" => [],
         "entryId" => "u1",
         "sessionId" => "native"
       }}
    )

    assert {:ok, _} =
             SessionsRewind.handle(
               Map.merge(
                 params,
                 %{"entryId" => "u1", "dryRun" => false, "confirmationToken" => "valid"}
               ),
               %{}
             )

    Process.put(:history_result, {:ok, []})
    assert {:ok, rewound} = Registry.dispatch("chat.history", params, ctx([:read]))
    assert rewound["messages"] == []

    Process.put(:history_result, {:error, :session_store_unavailable})

    assert {:error, {:unavailable, _, _}} =
             Registry.dispatch("chat.history", params, ctx([:read]))

    Process.put(:history_result, {:error, :session_not_found})
    assert {:ok, legacy} = Registry.dispatch("chat.history", params, ctx([:read]))
    assert Enum.any?(legacy["messages"], &(&1["content"] == "abandoned prompt"))
  end

  test "native history previews redact text without exposing thought or tool blocks" do
    content = "api_key=history-secret " <> String.duplicate("x", 600)

    Process.put(
      :history_result,
      {:ok,
       [
         %{
           type: :message,
           id: "u",
           timestamp: 1,
           message: %{"role" => "user", "content" => content}
         }
       ]}
    )

    assert {:ok, history} =
             Registry.dispatch(
               "chat.history",
               Map.put(target(), "includeFullText", false),
               ctx([:read])
             )

    assert [%{"truncated" => true, "content" => preview}] = history["messages"]
    refute preview =~ "history-secret"
    assert String.length(preview) <= 503
  end

  defp eventually(fun, attempts \\ 100)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false

  defp target, do: %{"sessionKey" => "agent:native_methods:main", "cwd" => "/workspace"}
  defp rewind_target, do: Map.put(target(), "entryId", "u1")
  defp ctx(scopes), do: %{auth: %{role: :operator, scopes: scopes}}
end
