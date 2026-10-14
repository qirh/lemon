defmodule LemonWeb.SessionCwd do
  @moduledoc """
  Resolves the workspace directory of an existing session.

  Native-session RPCs (`chat.history` with `cwd`, `sessions.fork`,
  `sessions.plan`, `sessions.context`, `sessions.compact`) need the session's
  workspace. A coding-agent session records it in its `:session_started`
  introspection event; a session that never ran resolves to the runtime's
  default workspace for operator-initiated runs (`LemonCore.Cwd.default_cwd/0`),
  which is also what `chat.send` uses when no `cwd` is given.

  The value is an operator workspace path: show it only on operator chat
  surfaces, never in logs or management projections.
  """

  alias LemonCore.Introspection

  @doc "The workspace recorded by the session's latest start, if any."
  @spec recorded(String.t()) :: {:ok, String.t()} | :error
  def recorded(session_key) when is_binary(session_key) and session_key != "" do
    case Introspection.list(session_key: session_key, event_type: :session_started, limit: 1) do
      [event | _] ->
        case event |> field(:payload) |> field(:cwd) do
          cwd when is_binary(cwd) and cwd != "" -> {:ok, cwd}
          _ -> :error
        end

      _ ->
        :error
    end
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end

  def recorded(_session_key), do: :error

  @doc "The recorded workspace, else the default workspace for operator runs."
  @spec resolve(String.t()) :: String.t()
  def resolve(session_key) do
    case recorded(session_key) do
      {:ok, cwd} -> cwd
      :error -> default()
    end
  end

  @doc "Default workspace for operator-initiated runs."
  @spec default() :: String.t()
  def default do
    LemonCore.Cwd.default_cwd()
  rescue
    _ -> File.cwd!()
  end

  defp field(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp field(_value, _key), do: nil
end
