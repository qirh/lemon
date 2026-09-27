defmodule LemonCore.PolicyStore do
  @moduledoc """
  Agent, channel, session, and runtime policy persistence.

  Each scope has its own durable table (`:agent_policies`,
  `:channel_policies`, `:session_policies`); the operator's global runtime
  override lives under the `:global` key of `:runtime_policy`.
  """

  alias LemonCore.Store

  @agent_table :agent_policies
  @channel_table :channel_policies
  @session_table :session_policies
  @runtime_table :runtime_policy
  @runtime_key :global

  @doc "Fetches the policy for the given agent, or `nil` if not set."
  @spec get_agent(binary()) :: map() | nil
  def get_agent(agent_id), do: Store.get(@agent_table, agent_id)

  @doc "Stores a policy for the given agent."
  @spec put_agent(binary(), map()) :: :ok | {:error, term()}
  def put_agent(agent_id, policy), do: Store.put(@agent_table, agent_id, policy)

  @doc "Fetches the policy for the given channel, or `nil` if not set."
  @spec get_channel(binary()) :: map() | nil
  def get_channel(channel_id), do: Store.get(@channel_table, channel_id)

  @doc "Stores a policy for the given channel."
  @spec put_channel(binary(), map()) :: :ok | {:error, term()}
  def put_channel(channel_id, policy), do: Store.put(@channel_table, channel_id, policy)

  @doc "Fetches the policy for the given session, or `nil` if not set."
  @spec get_session(binary()) :: map() | nil
  def get_session(session_key), do: Store.get(@session_table, session_key)

  @doc "Stores a policy for the given session."
  @spec put_session(binary(), map()) :: :ok | {:error, term()}
  def put_session(session_key, policy), do: Store.put(@session_table, session_key, policy)

  @doc "Deletes the policy for the given session."
  @spec delete_session(binary()) :: :ok | {:error, term()}
  def delete_session(session_key), do: Store.delete(@session_table, session_key)

  @doc "Fetches the runtime policy, or `nil` if not set."
  @spec get_runtime() :: map() | nil
  def get_runtime, do: Store.get(@runtime_table, @runtime_key)

  @doc "Stores the runtime policy."
  @spec put_runtime(map()) :: :ok | {:error, term()}
  def put_runtime(policy), do: Store.put(@runtime_table, @runtime_key, policy)

  @doc "Deletes the runtime policy."
  @spec delete_runtime() :: :ok | {:error, term()}
  def delete_runtime, do: Store.delete(@runtime_table, @runtime_key)
end
