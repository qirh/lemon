<div align="center">

<img src="docs/public/brand/lemon-banner.svg" alt="Lemon — Your agents. Your machine. Your move." width="100%">

# Lemon

A self-hosted AI assistant for your terminal, browser, Telegram and Discord.<br>
Native agents, durable conversations and local tools on Elixir/OTP.

[Documentation](https://z80dev.github.io/lemon/) · [Releases](https://github.com/z80dev/lemon/releases) · [LemonSim demo](#try-lemonsim-without-api-keys)

</div>

Lemon brings model providers, coding tools, memory, skills and scheduled work into
one runtime you control. Native subagents share the same execution stack; named
execution nodes can place work on another machine. Local-first does **not** mean
local-only: configured model providers and integrations receive the data needed
for their requests. Review the [safety model](docs/security/safety.md).

The repository also retains **LemonSim**: deterministic, event-sourced simulation
worlds for watching agents and evaluating model behavior. Its kernel and Phoenix
control room live beside the assistant, not in a separate product repository.

Lemon is **pre-1.0**. See [supported platforms](docs/install.md),
[current capabilities](docs/compare.md) and [support boundaries](docs/support.md).

## Start coding in five minutes

In an interactive terminal opened in your repository (macOS or Linux):

```bash
curl -fsSL https://raw.githubusercontent.com/z80dev/lemon/main/install.sh | sh -s -- --skip-setup
export PATH="$HOME/.lemon/bin:$PATH"
lemon setup
lemon tui
```

Setup supports **OpenAI Codex → Sign in with ChatGPT**, explicit import of an
existing Codex CLI login, and other providers/API keys. Accept an available default
model and skip optional automation for now. Prebuilt releases include the runtime
and TUI; no Elixir installation is needed.

Start `lemon` **from your repository**, then ask:

> Read the repository instructions. Find how to run the tests. Add the test
> command to README if missing, run the focused tests, and show the diff.

Review the change and test output. The daemon is reused on subsequent launches.
The [coding quickstart](docs/getting-started/quickstart.md) walks through the real
workflow, recovery, and these next steps:

| Work your way | Start here |
| --- | --- |
| Script a coding session | `lemon -p "Explain this repository; do not edit files." --output json` |
| Use Tern's native chat | `lemon tern install`, then type `lemon` in a new Tern pane |
| Delegate parallel work | Ask for `scout` and `reviewer` task children; both personas are read-only |
| Revisit an earlier prompt | `/rewind` previews and confirms a history change; files stay untouched by default |
| Connect MCP tools | `lemon mcp list`, then [add and test a trusted server](docs/skills.md#manage-named-mcp-servers) |
| Track durable work | Ask for a goal or kanban board, then inspect **Automation** with `lemon web --no-open` |

See [setup](docs/user-guide/setup.md), the [CLI guide](docs/user-guide/cli.md),
and the [web guide](docs/user-guide/web.md) for the complete command and
configuration reference.

## Develop from source

Use Erlang/OTP 28.5+, Elixir 1.19.5+, and Bun 1.3.14+ for the TUI. Node.js 24 LTS+
is used by the docs and browser client.

```bash
git clone https://github.com/z80dev/lemon.git
cd lemon
mix local.hex --force
mix deps.get
mix compile
./bin/lemon setup
./bin/lemon doctor
./bin/lemon
```

Run checks from the repository root with `scripts/test fast` and
`scripts/test quality`; [testing](docs/testing.md) describes the other lanes.

## Try LemonSim without API keys

From a source checkout with dependencies installed:

```bash
mix sim_ui.assets.setup
mix sim_ui.assets.build
mix lemon.sim.demo --seed 42
```

Open the spectator URL printed by the command. It runs deterministic heuristic
Werewolf seats, not an LLM, and keeps serving until you stop it with Ctrl+C twice.
No provider credentials or model configuration are needed. If the UI port is
already occupied, set `LEMON_SIM_UI_PORT` or call
`LemonSimUi.Demo.start_werewolf()` inside the existing node.

For model-backed arenas, offline benchmark bundles and replay verification, see
[LemonSim](apps/lemon_sim/README.md), [the control room](apps/lemon_sim_ui/README.md)
and [benchmark quickstart](docs/benchmarks/quickstart.md).

## Go deeper

- [Profiles](docs/user-guide/profiles.md), [memory](docs/user-guide/memory.md),
  [skills](docs/user-guide/skills.md) and [automation](docs/user-guide/reminders-and-heartbeats.md)
- [Backups](docs/user-guide/backups.md), [safe updates](docs/user-guide/updates.md)
  and [configuration](docs/config.md)
- [Architecture](docs/architecture/overview.md), [dependency boundaries](docs/architecture_boundaries.md)
  and [package publication status](docs/platform-split.md) — five package targets;
  repository 0.2.0 is not yet published
- [Documentation index](docs/README.md) and [machine-readable docs](https://z80dev.github.io/lemon/llms.txt)
- [Contributing](CONTRIBUTING.md), [agent guide](AGENTS.md), [security](SECURITY.md)
  and [changelog](CHANGELOG.md)

Inspired by [pi](https://github.com/badlogic/pi-mono),
[Oh-My-Pi](https://github.com/can1357/oh-my-pi), [takopi](https://github.com/banteg/takopi),
OpenClaw and Ironclaw. The skill library was bootstrapped from
[Hermes Agent](https://github.com/NousResearch/hermes-agent).
[MIT licensed](LICENSE). Named after a very good cat.
