defmodule LemonCore.ChatStateStore do
  @moduledoc """
  Per-scope chat-state persistence in the `:chat` table.

  Every write stamps `:expires_at` 24 hours ahead. Reads treat an expired
  entry as absent and delete it; `LemonCore.Store`'s periodic sweep removes
  expired entries nobody reads again. `:chat` is in the store's default
  read-cache set, so reads are served from ETS without a store round trip.
  """

  alias LemonCore.ChatState
  alias LemonCore.Store

  @table :chat
  @ttl_ms 24 * 60 * 60 * 1000

  @doc """
  Fetch the chat state for `scope`, or `nil` when absent or expired.

  An expired entry is deleted only if it is still the value that was read, so
  a concurrent `put/3` that refreshed the scope is never lost.
  """
  @spec get(Store.server(), term()) :: ChatState.t() | map() | nil
  def get(server \\ Store, scope) do
    case Store.get(server, @table, scope) do
      %{expires_at: expires_at} = value when is_integer(expires_at) ->
        if System.system_time(:millisecond) > expires_at do
          _ = Store.compare_and_delete(server, @table, scope, value)
          nil
        else
          value
        end

      value ->
        value
    end
  end

  @doc """
  Store `state` for `scope`, stamped with a fresh `:expires_at`.

  Synchronous: once this returns `:ok`, reads observe the new value.
  """
  @spec put(Store.server(), term(), ChatState.t() | map()) :: :ok | {:error, term()}
  def put(server \\ Store, scope, state) when is_map(state) do
    Store.put(server, @table, scope, stamp_expiry(state))
  end

  @spec delete(Store.server(), term()) :: :ok | {:error, term()}
  def delete(server \\ Store, scope), do: Store.delete(server, @table, scope)

  # Works for plain maps and `LemonCore.ChatState` structs alike.
  defp stamp_expiry(state) do
    expires_at = System.system_time(:millisecond) + @ttl_ms

    case state do
      %{__struct__: _} = struct -> %{struct | expires_at: expires_at}
      map -> Map.put(map, :expires_at, expires_at)
    end
  end
end
