defmodule LemonCore.Secrets.Lock do
  @moduledoc """
  Exclusive lease that serialises secret writes with master-key rotation.

  `LemonCore.Secrets.set/3` holds it from resolving the master key until the
  record is stored, and `LemonCore.Secrets.KeyRotation.rotate/2` holds it for
  the whole rotation, so no write can be encrypted under a key that a rotation
  is about to retire, and two rotations never interleave.

  The lease is a record in the `:secrets_lock` Store table created with
  `LemonCore.Store.put_new/4`. With the SQLite backend that insert is atomic
  across every OS process sharing the store file, so a `lemon secrets set` in
  one terminal and a rotation in another exclude each other. A lease whose
  holder has exited (its OS process, or its BEAM process when the holder lives
  in this VM) or whose expiry has passed is reclaimed with an atomic
  compare-and-delete.
  """

  alias LemonCore.Clock
  alias LemonCore.Store

  @table :secrets_lock
  @key :secrets
  @poll_ms 25

  @write_lease_ms 60_000
  @write_wait_ms 30_000
  @rotation_lease_ms 3_600_000
  @rotation_wait_ms 5_000

  @type error :: {:error, :secrets_locked | {:store_failed, term()}}

  @doc "Runs `fun` while holding the lock for one secret write."
  @spec with_write_lock((-> result)) :: result | error() when result: term()
  def with_write_lock(fun), do: with_lock(@write_lease_ms, @write_wait_ms, fun)

  @doc "Runs `fun` while holding the lock for a master-key rotation."
  @spec with_rotation_lock((-> result)) :: result | error() when result: term()
  def with_rotation_lock(fun), do: with_lock(@rotation_lease_ms, @rotation_wait_ms, fun)

  defp with_lock(lease_ms, wait_ms, fun) do
    case acquire(lease_ms, System.monotonic_time(:millisecond) + wait_ms) do
      {:ok, lease} ->
        try do
          fun.()
        after
          release(lease)
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp acquire(lease_ms, deadline) do
    lease = %{
      owner: Base.encode16(:crypto.strong_rand_bytes(12), case: :lower),
      os_pid: System.pid(),
      holder: self() |> :erlang.pid_to_list() |> List.to_string(),
      expires_at_ms: Clock.now_ms() + lease_ms
    }

    case Store.put_new(@table, @key, lease) do
      :ok -> {:ok, lease}
      {:error, :exists} -> contended(lease_ms, deadline)
      {:error, reason} -> {:error, {:store_failed, reason}}
    end
  end

  defp contended(lease_ms, deadline) do
    case Store.fetch(@table, @key) do
      {:ok, nil} ->
        acquire(lease_ms, deadline)

      {:ok, holder} ->
        if stale?(holder) do
          case Store.compare_and_delete_many([{@table, @key, holder}]) do
            :ok -> acquire(lease_ms, deadline)
            {:error, :mismatch} -> retry(lease_ms, deadline)
            {:error, reason} -> {:error, {:store_failed, reason}}
          end
        else
          retry(lease_ms, deadline)
        end

      {:error, reason} ->
        {:error, {:store_failed, reason}}
    end
  end

  defp retry(lease_ms, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, :secrets_locked}
    else
      Process.sleep(@poll_ms)
      acquire(lease_ms, deadline)
    end
  end

  defp release(lease), do: Store.compare_and_delete_many([{@table, @key, lease}])

  defp stale?(%{os_pid: os_pid, holder: holder, expires_at_ms: expires_at_ms}) do
    expires_at_ms <= Clock.now_ms() or
      if os_pid == System.pid(),
        do: not local_holder_alive?(holder),
        else: not os_process_alive?(os_pid)
  end

  defp stale?(_malformed), do: true

  defp local_holder_alive?(holder) do
    holder |> String.to_charlist() |> :erlang.list_to_pid() |> Process.alive?()
  rescue
    ArgumentError -> false
  end

  # `kill -0` probes without signalling. EPERM means the process exists but
  # belongs to someone else; anything undeterminable counts as alive, leaving
  # the lease to its expiry.
  defp os_process_alive?(os_pid) do
    case System.cmd("kill", ["-0", to_string(os_pid)], stderr_to_stdout: true) do
      {_output, 0} -> true
      {output, _status} -> output =~ ~r/not permitted/i
    end
  rescue
    _error -> true
  end
end
