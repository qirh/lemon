# Lemon platform split — status

Status as of 2026-09-27. This page replaced the August 2026 plan of record, which
aimed to publish a dozen Hex packages and move the products into their own
repositories. The boundary work survived; the package set was cut to five, and
the product extraction was abandoned. Git history has the full plan.

## Published packages

| Package | What it is | In repo | On Hex |
|---|---|---|---|
| `lemon_ai` | Provider-agnostic LLM client: providers, model registry, streaming, rate limiting, circuit breaking | 0.2.0 | 0.1.0 (uninstallable) |
| `lemon_core` | Bus and event envelope, pluggable Store, secrets, config, paths, boundary contracts | 0.2.0 | 0.1.0 (uninstallable) |
| `lemon_agent` | Agent loop, tool registry, subagents, model runtime, workspace stores | 0.2.0 | 0.1.0 (uninstallable) |
| `lemon_memory` | Durable memory: document schema, SQLite store, provider behaviour, ingest, search | 0.2.0 | 0.1.0 (uninstallable) |
| `lemon_platform_test` | Contract-test kit: `BackendCase`, `EventsCase`, `ProviderCase`, `FakeLLM` (and `PluginCase`, which needs the unpublished `lemon_channels`) | 0.2.0 | 0.1.0 (uninstallable) |

These are exactly what `mix lemon.new` generates against. `0.2.0` is the first
installable line; it has not been published yet. The mechanics of publishing,
proving the tarballs, and retiring 0.1.0 are in
[`docs/release/hex-packages.md`](release/hex-packages.md).

## In the repository only

Everything else is the **reference runtime and its products**, built and released
together as the umbrella (CalVer), not as packages: `lemon_router`,
`lemon_gateway`, `lemon_channels`, `lemon_media`, `lemon_skills`, `lemon_browser`,
`lemon_control_plane`, `lemon_automation`, `lemon_cli`, `lemon_web`,
`lemon_lsp`, `lemon_mcp`, `lemon_honcho`, `lemon_evals`, `coding_agent`,
`lemon_sim`, `lemon_sim_ui`, plus the TypeScript clients under `clients/`.

What still holds from the split, and is worth keeping whether or not anything is
published:

- **Dependency boundaries.** `mix lemon.quality`'s architecture check enforces an
  exact per-app `deps/0` policy and cross-app namespace references; the generated
  table is [`architecture_boundaries.md`](architecture_boundaries.md). `lemon_ai`
  and `lemon_core` have no umbrella dependencies.
- **A library-grade `lemon_core`.** Named, multi-instance Stores; optional
  `phoenix_pubsub`, `exqlite`, `file_system`, `sentry` and `finch` with explicit
  degradation; runtime registries instead of compile-time references to
  consumers.
- **Typed bus events** — [`platform/bus-events.md`](platform/bus-events.md).
- **The contract-test kit** and **the generator** (`installer/`), both verified
  against the unpacked tarballs by `scripts/verify_packages`.
