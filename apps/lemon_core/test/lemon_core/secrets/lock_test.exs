defmodule LemonCore.Secrets.LockTest do
  # Uses the global Store's lock table.
  use ExUnit.Case, async: false

  alias LemonCore.Secrets.Lock
  alias LemonCore.Store

  setup do
    case Store.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

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

  test "a lease whose holder died is reclaimed" do
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
end
