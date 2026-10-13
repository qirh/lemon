defmodule LemonControlPlane.Methods.ChatHistory do
  @moduledoc """
  Handler for the chat.history method.

  Returns the conversation history for a session.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.AgentRuntime
  alias LemonControlPlane.Methods.NativeSessions

  @default_limit 50
  @max_limit 200
  @preview_bytes 500

  @impl true
  def name, do: "chat.history"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    params = params || %{}
    session_key = get_param(params, "sessionKey")
    limit = normalize_limit(get_param(params, "limit"))
    before_id = get_param(params, "beforeId")
    include_full_text = truthy?(get_param(params, "includeFullText"), true)

    if is_nil(session_key) or session_key == "" do
      {:error, {:invalid_request, "sessionKey is required", nil}}
    else
      with {:ok, history} <- history(params, session_key, limit, before_id, include_full_text) do
        {:ok,
         %{
           "sessionKey" => session_key,
           "messages" => history,
           "summary" => summary(history, limit, before_id, include_full_text)
         }}
      end
    end
  end

  defp history(params, session_key, limit, before_id, full_text) do
    if Map.has_key?(params, "cwd") do
      with {:ok, _key, cwd} <- NativeSessions.target(params) do
        case AgentRuntime.call(:session_history, [session_key, cwd], {:error, :unavailable}) do
          {:ok, entries} when is_list(entries) ->
            messages = Enum.flat_map(entries, &native_message(&1, full_text))

            page =
              if before_id in [nil, ""],
                do: Enum.take(messages, -limit),
                else: messages |> apply_before_id(before_id) |> Enum.take(limit)

            {:ok, page}

          {:error, reason}
          when reason in [:session_not_found, :unsupported_session, :unavailable] ->
            {:ok, get_chat_history(session_key, limit, before_id, full_text)}

          {:error, reason} ->
            NativeSessions.failure(reason)

          _ ->
            NativeSessions.failure(:invalid_response)
        end
      end
    else
      {:ok, get_chat_history(session_key, limit, before_id, full_text)}
    end
  end

  defp native_message(%{type: :message, id: id, message: message} = entry, full_text)
       when is_map(message) do
    role = message["role"] || message[:role]

    if role in ["user", "assistant", :user, :assistant] do
      content = native_text(message["content"] || message[:content])

      [
        %{
          "id" => id,
          "role" => to_string(role),
          "content" => maybe_preview(content, full_text),
          "timestampMs" =>
            message["timestamp"] || message[:timestamp] || Map.get(entry, :timestamp),
          "ok" => (message["stop_reason"] || message[:stop_reason]) not in ["error", :error],
          "truncated" => truncated?(content, full_text)
        }
      ]
    else
      []
    end
  end

  defp native_message(_, _), do: []

  defp native_text(content) when is_binary(content), do: content

  defp native_text(content) when is_list(content) do
    content
    |> Enum.flat_map(fn
      %{"type" => "text", "text" => text} when is_binary(text) -> [text]
      %{type: :text, text: text} when is_binary(text) -> [text]
      _ -> []
    end)
    |> Enum.join("\n")
  end

  defp native_text(_), do: ""

  defp get_chat_history(session_key, limit, before_id, include_full_text) do
    runs = LemonCore.RunStore.history(session_key, limit: limit * 2)

    runs
    |> Enum.flat_map(fn {run_id, data} ->
      extract_messages(run_id, data, include_full_text)
    end)
    |> apply_before_id(before_id)
    |> Enum.take(limit)
  rescue
    _ -> []
  end

  defp extract_messages(run_id, data, include_full_text) do
    summary = data[:summary] || %{}
    completed = summary[:completed] || %{}
    timestamp = data[:started_at]

    messages = []

    # Add user prompt if available
    prompt = get_in(summary, [:prompt]) || get_prompt_from_events(data[:events])

    messages =
      if prompt do
        [
          %{
            "id" => "#{run_id}_user",
            "role" => "user",
            "content" => maybe_preview(prompt, include_full_text),
            "timestampMs" => timestamp,
            "truncated" => truncated?(prompt, include_full_text)
          }
          | messages
        ]
      else
        messages
      end

    # Add assistant response
    answer = completed[:answer]

    messages =
      if answer && answer != "" do
        [
          %{
            "id" => "#{run_id}_assistant",
            "role" => "assistant",
            "content" => maybe_preview(answer, include_full_text),
            "timestampMs" => timestamp,
            "ok" => completed[:ok],
            "truncated" => truncated?(answer, include_full_text)
          }
          | messages
        ]
      else
        messages
      end

    Enum.reverse(messages)
  end

  defp get_prompt_from_events(nil), do: nil

  defp get_prompt_from_events(events) when is_list(events) do
    events
    |> Enum.find(fn e -> is_map(e) and (e[:type] == :prompt or e["type"] == "prompt") end)
    |> case do
      %{text: text} -> text
      %{"text" => text} -> text
      _ -> nil
    end
  end

  defp get_prompt_from_events(_), do: nil

  defp apply_before_id(messages, nil), do: messages
  defp apply_before_id(messages, ""), do: messages

  defp apply_before_id(messages, before_id) do
    messages
    |> Enum.drop_while(&(&1["id"] != before_id))
    |> case do
      [] -> []
      [_matched | rest] -> rest
    end
  end

  defp summary(messages, limit, before_id, include_full_text) do
    %{
      "count" => length(messages),
      "limit" => limit,
      "beforeId" => before_id,
      "roleCounts" => count_by(messages, "role"),
      "okCount" => Enum.count(messages, &(&1["ok"] == true)),
      "errorCount" => Enum.count(messages, &(&1["ok"] == false)),
      "truncatedCount" => Enum.count(messages, &(&1["truncated"] == true)),
      "cleanup" => %{
        "includesMessageBodies" => true,
        "includesFullText" => include_full_text == true,
        "includesRawEvents" => false,
        "includesRunRecords" => false,
        "redactsSensitivePreviews" => include_full_text != true,
        "includesCredentials" => false,
        "includesSecretValues" => include_full_text == true
      }
    }
  end

  defp count_by(rows, key) do
    rows
    |> Enum.map(& &1[key])
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.frequencies()
  end

  defp maybe_preview(text, true), do: text

  defp maybe_preview(text, false) when is_binary(text) do
    text = LemonCore.Redact.text(text)

    if byte_size(text) > @preview_bytes do
      String.slice(text, 0, @preview_bytes) <> "..."
    else
      text
    end
  end

  defp maybe_preview(text, false), do: text

  defp truncated?(text, true) when is_binary(text), do: false
  defp truncated?(text, false) when is_binary(text), do: byte_size(text) > @preview_bytes
  defp truncated?(_, _), do: false

  defp normalize_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, @max_limit)

  defp normalize_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {parsed, _} when parsed > 0 -> min(parsed, @max_limit)
      _ -> @default_limit
    end
  end

  defp normalize_limit(_), do: @default_limit

  defp truthy?(value, _default) when is_boolean(value), do: value
  defp truthy?(value, _default) when value in [1, "1", "true", "TRUE", "yes", "on"], do: true
  defp truthy?(value, _default) when value in [0, "0", "false", "FALSE", "no", "off"], do: false
  defp truthy?(_value, default), do: default

  defp get_param(params, key) when is_map(params) and is_binary(key) do
    underscored = Macro.underscore(key)

    cond do
      Map.has_key?(params, key) -> Map.get(params, key)
      Map.has_key?(params, underscored) -> Map.get(params, underscored)
      true -> nil
    end
  end

  defp get_param(_params, _key), do: nil
end
