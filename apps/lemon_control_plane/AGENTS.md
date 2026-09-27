# Lemon Control Plane - Agent Guide

HTTP/WebSocket API server for controlling the Lemon agent system.

## Quick Orientation

- **What**: The external API surface for the entire Lemon agent system. Clients (TUI, web, mobile, browser extensions) communicate through this app via WebSocket JSON-RPC and REST HTTP endpoints.
- **Where**: `apps/lemon_control_plane/` in the umbrella.
- **Stack**: Bandit HTTP server, Plug router, WebSock for WebSocket, ETS-backed method registry.
- **Port**: 4040 in production, 0 (OS-assigned) in test.
- **Entry point**: `LemonControlPlane.Application` starts the supervision tree.

## Purpose and Responsibilities

The application also owns Lemon's optional A2A v1.0 network edge. Keep A2A
authentication, Agent Cards, JSON-RPC/SSE framing, rate limiting, and supervised
task reattachment in `LemonControlPlane.A2A.*`. Conversation persistence and
generic wire/client helpers belong to `lemon_core`; agent-facing outbound peer
actions belong to `lemon_skills`. A2A peers are independent principals and
must never be treated as named execution nodes or operator WebSocket clients.
Task terminal transitions are first-writer-wins: accepted cancellation cannot
be overwritten by a delayed submit/finalize path, and no post-cancel agent
message or context turn may be recorded. A runner lease remains the terminal
write owner after submission becomes working; a stale reclaimed runner must
not publish failure, timeout, or completion over the newer owner. External A2A and `sessions.active`
errors must use fixed bounded messages; classify failures for logs without
interpolating raw reasons, paths, credentials, or exception messages.
A2A submission `:outcome_unknown` must never trigger a retry or a false failed
task: reconcile the original caller-generated run ID for a bounded interval,
retain a fixed nonterminal reconciliation status if it remains unknown, and
reconcile later task reads from durable run state. Ambiguous abort
acknowledgements do not prove cancellation. Profile chat follows the same
no-retry rule and returns a bounded uncertain receipt with its pre-generated
run ID and `retrySafe: false`; profile errors never inspect raw reasons into a
client response or log.
An inbound A2A `messageId` is a durable replay key. Repeating it for the same
authenticated peer returns the original task and never submits a second router
run; reusing it across peers is a conflict and fails closed.

The control plane provides the external interface for clients (TUI, web, mobile, browser extensions) to:

- **Submit agent runs** - Send prompts to agents via `agent` or `chat.send`
- **Manage sessions** - List and maintain conversation sessions
- **Configure the system** - Read and update supported config values
- **Schedule cron jobs** - Create recurring agent runs
- **Install skills** - Manage skills
- **Pair nodes** - Connect restricted clients, including named native coding execution nodes
- **Stream real-time events** - WebSocket events for runs, chat deltas, and approvals

## Architecture Overview

