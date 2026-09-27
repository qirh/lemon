# LSP Diagnostics

Lemon has two diagnostics paths:

- `lsp_diagnostics`: the model-facing coding-agent tool for one-file
  diagnostics and post-edit baseline/delta checks.
- supervised LSP sessions: BEAM-owned stdio language-server processes exposed
  through the control plane for operator/editor-style integrations.

Both paths are preview surfaces. They are designed to be supportable first:
status and support bundles expose capabilities, counters, hashes, and install
hints, not raw file contents, raw workspace roots, raw session ids, diagnostic
output, or server I/O.

## Model-Facing Tool

`lsp_diagnostics` accepts a file path relative to the active working directory:

```json
{"path":"lib/example.ex"}
```

`write`, `edit`, and `patch` can opt into post-edit diagnostics with:

```json
{"diagnostics":true}
```

The post-edit path compares a pre-edit baseline with the post-edit result and
reports newly introduced diagnostics separately from pre-existing issues.
Missing tools or unsupported file types return structured skipped results
instead of failing the edit.

## Local Checker Install Guide

The preview runner uses local workspace tools when they are present:

| Language | File extensions | Checker path | Install notes |
| --- | --- | --- | --- |
| Elixir | `.ex`, `.exs`, `.heex` | syntax parser, then `mix compile --return-errors` when a `mix.exs` workspace exists | Install Elixir and Mix. |
| JavaScript | `.js`, `.cjs`, `.mjs` | `node --check` | Install Node.js. |
| TypeScript | `.ts`, `.tsx`, `.jsx` | `tsc --noEmit --pretty false` when `tsconfig.json` exists, preferring workspace `node_modules/.bin/tsc` when present | Install TypeScript in the workspace or on `PATH`. |
| Python | `.py` | `python3 -m py_compile` or `python -m py_compile` | Install Python 3. |
| Rust | `.rs` | `cargo check --message-format=short` when `Cargo.toml` exists | Install Rust and Cargo. |
| Go | `.go` | `go test ./...` when `go.mod` exists | Install Go. |
| C/C++ | `.c`, `.h`, `.cc`, `.cpp`, `.cxx`, `.hh`, `.hpp`, `.hxx` | `clang`/`gcc`/`cc` or `clang++`/`g++`/`c++` with `-fsyntax-only` | Install a C/C++ compiler; install `clangd` separately for supervised LSP sessions. |

The runner intentionally skips TypeScript, Rust, and Go when the expected
workspace marker is missing. C/C++ syntax checks run per file when a compiler is
available. That keeps single-file edits predictable outside a real project.

## Language Server Install Guide

The supervised stdio manager registers these language servers:

| Server id | Language | Command | Override env var | Install notes |
| --- | --- | --- | --- | --- |
| `elixir_ls` | Elixir | `elixir-ls` | `LEMON_LSP_ELIXIR_LS_COMMAND` | Install ElixirLS and put `elixir-ls` on `PATH`; alternatives `elixir-ls-language-server`, `language_server.sh`, and launcher paths such as `launch.sh` are also supported. Lemon sets `ELS_MODE=language_server` for this server. |
| `typescript_language_server` | TypeScript/JavaScript | `typescript-language-server --stdio` | `LEMON_LSP_TYPESCRIPT_COMMAND` | `npm install -g typescript typescript-language-server`. |
| `pyright` | Python | `pyright-langserver --stdio` | `LEMON_LSP_PYRIGHT_COMMAND` | `npm install -g pyright`. |
| `rust_analyzer` | Rust | `rust-analyzer` | `LEMON_LSP_RUST_ANALYZER_COMMAND` | Install rust-analyzer and put it on `PATH`. |
| `gopls` | Go | `gopls` | `LEMON_LSP_GOPLS_COMMAND` | `go install golang.org/x/tools/gopls@latest`. |
| `clangd` | C/C++ | `clangd` | `LEMON_LSP_CLANGD_COMMAND` | Install clangd and provide `compile_commands.json` or `compile_flags.txt` in the workspace for useful diagnostics. |

Override env vars can point at either a command on `PATH` or an absolute local
executable path. Public status redacts absolute paths to command basenames.

## Control-Plane Methods

Operator/editor surfaces can use:

| Method | Purpose |
| --- | --- |
| `lsp.diagnostics.status` | Inspect redacted checker and language-server capability metadata. |
| `lsp.server.start` | Start a supervised stdio language-server session. |
| `lsp.server.initialize` | Send `initialize`, wait for the response, then send `initialized`. |
| `lsp.document.open` | Send `textDocument/didOpen`. |
| `lsp.document.change` | Send `textDocument/didChange` with full text content. |
| `lsp.document.close` | Send `textDocument/didClose`. |
| `lsp.server.request` | Send a JSON-RPC request and correlate the response by id. |
| `lsp.server.stop` | Stop the supervised session. |

Session status reports request/response counts, notification counts, open and
known document counts, redacted document URI hashes, diagnostic batch counts,
and severity counts. It does not expose raw text, raw URIs, workspace paths,
server logs, or diagnostic messages.

Language-server stderr is redirected into the supervised port stream so noisy
servers cannot write private workspace paths directly to the caller console.
The parser discards non-LSP prefixes and only records redacted frame counters
from valid JSON-RPC messages. When a language-server launcher spawns child
processes, `stop_session` also terminates those children so wrapper-style
servers do not outlive the BEAM-owned session. If a JSON-RPC request times out,
the manager treats the session as unhealthy, replies with
`:request_timeout`, terminates the launcher plus descendants, and records the
recent session as `:request_timeout` instead of leaving a stuck port alive.

The manager records both push diagnostics from
`textDocument/publishDiagnostics` notifications and pull diagnostics from
`textDocument/diagnostic` responses. Public status keeps only URI hashes,
diagnostic counts, severity counts, and timestamps.

## Proof Lanes

Focused LSP coverage:

```bash
mix test apps/coding_agent/test/coding_agent/tools/lsp_diagnostics_test.exs \
  apps/lemon_lsp/test/lemon_lsp/lsp_servers_test.exs \
  apps/lemon_lsp/test/lemon_lsp/lsp_server_manager_test.exs \
  apps/lemon_control_plane/test/lemon_control_plane/methods/optional_parity_methods_extended_test.exs \
  apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs --seed 1
```

Broader preview lane:

```bash
mix test apps/coding_agent/test/coding_agent/tools/lsp_diagnostics_test.exs \
  apps/lemon_lsp/test/lemon_lsp/lsp_servers_test.exs \
  apps/lemon_lsp/test/lemon_lsp/lsp_server_manager_test.exs \
  apps/lemon_core/test/lemon_core/doctor/lsp_diagnostics_test.exs \
  apps/lemon_core/test/lemon_core/doctor/support_bundle_test.exs \
  apps/lemon_core/test/lemon_core/application_test.exs \
  apps/lemon_control_plane/test/lemon_control_plane/methods/optional_parity_methods_extended_test.exs \
  apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs \
  apps/lemon_web/test/lemon_web_test.exs \
  apps/coding_agent/test/coding_agent/tools/write_test.exs \
  apps/coding_agent/test/coding_agent/tools/edit_test.exs \
  apps/coding_agent/test/coding_agent/tools/patch_test.exs \
  apps/coding_agent/test/coding_agent/tools_test.exs \
  apps/coding_agent/test/coding_agent/tool_registry_test.exs \
  apps/coding_agent/test/coding_agent_test.exs --seed 1
```

The latest broader preview lane passed locally on 2026-05-16 with `404 tests,
0 failures`.

