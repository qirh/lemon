# LemonMCP App - Agent Guidelines

## Purpose and Responsibilities

The `lemon_mcp` app implements the client side of the **Model Context Protocol (MCP)**, an open JSON-RPC 2.0 protocol that lets LLM applications discover and call external tools.

### Key Responsibilities

- **MCP Client**: Spawn external MCP servers as subprocesses (via stdio) or connect to Streamable HTTP / legacy HTTP+SSE MCP endpoints, perform the handshake, handle OAuth client-credentials, refresh-token, and PKCE authorization-code callback flows for Streamable HTTP, and proxy tool calls to them — enabling Lemon to consume third-party tool servers (e.g. `@modelcontextprotocol/server-filesystem`)
- **Protocol Layer**: Build, encode, and decode MCP JSON-RPC 2.0 messages, and answer server-initiated `sampling/createMessage` requests through an explicit policy

Protocol version targeted: **"2024-11-05"**

## Architecture Overview

```
   LemonMCP.Client          LemonMCP.Client.HTTP        LemonMCP.Client.SSE
     (GenServer)                (GenServer)                 (GenServer)
          |                          |                           |
          v                          v                           v
 LemonMCP.Transport.Stdio    Streamable HTTP POST      legacy HTTP+SSE endpoint
  (GenServer, Port-based)    (:httpc, JSON or SSE)     (:httpc event stream)
          |
          v
 External MCP server process via stdin/stdout
```

All three clients share `LemonMCP.Protocol` for struct definitions and encode/decode helpers.

## File Structure

```
lib/
  lemon_mcp.ex                     # Public façade: protocol_version/0, create_response/2, encode!/1
  lemon_mcp/
    protocol.ex                    # All MCP message structs + encode/decode + builder helpers
    client.ex                      # GenServer client (stdio transport, state machine)
    client/
      http.ex                      # GenServer client (Streamable HTTP transport)
      sse.ex                       # GenServer client (legacy HTTP+SSE transport)
    sampling.ex                    # Policy wrapper for sampling/createMessage callbacks
    transport/
      stdio.ex                     # GenServer wrapping an Erlang Port for subprocess I/O

test/
  support/
    mcp_fixture_server.ex          # Scripted MCP server + Bandit-hosted HTTP/SSE fixture plugs
  lemon_mcp/
    protocol_test.exs
    client_test.exs
    sampling_test.exs
    skills_mcp_source_test.exs     # LemonSkills.McpSource suite (HTTP/SSE/stdio sources)
    release_composition_test.exs
    transport/
      stdio_test.exs
```

## Module Reference

| Module | Role |
|--------|------|
| `LemonMCP` | Thin public API; delegates to `Protocol` |
| `LemonMCP.Protocol` | All structs and encode/decode; also the JSON-RPC response helpers the client uses to answer server requests (`create_response/2`, `create_error_response/4`, `error_code/1`) |
| `LemonMCP.Client` | GenServer; owns stdio transport lifecycle, request correlation, timeout handling, resource/prompt calls, and optional `sampling/createMessage` callbacks or policies. It only advertises the MCP sampling capability when a `sampling_handler` or `sampling_policy` is configured. |
| `LemonMCP.Sampling` | Redacted policy wrapper for stdio `sampling/createMessage`; summarizes requests without raw prompt text, enforces max-token/model allowlists, and supports reviewed model-backed delegates. |
| `LemonMCP.Client.HTTP` | GenServer; owns Streamable HTTP initialize/initialized handshake, JSON or per-request SSE responses, session/protocol headers, OAuth protected-resource and authorization-server metadata discovery, optional OAuth client-credentials token acquisition with form-post or HTTP Basic client authentication, refresh-token grant retry when a token response supplies a refresh token, authorization-code PKCE callback/token exchange for public clients, storage-agnostic OAuth token cache load/save hooks, one-shot bearer reacquisition after later 401 challenges, synchronous request calls, timeout handling, and server capability metadata |
| `LemonMCP.Client.SSE` | GenServer; owns legacy HTTP+SSE endpoint discovery, POST/message response correlation, timeout handling, and server capability metadata |
| `LemonMCP.Transport.Stdio` | GenServer backed by an Erlang `Port`; newline-delimited JSON framing; calls `message_handler` callback for each inbound line |

## Key Types

### Protocol Structs (all in `LemonMCP.Protocol`)

```elixir
# Lifecycle
%Protocol.InitializeRequest{}   # client → server: jsonrpc, id, method, params
%Protocol.InitializeResponse{}  # server → client: jsonrpc, id, result | error
%Protocol.InitializedNotification{}  # client → server: no id (notification)

# Tool operations
%Protocol.ToolListRequest{}     # tools/list request
%Protocol.ToolListResponse{}    # result: %{tools: [...]}
%Protocol.ToolCallRequest{}     # params: %{name: String, arguments: map()}
%Protocol.ToolCallResponse{}    # result: %{content: [...], isError: bool}

# Generic JSON-RPC
%Protocol.JSONRPCResponse{}     # id, result — client replies to server requests (sampling)
%Protocol.JSONRPCError{}        # code, message, data — embedded in error responses
```

