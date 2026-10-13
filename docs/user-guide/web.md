# Use Lemon in a Browser

Last reviewed: 2026-08-30

The full Lemon runtime includes a local browser interface. The launcher starts
the daemon when needed, reuses a healthy runtime already serving the configured
control-plane port, waits for the Web UI to become healthy, and opens the page:

```bash
lemon web
```

For scripts, SSH sessions, or when you only want the address:

```bash
lemon web --no-open
```

The default address is `http://127.0.0.1:4080/`. Set `LEMON_WEB_PORT` before
launch to choose another port. A source checkout uses the same command with the
repository wrapper:

```bash
./bin/lemon web
```

In a source checkout, `./bin/lemon web` reuses a healthy runtime or starts one
when needed. In an interactive terminal, bare `./bin/lemon` opens the TUI,
which also reuses a healthy runtime.

`lemon web` requires the `lemon_runtime_full` release profile. If the launcher
reports that the Web UI is unavailable in the minimal profile, reinstall with
`LEMON_PROFILE=full`.

## First run

The page uses the same setup-readiness contract as `lemon setup` and the TUI.
It checks for:

1. a Lemon config;
2. secure secret storage; and
3. a matching default provider/model with a usable credential.

When any item is missing, the page explains exactly what is pending and keeps
the prompt and file-upload controls disabled. It does not persist uploads or
start a doomed agent run. In a terminal, run:

```bash
lemon setup
```

Then choose **Check again** in the browser. Config and secret changes made by a
running Lemon process also refresh the check automatically. If setup still does
not become ready, run `lemon doctor` and follow its recovery guidance.

## Chat and active runs

Once the page shows **Ready**, enter a prompt or attach up to five files (20 MB
each). Responses and tool activity stream into the page. While a run is active,
the composer switches to text-only active-run controls:

- **Follow-up** queues a separate turn after the current run finishes.
- **Steer** adds guidance to the current run without replacing its direction.
- **Redirect** replaces the pending direction while preserving tool work that
  has already completed.

The page discovers active work when a named session is opened, rechecks the
same shared router state before submitting guidance, and keeps the draft if the
run ended in the meantime. A successful message confirms what was requested;
a refused request uses a bounded explanation and never displays node
credentials, remote paths, or internal runtime terms. Choose **Check status**
to reconcile the controls manually or **Stop** to request cancellation of the
actual active run. Session and run identifiers remain hidden during ordinary
use and are available under **Session details** only when debugging.

Each browser tab gets its own stable session in `sessionStorage`. Use
`/sessions/<session-key>` only when deliberately attaching to a known Lemon
session. Named routes reload durable prompt, tool, and answer history before
subscribing to new streaming events, so an existing conversation can be
continued rather than merely reused as an empty routing key.

Tool cards update while a command is still running, not only when it finishes.
Expand a card to inspect its bounded arguments and latest output; the completed
result replaces the live preview. Reopening a named session retains one card
per durable action, with its latest phase; live updates reuse that same card.

The **Subagents** panel follows actual parent/child task links for the session.
It refreshes every two seconds while the page is connected and includes running
and finished children, their status, and links to available child sessions.
The tree is bounded to 50 nodes and eight levels. Missing runtime data is shown
as unavailable, never as proof that no child work exists. It does not expose
child prompts, results, repository paths, or credentials.

## Management access

Set `LEMON_WEB_ACCESS_TOKEN`, launch the full runtime, and open `/manage` with
the token once:

```text
http://127.0.0.1:4080/manage?token=<your-token>
```

The server validates the token, stores only a derived signed-session marker,
and redirects to the same address without `token` before rendering the page.
The server validates the same token for every page under `/manage`. The
sessions page shows local runtime health, live named-node names, and
durable-session counts. **Working now** includes active agents before their
first run has produced durable history. Open **Live transcript** to watch a run
or **Open** beside a saved session to continue it. The list refreshes every
three seconds while connected; an unavailable router preserves the last known
work with an explicit unavailable state. Up to 40 active runs and 200 matching
durable sessions are shown. From there you can:

- search session keys, titles, prompts, and answers, then filter active,
  archived, or all sessions;
- add a title, pin important work, archive completed work, and resume a chat;
- inspect redacted prompts, answers, and structured tool activity;
- download bounded, redacted JSON or Markdown exports; and
- preview and confirm pruning of archived, unpinned sessions older than a
  chosen threshold.

Prune never accepts a count-only confirmation. The preview token binds the
threshold and exact candidate identities plus their current lifecycle state.
If any candidate changes, no deletion occurs and the page asks for a fresh
preview. Export and inspection omit raw run records, raw event payloads,
credentials, and secret values and report any size-bound run omissions.

Management labels and in-page history additionally omit path-bearing tokens;
the private chat transcript remains available only through its authenticated
session page.

### Manage automated coding work

