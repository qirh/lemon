# Lemon command-line reference

The source checkout (`./bin/lemon`) and packaged releases (`lemon`) share the
same command surface. The launcher handles lifecycle commands; all other
commands are dispatched by the CLI registry.

## No-argument behavior

This behavior is identical in source checkouts and packaged installs:

- In an interactive terminal (stdin and stdout are TTYs), `lemon` opens the TUI.
- Without a TTY, `lemon` prints usage to stderr and exits with status 2.
- `lemon start` starts the runtime in the foreground; `lemon run` runs a prompt.

Use `./bin/lemon` instead of `lemon` in the examples below when running from a
source checkout.

## Commands and availability

### Launcher lifecycle commands

The registry defines their help and completion; the launcher executes them:

| Command | Source checkout | Packaged release | Purpose |
| --- | --- | --- | --- |
| `tui [args]` | Yes | Yes | Reuse a healthy runtime; otherwise run `setup --if-required` in an interactive terminal, start the daemon, and open the TUI. |
| `web [--no-open]` | Yes | Full profile only | Start the daemon if needed, wait for Web UI health, and print its URL; open a browser unless `--no-open` is set. |
| `start` | Yes | Yes | Run the runtime in the foreground. |
| `daemon` | Yes | Yes | Start the runtime in the background and wait for health. |
| `stop`, `restart`, `status` | Yes | Yes | Manage or inspect the daemon using its pidfile. |
| `remote`, `eval EXPR`, `rpc EXPR` | No | Yes | Use release VM remote/eval/RPC tools. |

Source runtime options go after `start`, `daemon`, or `restart`:
`--debug`, `--port N`, `--web-port N`, `--sim-port N`, `--name name@host`,
`--sname name`, `--cookie C`, and `--no-distribution`. For example,
`./bin/lemon start --no-distribution`. Runtime options are accepted after the
relevant lifecycle command, not as bare launcher flags.

### CLI commands

These commands are dispatched by `LemonCli.CLI` in both source checkouts and
packaged releases:

| Command | Availability | Notes |
| --- | --- | --- |
| `run`, `-p`, `--print` | Source and release | Run a coding prompt non-interactively, reusing or starting the local daemon. |
| `setup` | Source and release | `setup --if-required` exits 0 if setup is complete; otherwise runs the wizard and exits 1 if setup remains incomplete. |
| `model`, `gateway`, `doctor`, `config`, `secrets`, `channels`, `providers` | Source and release | Configure or inspect Lemon and its integrations. |
| `blueprints` | Source and release | Starts the local runtime through the launcher if it is not healthy. |
| `profile` | Source and release | `profile chat` starts the local runtime through the launcher if it is not healthy. |
| `backup`, `context`, `sessions`, `learn` | Source and release | Manage backups, bounded context, durable sessions, and learning. |
| `update` | Source and release | Release: full managed-update commands; source: `check` and `history` only, while plan/apply/rollback fail closed. Bare or unknown source update forms do not forward to Mix. Use `mix lemon.update` directly for source configuration migration and bundled-skill sync. |
| `completion` | Source and release | Generate completion for the current launcher's available commands. |
| `migrate` | Source and release | Hermes audit/import commands are available under `migrate hermes`. The former Hermes-specific Mix tasks are deleted. |
| `node` | Source and release | Includes `node join`. |
| `version` | Source and release | Print the Lemon version. |
| `send`, `media`, `models`, `policy`, `skill`, `usage` | Source and release | Mix-free channel notifications, diagnostics, catalog, policies, and skill management; existing Mix tasks remain thin source adapters. |

## Help and exit codes

`lemon <launcher-command> --help` and `lemon help <command>` print help.
Success exits 0, operational failures exit 1, and invalid commands or
arguments exit 2.

`--help`, `-h`, and `help` print command help without running the command body.
Commands that document `--json` emit JSON on success. Redacted operational
error JSON is supported by the profile, session, blueprint, provider, learning,
and secret-source command families; other commands report errors as text on
stderr. Invalid arguments remain human-readable usage errors.

## Non-interactive coding

```bash
lemon -p "Explain this repository"
echo 'list files' | lemon -p --output stream-json
lemon run "Fix the failing parser" --cwd ./project --model openai-codex:gpt-5.5 \
  --approval-policy allow --output json | jq .
lemon run "Continue the fix" --continue
lemon run "Review the changes" --session agent:default:cli-SESSION
```

With no prompt argument, `run` reads stdin to EOF. A prompt argument is used
as-is (stdin is not read). Empty prompts and invalid options exit 2. A fresh
run creates a durable, isolated session. `--continue` resumes the most recently
updated CLI session for the current `--cwd`; `--session` selects an explicit
session key. The two flags are mutually exclusive.