- **The sim seam.** `lemon_sim` depends only on core, agent and ai. Its wiring
  outside `apps/lemon_sim*` is marked `lemon-sim product block` (`config/*.exs`,
  `lemon.help`, the runtime profile, the architecture check's namespace table)
  so the seam stays visible; nothing is going to move it.

## Decision log

| # | Date | Decision |
|---|---|---|
| D1 | 08-09 | No merged `lemon_runtime` package; router, gateway and channels stay separate apps. |
| D2 | 08-10 | *Amended.* Gateway sheds only what is a channel: email moved to a `LemonChannels.Plugin`; webhook, SMS and voice stay gateway-owned because `Plugin.deliver/1` cannot answer a synchronous HTTP request. The original "move all five transports" was overturned by the code. |
| D3 | 08-09 | Bench stays inside `lemon_sim`. |
| D4 | 08-09 | `lemon_memory` split out of `lemon_core` as its own app. |
| D5 | 08-09 | Goal, kanban and heartbeat stores moved to `lemon_agent` as `LemonAgent.Workspace.*`. |
| D6 | 08-09 | Store library-ified before publishing; heavy deps made optional. |
| D7 | 08-09 | Vendor channels and tools isolated behind runtime registries (superseded by D17 for X). |
| D8 | 08-09 | LemonSim is the flagship demo, in this repository (see D18). |
| D9 | 08-09 | control_plane ↔ coding_agent inverted through a capability provider. |
| D10 | 08-09 | Umbrella stays CalVer; packages use independent semver, `1.0.0` only after the APIs have real consumers. |
| D11 | 08-10 | *Overturned the plan.* `chat_state`/`chat_state_store` stay in `lemon_core`: channels reads and writes them, so moving them to the router would have created a forbidden edge. The router is their single writer. |
| D12 | 08-10 | Farcaster transport deleted. |
| D13 | 08-10 | `lemon_media` published because router and channels depended on it (reversed by D18). |
| D14 | 08-13 | Publish `lemon_skills` and `lemon_browser` to unblock the coding-agent extraction. Never published; abandoned by D18. |
| D15 | 08-11 | CLI runners split into `lemon_cli_runners` (superseded by D16). |
| D16 | 08-21 | `lemon_cli_runners` deleted; subagents are native-only `CodingAgent.Session`s. |
| D17 | 09-01 | X/Twitter integration removed from the harness. |
| D18 | 09-27 | **Five packages, no extraction.** Publish only `lemon_ai`, `lemon_core`, `lemon_agent`, `lemon_memory`, `lemon_platform_test` — what the generator uses. Abandon Phase 5 (product repos, cross-repo CI) and D14. |

**Why D18.** The 0.1.0 releases of 2026-08-11 could not be installed: each shipped
a `mix.exs` that required `../../hex_package.exs`, a file outside the tarball, and
every check ran inside the umbrella where that file exists. Nobody reported it,
because there were no consumers. Router, gateway, channels, media, skills and
browser are runtime internals with vendor code; publishing them meant semver on
~100k lines nobody used. Extracting the products would turn every change to
core/agent/ai into a multi-repo release for a single maintainer, while the
architecture check already keeps the seams clean. The published `mix.exs` files
are now self-contained, and `scripts/verify_packages`
(`.github/workflows/packaging.yml`) builds consumer projects from the unpacked
tarballs so this class of break fails CI.

## Known gaps

- **0.1.0 is not retired yet**, and 0.2.0 is not published. Both are owner
  actions; the commands are in [`release/hex-packages.md`](release/hex-packages.md).
- **The generator needs a checkout.** `mix lemon.new` is built from `installer/`
  and emits path dependencies with the Hex line commented beneath; `lemon_new` is
  not on Hex and has no `--hex` mode.
- **`--channel` is checkout-only.** It depends on `lemon_channels`, which is not
  published; so does `PluginCase`.
- **`lemon_core` is broader than a core.** Stores the plan meant to move out are
  still there (`run_store`, `run_history_store`, `cwd`, `binding`,
  `binding_resolver`, `gateway_config`, `project_binding_store`,
  `config_reloader`, `usage_store`, `policy_store`, `progress_store`,
  `exec_approval_store`), as is `doctor/`. Only the repo tooling (`quality/`,
  `update/`, repo-only `mix lemon.*` tasks) is kept out of the tarball.
- **Elixir floor.** The packages declare `~> 1.15`; CI proves 1.19 and runs the
  1.15 leg as advisory.
- **Secrets key rotation** is not implemented: there is no re-encryption path, so
  replacing the master key means re-entering secrets. See the "Key rotation"
  section of the `LemonCore.Secrets` moduledoc.
- **`LemonChannels.Plugin.meta/0`** keeps its flag-map capability vocabulary;
  widening it to typed `Capability.spec()` lists waits for a consumer that needs
  sizes, features or rate limits.
