# ACP Preview

Lemon exposes a preview Agent Client Protocol bridge for ACP-shaped clients
that need to create sessions and submit prompt turns into Lemon. The bridge is
intentionally thin: it maps ACP JSON-RPC requests onto the existing Lemon router
run graph instead of creating a separate runtime path.

The current preview is implemented by `LemonControlPlane.ACP`, exposed over HTTP
at `POST /acp`, and packaged for spawned stdio clients through
`scripts/lemon_acp_stdio.exs`. It follows the official ACP JSON-RPC method shape
for the methods it advertises, while keeping unsupported media and editor
features out of the capability response.

## Supported Methods

| Method | Status | Behavior |
| --- | --- | --- |
| `initialize` | Preview | Negotiates protocol version and returns Lemon agent metadata plus honest capabilities and a safe summary of advertised client filesystem capabilities. |
| `session/new` | Preview | Creates a Lemon-backed ACP session for an absolute `cwd`, records safe client filesystem capability booleans, and returns an opaque `sessionId`. |
| `session/resume` | Preview | Recreates a session mapping for an existing ACP `sessionId` and `cwd`, preserving or refreshing safe client filesystem capability booleans. |
| `session/list` | Preview | Lists store-backed ACP sessions, with optional `cwd` filtering and redacted client filesystem capability metadata. |
| `session/prompt` | Preview | Converts ACP `text` and `resource_link` prompt blocks into a Lemon prompt, submits a router run, emits stdio `session/update` notifications while waiting, and returns ACP `stopReason` plus Lemon metadata. |
| `session/cancel` | Preview | Cancels the latest known run for the ACP session through `LemonRouter.abort_run/2`. |
| `session/close` | Preview | Cancels the latest known run and removes the ACP session mapping from the cache and store. |

The bridge advertises `sessionCapabilities.close`, `sessionCapabilities.list`,
and `sessionCapabilities.resume`. It does not advertise image, audio, embedded
resource, MCP HTTP, or MCP SSE support yet.

## Request Shape

`POST /acp` accepts JSON-RPC 2.0 request objects or batches:

```json
{
  "jsonrpc": "2.0",
  "id": "init-1",
  "method": "initialize",
  "params": {
    "protocolVersion": "1",
    "clientInfo": {
      "name": "example-client",
      "version": "0.1.0"
    }
  }
}
```

Create a session:

```json
{
  "jsonrpc": "2.0",
  "id": "new-1",
  "method": "session/new",
  "params": {
    "cwd": "/home/z80/dev/lemon",
    "mcpServers": []
  }
}
```

Submit a prompt:

```json
{
  "jsonrpc": "2.0",
  "id": "prompt-1",
  "method": "session/prompt",
  "params": {
    "sessionId": "acp_...",
    "prompt": [
      {
        "type": "text",
        "text": "Review the current checkout."
      },
      {
        "type": "resource_link",
        "name": "mix.exs",
        "uri": "file:///home/z80/dev/lemon/mix.exs",
        "mimeType": "text/x-elixir"
      }
    ],
    "_meta": {
      "lemon": {
        "timeoutMs": 60000,
        "model": "openai:gpt-5"
      }
    }
  }
}
```

By default, `session/prompt` waits through the same `agent.wait` path used by
the control-plane API. Set `_meta.lemon.wait` to `false` to submit a queued run
and return immediately. The response includes ACP `stopReason` and a
`_meta.lemon` object with `runId`, `sessionId`, `sessionKey`, status, and the
completed answer when a wait succeeds.

## Session Updates

When a stdio `session/prompt` waits for a Lemon run, the NDJSON runner
subscribes to the run topic and emits ACP `session/update` notifications before
the final prompt response:

- Lemon `:delta` events become `agent_message_chunk` updates with text content.
- Lemon `:engine_action` events become `tool_call_update` updates with tool
  call id, title, kind, status, and redacted message content.

The same stdio transport can also round-trip ACP agent-to-client JSON-RPC
requests while a prompt is waiting. Lemon currently uses this preview bridge
for `session/request_permission`, `fs/read_text_file`, and
`fs/write_text_file`, `fs/delete_file`, and `fs/rename_file` events emitted on
the run bus. It also subscribes to the shared `LemonCore.ExecApprovals` bus for
the active ACP session key and maps matching approval requests to ACP
`session/request_permission` decisions. The final prompt response records only
redacted request summaries, such as method names, permission outcomes, content
byte counts, and content hashes.

During stdio `initialize`, Lemon captures only safe booleans from
`clientCapabilities.fs.readTextFile` and
`clientCapabilities.fs.writeTextFile`, `clientCapabilities.fs.deleteFile`, and
`clientCapabilities.fs.renameFile`. Those booleans are carried into
`session/new` and `session/resume`, surfaced through `session/list`, and copied
into the Lemon run request metadata as `acp_client_fs_read_text_file`,
`acp_client_fs_write_text_file`, `acp_client_fs_delete_file`, and
`acp_client_fs_rename_file`. Raw client capability blobs are not stored in
prompt metadata.

When both the ACP session metadata and tool options show filesystem support,
Lemon's model-facing `read`, `write`, `edit`, and `patch` tools route text file
operations through the ACP client instead of the local filesystem. The bridge
uses the run bus to emit correlated `fs/read_text_file` and
`fs/write_text_file`, `fs/delete_file`, and `fs/rename_file` requests and waits
for the stdio ACP response. `patch` supports add, update, delete, and move-only
operations through ACP when the matching client filesystem capabilities are
available. Update+move patches that change content use read/write/delete because
the target content is rewritten before the old path is removed.

HTTP `/acp` remains a single request/response JSON-RPC endpoint. Use stdio or a
future streaming transport when clients need live ACP update notifications.

## Authentication

Set `:acp_api_token` in `:lemon_control_plane` config or
`LEMON_ACP_API_TOKEN` in the environment to require authentication on `/acp`.
Authenticated clients can send either:

```text
Authorization: Bearer <token>
```

or:

```text
x-api-key: <token>
```

The stdio runner does not perform HTTP header auth. Use it only in contexts
where the spawned local process boundary is already trusted, or wrap it with the
client/editor's own launch policy.

## Stdio Runner

ACP's TypeScript SDK documents newline-delimited JSON as the common stdio stream
format. Lemon's stdio preview uses the same line-oriented shape:

```bash
printf '%s\n' \
  '{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"protocolVersion":"1"}}' \
  | mix run --no-start scripts/lemon_acp_stdio.exs
```

Each non-empty input line must be a JSON-RPC request or notification. Each
response is emitted as one JSON line. Waiting prompt calls can also emit
intermediate `session/update` notification lines and agent-to-client request
lines before the final response. Clients answer those request lines by sending a
normal JSON-RPC response with the same id. Empty input lines are ignored, parse
errors return JSON-RPC `-32700`, and notifications with no `id` do not emit a
response. The `--no-start` form is useful for protocol-shape smoke tests that do
not submit runs. Spawned clients that need `session/prompt` to reach the router
must run the script in a Lemon runtime where the router is started.

## Boundaries

The preview session store uses Lemon's shared store with an ETS read cache. It
is suitable for early editor/client integration proof, but it is not a full
editor workspace/session index.
Stable ACP support still needs:

- real editor UI compatibility proof against a deployed ACP editor
- raw media/artifact support before advertising image, audio, or embedded
  resource prompt capabilities
- ACP delete/rename compatibility proof against a real editor client

