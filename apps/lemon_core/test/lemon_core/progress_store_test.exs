defmodule LemonCore.ProgressStoreTest do
  use ExUnit.Case, async: false

  alias LemonCore.{ProgressStore, Store}

  test "stores, overwrites, isolates by scope, and deletes mappings" do
    token = System.unique_integer([:positive])
    scope_a = {:progress_store_test, token, :a}
    scope_b = {:progress_store_test, token, :b}
    progress_msg_id = 42_001

    assert ProgressStore.get_run(scope_a, progress_msg_id) == nil

    :ok = ProgressStore.put(scope_a, progress_msg_id, "run_a_v1")
    :ok = ProgressStore.put(scope_b, progress_msg_id, "run_b_v1")

    assert ProgressStore.get_run(scope_a, progress_msg_id) == "run_a_v1"
    assert ProgressStore.get_run(scope_b, progress_msg_id) == "run_b_v1"

    :ok = ProgressStore.put(scope_a, progress_msg_id, "run_a_v2")
    assert ProgressStore.get_run(scope_a, progress_msg_id) == "run_a_v2"
    # Persisted under `{scope, progress_msg_id}` in `:progress`.
    assert Store.get(:progress, {scope_a, progress_msg_id}) == "run_a_v2"

    :ok = ProgressStore.delete(scope_a, progress_msg_id)

    assert ProgressStore.get_run(scope_a, progress_msg_id) == nil
    assert Store.get(:progress, {scope_a, progress_msg_id}) == nil
    assert ProgressStore.get_run(scope_b, progress_msg_id) == "run_b_v1"
  end
end
