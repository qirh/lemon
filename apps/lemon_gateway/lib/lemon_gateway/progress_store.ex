defmodule LemonGateway.ProgressStore do
  @moduledoc """
  Progress-message to run mapping, keyed by `{scope, progress_msg_id}` in the
  generic `:progress` store table.

  Gateway registers the table with `LemonCore.Store.register_cached_table/2`
  at boot, so lookups are served from the store's read cache without a store
  round trip.
  """

  alias LemonCore.Store

  @table :progress

  @doc "The generic store table backing progress mappings."
  @spec table() :: atom()
  def table, do: @table

  @spec put(Store.server(), term(), integer() | binary(), binary()) :: :ok | {:error, term()}
  def put(server \\ Store, scope, progress_msg_id, run_id),
    do: Store.put(server, @table, {scope, progress_msg_id}, run_id)

  @spec get_run(Store.server(), term(), integer() | binary()) :: binary() | nil
  def get_run(server \\ Store, scope, progress_msg_id),
    do: Store.get(server, @table, {scope, progress_msg_id})

  @spec delete(Store.server(), term(), integer() | binary()) :: :ok | {:error, term()}
  def delete(server \\ Store, scope, progress_msg_id),
    do: Store.delete(server, @table, {scope, progress_msg_id})
end
