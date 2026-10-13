defmodule LemonAgent.Loop.Streaming do
  @moduledoc false

  alias LemonAgent.AbortSignal
  alias LemonAgent.EventStream
  alias LemonAgent.Loop.TranscriptValidator
  alias LemonAgent.Types.{AgentLoopConfig, AgentTool}

  alias LemonAi.Types.{
    AssistantMessage,
    Context,
    Cost,
    TextContent,
    Tool,
    ToolCall,
    Usage
  }

  @max_retry_after_ms 120_000

  @spec stream_assistant_response(
          LemonAgent.Types.AgentContext.t(),
          AgentLoopConfig.t(),
          reference() | nil,
          AgentLoopConfig.stream_fn() | nil,
          EventStream.t()
        ) :: {:ok, AssistantMessage.t(), LemonAgent.Types.AgentContext.t()} | {:error, term()}
  def stream_assistant_response(context, config, signal, stream_fn, stream) do
    retry_response(context, config, signal, stream_fn, stream, 0)
  end

  defp retry_response(context, config, signal, stream_fn, stream, retries_done) do
    result = stream_once(context, config, signal, stream_fn, stream)

    case result do
      {:failed, message, failed_context, added} ->
        case retry_delay(message, config, retries_done) do
          {:ok, delay_ms} ->
            retry_attempt(
              context,
              config,
              signal,
              stream_fn,
              stream,
              retries_done,
              message,
              delay_ms
            )

          :stop ->
            finish_retry(stream, retries_done, false, false)
            message = strip_tool_calls(message)
            {message, context} = finalize_message(message, failed_context, added, stream)
            {:ok, message, context}
        end

      {:error, reason} ->
        case retry_delay(reason, config, retries_done) do
          {:ok, delay_ms} ->
            retry_attempt(
              context,
              config,
              signal,
              stream_fn,
              stream,
              retries_done,
              reason,
              delay_ms
            )

          :stop ->
            finish_retry(stream, retries_done, false, false)
            result
        end

      {:ok, message, _context} ->
        finish_retry(
          stream,
          retries_done,
          message.stop_reason not in [:error, :aborted, :redirected],
          message.stop_reason in [:aborted, :redirected]
        )

        result
    end
  end

  defp retry_attempt(context, config, signal, stream_fn, stream, retries_done, error, delay_ms) do
    attempt = retries_done + 1

    EventStream.push(
      stream,
      {:provider_retry,
       %{
         attempt: attempt,
         max_retries: config.max_retries,
         delay_ms: delay_ms,
         retry_after_ms: retry_after_ms(error),
         category: LemonAi.Error.classify(error),
         reason: LemonAi.Error.format_error(error_text(error)),
         provider: Map.get(config.model || %{}, :provider),
         model: Map.get(config.model || %{}, :id)
       }}
    )

    case wait_for_retry(signal, System.monotonic_time(:millisecond) + delay_ms) do
      :ok ->
        retry_response(context, config, signal, stream_fn, stream, attempt)

      reason ->
        finish_retry(stream, attempt, false, true)

        {message, context} =
          finalize_canceled_message(nil, context, false, stream, config, reason)

        {:ok, message, context}
    end
  end

  defp retry_delay(error, config, retries_done) do
    if retries_done < config.max_retries and LemonAi.Error.retryable?(error) do
      case retry_after_ms(error) do
        delay when is_integer(delay) and delay > @max_retry_after_ms ->
          :stop

        delay when is_integer(delay) and delay >= 0 ->
          {:ok, delay}

        _ ->
          {:ok,
           min(
             config.retry_base_delay_ms * Integer.pow(2, min(retries_done, 30)),
             config.retry_max_delay_ms
           )}
      end
    else
      :stop
    end
  end

  defp error_text(%AssistantMessage{error_message: message}), do: message
  defp error_text(error), do: error

  defp retry_after_ms(%{error_details: %{rate_limit_info: %{retry_after: delay}}})
       when is_integer(delay), do: delay

  defp retry_after_ms(%{retry_after_ms: delay}) when is_integer(delay), do: delay
  defp retry_after_ms(%{rate_limit_info: %{retry_after: delay}}) when is_integer(delay), do: delay

  defp retry_after_ms({:http_error, _status, _body, headers}),
    do: LemonAi.Providers.RetryHelper.retry_after_ms(headers)

  defp retry_after_ms({:http_error, status, body}),
    do: LemonAi.Error.parse_http_error(status, body) |> retry_after_ms()

  defp retry_after_ms(%{error_message: message}) when is_binary(message),
    do: retry_after_ms(message)

  defp retry_after_ms(message) when is_binary(message),
    do: LemonAi.Providers.RetryHelper.extract_retry_delay_ms(message)

  defp retry_after_ms(_error), do: nil

  defp wait_for_retry(signal, deadline) do
    cond do
      aborted?(signal) ->
        :aborted

      redirect_requested?(signal) ->
        :redirected

      true ->
        remaining = deadline - System.monotonic_time(:millisecond)

        if remaining <= 0 do
          :ok
        else
          Process.sleep(min(remaining, 50))
          wait_for_retry(signal, deadline)
        end
    end
  end

  defp finish_retry(_stream, 0, _success, _canceled), do: :ok

  defp finish_retry(stream, attempt, success, canceled) do
    EventStream.push(
      stream,
      {:provider_retry_end, %{attempt: attempt, success: success, canceled: canceled}}
    )
  end

  defp stream_once(context, config, signal, stream_fn, stream) do
    if aborted?(signal) do
      abort_message = build_error_message(config, :aborted, "Request was aborted")
      {abort_message, context} = finalize_message(abort_message, context, false, stream)
      {:ok, abort_message, context}
    else
      # NOTE: the redirect flag is deliberately NOT cleared here. The loop
      # clears it immediately BEFORE each steering drain (see
      # LemonAgent.Loop / LemonAgent.Loop.ToolCalls): a redirect cast that
      # lands after a drain keeps its flag set, so the in-stream check below
      # cancels this call and the loop retries with the correction. Clearing
      # here — after the drain — could swallow a redirect whose correction is
      # still sitting undrained in the steering queue, silently delaying it a
      # full turn.

      # Surface very large contexts early (telemetry warning only; no truncation here).
      _ = LemonAgent.Context.check_size(context.messages, context.system_prompt)

      with {:ok, messages} <- transform_messages(context, config, signal),
           :ok <- TranscriptValidator.validate(messages),
           {:ok, llm_messages} <- convert_messages(config, messages) do
        # Build LLM context
        llm_context = %Context{
          system_prompt: context.system_prompt,
          messages: llm_messages,
          tools: convert_tools_to_llm(context.tools)
        }

        # Resolve stream function
        stream_function = stream_fn || config.stream_fn || (&default_stream_fn/3)

        # Resolve API key (important for expiring tokens)
        api_key =
          case config.get_api_key do
            nil ->
              config.stream_options.api_key

            get_key_fn ->
              provider = config.model.provider

              get_key_fn.(provider) ||
                if(is_atom(provider), do: get_key_fn.(Atom.to_string(provider))) ||
                config.stream_options.api_key
          end

        options = %{config.stream_options | api_key: api_key}

        # Call the stream function (support {:ok, stream} or direct stream pid)
        case stream_function.(config.model, llm_context, options) do
          {:ok, response_stream} ->
            process_stream_events(
              context,
              response_stream,
              stream,
              config,
              signal,
              llm_context,
              options
            )

          {:error, reason} ->
            {:error, reason}

          response_stream when is_pid(response_stream) ->
            process_stream_events(
              context,
              response_stream,
              stream,
              config,
              signal,
              llm_context,
              options
            )

          other ->
            {:error, {:invalid_stream, other}}
        end
      else
        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp process_stream_events(
         context,
         response_stream,
         stream,
         config,
         signal,
         llm_context,
         options
       ) do
    # Accumulate the partial message
    result =
      Enum.reduce_while(
        ai_events(response_stream, signal),
        {nil, context, false},
        fn event, {partial, ctx, added} ->
          cond do
            aborted?(signal) ->
              LemonAi.EventStream.cancel(response_stream, :aborted)

              {final_message, final_ctx} =
                finalize_canceled_message(partial, ctx, added, stream, config, :aborted)

              {:halt, {:done, final_message, final_ctx}}

            redirect_requested?(signal) ->
              # Redirect cancels only this model request; the loop keeps prior
              # completed messages/tool results and retries with the queued
              # correction appended.
              LemonAi.EventStream.cancel(response_stream, :redirected)

              {final_message, final_ctx} =
                finalize_canceled_message(partial, ctx, added, stream, config, :redirected)

              {:halt, {:done, final_message, final_ctx}}

            true ->
              case process_stream_event(event, partial, ctx, added, stream, config) do
                {:continue, new_partial, new_ctx, new_added} ->
                  {:cont, {new_partial, new_ctx, new_added}}

                {:done, final_message, final_ctx} ->
                  {:halt, {:done, final_message, final_ctx}}

                {:failed, message, failed_context, failed_added} ->
                  {:halt, {:failed, message, failed_context, failed_added}}
              end
          end
        end
      )

    case result do
      {:done, final_message, ctx} ->
        _ =
          LemonAi.PromptDiagnostics.record_llm_call(
            config.model,
            llm_context,
            options,
            final_message
          )

        {:ok, final_message, ctx}

      {:failed, message, ctx, added} ->
        _ = LemonAi.PromptDiagnostics.record_llm_call(config.model, llm_context, options, message)
        {:failed, message, ctx, added}

      {partial, ctx, added} when partial != nil ->
        # Stream ended without done/error event - finalize with partial
        partial = normalize_terminal_message(partial)

        result =
          if partial.stop_reason == :error do
            {:failed, partial, ctx, added}
          else
            {final_message, final_ctx} = finalize_message(partial, ctx, added, stream)
            {:ok, final_message, final_ctx}
          end

        _ =
          LemonAi.PromptDiagnostics.record_llm_call(
            config.model,
            llm_context,
            options,
            partial
          )

        result

      _ ->
        {:error, :no_response}
    end
  end

  defp process_stream_event({:start, partial}, _partial, context, _added, stream, _config) do
    # Add partial to context
    context = %{context | messages: context.messages ++ [partial]}
    EventStream.push(stream, {:message_start, copy_message(partial)})
    {:continue, partial, context, true}
  end

  defp process_stream_event(event, partial, context, added, stream, _config)
       when elem(event, 0) in [
              :text_start,
              :text_delta,
              :text_end,
              :thinking_start,
              :thinking_delta,
              :thinking_end,
              :tool_call_start,
              :tool_call_delta,
              :tool_call_end
            ] do
    if partial != nil do
      # Get the updated partial from the event
      updated_partial = get_partial_from_event(event)

      # Update context with new partial
      context = update_last_message(context, updated_partial)

      EventStream.push(stream, {:message_update, copy_message(updated_partial), event})
      {:continue, updated_partial, context, added}
    else
      {:continue, partial, context, added}
    end
  end

  defp process_stream_event(
         {:done, _reason, final_message},
         partial,
         context,
         added,
         stream,
         _config
       ) do
    final_message = reconcile_final_message(final_message, partial)
    final_message = normalize_terminal_message(final_message)

    if final_message.stop_reason == :error do
      {:failed, final_message, context, added}
    else
      {final_message, context} = finalize_message(final_message, context, added, stream)
      {:done, final_message, context}
    end
  end

  defp process_stream_event(
         {:error, _reason, final_message},
         partial,
         context,
         added,
         _stream,
         _config
       ) do
    final_message = reconcile_final_message(final_message, partial)
    final_message = %{final_message | stop_reason: :error}
    {:failed, final_message, context, added}
  end

  defp process_stream_event({:canceled, reason}, partial, context, added, stream, config) do
    {final_message, context} =
      finalize_canceled_message(partial, context, added, stream, config, reason)

    {:done, final_message, context}
  end

  defp process_stream_event(_event, partial, context, added, _stream, _config) do
    {:continue, partial, context, added}
  end

  # Extract the partial message from stream events
  defp get_partial_from_event({_type, _idx, partial}) when is_struct(partial, AssistantMessage),
    do: partial

  defp get_partial_from_event({_type, _idx, _delta, partial})
       when is_struct(partial, AssistantMessage),
       do: partial

  defp get_partial_from_event(_), do: nil

  defp default_stream_fn(model, context, options) do
    LemonAi.stream(model, context, options)
  end

  # LemonAi.EventStream can stop immediately on cancel, which can raise on :take
  # (:noproc, :shutdown, or :normal depending on timing).
  # Wrap the take loop to treat those exits as a canceled terminal event.
  defp ai_events(response_stream, signal) do
    Stream.resource(
      fn -> {:active, response_stream} end,
      fn
        {:halting, _stream} ->
          {:halt, nil}

        {:active, stream} ->
          case safe_ai_take(stream, signal) do
            {:event, event} ->
              if terminal_ai_event?(event) do
                {[event], {:halting, stream}}
              else
                {[event], {:active, stream}}
              end

            :done ->
              {:halt, nil}
          end
      end,
      fn _acc -> :ok end
    )
  end

  defp safe_ai_take(stream, nil) do
    try do
      GenServer.call(stream, :take, :infinity)
    catch
      :exit, {:noproc, _} ->
        {:event, {:canceled, :canceled}}

      :exit, {:normal, _} ->
        {:event, {:canceled, :canceled}}

      :exit, {:shutdown, _} ->
        {:event, {:canceled, :canceled}}
    end
  end

  defp safe_ai_take(stream, signal) do
    request = :gen_server.send_request(stream, :take)
    await_ai_event(stream, signal, request)
  end

  defp await_ai_event(stream, signal, request) do
    cond do
      aborted?(signal) ->
        LemonAi.EventStream.cancel(stream, :aborted)
        :gen_server.receive_response(request, 0)
        {:event, {:canceled, :aborted}}

      redirect_requested?(signal) ->
        LemonAi.EventStream.cancel(stream, :redirected)
        :gen_server.receive_response(request, 0)
        {:event, {:canceled, :redirected}}

      true ->
        case :gen_server.wait_response(request, 50) do
          {:reply, reply} ->
            reply

          {:error, {reason, _server}} when reason in [:noproc, :normal, :shutdown] ->
            {:event, {:canceled, :canceled}}

          {:error, {reason, _server}} ->
            exit(reason)

          :timeout ->
            await_ai_event(stream, signal, request)
        end
    end
  end

  defp terminal_ai_event?({:done, _reason, _message}), do: true
  defp terminal_ai_event?({:error, _reason, _message}), do: true
  defp terminal_ai_event?({:canceled, _reason}), do: true
  defp terminal_ai_event?(_event), do: false

  defp reconcile_final_message(%AssistantMessage{} = final, %AssistantMessage{} = partial) do
    if empty_content?(final.content) and not empty_content?(partial.content) do
      %{final | content: partial.content}
    else
      final
    end
  end

  defp reconcile_final_message(final, _partial), do: final

  defp empty_content?(nil), do: true
  defp empty_content?([]), do: true
  defp empty_content?(_content), do: false

  defp normalize_terminal_message(%AssistantMessage{stop_reason: stop_reason} = message)
       when stop_reason in [:stop, nil] do
    if not has_tool_call?(message) and not has_visible_text?(message) do
      %{
        message
        | content: [
            %TextContent{
              type: :text,
              text: "The provider returned an empty assistant response."
            }
          ],
          stop_reason: :error,
          error_message: "empty_assistant_response"
      }
    else
      message
    end
  end

  defp normalize_terminal_message(message), do: message

  defp has_tool_call?(%AssistantMessage{content: content}) when is_list(content) do
    Enum.any?(content, &match?(%ToolCall{}, &1))
  end

  defp has_tool_call?(_message), do: false

  defp has_visible_text?(%AssistantMessage{content: content}) when is_list(content) do
    Enum.any?(content, fn
      %TextContent{text: text} when is_binary(text) -> String.trim(text) != ""
      _ -> false
    end)
  end

  defp has_visible_text?(_message), do: false

  defp aborted?(signal), do: AbortSignal.aborted?(signal)

  defp redirect_requested?(signal), do: AbortSignal.redirect_requested?(signal)

  defp transform_messages(context, %AgentLoopConfig{transform_context: nil}, _signal) do
    {:ok, context.messages}
  end

  defp transform_messages(context, %AgentLoopConfig{transform_context: transform_fn}, signal) do
    case transform_fn.(context.messages, signal) do
      {:ok, transformed} -> {:ok, transformed}
      {:error, reason} -> {:error, reason}
      transformed -> {:ok, transformed}
    end
  end

  defp convert_messages(%AgentLoopConfig{convert_to_llm: convert_fn}, messages) do
    case convert_fn.(messages) do
      {:ok, converted} -> {:ok, converted}
      {:error, reason} -> {:error, reason}
      converted -> {:ok, converted}
    end
  end

  defp finalize_message(final_message, context, added, stream) do
    context =
      if added do
        update_last_message(context, final_message)
      else
        %{context | messages: context.messages ++ [final_message]}
      end

    if not added do
      EventStream.push(stream, {:message_start, copy_message(final_message)})
    end

    EventStream.push(stream, {:message_end, final_message})
    {final_message, context}
  end

  defp finalize_canceled_message(partial, context, added, stream, config, reason) do
    stop_reason =
      case reason do
        :aborted -> :aborted
        :canceled -> :aborted
        :user_abort -> :aborted
        :redirected -> :redirected
        _ -> :error
      end

    # A redirect is not an error: the loop continues with a correction, so
    # leave error_message nil to avoid misreporting the run as failed.
    error_message =
      if stop_reason == :redirected, do: nil, else: "Stream canceled: #{inspect(reason)}"

    final_message =
      case partial do
        %AssistantMessage{} = msg ->
          msg = strip_tool_calls(msg)
          %{msg | stop_reason: stop_reason, error_message: error_message}

        _ ->
          build_error_message(config, stop_reason, error_message)
      end

    finalize_message(final_message, context, added, stream)
  end

  # A canceled response may contain tool calls that will never receive results.
  # Keep all cancellation paths transcript-valid for a later continue.
  defp strip_tool_calls(%AssistantMessage{content: content} = msg) when is_list(content) do
    stripped =
      Enum.reject(content, fn
        %ToolCall{} -> true
        %{type: :tool_call} -> true
        _ -> false
      end)

    stripped =
      if stripped == [] do
        [%TextContent{type: :text, text: ""}]
      else
        stripped
      end

    %{msg | content: stripped}
  end

  defp strip_tool_calls(msg), do: msg

  defp build_error_message(%AgentLoopConfig{} = config, stop_reason, error_text) do
    model = config.model || %{}

    %AssistantMessage{
      role: :assistant,
      content: [%TextContent{type: :text, text: ""}],
      api: Map.get(model, :api),
      provider: Map.get(model, :provider),
      model: Map.get(model, :id, ""),
      usage: %Usage{
        input: 0,
        output: 0,
        cache_read: 0,
        cache_write: 0,
        total_tokens: 0,
        cost: %Cost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0, total: 0.0}
      },
      stop_reason: stop_reason,
      error_message: error_text,
      timestamp: System.system_time(:millisecond)
    }
  end

  defp convert_tools_to_llm(agent_tools) do
    Enum.map(agent_tools, fn %AgentTool{} = tool ->
      %Tool{
        name: tool.name,
        description: tool.description,
        parameters: tool.parameters
      }
    end)
  end

  defp update_last_message(context, new_message) do
    messages = List.replace_at(context.messages, -1, new_message)
    %{context | messages: messages}
  end

  defp copy_message(%AssistantMessage{} = msg) do
    %{msg | content: msg.content}
  end

  defp copy_message(msg), do: msg
end