`--output text` (default) prints only the final answer. `json` prints one
result document with `ok`, `answer`, `error`, `run_id`, and `session_key`.
`stream-json` prints newline-delimited JSON: an `init` record, run-scoped
`event` records containing control-plane event names and payloads, and a final
`result` record. Startup diagnostics stay on stderr. Runs exit 0 only when the
agent reports success; submission, connection, provider, and execution failures
exit 1. Runs are bounded to ten minutes; timeout cancels the submitted run.
Protocol keepalive pings keep long-running tools connected without adding records
to stdout. A lost connection produces a failed result, not a successful fallback
or an automatic re-submission of the prompt.

Non-interactive mode never waits for a human approval. `--approval-policy deny`
(default) denies requested approvals; `allow` approves each request once.
Existing tool policy still applies. Use `--allowed-tools read,grep,find` and/or
`--denied-tools bash,write,edit` to narrow the run's tool policy. These flags
do not provide OS-level sandboxing. The daemon is reused when healthy and is
started through the normal launcher when absent; the client does not boot a
second router or scheduler.


## Update lifecycle

Managed releases use an explicit preview-confirm flow:

```bash
lemon update check
lemon update plan
lemon update apply --confirm <exact-plan-digest>
lemon update history
lemon update rollback --receipt <exact-apply-receipt> \
  --confirm <exact-rollback-digest>
```

Planning does not mutate disk. Apply re-plans under an exclusive lock, verifies
the schema-2 manifest's exact size/SHA-256 metadata, rejects unsafe archives,
checks the staged launcher's reported version, and writes a private content-free
receipt only after the atomic pointer flip verifies. Rollback is receipt-bound;
it accepts no path and restores no config, credentials, sessions, or stores.
Source checkouts expose check/history but fail packaged plan/apply/rollback
closed. See [Safely update and roll back Lemon](updates.md) for the complete
safety contract and current publisher-signing/network-cap residuals.

## External secret sources

External source diagnostics are available through the same packaged and source
command boundary:

```bash
lemon secrets sources status
lemon secrets sources status --json
lemon secrets sources test
lemon secrets sources test vault --json

# Source checkout
./bin/lemon secrets sources test --source-id vault
```

`status` validates configuration plus executable/bootstrap readiness without
executing the source. `test` runs all enabled sources, or one named source,
under the configured timeout and output bound. Human and JSON responses expose
only source id/type, readiness, provenance, counts, byte counts, duration, and
stable error kinds; they never include secret values. Operational test failure
exits `1`, invalid options exit `2`, and an empty/not-configured selection is an
operational failure.

