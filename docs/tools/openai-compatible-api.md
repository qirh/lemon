# OpenAI-Compatible API Preview

Lemon exposes a preview OpenAI-compatible HTTP surface for clients that already
know the `/v1` API shape. The adapter is intentionally thin: it translates
OpenAI-shaped requests into supervised Lemon runs instead of bypassing the
router, run graph, events, approvals, checkpoints, or operator visibility.

## Endpoints

| Endpoint | Status | Behavior |
| --- | --- | --- |
| `GET /v1/health` | Preview | Returns Lemon API health metadata. |
| `GET /v1/capabilities` | Preview | Returns supported compatibility features and known gaps. |
| `GET /v1/models` | Preview | Returns Lemon's model catalog in OpenAI list shape, including Lemon capability metadata such as `supportsVision`. |
| `GET /v1/models/:model_id` | Preview | Returns one OpenAI-shaped model object from Lemon's catalog, including Lemon capability metadata such as `supportsVision`, or a 404 error. |
| `POST /v1/chat/completions` | Preview | Accepts OpenAI-style `model`, `messages`, redacted URL/file-id image metadata, data URL image pass-through, and opt-in allowlisted HTTPS image URL fetch, submits a Lemon run, returns queued metadata by default, assistant text when `wait: true` completes before the timeout, or `text/event-stream` chunks when `stream: true`. |
| `POST /v1/responses` | Preview | Accepts OpenAI-style `model`, `input`, redacted URL/file-id image metadata, data URL image pass-through, opt-in allowlisted HTTPS image URL fetch, and optional `previous_response_id`, submits a Lemon run, returns queued metadata by default, Responses-style output text when `wait: true` completes before the timeout, or Responses-style SSE events when `stream: true`. |
| `GET /v1/responses/:response_id` | Preview | Reads `resp_<run_id>` from the Lemon run store and returns a Responses-shaped object with completed output when available. |
| `GET /v1/runs/:run_id` | Preview | Returns redacted Lemon run status, timestamps, event count, session key, and completion state. |
| `POST /v1/runs/:run_id/cancel` | Preview | Requests cancellation through `LemonRouter.abort_run/2` for non-terminal runs and returns a cancelling status. |

Queued mode is the default. Clients can either use the returned `lemon.runId`
with `agent.wait`, subscribe to `/ws` events, or set `wait: true` plus optional
`timeout_ms` / `timeoutMs` to wait synchronously through the same `agent.wait`
path.

`stream: true` returns `text/event-stream` and subscribes the HTTP process to
the run topic. Chat Completions streams `chat.completion.chunk` objects for
`:delta` events, emits redacted `lemon.tool_progress` events for
`:engine_action` updates, and ends with `data: [DONE]`. Responses streams
`response.output_text.delta`, redacted `response.tool_progress`, and
`response.completed` events, also ending with `data: [DONE]`.

## Request Shape

`POST /v1/chat/completions`:

```json
{
  "model": "zai:glm-5-turbo",
  "messages": [
    {"role": "system", "content": "be brief"},
    {
      "role": "user",
      "content": [
        {"type": "text", "text": "hello"},
        {
          "type": "image_url",
          "image_url": {
            "url": "https://example.test/image.png",
            "detail": "high"
          }
        }
      ]
    }
  ],
  "metadata": {
    "session_key": "agent:default:openai"
  },
  "wait": true,
  "timeout_ms": 60000
}
```

`POST /v1/responses`:

```json
{
  "model": "openai:gpt-4o",
  "input": [
    {
      "type": "message",
      "role": "user",
      "content": [
        {"type": "input_text", "text": "hello"},
        {"type": "input_image", "image_url": "data:image/png;base64,..."}
      ]
    }
  ],
  "agent_id": "default",
  "previous_response_id": "resp_run_...",
  "wait": true
}
```

## Response Boundary

Both generation endpoints return Lemon metadata:

```json
{
  "lemon": {
    "runId": "run_...",
    "sessionKey": "agent:default:openai",
    "imageInputCount": 1,
    "status": "queued",
    "events": {
      "jsonRpc": "agent.wait",
      "webSocket": "/ws"
    }
  }
}
```

