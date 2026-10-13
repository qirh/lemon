# Agent Client Protocol

Lemon can be launched as an ACP stdio agent by Tern and other ACP clients:

```bash
lemon acp
# Source checkout:
./bin/lemon acp
```

The launcher probes the local control plane and reuses a healthy daemon. If
needed, it starts the daemon using the same managed credential and lifecycle
path as the TUI. The stdio process is only a duplex client of that runtime: it
never starts a second router, scheduler, or session store. Runtime logs stay in
the daemon log; launch diagnostics go to stderr. Stdout contains only ACP JSON.

See [Lemon in Tern](../user-guide/tern.md) for native chat registration.

## Configure a client

Use a command and argument array, not a shell command string:

```json
{
  "command": "lemon",
  "args": ["acp"]
}
```

Launch in the project directory. ACP `session/new` takes an absolute `cwd`; if a
client omits it, Lemon supplies the original launcher directory rather than the
source checkout. A Tern launch sends the pane directory explicitly. Model keys
and OAuth state are resolved by the existing runtime from Lemon's configuration
and encrypted secret store, not by the spawned stdio process.

`LEMON_CONTROL_PLANE_PORT` selects the runtime (default `4040`). Managed
launchers load the port's operator credential; explicitly managed runtimes can
use `LEMON_CONTROL_PLANE_OPERATOR_TOKEN` or `LEMON_WS_TOKEN`. Credentials are not
passed in argv or ACP messages. The internal `GET /acp/ws` duplex endpoint
requires operator read/write/approval authorization. Tokenless access is
available only under the existing explicit direct-loopback compatibility policy.

## Framing and lifecycle

ACP uses newline-delimited JSON-RPC 2.0. Each nonempty stdin line is one request,
notification, or response to an agent-to-client request. Responses and live
`session/update` notifications are one JSON document per stdout line. Empty
lines are ignored and malformed JSON receives `-32700`.

For example, this negotiates capabilities against the real runtime:

```bash
printf '%s\n' \
  '{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"protocolVersion":1}}' \
  | lemon acp
```

Interactive clients keep stdin open. `session/prompt` streams updates before
its final response. Clients answer `session/request_permission` and filesystem
requests with ordinary JSON-RPC responses carrying the request's id. A pending
permission does not prevent receiving cancel or other control messages.

Prompt turns wait up to ten minutes by default; clients can override the bounded
wait through `_meta.lemon.timeoutMs`. The `/compact [instructions]` command
compacts the idle native session, retaining the durable transcript. Session
load/resume replay persisted native messages and tool history; close cancels an
active turn and retains the session for later resume. Fork creates a durable
branch rather than a new empty chat.

Session configuration exposes code/plan mode, registry model selection,
thinking level and approval policy. Plan mode is read-only; approval choices
cannot override administrator restrictions. Existing local provider credentials
use the `agent` authentication method. Image/audio/embedded resources and
client-provided MCP transports are rejected unless actually supported by the
negotiated capabilities.

`session/cancel` cancels the session's active turn. `$/cancel_request` maps the
original prompt request id to its session and cancels that turn, waking any
pending client callbacks. Stdin EOF closes the connection and cancels active
turns, without stopping the daemon or deleting durable sessions. Short piped
requests are drained before exit. Transport failures exit `1`; invalid CLI
arguments exit `2`; clean EOF exits `0`.

Session creation/fork bootstrap updates are delivered after their result so
clients know the session id before processing updates. History replay on load
is delivered before the load result. Use the capabilities returned by
`initialize` as the authoritative supported feature set.

## Rich session updates

Lemon maps runtime events to ACP text/thought chunks and tool calls. Tool calls
begin with `tool_call` and advance through `tool_call_update`; editor locations
use absolute paths. Small complete file changes use typed ACP diff content
(up to 16 KiB per side); larger changes use a bounded textual preview. Tool
text previews are bounded to 4 KiB and raw previews share a 32 KiB bound.

Usage with a known context window is exposed as `usage_update`; accounting
without a known window uses vendor metadata instead of inventing a context
percentage. The context gauge measures the latest request's input, cached
tokens and output—not the sum of every request in a tool-heavy turn. Turn usage
and cost totals aggregate the assistant responses separately. Context limits
are model- and provider-surface-specific; the Codex and direct OpenAI versions
of a model need not have the same window.

Plans preserve task priorities and completion state. Retry, compaction and
subagent lifecycle events use native notices, compaction and subagent updates.
The runtime preserves message and tool ids so a client can append streams and
update cards rather than duplicating them.

Negotiated client filesystem support lets model-facing coding tools read and
write editor-managed text buffers through the existing ACP client bridge. Raw
client capability blobs and editor contents are not copied into management
projections. Unsupported media or MCP capabilities must not be inferred from
registration: inspect the negotiated capabilities.

## HTTP integration

`POST /acp` remains a single request/response endpoint for JSON-RPC requests or
batches. It cannot round-trip client requests or stream notifications; use
`lemon acp` for interactive integrations.

The HTTP endpoint's optional `LEMON_ACP_API_TOKEN` (or application setting
`:acp_api_token`) is independent of the internal runtime operator credential.
When configured, send it as `Authorization: Bearer <token>` or `x-api-key`.

The obsolete `scripts/lemon_acp_stdio.exs` runtime-boot script is removed. Client
configurations must use `lemon acp`; there is no second runtime or fake runtime
mode in the stdio agent.