**Content items** follow MCP spec: `%{type: "text", text: "..."}` is the common case; image and resource variants also exist.

### Client State Machine

The `LemonMCP.Client` and `LemonMCP.Client.HTTP` GenServers hold an internal `state` field (not to be confused with the GenServer state map):

```
:disconnected  ->  :initializing  ->  :ready
                        ^-- sends InitializeRequest on init
                                       ^-- after InitializeResponse + InitializedNotification
```

Calls to `list_tools/2` and `call_tool/4` return `{:error, {:not_ready, current_state}}` unless in `:ready`.

## Common Modification Patterns

### Connecting a Client to an External MCP Server

Stdio client:

```elixir
{:ok, client} = LemonMCP.Client.start_link(
  command: "npx",
  args: ["-y", "@modelcontextprotocol/server-filesystem", "/path"],
  env: [{"HOME", System.get_env("HOME")}],
  timeout_ms: 15_000
)

# Wait for :ready (handshake is async during init)
{:ok, tools} = LemonMCP.Client.list_tools(client)
{:ok, content} = LemonMCP.Client.call_tool(client, "read_file", %{"path" => "/tmp/test.txt"})
# content is a list of %{type: "text", text: "..."} maps
```

Stdio sampling is opt-in at the low-level client boundary. Prefer
`sampling_policy` for model-backed sampling so redacted review and local limits
run before a delegate sees the raw request:

```elixir
{:ok, client} = LemonMCP.Client.start_link(
  command: "node",
  args: ["server.js"],
  sampling_policy: [
    mode: :reviewed_model,
    reviewer: fn summary -> :approve end,
    delegate: fn params, summary ->
      {:ok, model_sampling_result(params, summary)}
    end,
    max_tokens: 1_024,
    allowed_models: ["lemon"]
  ]
)
```

Use `sampling_handler` only for low-level integrations that already own review
and policy checks:

```elixir
{:ok, client} = LemonMCP.Client.start_link(
  command: "node",
  args: ["server.js"],
  sampling_handler: fn params ->
    {:ok,
     %{
       "role" => "assistant",
       "content" => %{"type" => "text", "text" => "sampled"},
       "model" => "lemon",
       "stopReason" => "endTurn"
     }}
  end
)
```

Do not advertise sampling by adding `"sampling"` to static capabilities unless
the client can actually answer server sampling requests. Prefer the
`sampling_policy` or `sampling_handler` option so capability advertisement and
response routing stay tied together.

When a stdio server is configured through `LemonSkills.McpSource`, the source
layer may use `reviewer: :ops_approval` to bridge reviewed sampling into
`LemonCore.ExecApprovals`. That production-facing bridge stores only redacted
`mcp_<server>_sampling` summaries for approval surfaces before the low-level
MCP delegate sees raw params. Approval summaries include the safe request hash,
model, token, message, role, and content-kind metadata.

Streamable HTTP client:

```elixir
{:ok, client} = LemonMCP.Client.HTTP.start_link(
  url: "http://localhost:3000/mcp",
  headers: [{"Authorization", "Bearer token"}]
)

{:ok, tools} = LemonMCP.Client.HTTP.list_tools(client)
{:ok, content} = LemonMCP.Client.HTTP.call_tool(client, "search", %{"query" => "beam"})
```

OAuth-protected Streamable HTTP servers can use configured client credentials:

```elixir
{:ok, client} = LemonMCP.Client.HTTP.start_link(
  url: "https://example.com/mcp",
  oauth: [client_id: "client", client_secret: "secret", scopes: ["tools"]]
)
```

The client uses `WWW-Authenticate` protected-resource metadata and declared
authorization-server metadata to find the token endpoint, requests a bearer
token with `grant_type=client_credentials`, and retries the protected MCP
request. If a later 401 arrives and the previous token response supplied a
refresh token, the client prefers `grant_type=refresh_token`, rotates the stored
refresh token when the token endpoint returns a replacement, and only falls back
to client credentials when no refresh token is available or refresh fails.
Metadata discovery requests use metadata-only headers; configured MCP headers
and acquired bearer tokens are not forwarded to metadata URLs.

