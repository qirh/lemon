defmodule LemonCore.Secrets.LockTest do
  # Uses the global Store's lock table.
  use ExUnit.Case, async: false

  alias LemonCore.Secrets.Lock
  alias LemonCore.Store

  @table :secrets_lock
  @key :secrets

  setup do
    case Store.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    Store.delete(@table, @key)
    on_exit(fn -> Store.delete(@table, @key) end)
    :ok
  end

  test "holders are mutually exclusive" do
    test_pid = self()

    holder =
      spawn(fn ->
        Lock.with_rotation_lock(fn ->
          send(test_pid, :holding)

          receive do
            :release -> :ok
          end
        end)

        send(test_pid, :released)
      end)

    assert_receive :holding
    waiter = Task.async(fn -> Lock.with_write_lock(fn -> :written end) end)
    assert Task.yield(waiter, 200) == nil

    send(holder, :release)
    assert_receive :released
    assert Task.await(waiter) == :written
  end

  test "a lease whose BEAM holder died is reclaimed" do
    test_pid = self()

    holder =
      spawn(fn ->
        Lock.with_rotation_lock(fn ->
          send(test_pid, :holding)
          Process.sleep(:infinity)
        end)
      end)

    assert_receive :holding
    Process.exit(holder, :kill)

    assert Lock.with_write_lock(fn -> :written end) == :written
  end

  test "a lease whose OS process on this host exited is reclaimed" do
    {pid, 0} = System.cmd("sh", ["-c", "echo $$"])
    :ok = Store.put(@table, @key, lease(os_pid: String.trim(pid)))

    assert Lock.with_write_lock(fn -> :written end) == :written
  end

  test "a live holder is never reclaimed, however long it holds the lease" do
    # pid 1 always exists; `kill -0` reports it as not permitted, i.e. alive.
    held = lease(os_pid: "1")
    :ok = Store.put(@table, @key, held)

    assert Lock.with_rotation_lock(fn -> flunk("acquired a live holder's lease") end) ==
             {:error, :secrets_locked}

    assert Store.get(@table, @key) == held
  end

  test "a lease from another host is reported, never reclaimed" do
    held = lease(host: "some-other-host", os_pid: "999999")
    :ok = Store.put(@table, @key, held)

    assert Lock.with_rotation_lock(fn -> flunk("acquired a foreign lease") end) ==
             {:error, {:secrets_lock_held, "some-other-host"}}

    assert Store.get(@table, @key) == held
  end

  defp lease(overrides) do
    {:ok, host} = :inet.gethostname()

    Map.merge(
      %{owner: "test", host: List.to_string(host), os_pid: "0", holder: "<0.0.0>"},
      Map.new(overrides)
    )
  end
end
