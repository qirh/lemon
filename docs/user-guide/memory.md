# Memory User Guide

Lemon has two memory concepts:

- **Remember** compact facts in assistant-home `USER.md` or `MEMORY.md` using the `remember`
  tool.
- **Recall** relevant past conversations and longer notes using `recall`. Lemon can also add a
  bounded **Relevant memory** block to each user message automatically.

These surfaces complement each other: `USER.md` and `MEMORY.md` are bootstrap context, while
`recall` searches prior conversation summaries and notes under the workspace's `memory/` folder.

---

## Remember compact facts

The `remember` tool writes assistant-home files only; it never writes into the active project:

| Target | File | Limit | Purpose |
|---|---|---:|---|
| `user` | `~/.lemon/agent/workspace/USER.md` | 1,375 chars | Stable facts and preferences about the human |
| `memory` (default) | `~/.lemon/agent/workspace/MEMORY.md` | 2,200 chars | Curated quick facts and links |

The tool accepts `text`, `target` (`user` or `memory`, default `memory`), and `replaces`.
Providing `text` adds a bullet; an existing duplicate is not added again. Providing both `text`
and `replaces` replaces the unique exact passage. Providing only `replaces` removes that exact
passage. Writes that exceed the file limit, ambiguous or missing replacement text, and invalid
targets are rejected. Content is screened for common secrets, prompt-injection phrases, NUL bytes,
and invisible or bidirectional control characters.

These files are included in the main-session workspace bootstrap context. `USER.md` is for
stable human profile facts; `MEMORY.md` is for concise curated context. Save reusable procedures
as skills instead of memory facts.

---

## Recall conversations and notes

The read-only `recall` tool searches two sources:

1. Past conversation summaries, ranked by lexical relevance.
2. Markdown notes under `<workspace_dir>/memory/` (except `TEMPLATE.md`), matched by query terms.

`USER.md` and `MEMORY.md` are not searched because they are already in the system prompt. Call
`recall` with a non-empty `query`; `scope` is `agent` by default or `project`, and `limit` ranges
from 1 to 10 (default 5). Agent scope searches that agent's conversation history; project scope
searches the active workspace's history. For questions about prior work, for example “What did I
use to deploy that app last week?”, use `recall` when the answer is not already in the supplied
context.

Conversation search uses OR/BM25 lexical matching: results may match any query term, and are
ranked for relevance. Paraphrases that share a keyword can therefore match even when they do not
share the full query wording. This is lexical search, not semantic search.

The old `session_search` scroll/browse interface for inspecting a session's message history has
been removed and has no replacement. The `[features] session_search` setting remains the durable
memory ingest/search kill switch; setting it to `"off"` disables those features.

### Automatic recall

Automatic recall is enabled by default. Before a meaningful turn, Lemon searches local
conversation history scoped to the session's agent/profile and attaches a **Relevant memory**
block to the user message after the cache breakpoint, never inside the static system prefix.
It includes the top three BM25-ranked conversations (up to five for embedders) and a bounded
USER.md excerpt from that session's assistant workspace. Any meaningful keyword may match.
The combined block is at most 2,048 bytes. Short queries, subagents, and sessions without an
agent id are skipped. Missing profile files never fall back to another profile's workspace.

Disable automatic recall in configuration:

```toml
[memory]
auto_recall = false
```

Automatic recall is also disabled when `[features] session_search = "off"`. The `recall` tool
additionally searches longer notes. Automatic recall performs no LLM pass or network request;
completed-run ingest does not perform post-run LLM fact extraction.

---

## Which persistence surface should agents use?

| Need | Use | Why |
|---|---|---|
| Save a stable profile fact or compact context | `remember` | Updates bounded assistant-home `USER.md` or `MEMORY.md` |
| Find relevant previous conversations and longer workspace notes | `recall` | Searches past conversation summaries and `memory/` Markdown notes |
| Capture a repeatable procedure, command sequence, integration, or checklist | `skill_manage` | Creates or updates an audited reusable skill |
| Track the current run's work queue | `todo` | Keeps transient progress for this session only |
| Inspect user-editable notes directly | `read` / `grep` | Opens files when direct inspection or editing is needed |

Use `remember` for concise facts, `recall` for finding prior work, `skill_manage` for repeatable
procedures, and `todo` for active work only.

Bare `USER.md`, `MEMORY.md`, and `memory/...` paths resolve to assistant home for file tools when
a session has `workspace_dir`; prefix with `./` to access a repo-local file with the same name.

---

## Memory management

### Retention and pruning

Memory documents older than the retention window are pruned automatically. Default retention is
**30 days**, with at most **500 documents per scope** (configurable through the
`LemonMemory.Store` application environment).

```elixir
config :lemon_memory, LemonMemory.Store,
  path: "~/.lemon/store",
  retention_ms: 30 * 24 * 60 * 60 * 1000,
  max_per_scope: 500
```

Manual maintenance commands:

```bash
mix lemon.memory stats
mix lemon.memory prune
mix lemon.memory erase --scope <session|agent|workspace> --key <value>
```

### Storage locations

| Scope | Database location |
|---|---|
| Default local provider | `~/.lemon/store/memory.sqlite3` |
| Custom store path | `<LEMON_STORE_PATH>/memory.sqlite3` |

### Privacy and secrets

Before a run is stored as a memory document, `LemonMemory.Safety` scans summaries for credential
key-value pairs, API key patterns, AWS access keys, PEM private-key headers, and JWT-like tokens.
The policy is **drop, not redact**: if a pattern matches, the entire run is not recorded.

Support bundles include `memory_diagnostics.json`. It reports provider count,
enabled provider count, provider ids, sources, scopes, timeout shape, and module
load state. It does not include memory document contents, raw provider config,
secret values, prompts, tool output, or provider error payloads.

### Feature flag

```toml
[features]
session_search = "default-on"
```

The `session_search` feature flag gates durable memory ingest and search, including automatic
recall. Set it to `"off"` or use `LEMON_FEATURE_SESSION_SEARCH=off` to disable them.

---

## Routing feedback and skill synthesis

Each completed run can also record routing feedback used by adaptive routing. When
`skill_synthesis_drafts` is enabled, Lemon can mine successful runs and generate draft skills.
See [`docs/user-guide/adaptive.md`](adaptive.md) and
[`docs/user-guide/skills.md`](skills.md#skill-drafts-synthesized-skills).
