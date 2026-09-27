defmodule CodingAgent.Session.ProviderRetryTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Session.ProviderRetry
  alias LemonAi.Types.{AssistantMessage, Context, StreamOptions, TextContent, Usage}

  @settings %{enabled: true, max_retries: 3, base_delay_ms: 1_000}

  defp model, do: LemonAi.Models.get_model(:openai, "gpt-4")

  defp message(content, stop_reason, error_message \\ nil) do
    %AssistantMessage{
      role: :assistant,
      content: content,
      api: :openai_completions,
      provider: :openai,
      model: "gpt-4",
      usage: %Usage{},
      stop_reason: stop_reason,
      error_message: error_message,
      timestamp: 0
    }
  end

  defp error_stream(text) do
    {:ok, stream} = LemonAi.EventStream.start_link()
    msg = message([], :error, text)
    LemonAi.EventStream.push_async(stream, {:start, msg})
    LemonAi.EventStream.error(stream, msg)
    stream
  end

  defp success_stream(text) do
    {:ok, stream} = LemonAi.EventStream.start_link()
    msg = message([%TextContent{type: :text, text: text}], :stop)
    LemonAi.EventStream.push_async(stream, {:start, msg})
    LemonAi.EventStream.push_async(stream, {:text_delta, 0, text, msg})
    LemonAi.EventStream.complete(stream, msg)
    stream
  end

  # Answers each call with the next scripted result and reports the attempt.
  defp scripted(results) do
    parent = self()
    {:ok, script} = Agent.start_link(fn -> results end)

    fn _model, _context, _options ->
      send(parent, :attempt)

      case Agent.get_and_update(script, fn [next | rest] -> {next, rest} end) do
        {:stream_error, text} -> {:ok, error_stream(text)}
        {:ok, text} -> {:ok, success_stream(text)}
        {:request_error, reason} -> {:error, reason}
      end
    end
  end

  defp run(stream_fn, settings \\ @settings) do
    parent = self()

    wrapped =
      ProviderRetry.wrap(stream_fn, settings,
        sleep_fn: fn ms -> send(parent, {:slept, ms}) end,
        notify: fn details -> send(parent, {:retry, details}) end
      )

    {:ok, stream} = wrapped.(model(), %Context{}, %StreamOptions{})
    LemonAi.EventStream.result(stream, 2_000)
  end

  test "retries a transient stream error with backoff and returns the success" do
    stream_fn =
      scripted([{:stream_error, "Service temporarily unavailable (HTTP 503)"}, {:ok, "hello"}])

    assert {:ok, %AssistantMessage{content: [%TextContent{text: "hello"}]}} = run(stream_fn)

    assert_received {:retry, %{attempt: 1, max_retries: 3, category: :transient} = details}
    assert details.retry_after_ms == nil
    # Attempt 0 backoff with jitter: between base/2 and base.
    assert details.delay_ms in 500..1_000
    assert_received {:slept, delay}
    assert delay == details.delay_ms
    assert_received :attempt
    assert_received :attempt
    refute_received :attempt
  end

  test "waits for the provider's retry hint instead of the backoff" do
    stream_fn =
      scripted([
        {:stream_error, "Rate limit exceeded (HTTP 429). Please retry in 7s"},
        {:ok, "later"}
      ])

    assert {:ok, %AssistantMessage{content: [%TextContent{text: "later"}]}} = run(stream_fn)

    # RetryHelper adds a one-second buffer to textual hints.
    assert_received {:retry, %{category: :rate_limit, retry_after_ms: 8_000, delay_ms: 8_000}}
    assert_received {:slept, 8_000}
  end

  test "honors retry-after carried by a parsed request error" do
    parsed = %{
      category: :rate_limit,
      status: 429,
      message: "rate limited",
      provider_message: nil,
      rate_limit_info: %{limit: nil, remaining: 0, reset_at: nil, retry_after: 3_000},
      retryable: true
    }

    stream_fn = scripted([{:request_error, parsed}, {:ok, "ok"}])

    assert {:ok, _message} = run(stream_fn)
    assert_received {:slept, 3_000}
  end

  test "does not wait out a retry hint longer than the cap" do
    stream_fn =
      scripted([{:stream_error, "Rate limit exceeded (HTTP 429). Please retry in 600s"}])

    assert {:error, %AssistantMessage{error_message: "Rate limit exceeded" <> _}} = run(stream_fn)
    refute_received {:slept, _}
  end

  test "does not retry client errors" do
    stream_fn = scripted([{:stream_error, "Invalid request (HTTP 400): bad schema"}])

    assert {:error, %AssistantMessage{error_message: "Invalid request (HTTP 400): bad schema"}} =
             run(stream_fn)

    refute_received {:retry, _}
    assert_received :attempt
    refute_received :attempt
  end

  test "surfaces the last error once max_retries is spent" do
    overloaded = {:stream_error, "Overloaded (HTTP 529)"}
    stream_fn = scripted([overloaded, overloaded, overloaded])

    assert {:error, %AssistantMessage{error_message: "Overloaded (HTTP 529)"}} =
             run(stream_fn, %{@settings | max_retries: 2})

    assert_received {:retry, %{attempt: 1}}
    assert_received {:retry, %{attempt: 2}}
    refute_received {:retry, %{attempt: 3}}
  end

  test "retries a local concurrency rejection" do
    stream_fn = scripted([{:request_error, :max_concurrency}, {:ok, "slot freed"}])

    assert {:ok, %AssistantMessage{content: [%TextContent{text: "slot freed"}]}} = run(stream_fn)
    assert_received {:retry, %{attempt: 1}}
  end

  test "does not retry once output has reached the consumer" do
    parent = self()

    stream_fn = fn _model, _context, _options ->
      send(parent, :attempt)
      {:ok, stream} = LemonAi.EventStream.start_link()
      partial = message([%TextContent{type: :text, text: "half"}], :stop)
      LemonAi.EventStream.push_async(stream, {:text_delta, 0, "half", partial})
      LemonAi.EventStream.error(stream, message([], :error, "connection reset"))
      {:ok, stream}
    end

    assert {:error, %AssistantMessage{error_message: "connection reset"}} = run(stream_fn)
    refute_received {:retry, _}
    assert_received :attempt
    refute_received :attempt
  end

  test "returns the stream fn unchanged when retry is disabled" do
    stream_fn = fn _model, _context, _options -> {:error, :nope} end

    assert ProviderRetry.wrap(stream_fn, %{@settings | enabled: false}) == stream_fn
    assert ProviderRetry.wrap(stream_fn, %{@settings | max_retries: 0}) == stream_fn
  end
end