With `wait: true`, successful runs return `lemon.status: "completed"` and map
the completed Lemon answer into assistant text. Wait timeouts return HTTP `504`.
Responses use `resp_<run_id>` ids; `GET /v1/responses/:response_id` reads the
stored Lemon run and maps completed answers back into Responses output text.
`previous_response_id` validates the prior response and defaults the follow-up
run to the prior session key, so continuation stays on Lemon's supervised
session/run-history path.
`GET /v1/runs/:run_id` and `POST /v1/runs/:run_id/cancel` expose a minimal run
status/cancellation boundary without returning raw run events or assistant
answers from status calls.

Image input is now a split boundary. Chat Completions accepts `image_url`
parts, and Responses accepts `input_image` parts with HTTP(S) URLs, data URLs,
or `file_id`. By default, HTTP(S) URLs and file ids remain metadata-only: they
are hashed, redacted, added as bounded `[image input ...]` placeholders, and
never returned raw. Base64 data URLs are validated at the API boundary,
size/count-limited, redacted from prompts and metadata, and threaded as
runtime-only image blocks through `RunRequest`, the router, gateway,
`LemonRunner`, and `CodingAgent.Session.prompt/3` so native Lemon providers can
receive `LemonAi.Types.ImageContent`. HTTPS image URL fetch is available only when
explicitly enabled and host-allowlisted. In that mode, fetched image bytes are
MIME-checked, size-limited, base64 encoded, redacted from prompt/metadata, and
sent through the same runtime-only image path as data URLs. Only redacted image
metadata and `lemon.imageInputCount` are exposed in HTTP responses or
run-status payloads.

For known provider-prefixed models, runtime image bytes are rejected before run
submission when Lemon's model catalog says the model is text-only. Metadata-only
URL/file references remain allowed because they are redacted prompt context, not
provider-visible image bytes. `/v1/models` and `/v1/models/:model_id` expose the
same `lemon.supportsVision` capability so clients can choose a compatible model
before sending data URL or allowlisted fetched-image requests.

URL image fetching is disabled unless `:openai_compat_image_url_fetch` or
`LEMON_OPENAI_COMPAT_IMAGE_URL_FETCH=true` is set. Fetching requires an allowed
host list through `:openai_compat_image_url_allowed_hosts`,
`LEMON_OPENAI_COMPAT_IMAGE_URL_ALLOWED_HOSTS`, or
`LEMON_OPENAI_COMPAT_IMAGE_HOST_ALLOWLIST`. The preview policy accepts HTTPS
only and rejects non-allowlisted hosts before starting a Lemon run.

By default the preview `/v1` surface is unauthenticated for local development.
Set `:openai_compat_api_token` in `:lemon_control_plane` application config or
`LEMON_OPENAI_COMPAT_API_TOKEN` / `LEMON_OPENAI_COMPAT_TOKEN` in the environment
to require either `Authorization: Bearer <token>` or `x-api-key: <token>`.

This keeps the compatibility slice honest while the stable adapter adds broader
Responses API fields, deployed editor UI coverage, and more provider-specific
image transport proof beyond the passing OpenRouter vision proof.

## Proof Lane

```bash
mix test apps/lemon_control_plane/test/lemon_control_plane/http/router_test.exs --seed 1
```

The latest focused lane passed locally on 2026-05-17 with `25 tests, 0
failures`. It covers health, capabilities, model list shape, single-model
retrieve shape, chat-completions run submission, responses run submission,
synchronous wait completion,
Responses output text mapping, wait timeout handling, session-key metadata,
`previous_response_id` continuation metadata, stored response retrieval,
unknown stored response errors, streaming flag metadata, redacted run status,
unknown-run errors, run cancellation dispatch, Chat Completions SSE over run bus
events, Responses SSE over run bus events, redacted tool-progress SSE events
without raw tool detail, optional bearer auth, optional `x-api-key` auth,
redacted image-input metadata normalization for Chat Completions and Responses,
data URL image pass-through into runtime-only Lemon image blocks, opt-in
allowlisted HTTPS image URL fetch into runtime-only image blocks, disallowed
remote image host rejection before submission, `supportsVision` model metadata,
known non-vision model rejection before runtime-image submission, prompt
normalization, and validation errors without starting a real model run.

