defmodule LemonAi.Providers.RetryHelperTest do
  use ExUnit.Case, async: true

  alias LemonAi.Providers.RetryHelper

  describe "extract_retry_delay_ms/2" do
    test "extracts retry-after headers" do
      assert RetryHelper.extract_retry_delay_ms("some error", %{"retry-after" => "5.0"}) == 6000
    end

    test "extracts millisecond retry-after headers" do
      assert RetryHelper.extract_retry_delay_ms("some error", %{"retry-after-ms" => "1500"}) ==
               2500

      assert RetryHelper.extract_retry_delay_ms("some error", %{"x-ms-retry-after-ms" => "2000"}) ==
               3000
    end

    test "extracts x-ratelimit-reset-after headers case-insensitively" do
      delay =
        RetryHelper.extract_retry_delay_ms("some error", [
          {"X-RateLimit-Reset-After", ["10.0"]}
        ])

      assert delay == 11_000
    end

    test "extracts reset-after text durations" do
      assert RetryHelper.extract_retry_delay_ms("Your quota will reset after 1h2m3s") ==
               3_724_000
    end

    test "extracts retry-in hints" do
      assert RetryHelper.extract_retry_delay_ms("Please retry in 500ms") == 1500
      assert RetryHelper.extract_retry_delay_ms("Please retry in 5s") == 6000
    end

    test "extracts retryDelay JSON fields" do
      assert RetryHelper.extract_retry_delay_ms(~s("retryDelay": "34.074824224s")) == 35_075
    end

    test "headers take priority over body hints" do
      delay =
        RetryHelper.extract_retry_delay_ms("Please retry in 100s", %{"retry-after" => "5.0"})

      assert delay == 6000
    end

    test "returns nil when no retry delay exists" do
      assert RetryHelper.extract_retry_delay_ms("temporary overload") == nil

      assert RetryHelper.extract_retry_delay_ms("temporary overload", %{"retry-after" => "0"}) ==
               nil
    end
  end

  describe "retry_after_ms/2" do
    @now ~U[2026-09-27 12:00:00Z]

    test "reads delta-seconds and HTTP-date retry-after exactly (no buffer)" do
      assert RetryHelper.retry_after_ms(%{"retry-after" => ["7"]}, @now) == 7_000

      assert RetryHelper.retry_after_ms(
               %{"retry-after" => "Sun, 27 Sep 2026 12:00:30 GMT"},
               @now
             ) == 30_000
    end

    test "falls back to the latest exhausted anthropic rate-limit reset" do
      headers = %{
        "anthropic-ratelimit-requests-remaining" => "12",
        "anthropic-ratelimit-requests-reset" => "2026-09-27T12:05:00Z",
        "anthropic-ratelimit-input-tokens-remaining" => "0",
        "anthropic-ratelimit-input-tokens-reset" => "2026-09-27T12:00:20Z",
        "anthropic-ratelimit-output-tokens-remaining" => "0",
        "anthropic-ratelimit-output-tokens-reset" => "2026-09-27T12:00:45Z"
      }

      assert RetryHelper.retry_after_ms(headers, @now) == 45_000
    end

    test "past or missing hints yield nil" do
      past = %{"retry-after" => "Sun, 27 Sep 2026 11:00:00 GMT"}
      assert RetryHelper.retry_after_ms(past, @now) == nil
      assert RetryHelper.retry_after_ms(%{"x-request-id" => "abc"}, @now) == nil
    end
  end

  describe "retry policy" do
    @policy %{
      max_attempts: 4,
      base_delay_ms: 1_000,
      max_delay_ms: 30_000,
      max_retry_after_ms: 60_000
    }

    test "allows four attempts in total" do
      assert Enum.map(0..3, &RetryHelper.retry_allowed?(&1, @policy)) == [true, true, true, false]
    end

    test "backoff doubles from ~1s with jitter and is capped" do
      for _ <- 1..50 do
        assert RetryHelper.backoff_delay_ms(0, @policy) in 501..1_000
        assert RetryHelper.backoff_delay_ms(2, @policy) in 2_001..4_000
        assert RetryHelper.backoff_delay_ms(10, @policy) in 15_001..30_000
      end
    end

    test "server hints win over backoff, and waits beyond the cap give up" do
      assert RetryHelper.http_retry_delay_ms(0, %{"retry-after" => "9"}, @policy) == 9_000
      assert RetryHelper.http_retry_delay_ms(0, %{"retry-after" => "61"}, @policy) == :give_up
      assert RetryHelper.http_retry_delay_ms(1, %{}, @policy) in 1_001..2_000
    end
  end
end
