# Lemon in Tern

Tern can host Lemon as a native ACP chat: streaming replies, reasoning, tool
cards, editor locations, permission requests and session controls are rendered
by Tern, not drawn by Lemon's terminal UI.

## Register once

First configure Lemon's model credentials normally (`lemon setup` on a new
installation), then run:

```bash
lemon tern install
```

From a source checkout, use `./bin/lemon tern install`. The installer records
that launcher's absolute path, merges the `lemon` custom-agent entry into Tern's
`settings.json`, and installs the Lemon palette plugin in `plugins/lemon`.
Unrelated preferences, agents and plugin files are preserved. ACP shell wrapping
is enabled; explicitly disabled plugins stay disabled. Installation does not
change Lemon credentials or start a daemon. Re-run after moving the checkout or
switching installations. Modified or linked Lemon plugin files are not overwritten.

Before registration, an interactive `lemon` launch in Tern falls back to Lemon's
own TUI with an installation hint, so first use still opens a working coding
session. Registered ACP startup or runtime errors are not hidden by that
fallback. Use `lemon tui` to select the terminal interface explicitly.

Open a **new Tern shell** and type:

```bash
lemon
```

Lemon's launcher recognizes the Tern pane and opens its registered id with
`tern acp lemon`, which starts `lemon acp` and shows native chat. Installed
`lemon` must be on PATH; in a source checkout type `./bin/lemon`. To open a chat
explicitly from an existing shell:

```bash
tern acp lemon
```

Use `lemon tui` to open Lemon's own terminal interface instead. Tern 0.7.2's
`--typed` wrapping recognizes its built-ins, not custom agent ids; Lemon's
launcher bridges that gap without a shell alias or plugin. Native omp's
usual Tern integration uses its terminal surface protocol; custom ACP agents do
not need to impersonate omp to receive native ACP chat rendering.

## Native terminal workspace

Run `tern plugin reload` after installation, or restart Tern. The command palette
then offers:

- **Lemon: New session in split** — opens `lemon tui` beside the focused pane,
  using its working directory and the launcher recorded during installation.
  With no focused pane it opens a new tab. Launching is available on the local
  POSIX host, not remote panes with an unrelated installation.
- **Lemon: Focus existing session** — lists live native Lemon TUI panes, including
  parked panes, and reveals the selected one without sending input.

These actions do not submit a prompt or convert ACP conversations into TUI
sessions. The TUI still reuses the local daemon and authenticates normally.
If the actions are absent, check Tern's plugin settings: installation preserves
`plugins=false` and entries in `plugins_disabled`.

In a Tern pane, `lemon tui` uses the same native surfaces as omp. The composer
has clickable model and effort chips, a context meter and Send/Stop. Tool calls
appear as structured cards: run boxes, diffs, file rows and checklists. Turns
have Copy/usage footers, approvals have decision buttons, and pickers open as
native sheets. See the [TUI guide](../../clients/tui/README.md#tern-and-modern-terminals)
for the full list.

Native file-tool cards carry editor locations. **⌘-click** an edit/read/patch
target (**Ctrl-click** on PC) to open Tern's file block at the reported changed
line or read offset; a plain click only folds the tool card. Resolved file paths,
including spaces and `#`, are preserved. The row-rendered TUI exposes the same
location through OSC 8 links. Nothing opens automatically when a tool runs.
For an explicit command, use `tern open --split right path/to/file:42`.

Use `/name <title>` to name a conversation. Its saved name is restored on the next
launch and appears in the Tern pane title and the plugin's session picker.

## Manual registration

Tern's **Settings → Agents → Custom agents** uses this shape:

```json
{
  "agents": {
    "auto_acp": true,
    "custom": [
      {
        "id": "lemon",
        "name": "Lemon",
        "command": "/absolute/path/to/lemon",
        "args": ["acp"],
        "env": {}
      }
    ]
  }
}
```

Merge the entry; do not replace your existing `agents.custom` array. `command`
is an executable path, **not** `"lemon acp"`; arguments belong in `args`.
The installer locates Tern's configuration using `tern plugin dir`, respecting
`TERN_CONFIG_DIR`. For a separate configuration:

```bash
lemon tern install --config-dir /path/to/tern-config
TERN_CONFIG_DIR=/path/to/tern-config tern acp lemon
```

Tern Settings normally live in `~/Library/Application Support/Tern` on macOS.
The plugin API also exposes `cx.settings:set` and `set_many`, but a plugin is not
required for native ACP hosting.

## Work in a project

Open Tern in the project directory before launching the agent. Tern sends that
absolute directory in `session/new`. Lemon attaches to the healthy local
runtime, starting a daemon only if needed. Closing chat disconnects the stdio
client and cancels an active turn; the daemon remains available for other panes.

Use Tern's model/thinking/approval config controls according to the options
Lemon negotiates; Lemon advertises no session modes, so Tern shows no mode
selector. Tool permissions are displayed as native ACP permission requests.
Tern's `/sessions`, `/new` and `/fork` controls operate on the advertised session
capabilities; neither a new chat pane nor the stdio process is another router.

Type `/plan` to toggle plan mode (or `/plan <request>` to start planning a
task). The agent explores read-only and drafts a plan file; when it proposes the
plan, Tern shows an **Approve plan** permission card with **Approve and
execute** or **Refine plan**. Approving switches back to normal tool access and
the agent starts implementing; `/plan` again leaves plan mode without approving.
See [plan mode](../tools/acp.md#plan-mode).

## Delegate from Carly or a plugin

Tern's agent API can target the registered ACP command directly. For example,
in Carly's Lua tool:

```lua
local pane = cx.agents:start({
  command = "tern acp lemon",
  cwd = "/absolute/path/to/project",
  prompt = "Review the latest diff and summarize the risks.",
  how = "split",
})
return await(cx.agents:wait(pane, {timeout = 120000}))
```

`cx.agents:ask(pane, text)` sends a follow-up; `list`, `transcript`, `interrupt`
and `stop` also work with Tern-hosted Lemon ACP. The host projects custom ACP
chat into its native conversation surface; Lemon does not need to identify
itself as omp.

Keep the target pane visible when waiting. In Tern 0.7.2, hidden-pane waits can
return a partial rendered reply or time out even after a complete ACP turn.
This also affects the omp reference. Transcript and last-message reads may
include Tern's turn footer; they are rendered chat projections, not raw ACP
responses. For authoritative automation outside the UI, use `lemon acp` or
Lemon's non-interactive CLI.

## Troubleshoot

- **The terminal UI appears instead of chat:** verify the custom id is `lemon`,
  its command points to the intended launcher, ACP shell wrapping is enabled,
  and the shell was opened after installation. Try `tern acp lemon` explicitly.
  An unknown `--typed` command can fall back to its ordinary terminal UI.
- **Agent not found:** the `tern acp` process must see the same `TERN_CONFIG_DIR`
  as the registration. Check Settings → Agents.
- **Could not attach:** run `lemon doctor`; ensure the runtime port and managed
  operator credential agree. An unrelated listener is not reused as Lemon.
- **No model reply:** verify model credentials in Lemon's configuration. Tern
  registration is not a model-provider login.
- **Capture protocol traffic:** set the log on the ACP host process:

  ```bash
  TERN_ACP_LOG=/tmp/lemon-acp.jsonl tern acp lemon
  ```

  The file contains JSONL `{at, dir, json}` records. It can contain conversation
  content and tool paths: keep it private and do not commit it.

For client framing, runtime authentication and cancellation details, see the
[ACP guide](../tools/acp.md).