```
+-----------------+     HTTP/WebSocket      +------------------+
|  Clients (TUI)  |<----------------------->|  Bandit Server   |
|  Web, Mobile    |      Port 4040          |  (Router plug)   |
+-----------------+                         +--------+---------+
                                                     |
                    +--------------------------------+--------------------------+
                    |                 |               |                         |
             +------v------+  +-----v----------+  +----------v--------+
             |  /healthz   |  |     /ws        |  |  (404 fallback)   |
             |  (health)   |  |  (WebSocket)   |  |                   |
             +-------------+  +------+---------+  +-------------------+
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

## Key Modules

| Module | File | Purpose |
|--------|------|---------|
| `LemonControlPlane` | `lib/lemon_control_plane.ex` | Main module, protocol/server version |
| `LemonControlPlane.Application` | `lib/lemon_control_plane/application.ex` | OTP supervision tree |
| `LemonControlPlane.HTTP.Router` | `lib/lemon_control_plane/http/router.ex` | HTTP routing (Bandit/Plug): `/ws`, `/healthz`, preview `/v1` OpenAI-compatible endpoints, preview `/acp` JSON-RPC endpoint |
| `LemonControlPlane.OpenAICompat` | `lib/lemon_control_plane/openai_compat.ex` | Preview `/v1/models`, `/v1/chat/completions`, `/v1/responses`, `/v1/runs/*`, and stored response adapter over Lemon model metadata, router-submitted runs, optional `agent.wait` synchronous completion, SSE streaming with redacted tool progress, run-store response retrieval, `supportsVision` model metadata, redacted URL/file-id image metadata plus data URL and opt-in allowlisted URL runtime image pass-through with known text-only model rejection before submission, redacted run status, and cancellation dispatch |
| `LemonControlPlane.ACP` | `lib/lemon_control_plane/acp.ex` | Preview Agent Client Protocol JSON-RPC bridge for initialize, store-backed session lifecycle, text/resource-link prompt submission through Lemon router runs, wait/queued prompt behavior, run-bus `session/update` projection, ACP filesystem client-request summaries, cancel/close, and honest capability negotiation |
| `LemonControlPlane.ACP.NDJSON` | `lib/lemon_control_plane/acp/ndjson.ex` | Newline-delimited JSON transport helper used by `scripts/lemon_acp_stdio.exs` for spawned ACP stdio clients, including intermediate `session/update` notification lines and permission/read/write/delete/rename client requests while prompt waits are active |
| `LemonControlPlane.WS.Connection` | `lib/lemon_control_plane/ws/connection.ex` | WebSocket connection handler (`WebSock` behaviour) |
| `LemonControlPlane.Presence` | `lib/lemon_control_plane/presence.ex` | Connected client tracking (ETS-backed GenServer) |
| `LemonControlPlane.NodeStore` | `lib/lemon_control_plane/node_store.ex` | Durable node identities, unique-name reservations, pairing challenges, and invocation status |
| `LemonControlPlane.EventBridge` | `lib/lemon_control_plane/event_bridge.ex` | Bus events -> WebSocket fanout (GenServer + Task.Supervisor) |
| `LemonControlPlane.Auth.Authorize` | `lib/lemon_control_plane/auth/authorize.ex` | Role-based access control; peer-aware `from_params/2`, constant-time operator-token validation, `authorize/3`, `default_operator/0` |
| `LemonControlPlane.Auth.TokenStore` | `lib/lemon_control_plane/auth/token_store.ex` | Token storage/validation for node auth (backed by `LemonCore.Store`) |
| `LemonControlPlane.Methods.Registry` | `lib/lemon_control_plane/methods/registry.ex` | Method dispatch registry (ETS); `dispatch/3`, `register/1`, `unregister/1`. Also defines `LemonControlPlane.Method` behaviour. |
| `LemonControlPlane.Methods.CommandsCatalog` | `lib/lemon_control_plane/methods/commands_catalog.ex` | Read-only `commands.catalog` discovery projection over `LemonChannels.CommandCatalog`; execution remains with consuming surfaces and runtime owners. |
| `LemonControlPlane.Methods.Background*` / `SessionBtw` | `lib/lemon_control_plane/methods/background_commands.ex` | Provider-backed lifecycle RPCs for isolated `/bg` sessions and bounded no-tools `/btw` questions; the control plane owns only validation and wire projection. |
| `LemonControlPlane.Methods.Profiles*` / `ProfileChat` | `lib/lemon_control_plane/methods/profiles.ex` | Lifecycle, node-aware roster, credential-safe export, and stable canonical chat projection over `LemonCore.ProfileStore` and the existing router. |
| `LemonControlPlane.Protocol.Frames` | `lib/lemon_control_plane/protocol/frames.ex` | Protocol frame encoding/decoding; `parse/1`, `encode_response/2`, `encode_event/4`, `encode_hello_ok/1` |
| `LemonControlPlane.Protocol.Errors` | `lib/lemon_control_plane/protocol/errors.ex` | Standard error constructors; `invalid_request/1`, `not_found/1`, `forbidden/1`, etc. |
| `LemonControlPlane.Protocol.Schemas` | `lib/lemon_control_plane/protocol/schemas.ex` | Param and event payload schema validation; `validate/2`, `validate_event/2` |
| `LemonCore.NodeRegistry` | `apps/lemon_core/lib/lemon_core/node_registry.ex` | Live name/ID resolution, targeted delivery, timeout/cancellation, disconnect failure, and invocation ownership |

## JSON-RPC Method Structure

### Adding a New Method

**Step 1: Create the method module** in `lib/lemon_control_plane/methods/`:

```elixir
defmodule LemonControlPlane.Methods.MyMethod do
  @moduledoc """
  Handler for the my.method control plane method.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "my.method"

  @impl true
  def scopes, do: [:read]  # or :write, :admin, :approvals, :pairing, :invoke, :event

  @impl true
  def handle(params, ctx) do
    # params: map() | nil - method parameters (already schema-validated)
    # ctx: %{auth: auth_context, conn_id: String.t(), conn_pid: pid()}

    # Use require_param/2 for concise required param extraction:
    with {:ok, required_param} <- LemonControlPlane.Method.require_param(params, "requiredParam") do
      # Do work...
      {:ok, %{"result" => "success"}}
    end
  end
end
```

**Error return formats** (from the `LemonControlPlane.Method` callback spec):
```elixir
{:ok, payload}                                    # success
{:error, {atom(), String.t()}}                    # e.g. {:not_found, "Session not found"}
{:error, {atom(), String.t(), term()}}            # e.g. {:invalid_request, "msg", nil}
```

Use helpers from `LemonControlPlane.Protocol.Errors` for consistency:
```elixir
alias LemonControlPlane.Protocol.Errors

{:error, Errors.invalid_request("message")}
{:error, Errors.not_found("Resource not found")}
{:error, Errors.forbidden("Insufficient permissions")}
{:error, Errors.internal_error("Something went wrong", details)}
```

**Step 2: Register the method** in the `@builtin_methods` list in `LemonControlPlane.Methods.Registry`:

```elixir
@builtin_methods [
  # ... existing methods ...
  LemonControlPlane.Methods.MyMethod,
]
```


**Step 3: Add a schema** entry to `LemonControlPlane.Protocol.Schemas` (`@schemas` map). Schemas are validated before dispatch; methods without schemas accept any params.

```elixir
"my.method" => %{
  required: %{"requiredParam" => :string},
  optional: %{"optionalParam" => :integer}
}
```

Supported types: `:string`, `:integer`, `:boolean`, `:map`, `:list`, `:any`.

**Step 4: Write tests** in `test/lemon_control_plane/methods/`.

### Scope Guidelines

| Scope | Use For |
|-------|---------|
| `[]` (empty) | Public methods: `health`, `connect`, `connect.challenge` |
| `[:read]` | Read operations |
| `[:write]` | Agent, chat, and channel-send operations |
| `[:admin]` | Configuration, cron, session, and skill mutations |
| `[:approvals]` | Approval management: `exec.approvals.*`, `exec.approval.resolve` |
| `[:pairing]` | Node pairing: `node.pair.request`, `node.pair.approve` |
| `[:invoke, :event]` | Node invocation responses: `node.invoke.result`, `node.invoke.control.result` |

## API Method Reference

The control plane retains these 79 methods:

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
| `session.btw`, `session.detail`, `sessions.active`, `sessions.active.list`, `sessions.compact`, `sessions.delete`, `sessions.export`, `sessions.list`, `sessions.metadata.patch`, `sessions.patch`, `sessions.preview`, `sessions.prune`, `sessions.reset`, `sessions.stats` |
| `skills.hermes.catalog`, `skills.install`, `status`, `tasks.active.list`, `tasks.recent.list`, `usage.cost`, `usage.status` |

Heartbeat scheduling is owned by `LemonAutomation.Heartbeat` and cron jobs with
`meta.heartbeat`; it has no separate control-plane RPC family.

## Authentication and Authorization

### Roles and Scopes

| Role | Scopes | How established |
|------|--------|-----------------|
| `operator` | `admin`, `read`, `write`, `approvals`, `pairing` | Configured `LEMON_CONTROL_PLANE_OPERATOR_TOKEN`; legacy tokenless direct-loopback access requires an explicit compatibility opt-in |
| `node` | `invoke`, `event` | Token from `connect.challenge` after node pairing |


### Connection Handshake

1. Client connects via WebSocket to `/ws`
2. Client sends `connect` request:
   ```json
   {
     "type": "req",
     "id": "uuid",
     "method": "connect",
     "params": {
       "auth": {"token": "configured-operator-token"},
       "role": "operator",
       "scopes": ["operator.read", "operator.write"]
     }
   }
   ```
3. Server responds with `hello-ok` frame (not a `res` frame) containing `features.methods`, `features.events`, `snapshot`, `auth`, and `policy`
4. All subsequent requests use the established auth context

The HTTP router passes the actual socket peer into authorization. An operator
token is required by default for every operator connection and compared in
constant time. `LEMON_CONTROL_PLANE_ALLOW_UNAUTHENTICATED_LOOPBACK=true`
explicitly restores the legacy tokenless path for direct loopback peers only;
it defaults to `false`, and non-loopback peers always fail closed. Node session
tokens derive role and scopes only from known stored identity types.

### Token-Based Auth (Nodes)

1. Node calls `node.pair.request` -> operator approves via `node.pair.approve`, which returns a one-time challenge
2. Node calls `connect.challenge` with that challenge -> receives a session token (TTL: seven days for this pairing flow)
3. Node uses `{"auth": {"token": "..."}}` in future `connect` calls


Token validation is handled by `LemonControlPlane.Auth.TokenStore` (backed by `LemonCore.Store` under `:session_tokens` namespace).

`./bin/lemon node join --pair` automates this exchange for the named coding
worker when its operator connection has pairing scope. The worker persists the
issued session and recovery credentials in a mode-0600 destination file keyed
by durable node ID and records the exact controller URL; reuse fails closed
when that controller does not match. ID-based recovery material is not loaded
unless the caller supplies that exact stored controller URL. After the
seven-day session expires,
`--pair` recovers the same durable node and issues a fresh session while
atomically revoking older sessions and their live sockets. Controller renames remain valid because recovery uses
the node ID and controller's current name. An explicit operator-authorized
`--pair --repair --node-id ID` rotates recovery credentials for compatible
legacy records that lack one.

## Presence System

`LemonControlPlane.Presence` tracks all connected WebSocket clients (ETS-backed GenServer):

```elixir
# Get connection counts
LemonControlPlane.Presence.counts()
# => %{total: 5, operators: 2, nodes: 2}

# List all clients
LemonControlPlane.Presence.list()
# => [{conn_id, %{role: :operator, client_id: "...", pid: pid(), connected_at: ms}}]

# Broadcast to all clients
LemonControlPlane.Presence.broadcast("event_name", payload)

# Broadcast with filter
LemonControlPlane.Presence.broadcast("event", payload, fn info ->
  info.role == :operator
end)
```

Presence changes emit a `presence_changed` bus event, which EventBridge forwards to all WS clients as a `presence` event.

## WebSocket Protocol

### Frame Types

**Request (client -> server):**
```json
{"type": "req", "id": "uuid", "method": "health", "params": {}}
```

**Response (server -> client):**
```json
{"type": "res", "id": "uuid", "ok": true, "payload": {}}
{"type": "res", "id": "uuid", "ok": false, "error": {"code": "...", "message": "..."}}
```

**Event (server -> client):**
```json
{"type": "event", "event": "chat", "seq": 1, "payload": {...}, "stateVersion": {...}}
```

**Hello-OK (handshake response, replaces `res` for `connect`):**
```json
{
  "type": "hello-ok",
  "protocol": 1,
  "server": {"version": "...", "connId": "...", "host": "..."},
  "features": {"methods": [...], "events": [...]},
  "snapshot": {"presence": {}, "health": {"ok": true}},
  "policy": {"maxPayload": 1048576, "maxBufferedBytes": 8388608, "tickIntervalMs": 1000},
  "auth": {"role": "operator", "scopes": [...]}
}
```

### Error Codes

| Code | Atom |
|------|------|
| `INVALID_REQUEST` | `:invalid_request` |
| `INVALID_PARAMS` | `:invalid_params` |
| `METHOD_NOT_FOUND` | `:method_not_found` |
| `UNAUTHORIZED` | `:unauthorized` |
| `FORBIDDEN` | `:forbidden` |
| `NOT_FOUND` | `:not_found` |
| `CONFLICT` | `:conflict` |
| `INTERNAL_ERROR` | `:internal_error` |
| `NOT_IMPLEMENTED` | `:not_implemented` |
| `HANDSHAKE_REQUIRED` | `:handshake_required` |
| `ALREADY_CONNECTED` | `:already_connected` |
| `UNAVAILABLE` | `:unavailable` |
| `TIMEOUT` | `:timeout` |

### Events

State-versioned events include a `stateVersion` map for client reconciliation;
the server broadcasts all events to non-node clients, while node connections
receive only targeted node traffic.

| Event | Trigger |
|-------|---------|
| `agent` | Run started/completed, tool use (`type`: `started`, `completed`, `tool_use`; tool-use events preserve nested `action.detail`, including `result_meta` failure fields such as `error_type` and `exit_code`. For operators, `detail.result` is the bounded full result (`result_full`, ≤32 KB) rather than the 500-char channel preview, `detail.details` carries the tool's structured details (edit `diff`/`first_changed_line`, `exit_code`, …), and reasoning `detail.reasoning.text` is the bounded full thought (≤16 KB)) |
| `chat` | Chat delta/streaming content |
| `presence` | Connection count changed |
| `tick` | Heartbeat tick (from `:tick` or `:cron_tick` bus events) |
| `heartbeat` | Agent heartbeat or heartbeat alert |
| `exec.approval.requested` | Approval needed, including structured `action` metadata for operator UI controls such as MCP OAuth links |
| `exec.approval.resolved` | Approval decided or timed out, including approval id, decision, and pending approval metadata when available |
| `cron` | Cron job started/completed |
| `cron.job` | Cron job created/updated/deleted |
| `cron.audit` | Cron lifecycle audit event recorded |
| `task.started` | Subtask/subagent started |
| `task.completed` | Subtask/subagent completed |
| `task.error` | Subtask/subagent errored |
| `task.timeout` | Subtask/subagent timed out |
| `task.aborted` | Subtask/subagent aborted/interrupted |
| `run.graph.changed` | Run graph/status changed |
| `shutdown` | System shutting down |
| `health` | Health status changed |
| `node.pair.requested` | Node wants to pair |
| `node.pair.resolved` | Node pairing approved or rejected |
| `node.invoke.request` | Operator invoked a node method |
| `node.invoke.completed` | Node invoke completed |


## EventBridge

`LemonControlPlane.EventBridge` subscribes to its bus topics and forwards
events to non-node WebSocket clients through a supervised fanout task. Node
connections receive only targeted node traffic; non-node clients receive all
events without per-connection topic filters.

WebSocket method handlers are inline unless their optional
`dispatch_mode/0` callback returns `:async`. Reserve async dispatch for work
that waits on human approval or slow external systems and does not require
`self()` to be the connection process. Approval-gated skill install/update
handlers are async so `exec.approval.*` events, approval resolution requests,
and liveness probes continue flowing while the mutation waits. Such handlers
must use `ctx.conn_pid` for the authenticated socket identity.

Key bus-event-to-WS-event mappings:

| Bus Event Type | WS Event Name |
|----------------|---------------|
| `:run_started` | `agent` (type: started) |
| `:run_completed` | `agent` (type: completed) |
| `:delta` | `chat` |
| `:engine_action` | `agent` (type: tool_use) |
| `:goal_set` / `:goal_paused` / `:goal_resumed` / `:goal_completed` / `:goal_cleared` | `goal` |
| `:goal_continuation_submitted` / `:goal_loop_verdict` / `:goal_loop_status` | `goal` |
| `:approval_requested` | `exec.approval.requested` with pending approval `action` metadata |
| `:approval_resolved` | `exec.approval.resolved` with approval id, decision, and pending approval metadata when available; timeouts use `decision: "timeout"` |
| `:cron_run_started` | `cron` (type: started) |
| `:cron_run_completed` | `cron` (type: completed) |
| `:cron_job_created` | `cron.job` (type: created) |
| `:cron_job_updated` | `cron.job` (type: updated) |
| `:cron_job_deleted` | `cron.job` (type: deleted) |
| `:cron_lifecycle_action` | `cron.audit` |
| `:tick` / `:cron_tick` | `tick` |
| `:presence_changed` | `presence` |
| `:task_started` | `task.started` |
| `:task_completed` | `task.completed` |
| `:task_error` | `task.error` |
| `:task_timeout` | `task.timeout` |
| `:task_aborted` | `task.aborted` |
| `:run_graph_changed` | `run.graph.changed` |
| `:shutdown` | `shutdown` |
| `:health_changed` | `health` |

The fanout uses `Task.Supervisor` for resilience. If the supervisor is temporarily unavailable (crash/restart), it falls back to inline dispatch. Telemetry events are emitted on `[:lemon, :control_plane, :event_bridge, :broadcast]` and `[:lemon, :control_plane, :event_bridge, :dropped]`.

## Common Tasks

### Join a Named Coding Execution Node

Start the controller normally, then run from the destination source checkout:

```bash
LEMON_NODE_OPERATOR_TOKEN=... ./bin/lemon node join \
  --name worker-1 \
  --controller wss://controller.example/ws \
  --pair \
  --cwd /srv/project
```

Later starts omit `--pair` and reuse the controller-bound token. Re-run with
`--pair` when that seven-day session expires. Use
`LEMON_NODE_TOKEN` to supply an existing token without placing it in shell
history. A name must be unique on the controller, and the destination cwd must
already exist.

Non-loopback plaintext `ws://` is rejected by default. A Tailscale deployment
may use `--controller ws://controller:4040/ws --allow-insecure-controller`
only after verifying that the complete path stays on the authenticated,
encrypted overlay; otherwise use `wss://`.

### Run Tests

```bash
# All tests
mix test apps/lemon_control_plane

# Specific test file
mix test apps/lemon_control_plane/test/lemon_control_plane/methods/control_plane_methods_test.exs

# Specific test
mix test --grep "name/0 returns correct method name"
```

### Add a New API Method

1. Create module in `lib/lemon_control_plane/methods/my_method.ex`
2. Implement `LemonControlPlane.Method` behaviour (`name/0`, `scopes/0`, `handle/2`)
4. Add to `@builtin_methods` in `Registry`.
5. Add tests in `test/lemon_control_plane/methods/`.

### Add a New REST Endpoint (Games API Pattern)

1. Add the route in `lib/lemon_control_plane/http/router.ex`:
   ```elixir
   get "/v1/my/path" do
     LemonControlPlane.HTTP.MyHandler.call(conn, :my_action)
   end
   ```
2. Create the handler module with action functions that take a `conn` and return via `json/3` or `error/4` helpers.
3. Use Bearer token authentication via the `authenticate/2` pattern if auth is needed.

### Add a New WebSocket Event

1. Add the bus event type mapping in `EventBridge.map_event_type/3`.
2. Add the event name to `Protocol.Frames.supported_events/0`.
3. Add an event payload schema to `Protocol.Schemas` (`@event_schemas`) when clients depend on the event shape.
4. Optionally add state version tracking in `EventBridge.state_version_key_for/1` if the event affects reconciliation state.

### Test a Method Directly

```elixir
# In iex or test
ctx = %{auth: LemonControlPlane.Auth.Authorize.default_operator(), conn_id: "test", conn_pid: self()}

{:ok, result} = LemonControlPlane.Methods.SessionsList.handle(%{}, ctx)
```

### Debug WebSocket Connections

```elixir
# List active connections
LemonControlPlane.Presence.list()

# Get counts
LemonControlPlane.Presence.counts()

# Inspect presence ETS state
:sys.get_state(LemonControlPlane.Presence)
```

### Event Bridge Debugging

Use bus events to exercise the broadcast path:

```elixir
LemonCore.Bus.broadcast("system", LemonCore.Event.new(:tick, %{}))
```

## Testing Guidelines

Control-plane WebSocket operator authentication uses
`LEMON_CONTROL_PLANE_OPERATOR_TOKEN`. The HTTP router must pass the actual socket
peer to `WS.Connection`; tokenless operator compatibility must remain default-off
and, when explicitly enabled, direct-loopback-only. Do not restore params-only
roles or map an unknown session-token identity to operator scopes.
Keep credentials out of URLs, auth contexts, logs, status formatting, and error
payloads.

- Use `async: true` for method tests that don't depend on shared state
- Tests requiring the full runtime should be marked `async: false`
- The `test_helper.exs` stops and restarts `:lemon_channels` (and related apps),
  then explicitly ensures `:lemon_control_plane` is running. Umbrella app suites
  share one BEAM, so the suite must establish its own supervised Registry/ETS
  baseline even when an earlier app suite stopped the control plane; it also
  disables Telegram.
- Mock external dependencies; test method logic in isolation
- Test error cases: missing params, invalid auth, not found scenarios
- For WebSocket tests, use `test/lemon_control_plane/ws/connection_test.exs` as the reference pattern
- Method tests typically verify: `name/0` returns the correct string, `scopes/0` returns expected scopes, `handle/2` succeeds with valid params, `handle/2` fails correctly with invalid/missing params
- The test suite at `test/lemon_control_plane/methods/control_plane_methods_test.exs` covers many methods in a single file using `describe` blocks per method

### Test File Organization

| Test File | Covers |
|-----------|--------|
| `methods/control_plane_methods_test.exs` | Broad coverage of retained method modules |
| `methods/node_methods_test.exs` | Node management and invocation |
| `methods/skills_methods_test.exs` | Skill catalog and installation |
| `methods/blueprints_test.exs` | Catalog containment, content-free review, exact confirmation, profile activation, and duplicate-safe replay |
| `methods/sessions_patch_test.exs` | Session patching |
| `methods/send_test.exs` / `send_idempotency_test.exs` | Channel send with idempotency |
| `methods/connect_challenge_test.exs` | Node token exchange |
| `methods/exec_approvals_test.exs` | Approval policy methods |
| `methods/cron_methods_test.exs` | Cron management methods |
| `methods/monitoring_methods_test.exs` | Runs and tasks methods |
| `methods/registry_test.exs` | ETS registry dispatch |
| `methods/event_type_validation_test.exs` / `event_type_atom_leak_test.exs` | Event type safety |
| `auth/authorize_test.exs` / `authorize_expiration_test.exs` | Authorization logic |
| `auth/token_store_persistence_test.exs` | Token storage |
| `ws/connection_test.exs` | WebSocket connection lifecycle |
| `tui_profiles_wire_e2e_test.exs` | Authenticated real-Bandit profile lifecycle and canonical chat |
| `protocol/errors_test.exs` / `frames_test.exs` / `schemas_test.exs` | Protocol layer |
| `presence_test.exs` | Presence tracking |
| `event_bridge_test.exs` / `event_bridge_tick_test.exs` / `event_bridge_monitoring_test.exs` / `event_bridge_mapping_test.exs` | EventBridge fanout |
## Connections to Other Apps

| Dependency | How Used |
|------------|----------|
| `lemon_core` | `LemonCore.Store` (token persistence, idempotency), `LemonCore.NodeRegistry` (live named-node delivery), `LemonCore.Bus` (event pub/sub), `LemonCore.Secrets`, `LemonCore.Event`, `LemonCore.Telemetry` |
| `lemon_router` | `LemonRouter.submit/1` and `LemonRouter.RunOrchestrator.submit/1` for agent run submission; `LemonRouter.RunRegistry` for active run queries |
| `lemon_channels` | `LemonChannels.Outbox` for channel delivery |
| `lemon_skills` | Skill catalog and installation |
| `lemon_automation` | `LemonAutomation.CronManager` for cron CRUD and heartbeat management; `LemonAutomation.Blueprint` for safe catalog-scoped skill + cron activation |
| _(none)_ | The agent is reached through `LemonControlPlane.AgentRuntime`; an agent registers a provider at boot. No compile-time dependency. |
| `ai` | AI model listing and configuration |

## Key Dependencies

- `bandit` - HTTP/WebSocket server
- `websock_adapter` - WebSocket adapter for Plug
- `plug` - HTTP routing and middleware
- `jason` - JSON encoding/decoding