`lemon secrets check` likewise reports only `present` for resolved entries; it
does not print prefixes or suffixes. External sources remain read-only
fallbacks behind the encrypted Lemon store. See
[External secret sources](../config.md#external-secret-sources) for the exact
configuration and fail-closed resolution contract.

## Portable blueprints

`lemon blueprints` talks only to the authenticated local control plane. It
never accepts a filesystem root or path and never starts a scheduler in the
one-shot CLI VM. Both source and packaged launchers start the local runtime
when it is not already healthy.

```bash
lemon blueprints
lemon blueprints inspect daily-note
lemon blueprints validate daily-note --json
lemon blueprints daily-note --profile operator
lemon blueprints preview daily-note --profile operator --json
```

The bundle-ID shorthand is preview, not activation. These reads return only
the control plane's sanitized projections: IDs/names, content hashes and byte
counts, profile/session target, cron schedule/state, provenance, collision
actions, and cleanup flags. They omit absolute paths, skill bodies, prompt or
command text, and secret values.

Activation requires the exact 64-character `confirmationDigest` from a fresh
preview:

```bash
lemon blueprints activate daily-note --profile operator \
  --confirm <exact-confirmation-digest>
```

The long-running runtime re-plans under the existing blueprint lock before any
write. Content, profile destination, enabled-skill state, or cron collision
changes invalidate the digest. Successful replay reports `unchanged` and keeps
one stable cron job. JSON success is one sanitized document on stdout;
operational failures are one redacted error document on stderr with exit `1`;
invalid CLI arguments use exit `2`. See the
[bundle manifest and safety guide](skills.md#portable-skill-and-automation-bundles).

## Durable sessions

`lemon sessions` is the operator boundary over Lemon's canonical run history,
chat state, policy, and session metadata stores. It does not create another
conversation database. All list and history reads are bounded; history and
exports are always redacted.
Session commands connect to the authenticated running daemon, starting it through
the normal launcher when absent. They read and mutate that daemon's canonical
state, not a separate store in the short-lived CLI process. This also applies
when the runtime uses an isolated home or agent directory. Export destination
files are still written locally by the client.

### List, search, show, and history

```bash
lemon sessions list --limit 20
lemon sessions list --archived --pinned --agent-id research --json
lemon sessions search "deployment follow-up" --limit 10
lemon sessions stats --active --group-limit 10
lemon sessions stats "deployment follow-up" --agent-id research --json
lemon sessions show agent:research:main
lemon sessions history agent:research:main --limit 25 --json
```

List and search accept `--limit` from 1 to 500 and `--offset` from 0 to
1,000,000. History accepts `--limit` from 1 to 200. Lifecycle filters are
explicit pairs: `--pinned` or `--unpinned`, and `--archived` or `--active`.
Contradictory filters are usage errors rather than silently selecting one.

Search checks session identifiers, agent identifiers, titles, and a bounded
redacted history selection. Human output avoids store paths and secret values;
JSON output contains normalized session and run fields only.

`sessions stats` applies the same agent, pin, archive, and bounded redacted
history-search filters. It reports exact valid-store and matched session counts,
active/archived/pinned/titled counts, the canonical run-count sum, and oldest
and newest update timestamps. Agent and origin dimensions are deterministically
ordered and capped from 1 to 50 entries (`--group-limit`, default 10); omitted
cardinality is reported. The report never contains session keys, titles,
messages, prompts, answers, paths, URLs, or credentials. Message/turn counts are
not inferred because no single canonical store exposes them reliably.

### Title, pin, and archive state

```bash
lemon sessions title agent:research:main "Literature review"
lemon sessions title agent:research:main --clear
lemon sessions pin agent:research:main
lemon sessions unpin agent:research:main
lemon sessions archive agent:research:main
lemon sessions restore agent:research:main
```

Titles are trimmed and limited to 160 characters. These commands update the
shared lifecycle metadata and verify the session still exists before reporting
success.

### Redacted export

Print an always-redacted JSON or Markdown export:

```bash
lemon sessions export agent:research:main --format json
lemon sessions export agent:research:main --format markdown
```

Write the selected export to an owner-only file:

```bash
lemon sessions export agent:research:main \
  --format json \
  --output research-session.json \
  --json
```

Existing files are refused unless `--force` is explicit. Symlinks and special
files are always refused. With `--output --json`, stdout contains safe export
metadata and only the output basename; the exported content stays in the file.
Without `--output`, `--json` returns the redacted content in its JSON envelope.
Exports contain selected session/run/tool fields, SHA-256 integrity metadata,
and omission counts. They never contain raw run records or raw event payloads.

### Preview-confirm prune

Prune is dry-run by default. It selects only archived sessions older than the
cutoff and excludes pinned sessions:

```bash
lemon sessions prune --older-than 30d
```

`--older-than` accepts a positive age with `s`, `m`, `h`, `d`, or `w`, an
ISO-8601 date/time, or epoch milliseconds. The preview prints the exact
`older_than_ms`, candidate keys, and confirmation token. Review the candidates,
then execute with the exact millisecond cutoff and token printed by the
preview:

```bash
lemon sessions prune \
  --older-than 1788062400000 \
  --confirm <preview-token>
```

Do not repeat a relative value such as `30d` for execution: time has advanced,
so the derived cutoff and token will differ. If any candidate or lifecycle
metadata changes after preview, execution fails and requires a new preview.

`--all` also considers non-archived sessions. `--include-pinned` also considers
pinned sessions. Both widen deletion scope and are included in the token, so
they must be identical at preview and execution. Deletion removes core-owned
chat, policy, metadata, index, and history state and verifies each session is
gone before reporting success.

### Verified single-session delete

Single-session deletion requires the exact session key twice:

```bash
lemon sessions delete agent:research:main \
  --confirm agent:research:main
```

A mismatch is a usage error and does not mutate state. The lifecycle service
deletes canonical run history last, verifies all core-owned state is gone, and
restores recoverable ancillary metadata if final deletion or verification
fails.

## Shell completion

Completion scripts are generated from the same registry used by CLI dispatch
and help, so new runtime families cannot be added to one surface while being
omitted from the others.

### Bash

```bash
mkdir -p "$HOME/.local/share/bash-completion/completions"
lemon completion bash > "$HOME/.local/share/bash-completion/completions/lemon"
```

### Zsh

```zsh
mkdir -p "$HOME/.zfunc"
lemon completion zsh > "$HOME/.zfunc/_lemon"
fpath=("$HOME/.zfunc" $fpath)
autoload -Uz compinit && compinit
```

Persist the `fpath` line in `.zshrc` if `$HOME/.zfunc` is not already in the
completion path.

### Fish

```fish
mkdir -p "$HOME/.config/fish/completions"
lemon completion fish > "$HOME/.config/fish/completions/lemon.fish"
```

Regenerate the script after upgrading Lemon so it reflects the installed
command registry.
