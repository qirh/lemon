defmodule LemonWeb.Chat.Uploads do
  @moduledoc """
  Composer attachments.

  One submission convention: everything is sent with `chat.send`. Images
  (PNG/JPEG/GIF/WebP, at most five and 10 MiB decoded, the `chat.send` image
  limits) travel inline as `images`; any other file is saved to the managed
  upload directory and its path is appended to the prompt so the agent can
  read it with its file tools. The transcript only ever shows file names.

  Upload limits: 5 entries, 20 MB each (`allow/1`). Callers must check
  readiness and `in_progress?/1` before `consume/1`.
  """

  import Phoenix.LiveView, only: [allow_upload: 3, consume_uploaded_entries: 3]

  @image_types ~w(image/png image/jpeg image/gif image/webp)
  @max_entries 5
  @max_file_size 20_000_000
  @max_image_bytes 10_485_760

  def max_entries, do: @max_entries
  def max_file_size, do: @max_file_size

  @doc "Registers the `:files` upload on `socket`."
  def allow(socket) do
    allow_upload(socket, :files,
      accept: :any,
      max_entries: @max_entries,
      max_file_size: @max_file_size,
      auto_upload: true
    )
  end

  def entries?(socket), do: socket.assigns.uploads.files.entries != []

  def in_progress?(socket),
    do: Enum.any?(socket.assigns.uploads.files.entries, &(not &1.done?))

  def image?(entry), do: entry.client_type in @image_types

  @doc """
  Consumes every finished entry. Returns `{:ok, %{images: [...], files: [...]}}`
  where files are `%{name, path}` or `{:error, message}` with safe text.
  """
  def consume(socket) do
    case Application.get_env(:lemon_web, :upload_persist_fun) do
      fun when is_function(fun, 1) -> fun.(socket)
      _ -> do_consume(socket)
    end
  end

  defp do_consume(socket) do
    entries = socket.assigns.uploads.files.entries
    image_bytes = entries |> Enum.filter(&image?/1) |> Enum.map(& &1.client_size) |> Enum.sum()

    if image_bytes > @max_image_bytes do
      {:error, "Images can total at most 10 MB per message. Remove an image and try again."}
    else
      root = upload_root()

      case File.mkdir_p(root) do
        :ok -> {:ok, collect(consume_entries(socket, root))}
        {:error, _} -> {:error, "Upload failed: the upload directory is not writable."}
      end
      |> case do
        {:ok, %{failed: []} = result} -> {:ok, Map.delete(result, :failed)}
        {:ok, %{failed: names}} -> {:error, "Upload failed: " <> Enum.join(names, ", ")}
        error -> error
      end
    end
  end

  defp consume_entries(socket, root) do
    consume_uploaded_entries(socket, :files, fn %{path: path}, entry ->
      name = entry.client_name || "upload"

      if image?(entry) do
        case File.read(path) do
          {:ok, data} ->
            {:ok,
             {:image, name,
              %{"type" => "image", "mime_type" => entry.client_type, "data" => Base.encode64(data)}}}

          {:error, _} ->
            {:ok, {:failed, name}}
        end
      else
        destination =
          Path.join(root, "#{System.system_time(:millisecond)}-#{entry.uuid}-#{sanitize(name)}")

        case File.cp(path, destination) do
          :ok -> {:ok, {:file, name, destination}}
          {:error, _} -> {:ok, {:failed, name}}
        end
      end
    end)
  end

  defp collect(results) do
    Enum.reduce(results, %{images: [], image_names: [], files: [], failed: []}, fn
      {:image, name, image}, acc -> %{acc | images: acc.images ++ [image], image_names: acc.image_names ++ [name]}
      {:file, name, path}, acc -> %{acc | files: acc.files ++ [%{name: name, path: path}]}
      {:failed, name}, acc -> %{acc | failed: acc.failed ++ [name]}
    end)
  end

  @doc "Prompt text sent to the agent: the message plus saved file paths."
  def submission_prompt(prompt, %{files: []} = attachments) do
    if prompt == "" and attachments.images != [], do: "Describe the attached image(s).", else: prompt
  end

  def submission_prompt(prompt, %{files: files}) do
    listing = Enum.map_join(files, "\n", &"- #{&1.path}")

    if prompt == "",
      do: "Process these uploaded files:\n" <> listing,
      else: prompt <> "\n\nUploaded files:\n" <> listing
  end

  @doc "Display names for the transcript (never managed paths)."
  def display_names(attachments),
    do: Map.get(attachments, :image_names, []) ++ Enum.map(attachments.files, & &1.name)

  def error_text(:too_large), do: "File is larger than 20 MB."
  def error_text(:too_many_files), do: "At most 5 files per message."
  def error_text(:not_accepted), do: "That file type is not accepted."
  def error_text(:external_client_failure), do: "Upload failed."
  def error_text(_), do: "Upload failed."

  defp upload_root do
    Application.get_env(:lemon_web, :uploads_dir) ||
      Path.join(System.tmp_dir!(), "lemon_web_uploads")
  end

  defp sanitize(name) do
    case String.replace(name, ~r/[^a-zA-Z0-9._-]/u, "_") do
      "" -> "upload"
      value -> value
    end
  end
end
