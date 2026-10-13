defmodule CodingAgent.Session.TransportErrorSerializationTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Session.MessageSerialization
  alias LemonAi.{Error, Types.AssistantMessage}

  test "structured transport retry metadata survives the JSON session boundary" do
    reset_at = DateTime.utc_now() |> DateTime.add(3, :second) |> DateTime.truncate(:second)
    details = Error.parse_http_error(503, "Service Unavailable", [{"retry-after", "1.5"}])
    details = %{details | rate_limit_info: %{details.rate_limit_info | reset_at: reset_at}}

    original = %AssistantMessage{
      stop_reason: :error,
      error_message: "Opaque display-only failure",
      error_details: details,
      retry_after_ms: 1_500
    }

    restored =
      original
      |> MessageSerialization.serialize_message()
      |> Jason.encode!()
      |> Jason.decode!()
      |> MessageSerialization.deserialize_message()

    assert restored.error_message == original.error_message
    assert restored.error_details == details
    assert restored.retry_after_ms == 1_500
    assert Error.classify(restored) == :transient
    assert Error.retryable?(restored)
    assert Error.suggested_retry_delay_from_error(restored.error_details) == 1_500
  end

  test "unknown serialized categories are not converted into atoms or retry permission" do
    details =
      Error.to_error_details(%{
        "category" => "unrecognized_category_90210",
        "message" => "opaque",
        "retryable" => true
      })

    assert details.category == :unknown
    refute details.retryable
  end
end