Public-client authorization-code + PKCE flows use an
`authorization_code_provider` callback as the narrow UI boundary. The callback
receives the authorization URL, state, verifier/challenge metadata, resource,
scope, and redirect URI, then returns a code plus matching state for token
exchange. OAuth tokens remain process-local unless the caller supplies
`oauth_token_cache: [load: ..., save: ...]` or the compatibility
`oauth_token_loader` / `oauth_token_persister` callbacks. The client loads a
cached access/refresh token before initialize and persists successful
client-credentials, refresh-token, and PKCE token responses, including refresh
token rotation. `lemon_mcp` deliberately does not own secret storage, loopback
HTTP callback hosting, or operator UI; those belong in higher-level Lemon
runtime or skills surfaces. If a higher-level provider may block for an
interactive authorization flow, pass the GenServer `:timeout` start option
alongside the client config.

HTTP resource/prompt calls use the same API shape and degrade with MCP RPC
errors when the remote endpoint does not implement those methods.

Legacy HTTP+SSE client:

```elixir
{:ok, client} = LemonMCP.Client.SSE.start_link(
  url: "http://localhost:3000/sse",
  headers: [{"Authorization", "Bearer token"}]
)

{:ok, tools} = LemonMCP.Client.SSE.list_tools(client)
{:ok, content} = LemonMCP.Client.SSE.call_tool(client, "search", %{"query" => "beam"})
```

## Error Codes Reference

Standard JSON-RPC 2.0 codes:

| Atom | Code | Meaning |
|------|------|---------|
| `:parse_error` | -32700 | Invalid JSON |
| `:invalid_request` | -32600 | Request structure wrong |
| `:method_not_found` | -32601 | Unknown method |
| `:invalid_params` | -32602 | Missing or malformed params |
| `:internal_error` | -32603 | Unexpected server failure |

Use `Protocol.error_code(:atom)` to convert; falls back to `-32603` for unknown atoms.

## Lifecycle and Release Composition

`lemon_mcp` is a library application. It has no application callback or
supervisor and starts no processes by default. `LemonMCP.Client`,
`LemonMCP.Client.HTTP`, `LemonMCP.Client.SSE`, and the stdio transport are
started on demand; the host application that needs one owns its supervision
strategy.

The `lemon_runtime_min` and `lemon_runtime_full` releases explicitly include
`lemon_mcp: :load` before `coding_agent` and `lemon_skills`. This assembles and
loads the client modules so `LemonSkills.McpSource.mcp_enabled?/0` can discover
them, without pretending the MCP library owns long-lived runtime processes.
`release-smoke.yml` builds both profiles and evaluates that contract inside
each packaged release; `scripts/verify_release_runtime_boot` repeats it against
each min/full release tarball. The client and source modules must load, MCP
feature detection must be enabled, `:lemon_mcp` must be loaded but not started,
and no application callback or `LemonMCP.Application` module may exist.

## Testing Guidance

### Running Tests

```bash
# All lemon_mcp tests (from umbrella root)
mix test apps/lemon_mcp/test

# Specific file
mix test apps/lemon_mcp/test/lemon_mcp/client_test.exs
```

### Test Patterns in Use

**Stdio transport tests** (`transport/stdio_test.exs`) require an actual executable to be present. Tests that spawn processes should be tagged or skipped in CI environments without the target command available.

**Client tests** (`client_test.exs`, `skills_mcp_source_test.exs`) are integration-level. Stdio cases spawn real processes; HTTP and SSE cases run a local Bandit listener. Tests that need the shared scripted server (`echo`/`fail` tools, a `fixture://status` resource, a `brief` prompt) start `LemonMCP.TestSupport.HTTPFixture` or `LemonMCP.TestSupport.SSEFixture` from `test/support/mcp_fixture_server.ex`; tests that need to observe headers, OAuth, or session behavior define their own `Plug.Router` fixture inline. `bandit` and `plug` are test-only dependencies.

## Gotchas

- **Stdio transport stderr merges into stdout.** `Port.open/2` is started with `:stderr_to_stdout`, so stderr from the MCP server subprocess arrives as ordinary data lines. This can cause spurious JSON parse warnings if the subprocess logs to stderr on startup (e.g. `npx` install output).

- **There is no `LemonMCP.Application` callback.** All client and transport
  processes must be started and supervised by the consuming app.
  Keep the runtime release entry at `:load`; changing it to `:permanent` does
  not create useful lifecycle ownership.

## How This App Connects to Other Umbrella Apps

- **`lemon_core`** (dependency): `LemonCore.Id` generates request IDs; its
  `:inets`/`:ssl` runtime backs the HTTP and SSE clients.
- **`lemon_skills`** (dependency): hosts `LemonSkills.McpSource`, whose suite
  lives in this app's tests (`skills_mcp_source_test.exs`); `lemon_mcp` lib code
  does not reference it.
- **Consumers**: Apps with a direct compile-time dependency use
  `{:lemon_mcp, in_umbrella: true}` and call `LemonMCP.Client.start_link/1`,
  `LemonMCP.Client.HTTP.start_link/1`, or `LemonMCP.Client.SSE.start_link/1`.
  `LemonSkills.McpSource` deliberately discovers the client dynamically; the
  runtime release contract assembles the library for that path.
