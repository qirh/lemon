# LemonControlPlane

Authenticated HTTP/WebSocket access to Lemon's assistant runtime. The TUI and
one-shot CLI use its frame-based protocol; handlers delegate to router, session,
profile, cron, skill and blueprint services. The control plane also transports
named native execution-node requests and hosts an optional separate A2A listener.

## Start and connect

From a source checkout, configure a high-entropy operator token and start Lemon:

```bash
export LEMON_CONTROL_PLANE_OPERATOR_TOKEN="$(openssl rand -hex 32)"
./bin/lemon start
```

Connect to the configured `/ws` endpoint (default local port 4040), and send:

```json
{
  "type": "req",
  "id": "connect-1",
  "method": "connect",
  "params": {
    "role": "operator",
    "scopes": ["operator.read", "operator.write"],
    "auth": {"token": "your-configured-operator-token"},
    "client": {"id": "my-client"}
  }
}
```

Use `wss://` for remote access. Never put auth in the URL. The first successful
response is `type: "hello-ok"`, not a normal response frame. It supplies protocol
version, server/connection info, available `features.methods` and `features.events`,
initial snapshot, resolved auth scopes and payload/buffer/tick policy. Discover
the actual supported surface there; do not assume an old method inventory.
A second connect is rejected as already connected.

Operator scopes include read, write, admin, approvals and pairing. Request only
what the client needs; a method requires a matching authorized scope. Before
handshake, ordinary method calls are rejected. Unknown methods, invalid params,
missing auth and insufficient scopes remain distinct protocol errors.

Tokenless loopback is disabled by default. The compatibility setting
`LEMON_CONTROL_PLANE_ALLOW_UNAUTHENTICATED_LOOPBACK=true` is only for direct local
clients and must not be used behind a reverse proxy whose socket peer appears
local. Node identity never falls back to operator access.

## Frames and events

After handshake, requests use `type`, correlation `id`, `method` and `params`:

```json
{"type":"req","id":"status-1","method":"status","params":{}}
```

Responses carry the same ID with `ok: true, payload: ...` or
`ok: false, error: {code, message, ...}`. Events are independent frames:

```json
{"type":"event","event":"presence","seq":1,"payload":{},"stateVersion":{"presence":2}}
```

The event bridge maps Bus run/chat/approval/cron/goal/presence traffic to socket
events. Non-node clients receive the general event stream; nodes receive only
targeted node traffic. State-version counters let clients reconcile changed
presence, health and cron data. They are not durable event replay cursors.
Slow/approval-gated handlers run asynchronously so events and approval resolution
can continue while their correlated request remains pending.

Tool action details use a bounded, credential-redacted wire projection of
visible text/images and selected public result metadata. Hidden thinking,
signatures, callbacks and runtime state are excluded; complete diff snapshots
are omitted rather than truncated into misleading edits. Unexpected JSON
encoding failures drop only the offending event frame and leave the socket
connected for later output and completion.

Ordinary `chat.send` requests may supply `cwd`: a nonempty absolute existing
directory forwarded to the native coding session and its tools. Relative,
missing and non-directory paths are rejected before submission. Canonical
profile sessions reject caller workspace overrides; use `profile.chat`, whose
workspace remains server-owned.

A lost mutation acknowledgement does not prove failure. In particular,
`profile.chat` may return `UNAVAILABLE` with its fixed run ID and
`retrySafe: false`; reconcile instead of blindly submitting again. Session delete,
prune, provider edits and blueprint activation retain their owning service's
preview/revision/exact-confirmation requirements. Public management history and
errors are bounded and redacted, not raw run/store dumps.

## Named execution nodes

On the destination host, supply the controller's operator credential for pairing:

```bash
LEMON_NODE_OPERATOR_TOKEN=... ./bin/lemon node join --name worker-1 \
  --controller wss://controller.example/ws --pair --cwd /srv/project
```

The worker saves its own private session/recovery credentials, bound to durable
node ID and exact controller URL; it does not retain the operator token. Later
starts omit `--pair`; use it again after session expiry to recover the same
identity and revoke old sessions. Legacy repair requires explicit
`--pair --repair --node-id ID` authorization.

The destination owns cwd and provider credentials. Only JSON-safe execution data
crosses the wire, not callbacks or source BEAM state. Cancellation and bounded
steer/redirect are invocation-bound and require destination acknowledgement.
Plaintext off loopback requires explicit `--allow-insecure-controller` and a
verified encrypted overlay; otherwise use TLS.

## Other HTTP surfaces

- `/healthz`: local service health; it does not prove a provider-backed turn.
- `/v1/*`: [OpenAI-compatible preview](../../docs/tools/openai-compatible-api.md),
  including model metadata, chat/responses, retrieval and cancellation. Configure
  `LEMON_OPENAI_COMPAT_API_TOKEN` (or `LEMON_OPENAI_COMPAT_TOKEN`) for bearer/
  `x-api-key` auth. Generation reuses the router; queued/wait/SSE modes and safe
  image input limits are described in the linked guide.
- `/acp`: [ACP editor adapter](../../docs/tools/acp.md); configure
  `LEMON_ACP_API_TOKEN` for HTTP bearer/`x-api-key` auth. The guide also describes
  the line-oriented stdio bridge and client filesystem/permission callbacks.
- Optional [A2A](../../docs/user-guide/a2a-peers.md) uses a separate listener
  (default 9901) enabled by `[gateway] enable_a2a = true`. Peers are independent
  principals. Task access is peer-scoped and message IDs durably replay the
  original task. Unknown submissions reconcile; cancellation is first-writer-wins.

`:lemon_control_plane, :port` controls the listener; test default `0` chooses a
free port. `:git_commit` may supply server version metadata. Runtime configuration
and source/release commands are covered in the [CLI guide](../../docs/user-guide/cli.md).

## Development

Read [AGENTS.md](AGENTS.md) for authorization, lifecycle and privacy invariants.
`Methods.Registry` and `Protocol.Schemas` are the authoritative method/schema
catalog. From the umbrella root, run `mix test apps/lemon_control_plane/test`.
