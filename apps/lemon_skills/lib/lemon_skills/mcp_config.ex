defmodule LemonSkills.McpConfig do
  @moduledoc """
  Named MCP configuration management. Mutations preserve unrelated JSON fields,
  serialize cooperating writers across VMs, and atomically replace private files.
  Reads never cache configuration; new sessions discover the next saved version.
  """

  alias LemonSkills.Config

  @spec path(keyword()) :: String.t()
  def path(opts \\ []) do
    if opts[:global],
      do: Config.global_mcp_config_file(),
      else: Config.project_mcp_config_file(Keyword.get(opts, :cwd, File.cwd!()))
  end

  def list(opts \\ []) do
    with {:ok, document, _original} <- load(path(opts)) do
      {:ok, Enum.map(Map.get(document, "servers", []), &summary/1)}
    end
  end

  def fetch(name, opts \\ []) do
    with {:ok, document, _original} <- load(path(opts)) do
      case Enum.filter(Map.get(document, "servers", []), &(&1["name"] == name)) do
        [entry] -> {:ok, entry}
        [] -> {:error, :not_found}
        _ -> {:error, :duplicate_name}
      end
    end
  end

  def add(entry, opts \\ []) do
    if valid_entry?(entry) do
      mutate(opts, fn document ->
        servers = Map.get(document, "servers", [])
        matches = Enum.filter(servers, &(&1["name"] == entry["name"]))

        case {matches, opts[:replace] == true} do
          {[], _} ->
            {:ok, Map.put(document, "servers", servers ++ [entry])}

          {[_], true} ->
            updated =
              Enum.map(servers, fn old ->
                if old["name"] == entry["name"], do: replace_entry(old, entry), else: old
              end)

            {:ok, Map.put(document, "servers", updated)}

          _ ->
            {:error, :duplicate_name}
        end
      end)
    else
      {:error, :invalid_entry}
    end
  end

  def remove(name, opts \\ []) do
    mutate(opts, fn document ->
      servers = Map.get(document, "servers", [])

      case Enum.count(servers, &(&1["name"] == name)) do
        0 -> {:error, :not_found}
        1 -> {:ok, Map.put(document, "servers", Enum.reject(servers, &(&1["name"] == name)))}
        _ -> {:error, :duplicate_name}
      end
    end)
  end

  def valid_name?(name),
    do: is_binary(name) and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_.-]{0,63}\z/, name)

  def valid_entry?(entry) when is_map(entry) do
    valid_name?(entry["name"]) and entry["approval"] in ["always", "never"] and
      Config.validate_mcp_metadata(
        name: entry["name"],
        approval: entry["approval"],
        tool_approvals: Map.get(entry, "tool_approvals", %{})
      ) == :ok and valid_transport?(entry)
  end

  def valid_entry?(_), do: false

  defp valid_transport?(%{"type" => "stdio", "command" => command} = entry) do
    is_binary(command) and String.trim(command) != "" and
      is_list(entry["args"]) and Enum.all?(entry["args"], &is_binary/1) and
      valid_pairs?(Map.get(entry, "env", %{}), fn key, value ->
        key != "" and not String.contains?(key, ["=", <<0>>]) and
          not String.contains?(value, <<0>>)
      end)
  end

  defp valid_transport?(%{"type" => "http", "url" => url} = entry) when is_binary(url) do
    uri = URI.parse(url)

    uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
      valid_pairs?(Map.get(entry, "headers", %{}), fn key, value ->
        key != "" and not String.contains?(key <> value, ["\r", "\n", <<0>>])
      end)
  end

  defp valid_transport?(_), do: false

  defp valid_pairs?(pairs, validator) when is_map(pairs) do
    Enum.all?(pairs, fn {key, value} ->
      is_binary(key) and is_binary(value) and validator.(key, value)
    end)
  end

  defp valid_pairs?(_, _), do: false

  defp summary(entry) do
    %{
      "name" => if(valid_name?(entry["name"]), do: entry["name"], else: nil),
      "type" => if(entry["type"] in ["stdio", "http", "sse"], do: entry["type"], else: "unknown"),
      "approval" =>
        case entry["approval"] do
          nil -> "never"
          value when value in ["always", "never"] -> value
          _ -> "invalid"
        end,
      "tool_approval_count" => map_size_safe(entry["tool_approvals"]),
      "environment_count" => map_size_safe(entry["env"]),
      "header_count" => map_size_safe(entry["headers"])
    }
  end

  defp map_size_safe(value) when is_map(value), do: map_size(value)
  defp map_size_safe(_), do: 0

  # Retain unknown extensions and same-transport credentials unless explicitly
  # supplied. On transport changes remove only obsolete transport-specific keys.
  defp replace_entry(old, entry) do
    old =
      if old["type"] == entry["type"] do
        old
      else
        Map.drop(old, ["command", "args", "env", "cwd", "url", "headers", "oauth"])
      end

    Map.merge(old, entry, fn key, previous, replacement ->
      if key in ["env", "headers", "tool_approvals"] and is_map(previous) and is_map(replacement),
        do: Map.merge(previous, replacement),
        else: replacement
    end)
  end

  defp load(path) do
    case File.read(path) do
      {:ok, bytes} ->
        case Jason.decode(bytes) do
          {:ok, document} when is_map(document) ->
            servers = Map.get(document, "servers", [])

            if is_list(servers) and Enum.all?(servers, &is_map/1),
              do: {:ok, document, bytes},
              else: {:error, :invalid_config}

          _ ->
            {:error, :invalid_config}
        end

      {:error, :enoent} ->
        {:ok, %{}, nil}

      {:error, _} ->
        {:error, :read_failed}
    end
  end

  defp mutate(opts, update) do
    path = path(opts)
    lock = path <> ".lock"

    with :ok <- make_parent(path), :ok <- acquire_lock(lock) do
      try do
        with {:ok, document, original} <- load(path),
             {:ok, updated} <- update.(document) do
          save(path, updated, original)
        end
      after
        File.rmdir(lock)
      end
    end
  end

  defp make_parent(path) do
    case File.mkdir_p(Path.dirname(path)) do
      :ok -> :ok
      _ -> {:error, :write_failed}
    end
  end

  defp acquire_lock(lock) do
    case File.mkdir(lock) do
      :ok -> :ok
      {:error, :eexist} -> {:error, :busy}
      _ -> {:error, :write_failed}
    end
  end

  defp save(path, document, original) do
    temp = path <> ".tmp." <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    try do
      with :ok <- write_private(temp, Jason.encode!(document, pretty: true) <> "\n"),
           :ok <- unchanged(path, original),
           :ok <- File.rename(temp, path) do
        :ok
      else
        {:error, :changed} -> {:error, :changed}
        _ -> {:error, :write_failed}
      end
    after
      File.rm(temp)
    end
  end

  defp write_private(path, bytes) do
    case File.open(path, [:write, :binary, :exclusive]) do
      {:ok, io} ->
        try do
          with :ok <- File.chmod(path, 0o600),
               :ok <- IO.binwrite(io, bytes),
               :ok <- :file.sync(io),
               do: :ok
        after
          File.close(io)
        end

      error ->
        error
    end
  end

  defp unchanged(path, original) do
    case {File.read(path), original} do
      {{:error, :enoent}, nil} -> :ok
      {{:ok, bytes}, bytes} -> :ok
      _ -> {:error, :changed}
    end
  end
end
