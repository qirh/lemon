defmodule LemonWeb.Live.Components.Payload do
  @moduledoc false

  # Tool arguments and approval actions are shown to whoever holds the browser
  # tab, so values under credential-looking keys are masked before display.
  @secret_markers ["token", "secret", "password", "api_key", "apikey", "credential", "cookie"]

  @doc "Read `key` as an atom or string key without collapsing `false` to `nil`."
  @spec fetch(term(), atom()) :: term()
  def fetch(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  def fetch(_map, _key), do: nil

  @doc "Mask values stored under credential-looking keys, recursively."
  @spec redact(term()) :: term()
  def redact(%_{} = struct), do: struct

  def redact(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      if secret_key?(key), do: {key, "[redacted]"}, else: {key, redact(value)}
    end)
  end

  def redact(list) when is_list(list), do: Enum.map(list, &redact/1)
  def redact(value), do: value

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

  defp secret_key?(key) do
    normalized = key |> to_string() |> String.downcase()
    Enum.any?(@secret_markers, &String.contains?(normalized, &1))
  end
end
