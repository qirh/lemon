defmodule CodingAgent.Tools.ReadNotebook do
  @moduledoc false

  alias CodingAgent.Tools.{ReadFormats, ReadFormatText}
  import LemonAgent.Tools.AbortHelpers, only: [check_abort: 1]

  def read(path, params, signal, opts) do
    with :ok <- ReadFormats.check_input(path, opts),
         {:ok, bytes} <- File.read(path),
         :ok <- check_abort(signal),
         {:ok, notebook} <- Jason.decode(bytes),
         {:ok, cells} <- cells(notebook) do
      start = Map.get(params, "cell", 1)
      limit = Map.get(params, "cell_limit", length(cells))

      if start > max(length(cells), 1) do
        {:error, "cell=#{start} is beyond the notebook's #{length(cells)} cells."}
      else
        selected = cells |> Enum.with_index(1) |> Enum.drop(start - 1) |> Enum.take(limit)

        text =
          if selected == [] do
            "(empty notebook)"
          else
            Enum.map_join(selected, "\n\n", fn {cell, index} -> render_cell(cell, index) end)
          end

        ReadFormatText.result(text, path, params, signal, opts, %{
          format: :notebook,
          immutable: true,
          total_cells: length(cells),
          start_cell: start,
          cells_shown: length(selected),
          next_cell: if(start + length(selected) <= length(cells), do: start + length(selected)),
          notebook_format: Map.get(notebook, "nbformat")
        })
      end
    else
      {:error, %Jason.DecodeError{}} -> {:error, "Notebook is not valid JSON: #{path}"}
      {:error, reason} when is_atom(reason) -> {:error, "Cannot read notebook #{path}: #{reason}"}
      error -> error
    end
  end

  defp cells(%{"cells" => cells}) when is_list(cells) do
    if Enum.all?(cells, &is_map/1),
      do: {:ok, cells},
      else: {:error, "Notebook cells must be JSON objects."}
  end

  defp cells(_), do: {:error, "Expected an nbformat 4 notebook with a cells array."}

  defp render_cell(cell, index) do
    type = Map.get(cell, "cell_type", "unknown")
    execution = Map.get(cell, "execution_count")
    execution_label = if type == "code", do: " execution_count=#{inspect(execution)}", else: ""
    header = "=== Cell #{index} [#{safe_label(type)}]#{execution_label} ==="
    source = text(Map.get(cell, "source", ""))
    outputs = Map.get(cell, "outputs", [])
    outputs = if is_list(outputs), do: outputs, else: []

    output_lines =
      Enum.with_index(outputs, 1) |> Enum.map(fn {output, n} -> render_output(output, n) end)

    Enum.join([header, source | output_lines], "\n")
  end

  defp render_output(output, index) when is_map(output) do
    type = Map.get(output, "output_type", "unknown")
    header = "--- Output #{index} [#{safe_label(type)}] ---"

    body =
      case type do
        "stream" ->
          "#{safe_label(Map.get(output, "name", "stdout"))}:\n" <>
            text(Map.get(output, "text", ""))

        "error" ->
          traceback = Map.get(output, "traceback", [])

          traceback =
            if is_list(traceback),
              do: Enum.map_join(traceback, "\n", &text/1),
              else: text(traceback)

          "#{text(Map.get(output, "ename", "Error"))}: #{text(Map.get(output, "evalue", ""))}\n" <>
            traceback

        _ ->
          render_mime(Map.get(output, "data", %{}))
      end

    header <> "\n" <> body
  end

  defp render_output(_, index), do: "--- Output #{index} [invalid output object] ---"

  defp render_mime(data) when is_map(data) do
    preferred =
      Enum.find(
        ["text/plain", "text/markdown", "text/html", "application/json"],
        &Map.has_key?(data, &1)
      )

    body =
      case preferred do
        nil ->
          "(no textual output)"

        "application/json" ->
          "application/json:\n" <> Jason.encode!(data[preferred], pretty: true)

        mime ->
          "#{mime}:\n" <> text(data[mime])
      end

    omitted = Map.keys(data) |> Enum.reject(&(&1 == preferred)) |> Enum.sort()

    if omitted == [],
      do: body,
      else: body <> "\n[Other MIME outputs retained in notebook: #{Enum.join(omitted, ", ")}]"
  end

  defp render_mime(_), do: "(invalid MIME data)"

  defp text(value) when is_binary(value), do: value
  defp text(value) when is_list(value), do: Enum.map_join(value, "", &text/1)
  defp text(nil), do: ""
  defp text(value), do: Jason.encode!(value)
  defp safe_label(value), do: value |> text() |> String.slice(0, 120)
end
