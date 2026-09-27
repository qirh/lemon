defmodule LemonCore.ChatStateStoreTest do
  use ExUnit.Case, async: false

  alias LemonCore.{ChatState, ChatStateStore, Store}
  alias LemonCore.Store.EtsBackend

  @day_ms 24 * 60 * 60 * 1000

  defp start_store(name) do
    spec = Supervisor.child_spec({Store, name: name, backend: EtsBackend}, id: name)
    start_supervised!(spec)
    name
  end

  test "round-trips chat state stamped with a 24h expiry" do
    key = "agent:test:main:#{System.unique_integer([:positive])}"
    value = %{last_engine: "codex", last_resume_token: "thread_123"}

    before_put = System.system_time(:millisecond)
    assert :ok = ChatStateStore.put(key, value)
    after_put = System.system_time(:millisecond)

    # Reads served from the mirror and from the backend have the same shape:
    # the value plus the stamped `:expires_at`.
    assert %{last_engine: "codex", last_resume_token: "thread_123", expires_at: expires_at} =
             ChatStateStore.get(key)

    assert %{expires_at: ^expires_at} = Store.get(:chat, key)
    assert expires_at >= before_put + @day_ms
    assert expires_at <= after_put + @day_ms

    assert :ok = ChatStateStore.delete(key)
    assert ChatStateStore.get(key) == nil
  end

  test "keeps ChatState structs intact while stamping the expiry" do
    store = start_store(:chat_state_store_struct)
    scope = {:chat_state_store_test, :struct}

    :ok =
      ChatStateStore.put(store, scope, %ChatState{
        last_engine: "codex",
        last_resume_token: "thread-1"
      })

    assert %ChatState{
             last_engine: "codex",
             last_resume_token: "thread-1",
             expires_at: expires_at
           } = ChatStateStore.get(store, scope)

    assert is_integer(expires_at)
  end

  test "an expired entry reads as absent and is deleted" do
    store = start_store(:chat_state_store_lazy_expiry)
    scope = {:chat_state_store_test, :lazy_expiry}

    :ok =
      Store.put(store, :chat, scope, %{
        phase: :stale,
        expires_at: System.system_time(:millisecond) - 1
      })

    assert ChatStateStore.get(store, scope) == nil
    assert Store.get(store, :chat, scope) == nil
  end
end