Choose **Automation** from the sessions page, or open `/manage/work`, to follow
the same kanban boards, goals, and cron jobs used by agent tools and the CLI.
The dashboard refreshes while connected and links accepted runs to their live
session transcripts. It shows bounded status, progress, result-state, and
retry information without exposing stored prompts, objectives, repository
paths, or raw errors.

- **Kanban:** inspect cards in the board's configured workflow order, including
  custom columns; start a board or stop its dispatcher and active work.
- **Goals:** start a bounded execution, inspect active and completed progress,
  and pause, resume, or stop its loop.
- **Cron:** run a configured job now, pause or resume its schedule, inspect
  recent runs, and stop an exact active invocation.

Controls use the existing automation managers, not a separate browser
scheduler. Changes are previewed against the current target revision before
confirmation. A changed target requires a new preview; stale confirmations
cannot stop a replacement run or silently apply to newer settings. Cancellation
requests and unknown outcomes remain visible until the shared runtime confirms
the final state.

A failed attempt is shown as **Last run: failed**, not silently treated as
unfinished work. Resume a paused goal before starting another bounded attempt.
Failed kanban cards are not automatically redispatched: after reviewing the
private transcript, use the `kanban` tool to update the card back to its first
column, then start its board. Cron shows each attempt's retry number and links
to that invocation's actual session rather than only the job's parent session.
If a browser control reports an unknown outcome, it does not retry the action;
inspect shared live state before reopening the page to act again.

Create repository-backed work with the `kanban`, `goal`, or `cron` agent tools
(or their existing control-plane surfaces), then use the dashboard to operate
it. Creating a cron job does not require enabling its schedule: a paused job can
still be run manually. The browser does not accept arbitrary shell commands or
repository paths in management forms.

### Manage provider routing

Choose **Providers** from the sessions page, or open `/manage/providers`, to
inspect effective routing without displaying config paths, prompts, base URLs,
environment-variable names, secret names, or credential references. The page
supports:

- ordered fallback append, removal, and clear;
- credential-pool create/update, strategy selection, activation, and delete;
- credential-reference add, remove, and provider-level clear; and
- redacted pool/reference counts plus the active pool.

Every mutation starts as a preview and writes nothing. The preview is bound to
an opaque revision of the target config; if another process changes that config
before apply, Lemon rejects the stale apply and keeps the non-secret form draft
for another preview. Removing or clearing fallbacks, updating or deleting an
existing pool, and removing or clearing credential references also require the
provider or pool confirmation shown by the preview to be typed exactly.

Credential references accept only `secret:NAME` or `env:NAME`. Their names are
entered through a password field, filtered from LiveView logs, and never stored
in socket draft state or rendered back into HTML. For an apply, the browser asks
you to re-enter the same reference and Lemon compares only its digest before
calling the shared provider-configuration service. The service remains the
single owner of comment-preserving validation and atomic TOML replacement.

Skills/MCP, memory, logs, and broader configuration retain their existing
CLI/TUI/control-plane surfaces where no management page is linked.

## Access control

The Web UI binds to localhost in the supported local launch path. To require a
token for chat as well, set a high-entropy `LEMON_WEB_ACCESS_TOKEN` before
starting Lemon. The management surface always requires this token and returns
HTTP 503 when it is not configured. `lemon web` passes URL-safe configured
tokens to the browser for the one-time login; the server consumes the query
parameter with an immediate token-free redirect after the authenticated
session cookie is established.

For a remote deployment, terminate TLS in front of Lemon and require the token.
Do not expose an unauthenticated HTTP listener to an untrusted network.

## Recovery

| Symptom | What to do |
| --- | --- |
| `Setup needed` | Run `lemon setup`, then choose **Check again**. |
| Provider or model remains pending | Run `lemon setup provider`; use `--skip-verify` only when deliberately offline. |
| Web UI does not become healthy | Run `lemon status`, inspect the launcher log, then run `lemon doctor`. |
| Port 4080 is occupied | Set `LEMON_WEB_PORT` to an unused port and rerun `lemon web`. |
| Minimal-profile error | Reinstall with `LEMON_PROFILE=full`. |
| Browser did not open | Use `lemon web --no-open` and open the printed URL manually. |
| HTTP 401 | Launch through `lemon web` with the same `LEMON_WEB_ACCESS_TOKEN`, or supply the token once as `?token=...`. |
| Management HTTP 503 | Set a non-empty `LEMON_WEB_ACCESS_TOKEN`, restart Lemon, and authenticate once. |
| Provider preview became stale | Keep the preserved non-secret draft, review the refreshed status, and preview the exact change again. |
| Active-run choices disappeared | The run finished or is no longer eligible. Send the preserved draft as a new message, or choose **Check status** if the run is still active elsewhere. |

The UI ships its CSS and Phoenix client assets inside the Lemon release. It
does not require a JavaScript or CSS CDN at runtime. The page includes a skip
link, labeled status regions, keyboard focus states, responsive layouts, and
live announcements for streamed activity and errors.
