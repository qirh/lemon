# LemonControlPlane

HTTP and WebSocket control plane API server for the Lemon agent system. Provides a frame-based JSON protocol over WebSocket for real-time bidirectional communication.


## Overview
LemonControlPlane is the external interface through which clients (terminal UI, web dashboards, mobile apps, browser extensions) interact with the Lemon agent runtime. It exposes 80 JSON-RPC methods over WebSocket for submitting agent runs, managing sessions, configuring the system, scheduling cron jobs, pairing nodes, and streaming real-time events.



It is also the controller transport for named coding execution nodes. Paired
nodes authenticate as the restricted `node` role, register one live connection
under a durable unique name, and receive targeted native `coding_agent.run`
invocations through `LemonCore.NodeRegistry`.

The server runs on [Bandit](https://github.com/mtrudel/bandit) with [Plug](https://github.com/elixir-plug/plug) routing, and uses [WebSockAdapter](https://github.com/phoenixframework/websock_adapter) for WebSocket upgrades.

## Architecture
```
+-----------------+     HTTP/WebSocket      +------------------+
|  Clients (TUI)  |<----------------------->|  Bandit Server   |
|  Web, Mobile    |      Port 4040          |  (Router plug)   |
+-----------------+                         +--------+---------+
                                                     |
                    +--------------------------------+---------------------------+
                    |                 |               |                          |
             +------v------+  +------v------+  +-----v----------+  +-----------v---------+
             |  /healthz   |  |     /ws        |  |  404 fallback       |
             |  (GET JSON) |  |  (WebSocket)   |  |                     |
             +-------------+  +------+---------+  +---------------------+
                                                      |
                      +-------------------------------+-------------------------------+
                      |                               |                               |
               +------v------+              +---------v---------+           +---------v---------+
               |   Connect   |              |  Request Frame    |           |   Event Bridge    |
               |  Handshake  |              |   Dispatch        |           |  (Bus -> WS)      |
               +-------------+              +--------+----------+           +-------------------+
                                                     |
                                             +-------v--------+
                                             | Schema Validate|
                                             | (Schemas mod)  |
                                             +-------+--------+
                                                     |
                                             +-------v--------+
                                             | Method Registry|
                                             | (ETS lookup)   |
                                             +-------+--------+
                                                     |
                                             +-------v--------+
                                             |  Auth Check    |
                                             |  (scopes)      |
                                             +-------+--------+
                                                     |
                                             +-------v--------+
                                             | Method Handler |
                                             +----------------+
```

### Request Lifecycle

1. A JSON text frame arrives on the WebSocket connection.
2. `Protocol.Frames.parse/1` decodes and validates the frame structure.
3. If the connection has not yet completed the handshake, only `connect` is allowed; all other methods return `HANDSHAKE_REQUIRED`.
4. For `connect`, `Auth.Authorize.from_params/2` establishes the auth context from the credential and actual socket peer, and a `hello-ok` frame is returned.
5. For all other methods, `Protocol.Schemas.validate/2` checks required/optional parameter types.
6. `Methods.Registry.dispatch/3` looks up the handler module in the ETS table.
7. `Auth.Authorize.authorize/3` verifies the connection has the required scopes for the method.
8. The handler's `handle/2` callback executes and returns `{:ok, payload}` or `{:error, ...}`.
9. `Protocol.Frames.encode_response/2` serializes the result to JSON and pushes it to the client.

### Supervision Tree

```
LemonControlPlane.Supervisor (one_for_one)
  |-- Methods.Registry          (GenServer, ETS-backed method dispatch)
  |-- Presence                  (GenServer, ETS-backed client tracking)
  |-- EventBridge.FanoutSupervisor  (Task.Supervisor for broadcast dispatch)
  |-- EventBridge              (GenServer, Bus -> WebSocket event fanout)
  |-- ConnectionSupervisor     (DynamicSupervisor for WS connections)
  |-- ConnectionRegistry       (Registry for connection process lookup)
  |-- Bandit                   (HTTP server, Plug router)
  |-- A2A.TaskSupervisor       (A2A runs outlive HTTP/SSE clients)
  |-- A2A.RateLimiter          (per-authenticated-peer request bounds, when enabled)
  |-- A2A.Server               (optional A2A v1.0 listener, default port 9901)
```

## HTTP Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/healthz` | Health check, returns `{"ok": true}` |
| GET | `/ws` | WebSocket upgrade endpoint |
| GET | `/v1/health` | OpenAI-compatible preview health metadata |
| GET | `/v1/capabilities` | OpenAI-compatible preview capability metadata |
| GET | `/v1/models` | OpenAI-compatible model list shape backed by Lemon model metadata, including `supportsVision` |
| POST | `/v1/chat/completions` | Preview adapter that submits a Lemon run and returns queued `chat.completion` metadata by default, assistant text with `wait: true`, or SSE chunks with `stream: true`; accepts redacted URL/file-id image metadata, data URL image pass-through, and opt-in allowlisted HTTPS image URL fetch, and rejects runtime image bytes for known text-only models before submission |
| POST | `/v1/responses` | Preview adapter that submits a Lemon run and returns a queued `response` object by default, output text with `wait: true`, or Responses-style SSE events with `stream: true`; accepts redacted URL/file-id image metadata, data URL image pass-through, opt-in allowlisted HTTPS image URL fetch, and `previous_response_id` for session continuation, and rejects runtime image bytes for known text-only models before submission |
| GET | `/v1/responses/:response_id` | Preview stored response retrieval for `resp_<run_id>` over the Lemon run store |
| GET | `/v1/runs/:run_id` | Preview redacted run status metadata |
| POST | `/v1/runs/:run_id/cancel` | Preview run cancellation dispatch through the Lemon router |
| POST | `/acp` | Preview Agent Client Protocol JSON-RPC bridge for initialize, session lifecycle, prompt, cancel, and close over Lemon router runs |

When `[gateway] enable_a2a = true`, a separate listener serves the A2A v1.0
Agent Card, JSON-RPC, and SSE task surface on port 9901 by default. It is kept
off the operator control-plane port so peer credentials and exposure policy do
not become control-plane authorization. See
[`docs/user-guide/a2a-peers.md`](../../docs/user-guide/a2a-peers.md).
Accepted cancellation is a terminal, first-writer-wins task transition: a
delayed submission or run completion cannot revive a canceled task, add an
agent reply, or increment its context turn count. Router/store failures are
mapped to fixed bounded A2A error messages; internal reasons, paths, and secret
values never cross the peer wire. If submission acknowledgement is lost, the
runner never retries: it reconciles the caller-generated run ID for one bounded
wait and otherwise leaves the task working with a fixed reconciliation status.
Later task reads reconcile durable completion through that same run ID. An
ambiguous cancellation acknowledgement likewise never invents a canceled task.

`profile.chat` also generates its run ID before router submission. A definite
acknowledgement returns the ordinary success projection; an ambiguous
acknowledgement returns a bounded `UNAVAILABLE` error containing that run ID,
the stable profile/session identifiers, and `retrySafe: false`. Raw router
reasons are neither logged nor returned by the profile methods.

The `/v1` generation endpoints are compatibility adapters, not a separate
runtime path. They submit through the Lemon router and return `lemon.runId` by
default; clients can use `/ws` events, call `agent.wait`, or set `wait: true`
with optional `timeout_ms` / `timeoutMs` to synchronously wait through the same
`agent.wait` path. With `stream: true`, the HTTP process subscribes to the run
topic and returns `text/event-stream` chunks from Lemon run bus events,
including redacted tool-progress events for `:engine_action` updates. Run
status responses intentionally omit raw run events and assistant answer text.
Stored Responses use `resp_<run_id>` ids, and `previous_response_id` reuses the
prior response session key by default. Image input has a split boundary:
HTTP(S) URLs and file ids are hashed/redacted into run metadata and bounded
prompt placeholders by default, while base64 data URLs are validated,
size/count-limited, redacted from prompts and metadata, and passed as
runtime-only image blocks to native Lemon providers. HTTPS image URL fetch is
available only when `:openai_compat_image_url_fetch` or
`LEMON_OPENAI_COMPAT_IMAGE_URL_FETCH=true` is set and the host is present in
`:openai_compat_image_url_allowed_hosts`,
`LEMON_OPENAI_COMPAT_IMAGE_URL_ALLOWED_HOSTS`, or
`LEMON_OPENAI_COMPAT_IMAGE_HOST_ALLOWLIST`; fetched images use the same
runtime-only image path. Raw image references are omitted from HTTP responses
and status payloads.
Set `:openai_compat_api_token`,
`LEMON_OPENAI_COMPAT_API_TOKEN`, or `LEMON_OPENAI_COMPAT_TOKEN` to require
`Authorization: Bearer <token>` or `x-api-key: <token>` on `/v1`.

The `/acp` endpoint is also an adapter over the existing router/run graph. It
supports JSON-RPC `initialize`, `session/new`, `session/resume`, `session/list`,
`session/prompt`, `session/cancel`, and `session/close`. `session/prompt`
accepts ACP `text` and `resource_link` blocks, submits a supervised Lemon run,
and either waits through `agent.wait` or returns queued metadata when
`_meta.lemon.wait` is `false`. The same handler is available to spawned
line-oriented stdio clients through `scripts/lemon_acp_stdio.exs`, using ACP's
newline-delimited JSON stream shape. Waiting stdio prompts emit intermediate
`session/update` notification lines for Lemon text deltas and redacted tool
progress before the final response. The stdio bridge can round-trip
`session/request_permission`, `fs/read_text_file`, `fs/write_text_file`,
`fs/delete_file`, and `fs/rename_file` client requests while the prompt waits,
and carries only safe filesystem capability booleans into Lemon run metadata.
The capability response intentionally leaves image, audio, embedded-resource,
MCP HTTP, and MCP SSE support disabled until those paths have safe artifact and
streaming contracts. Set
`:acp_api_token` or `LEMON_ACP_API_TOKEN` to require bearer or `x-api-key` auth
for HTTP.

## WebSocket Protocol

### Frame Types

**Request** (client to server):
```json
{
  "type": "req",
  "id": "<uuid>",
  "method": "<method_name>",
  "params": {}
}
```

**Response** (server to client):
```json
{
  "type": "res",
  "id": "<uuid>",
  "ok": true,
  "payload": {}
}
```

```json
{
  "type": "res",
  "id": "<uuid>",
  "ok": false,
  "error": {"code": "NOT_FOUND", "message": "..."}
}
```

**Event** (server to client, asynchronous):
```json
{
  "type": "event",
  "event": "<event_name>",
  "seq": 1,
  "payload": {},
  "stateVersion": {"presence": 2, "health": 0, "cron": 1}
}
```

Method handlers run inline by default. A handler that can wait for human input
or slow external work may declare `dispatch_mode/0` as `:async`; the server then
keeps the correlated request open while the WebSocket process continues to
deliver events and answer other requests. Approval-gated `skills.install` uses this
mode so its approval events and client liveness probes cannot deadlock behind the
pending mutation.
Async handlers must use the
`conn_pid` in their context when they need the authenticated connection; they
must not assume their own `self()` is the socket process.

**Hello-OK** (handshake completion, replaces `res` for `connect`):
```json
{
  "type": "hello-ok",
  "protocol": 1,
  "server": {
    "version": "0.1.0",
    "commit": "abc123",
    "host": "hostname",
    "connId": "<uuid>"
  },
  "features": {
    "methods": ["health", "status", "agent", "..."],
    "events": ["agent", "chat", "presence", "..."]
  },
  "snapshot": {
    "presence": {},
    "health": {"ok": true}
  },
  "policy": {
    "maxPayload": 1048576,
    "maxBufferedBytes": 8388608,
    "tickIntervalMs": 1000
  },
  "auth": {
    "role": "operator",
    "scopes": ["admin", "read", "write", "approvals", "pairing"]
  }
}
```

### Connection Handshake

1. Client connects to `ws://host:4040/ws`.
2. Client sends a `connect` request:
   ```json
   {
     "type": "req",
     "id": "uuid",
     "method": "connect",
     "params": {
       "role": "operator",
       "scopes": ["operator.read", "operator.write"],
       "auth": {"token": "optional-session-token"},
       "client": {"id": "my-client"}
     }
   }
   ```
3. Server responds with a `hello-ok` frame containing available methods, events, initial snapshot, and the resolved auth context.
4. All subsequent requests use the established auth context.
5. Sending `connect` again on the same connection returns `ALREADY_CONNECTED`.

### Error Codes

| Code | Atom | Description |
|------|------|-------------|
| `INVALID_REQUEST` | `:invalid_request` | Malformed request or missing required fields |
| `INVALID_PARAMS` | `:invalid_params` | Invalid method parameters |
| `METHOD_NOT_FOUND` | `:method_not_found` | Unknown method name |
| `UNAUTHORIZED` | `:unauthorized` | Authentication required or invalid token |
| `FORBIDDEN` | `:forbidden` | Insufficient permissions |
| `NOT_FOUND` | `:not_found` | Requested resource not found |
| `CONFLICT` | `:conflict` | Resource state conflict |
| `RATE_LIMITED` | `:rate_limited` | Too many requests |
| `TIMEOUT` | `:timeout` | Operation timed out |
| `INTERNAL_ERROR` | `:internal_error` | Server error |
| `NOT_IMPLEMENTED` | `:not_implemented` | Method not yet implemented |
| `HANDSHAKE_REQUIRED` | `:handshake_required` | Must complete `connect` handshake first |
| `ALREADY_CONNECTED` | `:already_connected` | Connection already established |
| `UNAVAILABLE` | `:unavailable` | Resource temporarily unavailable |

## Authentication and Authorization

### Roles and Scopes

| Role | Scopes | How Established |
|------|--------|-----------------|
| `operator` | `admin`, `read`, `write`, `approvals`, `pairing` | `LEMON_CONTROL_PLANE_OPERATOR_TOKEN`; legacy tokenless direct-loopback access requires an explicit compatibility opt-in |
| `node` | `invoke`, `event` | Token from `connect.challenge` after node pairing |

Set `LEMON_CONTROL_PLANE_OPERATOR_TOKEN` to a high-entropy value. Operator
clients send it as `auth.token` in the `connect` request, never in the
WebSocket URL.

### Token-Based Authentication (Nodes)

1. A node requests pairing with `node.pair.request`.
2. An operator approves it with `node.pair.approve`, which returns a one-time
   challenge.
3. The node exchanges that challenge with `connect.challenge` for a session
   token, then uses the token in future `connect` requests.

`./bin/lemon node join --pair` automates the exchange. Node credentials are
bound to the controller and stored separately from the operator credential.

Each method declares required scopes; a connection must have at least one
matching scope. Methods with no required scopes are public.
## API Method Inventory

The control plane exposes these 80 retained methods:

| Methods |
|---------|
| `agent`, `agent.directory.list`, `agent.wait`, `agents.list` |
| `background.cancel`, `background.list`, `background.result`, `background.start`, `background.status` |
| `blueprints.activate`, `blueprints.inspect`, `blueprints.list`, `blueprints.preview`, `blueprints.validate` |
| `chat.abort`, `chat.history`, `chat.send`, `commands.catalog` |
| `config.get`, `config.set`, `connect.challenge` |
| `cron.abort`, `cron.add`, `cron.audit`, `cron.list`, `cron.pause`, `cron.remove`, `cron.resume`, `cron.run`, `cron.runs`, `cron.status`, `cron.update` |
| `exec.approval.resolve`, `exec.approvals.get` |
| `goal.clear`, `goal.pause`, `goal.resume`, `goal.set`, `goal.status` |
| `health`, `logs.tail`, `models.list`, `node.invoke`, `node.invoke.control.result`, `node.invoke.result`, `node.pair.approve`, `node.pair.request` |
| `profile.chat`, `profiles.clone`, `profiles.create`, `profiles.delete`, `profiles.export`, `profiles.get`, `profiles.list`, `profiles.rename`, `profiles.roster` |
| `runs.active.list`, `runs.recent.list` |
| `session.btw`, `session.detail`, `sessions.active`, `sessions.active.list`, `sessions.compact`, `sessions.delete`, `sessions.export`, `sessions.heartbeat`, `sessions.list`, `sessions.metadata.patch`, `sessions.patch`, `sessions.preview`, `sessions.prune`, `sessions.reset`, `sessions.stats` |
| `skills.hermes.catalog`, `skills.install`, `status`, `tasks.active.list`, `tasks.recent.list`, `usage.cost`, `usage.status` |
## Event System

The EventBridge forwards bus events to WebSocket clients. Each non-node client
receives all events; node connections receive only targeted node traffic.

### WebSocket Events

The server emits run, chat, goal, presence, tick, heartbeat, approval, cron,
task, shutdown, health, and node pairing/invocation events. Approval events
include structured action metadata and report timeouts as
`exec.approval.resolved` with `decision: "timeout"`.

## Presence System

`LemonControlPlane.Presence` is an ETS-backed GenServer that tracks all connected WebSocket clients. It provides:

- Registration/unregistration on connect/disconnect
- Role-based counting (operators and nodes)
- Client lookup by connection ID
- Broadcast to non-node clients; node connections receive targeted traffic
- Automatic `presence_changed` bus event emission on changes

## Schema Validation

Method parameters are validated against schemas defined in `Protocol.Schemas` before dispatch. Server-to-client event payloads that need stable client contracts also have event schemas in the same module and can be checked with `validate_event/2`.

- **Required fields** with types -- requests missing these fields are rejected.
- **Optional fields** with types -- provided values are type-checked.
- **Supported types**: `:string`, `:integer`, `:boolean`, `:map`, `:list`, `:any`.

Methods or events without a schema entry accept any parameters. Approval events currently have schema-backed payload contracts so operator clients can rely on `exec.approval.requested` and `exec.approval.resolved` metadata, including `decision: "timeout"` when a pending approval expires.


### Port Configuration

```elixir
config :lemon_control_plane, port: 4040
```

In test mode, the port defaults to `0` (OS-assigned) to avoid conflicts.

## Dependencies

### Umbrella Dependencies

| App | Relationship |
|-----|-------------|
| `lemon_core` | Store, secrets, event bus, idempotency, telemetry |
| `lemon_router` | Run submission (`LemonRouter.submit/1`, `LemonRouter.RunOrchestrator`) |
| `lemon_channels` | Channel backends, Outbox for `send` method |
| `lemon_skills` | Skill management |
| `lemon_automation` | Cron manager, heartbeat features |
| `coding_agent` | Compile-time only (not started at runtime) |
| `agent_core` | Provider credential readiness checks through the model runtime |
| `ai` | AI/model integration |

### External Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| `bandit` | ~> 1.5 | HTTP/WebSocket server |
| `plug` | ~> 1.16 | HTTP routing and middleware |
| `websock_adapter` | ~> 0.5 | WebSocket adapter for Plug |
| `jason` | ~> 1.4 | JSON encoding/decoding |

## Running

```bash
# Start the umbrella (control plane starts automatically)
iex -S mix

# From a destination source checkout, pair a named native execution node
LEMON_NODE_OPERATOR_TOKEN=... ./bin/lemon node join --name worker-1 \
  --controller ws://localhost:4040/ws --pair --cwd /path/to/project

# Run tests
mix test apps/lemon_control_plane

# Run a specific test file
mix test apps/lemon_control_plane/test/lemon_control_plane/methods/control_plane_methods_test.exs

# Safe catalog resolution, exact confirmation, and duplicate-safe activation
mix test apps/lemon_control_plane/test/lemon_control_plane/methods/blueprints_test.exs --seed 1
```

The server starts automatically via the OTP application supervision tree. Connect with any WebSocket client to `ws://localhost:4040/ws` and send a `connect` request to begin.
