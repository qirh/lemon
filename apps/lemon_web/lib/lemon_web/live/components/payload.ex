defmodule LemonWeb.Live.Components.Payload do
  @moduledoc false

  @doc "Read `key` as an atom or string key without collapsing `false` to `nil`."
  @spec fetch(term(), atom()) :: term()
  def fetch(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  def fetch(_map, _key), do: nil

  @doc "Format a payload for a `<pre>` block; empty values become `nil`."
  @spec format(term()) :: String.t() | nil
  def format(nil), do: nil
  def format(""), do: nil
  def format(value) when is_binary(value), do: value
  def format(value) when value == %{} or value == [], do: nil

  def format(value) when is_map(value) or is_list(value) do
    case Jason.encode(value, pretty: true) do
      {:ok, encoded} -> encoded
      {:error, _reason} -> inspect(value, pretty: true, limit: 50)
    end
  rescue
    Protocol.UndefinedError -> inspect(value, pretty: true, limit: 50)
  end

  def format(value), do: inspect(value, pretty: true, limit: 50)
end
