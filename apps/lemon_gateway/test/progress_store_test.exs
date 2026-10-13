defmodule LemonGateway.ProgressStoreTest do
  use ExUnit.Case, async: false

  alias LemonCore.Store
  alias LemonCore.Store.EtsBackend
  alias LemonCore.Store.ReadCache
  alias LemonGateway.ProgressStore

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

  test "the running gateway mirrors progress mappings into the default store's read cache" do
    {:ok, _} = Application.ensure_all_started(:lemon_gateway)
    scope = {:progress_store_cache_test, System.unique_integer([:positive])}

    assert ProgressStore.table() in ReadCache.cached_domains(Store)

    :ok = ProgressStore.put(scope, 7, "run_cached")
    assert ReadCache.get(Store, ProgressStore.table(), {scope, 7}) == "run_cached"

    :ok = ProgressStore.delete(scope, 7)
    assert ReadCache.get(Store, ProgressStore.table(), {scope, 7}) == nil
  end

  test "mappings written to one store instance are not visible in another" do
    alpha = start_store(:"progress_store_alpha_#{System.unique_integer([:positive])}")
    beta = start_store(:"progress_store_beta_#{System.unique_integer([:positive])}")
    scope = {:progress_store_instance_test, :progress}

    assert :ok = ProgressStore.put(alpha, scope, 42, "run_alpha")
    assert ProgressStore.get_run(alpha, scope, 42) == "run_alpha"
    assert ProgressStore.get_run(beta, scope, 42) == nil
  end

  defp start_store(name) do
    spec = Supervisor.child_spec({Store, name: name, backend: EtsBackend}, id: name)
    start_supervised!(spec)
    name
  end
end
