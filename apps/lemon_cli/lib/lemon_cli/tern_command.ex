defmodule LemonCli.TernCommand do
  @moduledoc """
  Registers the invoking Lemon launcher in Tern's custom stdio ACP agents.
  Unrelated preferences and custom agents are preserved.
  """

  def run(["install" | args]) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [config_dir: :string])

    if rest != [] or invalid != [] do
      usage()
    else
      with {:ok, directory} <- config_directory(opts),
           {:ok, launcher} <- launcher(),
           :ok <- install(directory, launcher) do
        IO.puts(
          "Registered Lemon in Tern. Open a new Tern shell and type `lemon`, or run `tern acp lemon`."
        )

        0
      else
        {:error, message} ->
          IO.puts(:stderr, "Error: " <> message)
          1
      end
    end
  end

  def run(_args), do: usage()

  @doc false
  def install(directory, launcher) do
    path = Path.join(directory, "settings.json")

    with {:ok, settings} <- settings(path),
         {:ok, settings} <- register(settings, launcher),
         :ok <- File.mkdir_p(directory) do
      temporary = path <> ".lemon-" <> Integer.to_string(System.unique_integer([:positive]))

      try do
        with :ok <-
               File.write(temporary, Jason.encode!(settings, pretty: true) <> "\n", [:exclusive]),
             :ok <- File.rename(temporary, path) do
          :ok
        else
          _ ->
            {:error,
             "Could not write Tern settings; check the configuration directory permissions."}
        end
      after
        File.rm(temporary)
      end
    else
      {:error, message} when is_binary(message) -> {:error, message}
      _ -> {:error, "Could not create the Tern configuration directory."}
    end
  end

  defp register(settings, launcher) do
    agents = Map.get(settings, "agents", %{})
    custom = if is_map(agents), do: Map.get(agents, "custom", []), else: nil

    if is_list(custom) and Enum.all?(custom, &is_map/1) do
      lemon = %{
        "id" => "lemon",
        "name" => "Lemon",
        "command" => launcher,
        "args" => ["acp"],
        "env" => %{}
      }

      custom = Enum.reject(custom, &(&1["id"] == "lemon")) ++ [lemon]

      {:ok,
       Map.put(
         settings,
         "agents",
         agents |> Map.put("custom", custom) |> Map.put("auto_acp", true)
       )}
    else
      {:error, "Tern agents.custom must be an array; settings were not changed."}
    end
  end

  defp settings(path) do
    case File.read(path) do
      {:ok, encoded} ->
        case Jason.decode(encoded) do
          {:ok, settings} when is_map(settings) -> {:ok, settings}
          _ -> {:error, "Tern settings.json is not a JSON object; settings were not changed."}
        end

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, _reason} ->
        {:error, "Could not read Tern settings.json; settings were not changed."}
    end
  end

  defp config_directory(opts) do
    case Keyword.get(opts, :config_dir) || System.get_env("TERN_CONFIG_DIR") do
      directory when is_binary(directory) and directory != "" ->
        {:ok, Path.expand(directory)}

      _ ->
        case System.find_executable("tern") do
          nil ->
            {:error, "Tern is not on PATH. Install Tern or pass --config-dir PATH."}

          tern ->
            case System.cmd(tern, ["plugin", "dir"], stderr_to_stdout: true) do
              {directory, 0} -> {:ok, directory |> String.trim() |> Path.dirname()}
              _ -> {:error, "Could not locate Tern configuration; pass --config-dir PATH."}
            end
        end
    end
  end

  defp launcher do
    case System.get_env("LEMON_LAUNCHER") || System.find_executable("lemon") do
      path when is_binary(path) and path != "" -> {:ok, Path.expand(path)}
      _ -> {:error, "Run install through the Lemon launcher (`lemon tern install`)."}
    end
  end

  defp usage do
    IO.puts(:stderr, "usage: lemon tern install [--config-dir PATH]")
    2
  end
end
