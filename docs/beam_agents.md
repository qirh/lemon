# BEAM Agent Architecture and Invariants

Lemon uses OTP processes for agent/session ownership and supervised tasks for
model/tool work. This page records lifecycle guarantees and limits; the
[architecture overview](architecture/overview.md) explains app boundaries,
[telemetry reference](telemetry.md) owns event names, and the
[agent guide](../apps/lemon_agent/AGENTS.md) owns contributor gotchas.

## Supervision and isolation

`LemonAgent.Supervisor` owns the abort-signal table owner, agent registry,
subagent supervisor, loop task supervisor and tool task supervisor.
`CodingAgent` separately owns native sessions, persistence and coordination.
Supervision does not mean replaying a side effect: crashed tool tasks report
errors and are not automatically restarted/retried.

- Agent loops run under `LemonAgent.LoopTaskSupervisor`.
- Tools run under `LemonAgent.ToolTaskSupervisor`; monitors connect crashes to
  the corresponding tool result without crashing unrelated sessions.
- Subagents are discoverable and supervised. Coordinators track their children
  and cancel outstanding work on timeout or parent termination.
- Abort is cooperative and best-effort for external work. The loop checks the
  abort signal at safe points, and tools must honor it. A task can remain active
  briefly during scheduler/NIF/external-process cleanup.
- Context truncation preserves chronological history and tool-call/result units.
  Session persistence and prompt projection are separate: a model-facing safety
  transform must not silently rewrite the user's stored transcript.

## Event flow

```text
provider stream → agent loop → coding session → runtime bus
                     │              │              │
                 tool tasks     subscribers     router/client
```

The agent emits turn/message/tool events and a terminal result. The terminal
`agent_end` carries newly produced messages, not the entire conversation.
Session notifications use `{:session_event, session_id, event}`.

`CodingAgent.Session.Notifier` owns subscriber bookkeeping. It has two deliberately
different paths:

| Subscription | Delivery | Limit |
| --- | --- | --- |
| Direct | Fire-and-forget `send/2` | No mailbox backpressure; trusted consumers must keep up |
| EventStream | Bounded stream with configured drop/timeout policy | Queue bounds do not guarantee lossless replay |

Prefer the stream path for consumers that may fall behind. Stream owner death
cancels its attached task. Subscriber monitoring removes dead direct listeners
and cancels/demonitors owned streams. Every terminal/error path must release
subscriptions and resources without inventing a successful result.

## Failure and mutation semantics

A tool failure is a result, not a reason to rerun all other tools in the batch.
Unexpected owner-process bugs should reach OTP supervision rather than return
fabricated empty/unchanged state. Boundary code distinguishes definite rejection
from an unknown mutation outcome: a timeout or exit can happen after acceptance.
Retain fixed run identity and reconcile unknown outcomes; do not duplicate work.

Session direct fanout remains fire-and-forget and events are not batched. There
is no universal lossless replay protocol for transient subscribers. Supervision
recovers a process, not arbitrary in-flight remote effects. Durable lifecycle
stores and explicit idempotency/lease contracts provide those guarantees where
implemented.

## Verification

Use [the canonical test lanes](testing.md) from the umbrella root. For runtime
changes exercise normal completion, tool crash, abort during tools, owner death,
slow/dead subscribers, restart and cross-session isolation. Assert observable
results and terminal cleanup; do not pin copied supervisor trees or module
existence. Live provider tests are separate opt-in checks, not implied by unit
coverage.
