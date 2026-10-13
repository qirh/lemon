defmodule CodingAgent.Tools.ReadArchive do
  @moduledoc false

  require Record
  Record.defrecordp(:zip_file, Record.extract(:zip_file, from_lib: "stdlib/include/zip.hrl"))
  Record.defrecordp(:file_info, Record.extract(:file_info, from_lib: "kernel/include/file.hrl"))

  alias CodingAgent.Tools.{ReadFormats, ReadFormatText}
  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.ImageContent
  import LemonAgent.Tools.AbortHelpers, only: [check_abort: 1]

  @suffix ~r/\.(?:zip|tar|tar\.gz|tgz)$/i
  @member_path ~r/^(.*?\.(?:zip|tar\.gz|tgz|tar)):(.*)$/i

  def archive?(path), do: Regex.match?(@suffix, path)

  def split_path(path) do
    case Regex.run(@member_path, path, capture: :all_but_first) do
      [archive, member] -> {archive, member}
      _ -> nil
    end
  end

  def read(path, member, params, signal, opts) do
    with :ok <- ReadFormats.check_input(path, opts),
         :ok <- check_abort(signal),
         {:ok, entries} <- entries(path),
         :ok <- check_abort(signal) do
      source = if member == "", do: path, else: path <> ":" <> member
      entry = Enum.find(entries, &(&1.name == member))
      prefix = String.trim_trailing(member, "/") <> "/"

      cond do
        member == "" ->
          listing(entries, path, source, params, signal, opts)

        entry && entry.type == :regular ->
          read_member(path, entry, source, params, signal, opts)

        (entry && entry.type == :directory) ||
            Enum.any?(entries, &String.starts_with?(&1.name, prefix)) ->
          entries
          |> Enum.filter(&String.starts_with?(&1.name, prefix))
          |> listing(path, source, params, signal, opts)

        entry ->
          {:error,
           "Archive member #{source} is #{entry.type}, not a regular file. Links are not followed."}

        true ->
          {:error,
           "Archive member not found: #{source}. Read #{path} to list exact member names."}
      end
    end
  rescue
    error -> {:error, "Cannot read archive #{path}: #{Exception.message(error)}"}
  end

  defp entries(path) do
    if zip?(path) do
      case :zip.list_dir(String.to_charlist(path)) do
        {:ok, records} ->
          entries =
            for zip_file(name: name, info: info) <- records do
              %{
                name: List.to_string(name),
                type: file_info(info, :type),
                size: file_info(info, :size)
              }
            end

          {:ok, Enum.sort_by(entries, & &1.name)}

        {:error, reason} ->
          {:error, "Cannot list ZIP: #{inspect(reason)}"}
      end
    else
      case :erl_tar.table(String.to_charlist(path), [:verbose | tar_options(path)]) do
        {:ok, records} ->
          entries =
            Enum.map(records, fn {name, type, size, _mtime, _mode, _uid, _gid} ->
              %{name: List.to_string(name), type: type, size: size}
            end)

          {:ok, Enum.sort_by(entries, & &1.name)}

        {:error, reason} ->
          {:error, "Cannot list TAR: #{inspect(reason)}"}
      end
    end
  end

  defp listing(entries, archive, source, params, signal, opts) do
    text =
      if entries == [] do
        "(empty archive directory)"
      else
        Enum.map_join(entries, "\n", fn entry ->
          suffix =
            if entry.type == :directory and not String.ends_with?(entry.name, "/"),
              do: "/",
              else: ""

          "#{entry.name}#{suffix}\t#{entry.type}\t#{entry.size} bytes"
        end)
      end

    ReadFormatText.result(text, source, params, signal, opts, %{
      format: :archive,
      archive_path: archive,
      is_directory: true,
      total_entries: length(entries),
      immutable: true
    })
  end

  defp read_member(path, entry, source, params, signal, opts) do
    max_bytes = Keyword.get(opts, :format_max_member_bytes, 32 * 1024 * 1024)

    if entry.size > max_bytes do
      {:error,
       "Member #{source} is #{entry.size} bytes, exceeding the #{max_bytes}-byte decoded-member limit. Use a streaming archive CLI or raise :format_max_member_bytes."}
    else
      with {:ok, bytes} <- extract_memory(path, entry.name),
           :ok <- check_abort(signal) do
        if byte_size(bytes) > max_bytes do
          {:error, "Decoded member exceeds the #{max_bytes}-byte limit: #{source}"}
        else
          details = %{
            format: :archive_member,
            archive_path: path,
            member: entry.name,
            immutable: true,
            size: byte_size(bytes)
          }

          member_result(bytes, source, params, signal, opts, details)
        end
      end
    end
  end

  defp extract_memory(path, member) do
    name = String.to_charlist(member)

    result =
      if zip?(path) do
        :zip.extract(String.to_charlist(path), [:memory, {:file_list, [name]}])
      else
        :erl_tar.extract(String.to_charlist(path), [:memory, {:files, [name]} | tar_options(path)])
      end

    case result do
      {:ok, [{_name, bytes}]} when is_binary(bytes) -> {:ok, bytes}
      {:ok, []} -> {:error, "Archive backend did not return member #{member}"}
      {:ok, _} -> {:error, "Archive member #{member} is ambiguous (duplicate entries)"}
      {:error, reason} -> {:error, "Cannot read archive member #{member}: #{inspect(reason)}"}
    end
  end

  defp member_result(bytes, source, params, signal, opts, details) do
    mime =
      case String.downcase(Path.extname(source)) do
        ".png" -> "image/png"
        ".jpg" -> "image/jpeg"
        ".jpeg" -> "image/jpeg"
        ".gif" -> "image/gif"
        ".webp" -> "image/webp"
        _ -> nil
      end

    cond do
      mime && byte_size(bytes) <= 20 * 1024 * 1024 ->
        {:ok,
         %AgentToolResult{
           content: [%ImageContent{data: Base.encode64(bytes), mime_type: mime}],
           details:
             Map.merge(details, %{
               path: source,
               source_path: source,
               full_source: source,
               mime_type: mime
             })
         }}

      mime ->
        {:error,
         "Image member exceeds the 20 MiB image limit: #{source}. Resize externally before reading."}

      true ->
        case ReadFormatText.result(bytes, source, params, signal, opts, details) do
          {:error, reason} ->
            {:error,
             "#{reason} Full member source: #{source}; use an archive CLI for binary inspection."}

          result ->
            result
        end
    end
  end

  defp zip?(path), do: String.downcase(Path.extname(path)) == ".zip"

  defp tar_options(path) do
    if String.ends_with?(String.downcase(path), [".tar.gz", ".tgz"]), do: [:compressed], else: []
  end
end
