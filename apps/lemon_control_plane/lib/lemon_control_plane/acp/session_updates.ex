defmodule LemonControlPlane.ACP.SessionUpdates do
  @moduledoc """
  Stateful projection of native agent tuples and run-bus events into ACP updates.

  Create one mapper per prompt with `new/2`, then thread the state returned by
  `map_event/2` through the run subscription (including completion events). Tool
  starts retain their arguments until completion; cumulative reasoning and final
  answers are not replayed after their streamed chunks. Returned values are full
  JSON-RPC `session/update` notifications, ready for any ACP transport.

  Tool data is untrusted. Text previews are capped at 4,000 bytes, raw envelopes
  have a shared 32 KiB budget, collections are capped at 100 entries and nesting
  at six levels. Typed diffs contain complete snapshots only, up to 16 KiB per
  side; larger edits use the bounded textual diff rather than a fabricated file.
  """

  @text_limit 4_000
  @raw_limit 32_768
  @diff_limit 16_384
  @items_limit 100
  @depth_limit 6

  defstruct [
    :session_id,
    :cwd,
    tools: %{},
    thoughts: %{},
    message_id: nil,
    message_seq: 0,
    text_emitted: false,
    completed: false
  ]

  def new(session_id, opts \\ []) do
    %__MODULE__{
      session_id: session_id,
      cwd: Keyword.get(opts, :cwd),
      message_id: "message_#{System.unique_integer([:positive, :monotonic])}"
    }
  end

  def session_updates(session_id, event, opts \\ []) do
    {updates, _state} = map_event(new(session_id, opts), event)
    updates
  end

  def tool_call(session_id, id, name, args, opts \\ []) do
    state = new(session_id, opts)

    notification(
      state,
      start_update(
        state,
        id,
        name,
        args,
        Keyword.get(opts, :intent),
        Keyword.get(opts, :status, "pending")
      )
    )
  end

  def tool_kind(name, args \\ %{}) do
    case to_string(name || "") do
      "read" -> "read"
      "write" -> if internal_path?(get(args, :path)), do: "execute", else: "edit"
      n when n in ["edit", "patch", "apply_patch"] -> "edit"
      "delete" -> "delete"
      "move" -> "move"
      n when n in ["bash", "bash_output", "kill_process", "shell", "exec", "eval"] -> "execute"
      n when n in ["grep", "glob", "find", "ast_grep"] -> "search"
      n when n in ["web_search", "websearch", "webfetch", "fetch"] -> "fetch"
      "todo" -> "think"
      _ -> "other"
    end
  end

  def map_event(state, {:session_event, _session_id, event}), do: map_event(state, event)
  def map_event(state, {:agent_event, event}), do: map_event(state, event)

  def map_event(state, %{type: type, payload: payload}),
    do: map_bus(state, to_string(type), payload)

  def map_event(state, %{"type" => type, "payload" => payload}),
    do: map_bus(state, to_string(type), payload)

  def map_event(state, {:message_start, message}) do
    seq = state.message_seq + 1

    {[],
     %{
       state
       | message_seq: seq,
         message_id: get(message, :id) || "message_#{seq}",
         text_emitted: false
     }}
  end

  def map_event(state, {:message_update, message, event}) do
    if assistant?(message), do: message_delta(state, message, event), else: {[], state}
  end

  def map_event(state, {:message_end, message}) do
    if assistant?(message) and not state.text_emitted,
      do: chunks(state, "agent_message_chunk", assistant_text(message)),
      else: {[], state}
  end

  def map_event(state, {:tool_execution_start, id, name, args}) do
    update = start_update(state, id, name, args, get(args, :intent) || get(args, :i), "pending")

    {[notification(state, update)],
     %{state | tools: Map.put(state.tools, id, {name, bounded(args)})}}
  end

  def map_event(state, {:tool_execution_update, id, name, args, result}),
    do: tool_result(state, id, name, args, result, "in_progress")

  def map_event(state, {:tool_execution_end, id, name, result, is_error}) do
    {_name, args} = Map.get(state.tools, id, {name, %{}})
    tool_result(state, id, name, args, result, if(is_error, do: "failed", else: "completed"))
  end

  def map_event(state, {:todo_reminder, todos}), do: emit(state, plan(todos))
  def map_event(state, {:todo_auto_clear}), do: emit(state, plan([]))
  def map_event(state, {:provider_retry, details}), do: retry_update(state, details)
  def map_event(state, {:compaction_start, info}), do: compaction(state, info, "in_progress")
  def map_event(state, {:compaction_complete, info}), do: compaction(state, info, "completed")
  def map_event(state, {:compaction_failed, info}), do: compaction(state, info, "failed")

  def map_event(state, {:error, reason, _partial_state}),
    do: chunks(state, "agent_message_chunk", readable(reason))

  def map_event(state, {:agent_end, messages}) do
    message = messages |> Enum.reverse() |> Enum.find(&assistant?/1)
    completion(state, %{answer: assistant_text(message), usage: aggregate_usage(messages)})
  end

  def map_event(state, event) when is_map(event),
    do: map_named_event(state, to_string(get(event, :type) || ""), event)

  def map_event(state, _event), do: {[], state}

  defp map_bus(state, "delta", payload),
    do: chunks(state, "agent_message_chunk", get(payload, :text))

  defp map_bus(state, "engine_action", payload), do: action_event(state, payload)

  defp map_bus(state, type, payload) when type in ["engine_completed", "run_completed"],
    do: completion(state, get(payload, :completed) || payload)

  defp map_bus(state, "agent_event", payload),
    do: map_event(state, get(payload, :event) || payload)

  defp map_bus(state, type, payload), do: map_named_event(state, type, payload)

  defp map_named_event(state, "message_update", event),
    do:
      map_event(
        state,
        {:message_update, get(event, :message), get(event, :assistantMessageEvent)}
      )

  defp map_named_event(state, "message_end", event),
    do: map_event(state, {:message_end, get(event, :message)})

  defp map_named_event(state, "tool_execution_start", event),
    do:
      map_event(
        state,
        {:tool_execution_start, get(event, :toolCallId), get(event, :toolName), get(event, :args)}
      )

  defp map_named_event(state, "tool_execution_update", event),
    do:
      tool_result(
        state,
        get(event, :toolCallId),
        get(event, :toolName),
        get(event, :args),
        get(event, :partialResult),
        "in_progress"
      )

  defp map_named_event(state, "tool_execution_end", event),
    do:
      map_event(
        state,
        {:tool_execution_end, get(event, :toolCallId), get(event, :toolName), get(event, :result),
         get(event, :isError) == true}
      )

  defp map_named_event(state, "todo_reminder", event),
    do: emit(state, plan(get(event, :todos) || []))

  defp map_named_event(state, "todo_auto_clear", _event), do: emit(state, plan([]))
  defp map_named_event(state, "provider_retry", event), do: retry_update(state, event)

  defp map_named_event(state, "compaction_start", event),
    do: compaction(state, event, "in_progress")

  defp map_named_event(state, "compaction_complete", event),
    do: compaction(state, event, "completed")

  defp map_named_event(state, "compaction_failed", event), do: compaction(state, event, "failed")
  defp map_named_event(state, "usage", event), do: emit_many(state, usage_updates(event))
  defp map_named_event(state, "subagent_progress", event), do: subagent_update(state, event)
  defp map_named_event(state, _type, _event), do: {[], state}

  defp message_delta(state, _message, text) when is_binary(text),
    do: chunks(state, "agent_message_chunk", text)

  defp message_delta(state, _message, {:text_delta, _index, text, _partial}),
    do: chunks(state, "agent_message_chunk", text)

  defp message_delta(state, _message, {:thinking_delta, _index, text, _partial}),
    do: chunks(state, "agent_thought_chunk", text)

  defp message_delta(state, message, {:done, _reason, _final}),
    do: map_event(state, {:message_end, message})

  defp message_delta(state, _message, event) when is_map(event) do
    case to_string(get(event, :type) || "") do
      "text_delta" ->
        chunks(state, "agent_message_chunk", get(event, :delta))

      "thinking_delta" ->
        chunks(state, "agent_thought_chunk", get(event, :delta))

      "done" ->
        map_event(state, {:message_end, get(event, :message)})

      "error" ->
        chunks(state, "agent_message_chunk", readable(get(event, :error)))

      "image_end" ->
        emit(state, %{
          "sessionUpdate" => "agent_message_chunk",
          "content" => bounded(get(event, :content))
        })

      _ ->
        {[], state}
    end
  end

  defp message_delta(state, _message, _event), do: {[], state}

  defp action_event(state, payload) do
    action = get(payload, :action) || %{}
    detail = get(action, :detail) || %{}
    id = get(action, :id)
    kind = to_string(get(action, :kind) || "")
    phase = to_string(get(payload, :phase) || "")

    cond do
      kind == "reasoning" ->
        reasoning_update(state, id, get(detail, :reasoning) || %{})

      kind == "compaction" ->
        info = get(detail, :compaction) || detail

        compaction(
          state,
          info,
          get(info, :status) || if(phase == "completed", do: "completed", else: "in_progress")
        )

      is_map(get(detail, :retry)) ->
        retry_update(state, get(detail, :retry))

      kind == "approval" ->
        {[], state}

      true ->
        name = get(detail, :name) || kind
        args = get(detail, :args) || elem(Map.get(state.tools, id, {name, %{}}), 1)

        case phase do
          "started" ->
            map_event(state, {:tool_execution_start, id, name, args})

          "updated" ->
            tool_result(
              state,
              id,
              name,
              args,
              get(detail, :partial_result) || result_envelope(detail),
              "in_progress"
            )

          "completed" ->
            tool_result(
              state,
              id,
              name,
              args,
              result_envelope(detail),
              if(get(payload, :ok) == false, do: "failed", else: "completed")
            )

          _ ->
            {[], state}
        end
    end
  end

  defp result_envelope(detail) do
    %{
      "content" => [
        %{"type" => "text", "text" => get(detail, :result_full) || get(detail, :result) || ""}
      ],
      "details" => get(detail, :details) || get(detail, :result_meta) || %{}
    }
  end

  defp reasoning_update(state, id, reasoning) do
    text = get(reasoning, :full_text) || get(reasoning, :text) || ""
    previous = Map.get(state.thoughts, id, "")

    delta =
      if String.starts_with?(text, previous),
        do: binary_part(text, byte_size(previous), byte_size(text) - byte_size(previous)),
        else: ""

    {updates, state} = chunks(state, "agent_thought_chunk", delta)
    {updates, %{state | thoughts: Map.put(state.thoughts, id, text)}}
  end

  defp start_update(state, id, name, args, intent, status) do
    %{
      "sessionUpdate" => "tool_call",
      "toolCallId" => id,
      "title" => title(name, args, intent),
      "kind" => tool_kind(name, args),
      "status" => status,
      "rawInput" => bounded(args)
    }
    |> put_nonempty("content", start_content(name, args))
    |> put_nonempty("locations", locations(state, args, name))
  end

  defp tool_result(state, id, name, args, result, status) do
    update =
      %{
        "sessionUpdate" => "tool_call_update",
        "toolCallId" => id,
        "status" => status,
        "rawOutput" => bounded(result)
      }
      |> put_nonempty(
        "content",
        Enum.uniq(start_content(name, args) ++ result_content(state, result))
      )
      |> put_nonempty("locations", result_locations(state, result, args, name))

    updates = [update]
    todos = todo_entries(name, args, result)

    updates =
      if status == "completed" and is_list(todos), do: updates ++ [plan(todos)], else: updates

    state =
      if status in ["completed", "failed"],
        do: %{state | tools: Map.delete(state.tools, id)},
        else: state

    emit_many(state, updates)
  end

  defp title(name, args, intent) do
    command = get(args, :command)

    subject =
      get(args, :path) || get(args, :file_path) || command || get(args, :pattern) ||
        get(args, :query)

    text =
      cond do
        name in ["bash", "shell", "exec"] and is_binary(command) ->
          "$ " <> command

        name == "eval" and is_binary(get(args, :code)) ->
          "[#{get(args, :language) || "?"}] #{get(args, :title) || ""}\n#{get(args, :code)}"

        is_binary(intent) and String.trim(intent) != "" ->
          String.trim(intent)

        is_binary(subject) ->
          if internal_path?(subject), do: subject, else: "#{name}: #{subject}"

        true ->
          to_string(name || "Tool")
      end

    preview(text)
  end

  defp start_content(name, args) when name in ["bash", "shell", "exec", "eval"] do
    if is_binary(get(args, :command)) or is_binary(get(args, :code)),
      do: [text_content(title(name, args, nil))],
      else: []
  end

  defp start_content(_name, _args), do: []

  defp result_content(state, result) do
    details = get(result, :details) || %{}
    entries = get(details, :perFileResults) || [details]

    diffs =
      entries |> list() |> Enum.take(@items_limit) |> Enum.flat_map(&diff_content(state, &1))

    blocks = get(result, :content) || if(is_list(result), do: result, else: [])
    rich = blocks |> list() |> Enum.take(@items_limit) |> Enum.flat_map(&content_block/1)
    terminal_id = get(result, :terminalId) || get(details, :terminalId)

    terminal =
      if is_binary(terminal_id),
        do: [%{"type" => "terminal", "terminalId" => preview(terminal_id)}],
        else: []

    fallback =
      cond do
        rich != [] or terminal != [] ->
          []

        is_binary(get(details, :diff)) ->
          [text_content(get(details, :diff))]

        true ->
          case readable(result) do
            "" -> []
            text -> [text_content(text)]
          end
      end

    Enum.uniq(diffs ++ rich ++ terminal ++ fallback) |> Enum.take(@items_limit)
  end

  defp content_block(block) do
    case to_string(get(block, :type) || "") do
      "text" ->
        case get(block, :text) do
          text when is_binary(text) and text != "" -> [text_content(text)]
          _ -> []
        end

      type when type in ["image", "audio"] ->
        if is_binary(get(block, :data)) and byte_size(get(block, :data)) <= @raw_limit and
             is_binary(get(block, :mimeType)),
           do: [%{"type" => "content", "content" => bounded(block)}],
           else: []

      type when type in ["resource_link", "resource"] ->
        [%{"type" => "content", "content" => bounded(block)}]

      _ ->
        []
    end
  end

  defp diff_content(state, entry) do
    path = local_path(state, get(entry, :path))
    old = get(entry, :oldText) || get(entry, :old_text)
    new = get(entry, :newText) || get(entry, :new_text)

    if path && get(entry, :isError) != true && is_binary(new) && byte_size(new) <= @diff_limit &&
         (is_nil(old) || (is_binary(old) && byte_size(old) <= @diff_limit)) do
      [%{"type" => "diff", "path" => path, "oldText" => old, "newText" => new}]
    else
      []
    end
  end

  defp locations(state, args, name) do
    [get(args, :path) || get(args, :file_path), get(args, :oldPath), get(args, :newPath)]
    |> Enum.flat_map(fn raw ->
      case location_path(state, raw, name) do
        nil -> []
        path -> [%{"path" => path} |> maybe_put("line", get(args, :offset) || get(args, :line))]
      end
    end)
    |> Enum.uniq()
  end

  defp result_locations(state, result, args, name) do
    details = get(result, :details) || %{}
    entries = [details | list(get(details, :perFileResults))]

    found =
      entries
      |> Enum.take(@items_limit)
      |> Enum.flat_map(fn entry ->
        path = local_path(state, get(entry, :path) || get(entry, :resolvedPath))

        if path,
          do: [%{"path" => path} |> maybe_put("line", get(entry, :first_changed_line))],
          else: []
      end)

    if found == [], do: locations(state, args, name), else: Enum.uniq(found)
  end

  defp location_path(state, raw, "read") when is_binary(raw) do
    literal = local_path(state, raw)

    cond do
      literal && File.regular?(literal) ->
        literal

      true ->
        base = Regex.replace(~r/:\d+(?:[-+]\d*)?(?::raw)?$/, raw, "")
        candidate = local_path(state, base)
        if candidate && File.regular?(candidate), do: candidate
    end
  end

  defp location_path(state, raw, _name), do: local_path(state, raw)

  defp local_path(state, raw) when is_binary(raw) and raw != "" do
    if internal_path?(raw) or byte_size(raw) > @text_limit,
      do: nil,
      else: Path.expand(raw, state.cwd || File.cwd!())
  end

  defp local_path(_state, _raw), do: nil

  defp internal_path?(raw) when is_binary(raw),
    do: Regex.match?(~r/^[a-z][a-z0-9+.-]*:\/\//i, raw)

  defp internal_path?(_raw), do: false

  defp todo_entries(name, args, result) when name in ["todo", "todo_write"] do
    details = get(result, :details) || %{}

    get(details, :todos) ||
      case get(details, :phases) do
        phases when is_list(phases) -> Enum.flat_map(phases, &list(get(&1, :tasks)))
        _ -> if get(args, :action) == "write", do: get(args, :todos)
      end
  end

  defp todo_entries(_name, _args, _result), do: nil

  defp plan(todos) do
    entries =
      todos
      |> list()
      |> Enum.take(@items_limit)
      |> Enum.flat_map(fn todo ->
        content = get(todo, :content)

        if is_binary(content) and content != "" do
          status =
            case to_string(get(todo, :status) || "pending") do
              n when n in ["completed", "abandoned"] -> "completed"
              "in_progress" -> "in_progress"
              _ -> "pending"
            end

          [%{"content" => preview(content), "priority" => "medium", "status" => status}]
        else
          []
        end
      end)

    %{"sessionUpdate" => "plan", "entries" => entries}
  end

  defp retry_update(state, details) do
    attempt = get(details, :attempt) || 1
    delay = get(details, :delay_ms) || 0

    chunks(
      state,
      "agent_message_chunk",
      "Provider request failed; retrying in #{delay}ms (attempt #{attempt}/#{get(details, :max_retries) || attempt}).\n",
      %{"_meta" => %{"lemon" => %{"retry" => bounded(details)}}}
    )
  end

  defp compaction(state, info, status) do
    emit(
      state,
      %{
        "sessionUpdate" => "compaction_update",
        "compactionId" => get(info, :compactionId) || get(info, :id) || "compaction",
        "status" => to_string(status)
      }
      |> maybe_put("summary", optional_preview(get(info, :summary)))
    )
  end

  defp subagent_update(state, event) do
    chunks(
      state,
      "agent_message_chunk",
      get(event, :text) || get(event, :message),
      %{}
      |> maybe_put("senderSessionId", get(event, :senderSessionId) || get(event, :session_id))
      |> maybe_put("recipientSessionId", get(event, :recipientSessionId) || state.session_id)
    )
  end

  defp completion(%{completed: true} = state, _payload), do: {[], state}

  defp completion(state, payload) do
    {answer, state} =
      if state.text_emitted,
        do: {[], state},
        else: chunks(state, "agent_message_chunk", get(payload, :answer))

    {errors, state} =
      if get(payload, :ok) == false,
        do: chunks(state, "agent_message_chunk", readable(get(payload, :error))),
        else: {[], state}

    {usage, state} = emit_many(state, usage_updates(get(payload, :usage) || %{}))
    {answer ++ errors ++ usage, %{state | completed: true}}
  end

  defp usage_updates(usage) do
    if is_map(usage) and map_size(usage) > 0 do
      total =
        get(usage, :totalTokens) || get(usage, :total_tokens) ||
          number(get(usage, :input)) + number(get(usage, :output)) +
            number(get(usage, :cache_read)) + number(get(usage, :cache_write))

      size = get(usage, :contextWindow) || get(usage, :context_window)
      meta = %{"_meta" => %{"lemon" => %{"usage" => bounded(usage)}}}

      if is_number(size) and size > 0 do
        [
          Map.merge(meta, %{
            "sessionUpdate" => "usage_update",
            "size" => size,
            "used" => get(usage, :context_tokens) || total
          })
        ]
      else
        [
          Map.merge(meta, %{
            "sessionUpdate" => "session_info_update",
            "token_count" => %{"totalTokens" => total}
          })
        ]
      end
    else
      []
    end
  end

  defp aggregate_usage(messages) do
    Enum.reduce(messages, %{}, fn message, acc ->
      case get(message, :usage) do
        usage when is_map(usage) ->
          Map.merge(acc, Map.new(usage), fn _key, a, b -> number(a) + number(b) end)

        _ ->
          acc
      end
    end)
  end

  defp chunks(state, kind, text, extra \\ %{})

  defp chunks(state, kind, text, extra) when is_binary(text) and text != "" do
    updates =
      text_chunks(text)
      |> Enum.map(fn chunk ->
        notification(
          state,
          Map.merge(
            %{"sessionUpdate" => kind, "content" => %{"type" => "text", "text" => chunk}},
            extra
          )
          |> maybe_put("messageId", state.message_id)
        )
      end)

    {updates, if(kind == "agent_message_chunk", do: %{state | text_emitted: true}, else: state)}
  end

  defp chunks(state, _kind, _text, _extra), do: {[], state}

  defp text_chunks(text) when byte_size(text) <= @text_limit, do: [text]

  defp text_chunks(text) do
    prefix = utf8_prefix(text, @text_limit)

    [
      prefix
      | text_chunks(binary_part(text, byte_size(prefix), byte_size(text) - byte_size(prefix)))
    ]
  end

  defp emit(state, update), do: {[notification(state, update)], state}
  defp emit_many(state, updates), do: {Enum.map(updates, &notification(state, &1)), state}

  defp notification(state, update),
    do: %{
      "jsonrpc" => "2.0",
      "method" => "session/update",
      "params" => %{"sessionId" => state.session_id, "update" => update}
    }

  defp text_content(text),
    do: %{"type" => "content", "content" => %{"type" => "text", "text" => preview(text)}}

  defp put_nonempty(map, _key, []), do: map
  defp put_nonempty(map, key, value), do: Map.put(map, key, value)
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
  defp optional_preview(text) when is_binary(text), do: preview(text)
  defp optional_preview(_text), do: nil
  defp number(value) when is_number(value), do: value
  defp number(_value), do: 0
  defp list(value) when is_list(value), do: value
  defp list(_value), do: []

  defp assistant?(message), do: to_string(get(message, :role) || "") == "assistant"

  defp assistant_text(message),
    do:
      get(message, :content)
      |> list()
      |> Enum.flat_map(fn block ->
        if to_string(get(block, :type) || "") == "text" and is_binary(get(block, :text)),
          do: [get(block, :text)],
          else: []
      end)
      |> Enum.join("\n")

  defp readable(value) when is_binary(value), do: preview(value)

  defp readable(value) when is_map(value) do
    direct = get(value, :text) || get(value, :errorMessage) || get(value, :message)

    cond do
      is_binary(direct) -> preview(direct)
      is_list(get(value, :content)) -> assistant_text(value) |> preview()
      true -> value |> bounded() |> Jason.encode!() |> preview()
    end
  end

  defp readable(nil), do: ""
  defp readable(value), do: value |> bounded() |> Jason.encode!() |> preview()

  defp get(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp get(_map, _key), do: nil

  defp preview(text) when is_binary(text) do
    if byte_size(text) <= @text_limit, do: text, else: utf8_prefix(text, @text_limit - 3) <> "…"
  end

  defp utf8_prefix(text, bytes) do
    prefix = binary_part(text, 0, min(bytes, byte_size(text)))
    if String.valid?(prefix), do: prefix, else: utf8_prefix(text, bytes - 1)
  end

  defp bounded(value) do
    {safe, _budget} = bound(value, @raw_limit, 0)
    safe
  end

  defp bound(_value, budget, depth) when budget <= 0 or depth > @depth_limit, do: {"[omitted]", 0}

  defp bound(value, budget, _depth) when is_binary(value) do
    safe =
      if String.valid?(value),
        do: utf8_prefix(value, min(budget, @raw_limit)),
        else: "[non-UTF8 output]"

    {safe, max(budget - byte_size(safe), 0)}
  end

  defp bound(value, budget, _depth) when is_nil(value) or is_boolean(value) or is_number(value),
    do: {value, max(budget - 8, 0)}

  defp bound(value, budget, depth) when is_atom(value),
    do: bound(Atom.to_string(value), budget, depth)

  defp bound(value, budget, depth) when is_map(value) do
    value
    |> Map.delete(:__struct__)
    |> Enum.take(@items_limit)
    |> Enum.reduce_while({%{}, budget}, fn {key, item}, {acc, left} ->
      if left <= 0 do
        {:halt, {acc, 0}}
      else
        if is_atom(key) or is_binary(key) do
          {key, left} = bound(to_string(key), left, depth + 1)
          {item, left} = bound(item, left, depth + 1)
          {:cont, {Map.put(acc, key, item), left}}
        else
          {:cont, {acc, left}}
        end
      end
    end)
  end

  defp bound(value, budget, depth) when is_list(value) do
    {items, left} =
      value
      |> Enum.take(@items_limit)
      |> Enum.reduce_while({[], budget}, fn item, {acc, left} ->
        if left <= 0,
          do: {:halt, {acc, 0}},
          else:
            (
              {item, left} = bound(item, left, depth + 1)
              {:cont, {[item | acc], left}}
            )
      end)

    {Enum.reverse(items), left}
  end

  defp bound(_value, budget, _depth), do: {"[unsupported value]", max(budget - 19, 0)}
end
