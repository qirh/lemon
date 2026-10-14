# Delegating to omp

[omp](https://github.com/can1357/oh-my-pi) (oh-my-pi) is a separate coding
agent. Lemon can hand it work: start an omp session in a workspace, watch what
it is doing, steer or cancel it, and resume it later. You can drive this from
chat (“run this in omp”), from the TUI's `/omp` panel, or with `lemon omp`.

omp is a *delegate*, not Lemon's engine. Lemon's own conversations still run on
its native agent; omp runs as its own process with its own model, credentials,
settings and session history, and Lemon observes it through omp's structured
RPC protocol (`omp --mode rpc`).

## Requirements

- `omp` installed and on the `PATH` of the Lemon runtime (`which omp`), or
  `LEMON_OMP_BIN` pointing at it. Without it every surface says “omp is not
  installed” and nothing else changes.
- omp configured with a working model (its own `omp` setup, API keys in the
  environment, or `--model` per session). Lemon never passes its own provider
  credentials to omp.

`lemon omp status` (or `omp.status` in the control plane) reports whether omp
was found and its version.

## From chat

Ask in plain words; Lemon uses its `omp` tool:

> Run this in omp: add input validation to `lib/parser.ex` and its tests.

Lemon starts omp in the conversation's working directory and replies with the
session id (for example `omp_3f9a1c2b7d4e`). Then:

- “What's omp doing?” — Lemon reports the current activity, running tools,
  todo progress, token usage and cost, and the latest output.
- “Wait for omp to finish” — Lemon blocks until the turn ends; the tool card
  streams progress while it waits.
- “Tell omp to skip the docs” — steers the running turn; “after that, also
  run the linter” queues a follow-up. A message to an idle session starts a
  new turn.
- “Cancel the omp run” — aborts the current turn; the session stays open.
- “Close it” — ends the omp process. Its history stays on disk.
- “Which omp sessions exist here?” / “resume the last one” — lists omp's stored
  sessions for the workspace and reopens one.

A conversation can only see and control the omp sessions it started. Sessions
you start from the TUI or CLI are operator sessions; manage those from the TUI
or CLI.

## From the TUI

`/omp` (also in the command palette) opens the omp panel: live and recent
sessions with status, workspace, model, current activity, elapsed time and
tokens/cost. Select a session for its detail view — activity, running and
recent tools, todos, subagents, usage, latest output or result. Keys:

| Key | Action |
| --- | --- |
| Enter | open the detail view / back |
| `s` / `f` | steer the running turn / queue a follow-up |
| `c` | cancel the running turn |
| `x` | close the omp process |
| `d` | discover stored omp sessions for this workspace; Enter resumes one |
| `r` | refresh |
| Esc | close the panel |

`/omp run <prompt>` starts a session in the TUI's working directory, and
`/omp status` prints a one-line summary of live sessions. The panel updates
live from the runtime's `omp.session` events.

## From the CLI

```bash
lemon omp status
lemon omp start --cwd ~/src/app "Add input validation to lib/parser.ex"
lemon omp list
lemon omp show omp_3f9a1c2b7d4e
lemon omp send omp_3f9a1c2b7d4e "Skip the docs"
lemon omp send --follow-up omp_3f9a1c2b7d4e "Then run the linter"
lemon omp cancel omp_3f9a1c2b7d4e
lemon omp close omp_3f9a1c2b7d4e
lemon omp discover --cwd ~/src/app
lemon omp resume 01a137e9-baf8 --cwd ~/src/app "Continue with the tests"
```

These talk to the running Lemon runtime; see [CLI](cli.md) for every option.

## What Lemon reports

For each session Lemon keeps a bounded snapshot: status (`starting`,
`running`, `idle`, `closed`, `failed`), the outcome of the last turn
(`completed`, `error`, `aborted`), current activity, active and recent tools,
todos, subagents, token usage and cost (omp's own totals), context use, the
latest assistant text and the last turn's result. Text is clipped and stripped
of control sequences. Ended sessions stay listed until the runtime restarts.

**Discovery** reads omp's session files for a workspace
(`~/.omp/agent/sessions/…`, or `$PI_CODING_AGENT_DIR/sessions`) without
writing, locking or migrating them. Each entry shows omp's session id, title,
model, last outcome, whether Lemon currently runs it, and whether it was
written to in the last two minutes without a clean exit (probably open in
another omp).

## Safety and lifecycle

- **omp output is untrusted.** Everything quoted from omp — its replies,
  errors, todo text — reaches Lemon's model fenced as external data, never as
  instructions.
- **Headless.** omp sometimes asks interactive questions (approvals, pickers).
  Lemon has no surface to answer them, so it declines: confirms answer “no” and
  other prompts are cancelled. The snapshot counts declined prompts. If your
  omp is set to ask before writing, it will be unable to write; choose an omp
  approval mode that suits unattended work.
- **Control fails closed.** Steering, follow-ups and cancellation go to one
  process invocation and are acknowledged only after omp accepts them. A
  closed or crashed session refuses them; resume it to continue (resuming is a
  new invocation with a new id). If omp does not answer in time the result is
  “outcome unknown” — check the status before retrying, because the request
  may already have taken effect.
- **No orphans.** omp exits when its input closes, aborting the running turn
  and its shell commands. Lemon holds that input, so stopping, crashing or
  killing the Lemon runtime ends every omp it started; on a normal stop Lemon
  also escalates to SIGTERM and SIGKILL if omp lingers.
- **Bounded.** At most `LEMON_OMP_MAX_SESSIONS` (default 4) live omp
  processes; an idle process closes after `LEMON_OMP_IDLE_TIMEOUT_MS`
  (default 30 minutes, `0` disables) and stays resumable. Lemon's own
  `LEMON_*` environment variables (including control-plane tokens) are removed
  from omp's environment.

## Settings

| Variable | Default | Meaning |
| --- | --- | --- |
| `LEMON_OMP_BIN` | first `omp` on `PATH` | omp executable |
| `LEMON_OMP_MAX_SESSIONS` | `4` | live omp processes |
| `LEMON_OMP_IDLE_TIMEOUT_MS` | `1800000` | close idle processes (0 = never) |
| `PI_CODING_AGENT_DIR` / `PI_CONFIG_DIR` | omp's defaults | where discovery looks (omp's own variables) |

See also the [`omp` tool reference](../tools/omp.md).
