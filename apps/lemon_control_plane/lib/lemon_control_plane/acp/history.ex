defmodule LemonControlPlane.ACP.History do
  @moduledoc """
  Repairs a replay view from retained finalized runs without rewriting the journal.

  A run is associated only with its exact user prompt and recorded start interval.
  Already-journaled assistant text must be an exact prefix of the retained answer;
  only the missing suffix is inserted inside that user turn, before the next user.
  Ambiguous or unmatched records are left alone rather than inventing chronology.
  """

  def reconcile_answers(entries, runs) do
    runs =
      Enum.flat_map(runs, fn {run_id, data} ->
        summary = field(data, :summary) || %{}
        completed = field(summary, :completed)
        prompt = field(summary, :prompt)
        answer = field(completed, :answer)
        started = milliseconds(field(data, :started_at))

        if is_map(completed) and is_binary(prompt) and is_binary(answer) and answer != "" and
             started do
          [
            %{
              id: run_id,
              prompt: prompt,
              answer: answer,
              started: started,
              events: field(data, :events) || []
            }
          ]
        else
          []
        end
      end)

    {groups, leading} = groups(entries)

    {replayed, _used, _previous} =
      Enum.reduce(groups, {[], MapSet.new(), nil}, fn group, {all, used, previous} ->
        user = hd(group)
        timestamp = entry_time(user)
        prompt = text(field(user, :message))

        candidates =
          Enum.filter(runs, fn run ->
            run.prompt == prompt and not MapSet.member?(used, run.id) and
              is_integer(timestamp) and run.started <= timestamp and
              (is_nil(previous) or run.started > previous)
          end)

        case candidates do
          [run] ->
            repaired = repair(group, run)
            {Enum.reverse(repaired, all), MapSet.put(used, run.id), timestamp}

          _ ->
            {Enum.reverse(group, all), used, timestamp || previous}
        end
      end)

    leading ++ Enum.reverse(replayed)
  end

  defp groups(entries) do
    {groups, current, leading} =
      Enum.reduce(entries, {[], [], []}, fn entry, {groups, current, leading} ->
        if role(entry) in [:user, "user"] do
          groups = if current == [], do: groups, else: [Enum.reverse(current) | groups]
          {groups, [entry], leading}
        else
          if current == [],
            do: {groups, current, [entry | leading]},
            else: {groups, [entry | current], leading}
        end
      end)

    groups = if current == [], do: groups, else: [Enum.reverse(current) | groups]
    {Enum.reverse(groups), Enum.reverse(leading)}
  end

  defp repair(group, run) do
    known =
      group
      |> Enum.filter(&(role(&1) in [:assistant, "assistant"]))
      |> Enum.map(&text(field(&1, :message)))
      |> Enum.reject(&(&1 == ""))

    suffix =
      Enum.reduce_while(known, {:ok, run.answer}, fn visible, {:ok, remaining} ->
        cond do
          String.starts_with?(remaining, visible) ->
            {:cont, {:ok, drop_prefix(remaining, visible)}}

          String.starts_with?(remaining, "\n" <> visible) ->
            {:cont, {:ok, drop_prefix(remaining, "\n" <> visible)}}

          true ->
            {:halt, :mismatch}
        end
      end)

    case suffix do
      {:ok, missing} when missing != "" -> insert_missing(group, run, missing)
      _ -> group
    end
  end

  defp insert_missing(group, run, missing) do
    pending =
      Enum.reduce(group, MapSet.new(), fn entry, pending ->
        message = field(entry, :message)

        cond do
          role(entry) in [:tool_result, "tool_result"] ->
            MapSet.delete(pending, field(message, :tool_call_id))

          role(entry) in [:assistant, "assistant"] ->
            Enum.reduce(List.wrap(field(message, :content)), pending, fn block, ids ->
              if field(block, :type) in [:tool_call, "tool_call"],
                do: MapSet.put(ids, field(block, :id)),
                else: ids
            end)

          true ->
            pending
        end
      end)

    latest =
      Enum.reduce(run.events, %{}, fn event, latest ->
        action = field(event, :action) || %{}
        detail = field(action, :detail) || %{}

        id =
          field(detail, :tool_call_id) ||
            Enum.find(pending, fn id ->
              is_binary(id) and field(action, :id) in [id, "tool_" <> id]
            end)

        if id, do: Map.put_new(latest, id, field(event, :phase)), else: latest
      end)

    active =
      Enum.filter(pending, fn id -> Map.get(latest, id) not in [:completed, "completed"] end)
      |> MapSet.new()

    {group, inserted?} =
      Enum.map_reduce(group, false, fn entry, inserted? ->
        message = field(entry, :message)

        if not inserted? and role(entry) in [:assistant, "assistant"] and
             is_list(field(message, :content)) do
          {blocks, placed?} =
            Enum.reduce(field(message, :content), {[], false}, fn block, {blocks, placed?} ->
              if not placed? and field(block, :type) in [:tool_call, "tool_call"] and
                   MapSet.member?(active, field(block, :id)) do
                {[block, %{type: :text, text: missing} | blocks], true}
              else
                {[block | blocks], placed?}
              end
            end)

          if placed?,
            do: {Map.put(entry, :message, put_content(message, Enum.reverse(blocks))), true},
            else: {entry, false}
        else
          {entry, inserted?}
        end
      end)

    if inserted? do
      group
    else
      group ++
        [
          %{
            type: :message,
            id: "#{run.id}:retained-answer",
            message: %{role: :assistant, content: [%{type: :text, text: missing}], timestamp: nil}
          }
        ]
    end
  end

  defp put_content(message, content) do
    if Map.has_key?(message, "content"),
      do: Map.put(message, "content", content),
      else: Map.put(message, :content, content)
  end

  defp role(entry), do: entry |> field(:message) |> field(:role)

  defp entry_time(entry),
    do:
      milliseconds(field(field(entry, :message), :timestamp)) ||
        milliseconds(field(entry, :timestamp))

  defp milliseconds(value) when is_integer(value) and value > 0, do: value

  defp milliseconds(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, _offset} -> DateTime.to_unix(time, :millisecond)
      _ -> nil
    end
  end

  defp milliseconds(_value), do: nil

  defp text(message) do
    case field(message, :content) do
      content when is_binary(content) ->
        content

      content when is_list(content) ->
        content
        |> Enum.flat_map(fn block ->
          if field(block, :type) in [:text, "text"] and is_binary(field(block, :text)),
            do: [field(block, :text)],
            else: []
        end)
        |> Enum.join("")

      _ ->
        ""
    end
  end

  defp drop_prefix(text, prefix),
    do: binary_part(text, byte_size(prefix), byte_size(text) - byte_size(prefix))

  defp field(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp field(_value, _key), do: nil
end
