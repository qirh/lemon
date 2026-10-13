<div align="center">

<img src="docs/public/brand/lemon-banner.svg" alt="Lemon — Your agents. Your machine. Your move." width="100%">

# Lemon

A self-hosted AI assistant for your terminal, browser, Telegram, and Discord.<br>
Native agents, durable conversations, and local tools on Elixir/OTP.

[Documentation](https://z80dev.github.io/lemon/) · [Releases](https://github.com/z80dev/lemon/releases) · [LemonSim demo](#try-lemonsim-without-api-keys)

</div>

Lemon puts model providers, coding tools, memory, skills, and scheduled tasks in
one runtime. You control this runtime. Native subagents use the same execution
stack as the main agent. Named execution nodes can run tasks on a different computer.

**Important:** Lemon is local-first, but it is not local-only. Lemon sends data to
the model providers and integrations that you configure. Each provider gets the
data that it needs for its requests. Read the [safety model](docs/security/safety.md).

This repository also contains **LemonSim**. LemonSim makes deterministic,
event-sourced simulation worlds. Use these worlds to watch agents and to evaluate
model behavior. The LemonSim kernel and its Phoenix control room are in this
repository, next to the assistant.

Lemon is **pre-1.0**. For more information, read about
[supported platforms](docs/install.md), [current capabilities](docs/compare.md),
and [support boundaries](docs/support.md).

## Write code with Lemon in five minutes

You must use macOS or Linux. Open an interactive terminal in your repository.
Then type these commands:

```bash
curl -fsSL https://raw.githubusercontent.com/z80dev/lemon/main/install.sh | sh -s -- --skip-setup
export PATH="$HOME/.lemon/bin:$PATH"
lemon setup
lemon tui
```

In `lemon setup`, do these steps:

1. Select a model provider. You can use **OpenAI Codex → Sign in with ChatGPT**.
   You can also import an existing Codex CLI login, or use a different provider
   or API key.
2. Accept an available default model.
3. Skip the optional automation steps. You can configure them later.

**Note:** The prebuilt releases contain the runtime and the TUI. You do not have
to install Elixir.

Start `lemon` **in your repository**. Then send this prompt:

> Read the repository instructions. Find how to run the tests. If the README does
> not show the test command, add it. Run the focused tests. Show the diff.

Examine the change and the test output. When you start Lemon again, it uses the
same daemon. The [coding quickstart](docs/getting-started/quickstart.md) shows the
full workflow, the recovery steps, and the next steps:

| Task | Start here |
| --- | --- |
| Run a coding session from a script | `lemon -p "Explain this repository; do not edit files." --output json` |
| Use the native chat in Tern | Type `lemon tern install`. Then type `lemon` in a new Tern pane. |
| Do tasks in parallel | Ask for `scout` and `reviewer` task children. These two personas are read-only. |
| Go back to an earlier prompt | Type `/rewind`. Lemon shows the history change and asks you to confirm it. By default, it does not change your files. |
| Connect MCP tools | Type `lemon mcp list`. Then [add and test a trusted server](docs/skills.md#manage-named-mcp-servers). |
| Track long-term work | Ask for a goal or a kanban board. Then start `lemon web --no-open` and look at **Automation**. |

**Note:** The published `2026.08.1` release is older than the current Tern and
agent-workflow features. To use these features, install Lemon from source. Do
this until a newer release is available.

For all commands and configuration settings, read [setup](docs/user-guide/setup.md),
the [CLI guide](docs/user-guide/cli.md), and the [web guide](docs/user-guide/web.md).

## Develop from source

You must have these tools:

- Erlang/OTP 28.5 or later
- Elixir 1.19.5 or later
- Bun 1.3.14 or later, for the TUI
- Node.js 24 LTS or later, for the documentation and the browser client

Type these commands:

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

Run the checks from the repository root. Use `scripts/test fast` and
`scripts/test quality`. For the other test lanes, read [testing](docs/testing.md).

## Try LemonSim without API keys

Use a source checkout. Make sure that the dependencies are installed. Then type
these commands:

```bash
mix sim_ui.assets.setup
mix sim_ui.assets.build
mix lemon.sim.demo --seed 42
```

The last command shows a spectator URL. Open this URL.

The demo uses deterministic heuristic Werewolf seats. It does not use an LLM.
You do not have to configure provider credentials or a model. The demo runs until
you stop it. To stop the demo, push Ctrl+C two times.

If a different process uses the UI port, do one of these steps:

- Set `LEMON_SIM_UI_PORT` to a different port.
- Call `LemonSimUi.Demo.start_werewolf()` in the existing node.

For model-backed arenas, offline benchmark bundles, and replay verification, read
these guides:

- [LemonSim](apps/lemon_sim/README.md)
- [The control room](apps/lemon_sim_ui/README.md)
- [Benchmark quickstart](docs/benchmarks/quickstart.md)

## More information

- [Profiles](docs/user-guide/profiles.md), [memory](docs/user-guide/memory.md),
  [skills](docs/user-guide/skills.md), and [automation](docs/user-guide/reminders-and-heartbeats.md)
- [Backups](docs/user-guide/backups.md), [safe updates](docs/user-guide/updates.md),
  and [configuration](docs/config.md)
- [Architecture](docs/architecture/overview.md) and
  [dependency boundaries](docs/architecture_boundaries.md)
- [Package publication status](docs/platform-split.md). There are five package
  targets. Version 0.2.0 is not published yet.
- [Documentation index](docs/README.md) and
  [machine-readable documentation](https://z80dev.github.io/lemon/llms.txt)
- [Contributing](CONTRIBUTING.md), [agent guide](AGENTS.md), [security](SECURITY.md),
  and [changelog](CHANGELOG.md)

## Credits

Lemon got ideas from [pi](https://github.com/badlogic/pi-mono),
[Oh-My-Pi](https://github.com/can1357/oh-my-pi), [takopi](https://github.com/banteg/takopi),
OpenClaw, and Ironclaw. The first version of the skill library came from
[Hermes Agent](https://github.com/NousResearch/hermes-agent).

Lemon uses the [MIT license](LICENSE). We gave Lemon the name of a very good cat.
