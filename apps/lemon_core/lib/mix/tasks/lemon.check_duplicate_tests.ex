defmodule Mix.Tasks.Lemon.CheckDuplicateTests do
  use Mix.Task

  @shortdoc "Check for duplicate test module names"
  @ignored_dirs MapSet.new([
                  ".elixir_ls",
                  ".expert",
                  ".git",
                  ".worktrees",
                  "_build",
                  "cover",
                  "deps",
                  "node_modules",
                  "tmp"
                ])

  @moduledoc """
  Scans test files for duplicate literal module declarations, resolving nested
  names against their enclosing module and respecting absolute `Elixir` names.

  Usage:
    mix lemon.check_duplicate_tests
    mix lemon.check_duplicate_tests --root /path/to/repo
  """

  @impl true
  def run(args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        switches: [root: :string],
        aliases: [r: :root]
      )

    root = opts[:root] || File.cwd!()

    duplicates =
      root
      |> test_files()
      |> Enum.flat_map(&module_occurrences(root, &1))
      |> Enum.group_by(fn {module_name, _path} -> module_name end, fn {_module_name, path} ->
        path
      end)
      |> Enum.filter(fn {_module_name, paths} -> length(paths) > 1 end)
      |> Enum.sort_by(fn {module_name, _paths} -> module_name end)

    if duplicates == [] do
      Mix.shell().info("[ok] duplicate test module check passed")
    else
      details =
        Enum.map_join(duplicates, "\n", fn {module_name, paths} ->
          "  - #{module_name}: #{Enum.join(Enum.sort(paths), ", ")}"
        end)

      Mix.raise("Duplicate test modules found:\n#{details}")
    end
  end

  defp module_occurrences(root, file) do
    with {:ok, source} <- File.read(file),
         {:ok, ast} <- Code.string_to_quoted(source) do
      collect_modules(ast, [], Path.relative_to(file, root), [])
    else
      _ -> []
    end
  end

  defp collect_modules({:defmodule, _, [name, [do: body]]}, namespace, path, modules) do
    case module_parts(name, namespace) do
      nil ->
        modules

      parts ->
        collect_modules(body, parts, path, [{Enum.join(parts, "."), path} | modules])
    end
  end

  defp collect_modules({_form, _metadata, args}, namespace, path, modules) when is_list(args),
    do: collect_modules(args, namespace, path, modules)

  defp collect_modules({_key, value}, namespace, path, modules),
    do: collect_modules(value, namespace, path, modules)

  defp collect_modules(nodes, namespace, path, modules) when is_list(nodes),
    do: Enum.reduce(nodes, modules, &collect_modules(&1, namespace, path, &2))

  defp collect_modules(_node, _namespace, _path, modules), do: modules

  defp module_parts({:__aliases__, _, [:"Elixir" | parts]}, _namespace), do: parts

  defp module_parts({:__aliases__, _, [{:__MODULE__, _, _} | parts]}, namespace),
    do: namespace ++ parts

  defp module_parts({:__aliases__, _, parts}, namespace), do: namespace ++ parts
  defp module_parts({:__MODULE__, _, _}, namespace), do: namespace

  defp module_parts(name, _namespace) when is_atom(name),
    do: name |> Atom.to_string() |> String.trim_leading("Elixir.") |> String.split(".")

  defp module_parts(_dynamic, _namespace), do: nil

  defp test_files(root) do
    root
    |> Path.join("apps")
    |> walk_test_files(root)
    |> Enum.uniq()
  end

  defp walk_test_files(dir, root) do
    if ignored_path?(root, dir) do
      []
    else
      case File.ls(dir) do
        {:ok, entries} ->
          Enum.flat_map(entries, fn entry ->
            path = Path.join(dir, entry)

            cond do
              ignored_path?(root, path) ->
                []

              symlink?(path) ->
                []

              File.dir?(path) ->
                walk_test_files(path, root)

              String.ends_with?(path, "_test.exs") ->
                [path]

              true ->
                []
            end
          end)

        {:error, _} ->
          []
      end
    end
  end

  defp ignored_path?(root, path) do
    path
    |> Path.relative_to(root)
    |> Path.split()
    |> Enum.any?(&MapSet.member?(@ignored_dirs, &1))
  end

  defp symlink?(path), do: match?({:ok, %File.Stat{type: :symlink}}, File.lstat(path))
end
