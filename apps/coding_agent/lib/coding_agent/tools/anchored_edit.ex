defmodule CodingAgent.Tools.AnchoredEdit do
  @moduledoc """
  Snapshot-checked edits against the original, 1-based lines shown by `read`.

  The file tag is derived from the complete bytes, not just a displayed range.
  Every edit in a batch addresses the same original snapshot. Overlapping ranges
  and coincident insertion points are rejected before any write. Original BOM,
  line endings and final-newline convention are preserved by the edit caller.
  """

  alias CodingAgent.Tools.{FileFormatHelpers, FileValidation}

  @operations ~w(replace insert_before insert_after delete)
  @max_edits 100

  def snapshot(content) when is_binary(content), do: snapshot_for_digest(:erlang.md5(content))

  def snapshot_for_digest(<<prefix::binary-size(8), _rest::binary>>) do
    Base.encode16(prefix, case: :upper)
  end

  def validate(snapshot, edits) do
    cond do
      not is_binary(snapshot) or not Regex.match?(~r/^[0-9a-fA-F]{16}$/, snapshot) ->
        {:error, "snapshot must be the 16-character file tag returned by read; re-read the file."}

      not is_list(edits) or edits == [] ->
        {:error, "edits must be a non-empty array of line edits"}

      length(edits) > @max_edits ->
        {:error, "A single edit call supports at most #{@max_edits} line edits"}

      true ->
        Enum.reduce_while(edits, :ok, fn edit, :ok ->
          case validate_edit(edit) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end
        end)
    end
  end

  def apply(raw_content, normalized_content, snapshot, edits) do
    expected = snapshot(raw_content)

    if String.upcase(snapshot) == expected do
      lines = lines(normalized_content)

      with {:ok, operations} <- operations(edits, length(lines)),
           :ok <- validate_disjoint(operations) do
        {remaining, chunks, _cursor} =
          Enum.reduce(operations, {lines, [], 0}, fn op, {remaining, chunks, cursor} ->
            {before, after_before} = Enum.split(remaining, op.start - cursor)
            {_removed, after_removed} = Enum.split(after_before, op.finish - op.start)
            {after_removed, [op.lines, before | chunks], op.finish}
          end)

        result_lines = Enum.concat(Enum.reverse([remaining | chunks]))
        result = Enum.join(result_lines, "\n")

        result =
          if result_lines != [] and String.ends_with?(normalized_content, "\n"),
            do: result <> "\n",
            else: result

        {:ok, result}
      end
    else
      {:error,
       "Snapshot mismatch: the file changed since read. Re-read it and use fresh line numbers and snapshot; no edits were applied."}
    end
  end

  # A terminal LF closes a line; it is not an extra editable empty line.
  def lines(content) do
    segments = String.split(content, "\n", trim: false)

    if content != "" and String.ends_with?(content, "\n"),
      do: Enum.drop(segments, -1),
      else: segments
  end

  defp validate_edit(edit) when is_map(edit) do
    operation = Map.get(edit, "operation", "replace")
    first = Map.get(edit, "start_line")
    last = Map.get(edit, "end_line", first)

    cond do
      operation not in @operations ->
        {:error, "operation must be replace, insert_before, insert_after, or delete"}

      not is_integer(first) or first < 1 ->
        {:error, "start_line must be a positive, 1-based line number from read"}

      not is_integer(last) or last < first ->
        {:error, "end_line must be an integer greater than or equal to start_line"}

      operation in ["insert_before", "insert_after"] and last != first ->
        {:error, "Insertions target one start_line; omit end_line or use the same line"}

      operation == "delete" ->
        :ok

      not is_binary(Map.get(edit, "new_text")) ->
        {:error, "new_text must be a string for replacement and insertion edits"}

      true ->
        FileValidation.check_text_content(edit["new_text"], "new_text")
    end
  end

  defp validate_edit(_edit), do: {:error, "Each line edit must be an object"}

  defp operations(edits, count) do
    Enum.reduce_while(edits, {:ok, []}, fn edit, {:ok, acc} ->
      first = edit["start_line"]
      last = Map.get(edit, "end_line", first)

      if last > count do
        {:halt,
         {:error,
          "Line range #{first}-#{last} exceeds the file's #{count} editable lines. Re-read the file; no edits were applied."}}
      else
        operation = Map.get(edit, "operation", "replace")

        {start, finish} =
          case operation do
            "insert_before" -> {first - 1, first - 1}
            "insert_after" -> {first, first}
            _ -> {first - 1, last}
          end

        replacement = if operation == "delete", do: [], else: replacement_lines(edit["new_text"])
        {:cont, {:ok, [%{start: start, finish: finish, lines: replacement} | acc]}}
      end
    end)
    |> case do
      {:ok, operations} -> {:ok, Enum.sort_by(operations, &{&1.start, &1.finish})}
      error -> error
    end
  end

  defp replacement_lines(text) do
    text |> FileFormatHelpers.normalize_to_lf() |> lines()
  end

  defp validate_disjoint(operations) do
    Enum.reduce_while(operations, {:ok, nil}, fn op, {:ok, previous} ->
      if previous && (op.start < previous.finish or op.start == previous.start) do
        {:halt,
         {:error,
          "Line edits overlap at original line #{op.start + 1}. Combine overlapping changes into one edit; no edits were applied."}}
      else
        {:cont, {:ok, op}}
      end
    end)
    |> case do
      {:ok, _last} -> :ok
      error -> error
    end
  end
end
