defmodule CodingAgent.Session.ProviderRetry do
  @moduledoc """
  Session-level retry for transient provider failures.

  Wraps a session's stream function (outside `CodingAgent.Session.ProviderFallback`,
  so a retry re-runs the whole provider/credential chain). A request that fails
  with a rate limit, overload, 5xx, or network error *before any output reaches
  the agent loop* is retried with exponential backoff and jitter, up to
  `[runtime.retry] max_retries` times starting from `base_delay_ms`. When the
  error carries a retry hint (`retry-after` parsed into
  `rate_limit_info.retry_after`, or a textual hint such as "Please retry in 7s"
  in the error message), that delay is used instead of the backoff; a hint
  longer than 120s is not waited out and the error surfaces.

  Failures after output has started are not retried here: the agent loop has
  already seen partial content, and replaying it would duplicate the turn.

  Before each wait the `:notify` callback receives a details map (see
  `t:details/0`); the session broadcasts it as `{:provider_retry, details}`.
  While waiting, the output stream receives `{:provider_retry_wait, remaining_ms}`
  ticks so the agent loop, which checks for aborts on every event, can cancel
  the wait promptly. The loop ignores the tick events otherwise.
  """

  require Logger

  alias LemonAi.EventStream
  alias LemonAi.Providers.RetryHelper

  @retry_categories [:rate_limit, :transient, :server]
  # Local dispatcher rejections: the node is at its concurrency cap or the
  # provider's breaker is open. Waiting and trying again is the fix for both.
  @retry_request_reasons [:max_concurrency, :circuit_open]
  @max_backoff_ms 30_000
  @max_retry_after_ms 120_000
  @wait_tick_ms 250

  @type stream_fn ::
          (LemonAi.Types.Model.t(), LemonAi.Types.Context.t(), LemonAi.Types.StreamOptions.t() ->
             {:ok, EventStream.t()} | EventStream.t() | {:error, term()})

  @type settings :: %{
          required(:enabled) => boolean(),
          required(:max_retries) => non_neg_integer(),
          required(:base_delay_ms) => non_neg_integer()
        }

  @type details :: %{
          attempt: pos_integer(),
          max_retries: pos_integer(),
          delay_ms: non_neg_integer(),
          retry_after_ms: non_neg_integer() | nil,
          category: atom(),
          reason: String.t(),
          provider: term(),
          model: String.t() | nil
        }

  @doc """
  Wrap `stream_fn` with retry. Returns `stream_fn` unchanged when retry is
  disabled or `max_retries` is not positive.

  Options:

    * `:notify` - `(details() -> any())`, called before each retry wait
    * `:sleep_fn` - `(delay_ms -> any())`, replaces the abort-aware wait
      (tests use it to observe delays without sleeping)
  """
  @spec wrap(stream_fn() | nil, settings(), keyword()) :: stream_fn() | nil
  def wrap(stream_fn, settings, opts \\ [])

  def wrap(stream_fn, %{enabled: true, max_retries: max_retries} = settings, opts)
      when is_integer(max_retries) and max_retries > 0 do
    ctx = %{
      stream_fn: stream_fn || (&LemonAi.stream/3),
      max_retries: max_retries,
      base_delay_ms: max(Map.get(settings, :base_delay_ms) || 0, 1),
      notify: Keyword.get(opts, :notify, fn _details -> :ok end),
      sleep_fn: Keyword.get(opts, :sleep_fn)
    }

    fn model, context, options ->
      stream_with_retry(Map.merge(ctx, %{model: model, context: context, options: options}))
    end
  end

  def wrap(stream_fn, _settings, _opts), do: stream_fn

  defp stream_with_retry(ctx) do
    {:ok, output} = EventStream.start_link(timeout: :infinity)
    ctx = Map.put(ctx, :output, output)

    # Every attempt runs inside this task, so every provider stream it opens is
    # owned by the task and dies with it when the consumer cancels the output.
    {:ok, task_pid} =
      Task.Supervisor.start_child(LemonAi.StreamTaskSupervisor, fn -> attempt(ctx, 0) end)

    EventStream.attach_task(output, task_pid)
    {:ok, output}
  end

  defp attempt(ctx, retries_done) do
    case ctx.stream_fn.(ctx.model, ctx.context, ctx.options) do
      {:ok, stream} when is_pid(stream) ->
        relay(stream, ctx, retries_done)

      stream when is_pid(stream) ->
        relay(stream, ctx, retries_done)

      {:error, reason} ->
        if retryable_request?(reason) do
          retry_or_fail(ctx, retries_done, {:request, reason}, fn ->
            push_request_error(ctx, reason)
          end)
        else
          push_request_error(ctx, reason)
        end

      other ->
        EventStream.error(ctx.output, error_message(ctx.model, "invalid_stream: #{inspect(other)}"))
    end
  end

  # Events are held back until the first one that carries output (text,
  # thinking, or a tool call). Until then nothing has reached the loop, so a
  # transient error can still be retried invisibly.
  defp relay(stream, ctx, retries_done) do
    result =
      stream
      |> EventStream.events()
      |> Enum.reduce_while(%{committed: false, buffer: []}, fn event, acc ->
        cond do
          acc.committed ->
            emit(ctx.output, event)
            if terminal?(event), do: {:halt, :done}, else: {:cont, acc}

          retryable_stream_error?(event) ->
            {:halt, {:retryable, event, acc.buffer}}

          useful?(event) or terminal?(event) ->
            flush(ctx.output, acc.buffer)
            emit(ctx.output, event)
            if terminal?(event), do: {:halt, :done}, else: {:cont, %{committed: true, buffer: []}}

          true ->
            {:cont, %{acc | buffer: [event | acc.buffer]}}
        end
      end)

    case result do
      :done ->
        :ok

      {:retryable, event, buffer} ->
        retry_or_fail(ctx, retries_done, {:stream, event}, fn ->
          flush(ctx.output, buffer)
          emit(ctx.output, event)
        end)

      %{buffer: buffer} ->
        flush(ctx.output, buffer)
        EventStream.error(ctx.output, error_message(ctx.model, "provider_stream_closed"))
    end
  end

  defp retry_or_fail(ctx, retries_done, error, give_up) do
    with true <- retries_done < ctx.max_retries,
         {:ok, delay_ms, retry_after_ms} <- retry_delay(error, retries_done, ctx) do
      details = %{
        attempt: retries_done + 1,
        max_retries: ctx.max_retries,
        delay_ms: delay_ms,
        retry_after_ms: retry_after_ms,
        category: LemonAi.Error.classify(error_term(error)),
        reason: error_text(error),
        provider: Map.get(ctx.model || %{}, :provider),
        model: Map.get(ctx.model || %{}, :id)
      }

      Logger.warning(
        "Provider request failed transiently; retrying " <>
          "attempt=#{details.attempt}/#{details.max_retries} delay_ms=#{delay_ms} " <>
          "provider=#{inspect(details.provider)} model=#{inspect(details.model)} " <>
          "reason=#{inspect(details.reason, printable_limit: 500)}"
      )

      _ = ctx.notify.(details)
      wait(ctx, delay_ms)
      attempt(ctx, retries_done + 1)
    else
      _ -> give_up.()
    end
  end

  defp retry_delay(error, retries_done, ctx) do
    case retry_after_ms(error) do
      nil ->
        backoff = RetryHelper.exponential_backoff_with_jitter(ctx.base_delay_ms, retries_done)
        {:ok, min(backoff, @max_backoff_ms), nil}

      ms when ms > @max_retry_after_ms ->
        :too_long

      ms ->
        {:ok, ms, ms}
    end
  end

  defp retry_after_ms({:stream, {:error, _reason, %{error_message: text}}}) when is_binary(text),
    do: RetryHelper.extract_retry_delay_ms(text)

  defp retry_after_ms({:request, %{rate_limit_info: %{retry_after: ms}}})
       when is_integer(ms) and ms > 0,
       do: ms

  defp retry_after_ms({:request, {:http_error, status, body}}) when is_integer(status) do
    case LemonAi.Error.parse_http_error(status, body, []) do
      %{rate_limit_info: %{retry_after: ms}} when is_integer(ms) and ms > 0 -> ms
      _ -> nil
    end
  end

  defp retry_after_ms({:request, text}) when is_binary(text),
    do: RetryHelper.extract_retry_delay_ms(text)

  defp retry_after_ms(_error), do: nil

  defp wait(%{sleep_fn: sleep_fn}, delay_ms) when is_function(sleep_fn, 1),
    do: sleep_fn.(delay_ms)

  defp wait(%{output: output}, delay_ms), do: tick_wait(output, delay_ms)

  defp tick_wait(_output, remaining_ms) when remaining_ms <= 0, do: :ok

  defp tick_wait(output, remaining_ms) do
    slice = min(remaining_ms, @wait_tick_ms)
    Process.sleep(slice)
    left = remaining_ms - slice
    _ = EventStream.push(output, {:provider_retry_wait, left})
    tick_wait(output, left)
  end

  defp retryable_request?(reason) when reason in @retry_request_reasons, do: true
  defp retryable_request?(reason), do: LemonAi.Error.classify(reason) in @retry_categories

  defp retryable_stream_error?({:error, _reason, _message} = event),
    do: LemonAi.Error.classify(event) in @retry_categories

  defp retryable_stream_error?(_event), do: false

  defp error_term({:stream, event}), do: event
  defp error_term({:request, reason}), do: reason

  defp error_text({:stream, {:error, _reason, %{error_message: text}}}) when is_binary(text),
    do: text

  defp error_text({:stream, event}), do: inspect(event)
  defp error_text({:request, reason}), do: LemonAi.Error.format_error(reason)

  defp terminal?({:done, _reason, _message}), do: true
  defp terminal?({:error, _reason, _message}), do: true
  defp terminal?({:canceled, _reason}), do: true
  defp terminal?(_event), do: false

  defp useful?({:text_delta, _idx, text, _message}) when is_binary(text), do: text != ""
  defp useful?({:thinking_delta, _idx, text, _message}) when is_binary(text), do: text != ""
  defp useful?({:tool_call_start, _idx, _message}), do: true
  defp useful?({:tool_call_end, _idx, _tool_call, _message}), do: true
  defp useful?(_event), do: false

  defp flush(output, buffer), do: buffer |> Enum.reverse() |> Enum.each(&emit(output, &1))

  defp emit(output, {:done, _reason, message}), do: EventStream.complete(output, message)
  defp emit(output, {:error, _reason, message}), do: EventStream.error(output, message)
  defp emit(output, {:canceled, reason}), do: EventStream.cancel(output, reason)
  defp emit(output, event), do: EventStream.push(output, event)

  defp push_request_error(ctx, reason) when is_binary(reason),
    do: EventStream.error(ctx.output, error_message(ctx.model, reason))

  defp push_request_error(ctx, reason),
    do: EventStream.error(ctx.output, error_message(ctx.model, inspect(reason)))

  defp error_message(model, text) do
    %LemonAi.Types.AssistantMessage{
      role: :assistant,
      content: [%LemonAi.Types.TextContent{type: :text, text: ""}],
      api: model && model.api,
      provider: model && model.provider,
      model: (model && model.id) || "",
      usage: %LemonAi.Types.Usage{},
      stop_reason: :error,
      error_message: text,
      timestamp: System.system_time(:millisecond)
    }
  end
end
