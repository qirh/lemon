defmodule LemonCore.ProgressStore do
  @moduledoc """
  Progress-message to run mapping, keyed by `{scope, progress_msg_id}` in the
  `:progress` table. `:progress` is in the store's default read-cache set, so
  lookups are served from ETS without a store round trip.
  """

  alias LemonCore.Store

  @table :progress

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
