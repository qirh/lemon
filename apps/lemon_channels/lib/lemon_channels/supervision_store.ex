defmodule LemonChannels.SupervisionStore do
  @moduledoc """
  Channels-owned durable run bindings and terminal-notice intents.

  Reads preserve store failures, and all mutations compare exact snapshots. Keys
  are hashed so generic store diagnostics never contain session or notice text.
  Durability follows the configured `LemonCore.Store` backend.
  """

  alias LemonCore.Store

  @bindings :channels_supervision_bindings
  @notices :channels_supervision_notices

  @type identity ::
          {:goal | :kanban | :cron, binary(), binary(), :completed | :failed | :cancelled}
  @type binding :: %{session_key: binary(), target: LemonChannels.Supervision.target()}
  @type delivery_state ::
          :pending | :submitting | :queued | :delivered | :failed | :unknown | :rejected
  @type notice :: %{
          identity: identity(),
          target: LemonChannels.Supervision.target(),
          text: binary(),
          delivery_state: delivery_state(),
          attempts: non_neg_integer(),
          reason: atom() | nil,
          updated_at_ms: integer()
        }

  @spec binding(Store.server(), binary()) :: {:ok, binding() | nil} | {:error, atom()}
  def binding(store, run_id), do: Store.fetch(store, @bindings, key(run_id))

  @spec bind(Store.server(), binary(), binding()) :: :ok | {:error, atom()}
  def bind(store, run_id, binding) do
    case Store.compare_and_swap(store, @bindings, key(run_id), nil, binding) do
      :ok ->
        :ok

      {:error, :mismatch} ->
        case binding(store, run_id) do
          {:ok, ^binding} -> :ok
          {:ok, _} -> {:error, :binding_conflict}
          _ -> {:error, :store_unavailable}
        end

      _ ->
        {:error, :store_unavailable}
    end
  end

  @spec notice(Store.server(), identity()) :: {:ok, notice() | nil} | {:error, atom()}
  def notice(store, identity), do: Store.fetch(store, @notices, key(identity))

  @spec replace_notice(Store.server(), identity(), notice() | nil, notice()) ::
          :ok | {:error, atom()}
  def replace_notice(store, identity, expected, replacement) do
    case Store.compare_and_swap(store, @notices, key(identity), expected, replacement) do
      :ok -> :ok
      {:error, :mismatch} -> {:error, :mismatch}
      _ -> {:error, :store_unavailable}
    end
  end

  @spec notices(Store.server()) :: {:ok, [notice()]} | {:error, atom()}
  def notices(store) do
    case Store.fetch_all(store, @notices) do
      {:ok, entries} -> {:ok, Enum.map(entries, fn {_key, record} -> record end)}
      _ -> {:error, :store_unavailable}
    end
  end

  defp key(value), do: :crypto.hash(:sha256, :erlang.term_to_binary(value)) |> Base.encode16()
end
