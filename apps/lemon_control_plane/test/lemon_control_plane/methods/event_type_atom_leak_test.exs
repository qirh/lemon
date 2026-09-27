defmodule LemonControlPlane.Methods.EventTypeAtomLeakTest do
  # This test measures global atom table growth and is sensitive to concurrent
  # test activity. Keep it synchronous to avoid flakiness.
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.ConfigGet

  @admin_ctx %{conn_id: "test-conn", auth: %{role: :operator}}

  test "ConfigGet does not create atoms from arbitrary keys" do
    atom_count_before = :erlang.system_info(:atom_count)

    for i <- 1..100 do
      params = %{"key" => "config_key_#{i}_#{:rand.uniform(1_000_000)}"}
      ConfigGet.handle(params, @admin_ctx)
    end

    atom_count_after = :erlang.system_info(:atom_count)

    assert atom_count_after - atom_count_before < 50
  end
end
