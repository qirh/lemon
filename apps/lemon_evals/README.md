# LemonEvals

Deterministic and opt-in live evaluation harnesses for the Lemon coding-agent stack.

## Responsibilities

- `LemonEvals.Harness` runs deterministic tool, prompt, memory, skill, delegation, and coding-repair contracts against the real coding-agent surface.
- `mix lemon.eval` runs the harness from the umbrella root with the existing task name.
- Live-model checks remain opt-in through `--live-model` and the `LEMON_EVAL_*` / `INTEGRATION_*` credential environment variables.

`lemon_evals` is a dev/CI rig and is not included in runtime releases.

## Commands

```bash
mix lemon.eval --iterations 20
mix test apps/lemon_evals/test
cd apps/lemon_evals && mix test --cover
```

## Live agentic coding benchmark

This separate, paid-model lane measures actual coding outcomes through the
production `lemon -p --output json` client. It is never part of the fast lane:

```bash
LEMON_CONTROL_PLANE_PORT=4210 mix lemon.eval.coding \
  --model openai-codex:gpt-5.5 \
  --output /tmp/lemon-coding-benchmark.json
```

Configure credentials normally and reuse a healthy daemon, or let the standard
launcher start it. The Mix task itself does not boot another router. `--lemon`
selects an installed launcher; `--timeout` bounds each CLI invocation (default
660 seconds, slightly longer than the client's ten-minute run deadline).

Eight disposable git repositories exercise bug repair, multi-file refactoring,
feature implementation with tests, reading and answering, bash debugging,
targeted editing of a 12,000-entry file, repository-wide search/migration, and
recovery after a failing tool. A verifier outside each repository checks real
behavior, and applicable tasks must also pass their repository's unittest suite.
Runs explicitly allow requested tool approvals; use an isolated runtime and do
not point this benchmark at a sensitive workspace.

The command writes a JSON report and adjacent Markdown table containing task
pass/fail, completed assistant turns, tokens, wall time, and failed tool calls.
Missing runtime counters are `null`/`n/a`, never estimated from tool-call count.
All tasks run even when one fails; any failure makes the command exit nonzero.
The report contains no raw prompts, model output, credentials, or workspace paths.
It measures one trial per task, not statistically significant model rankings.

For local failure diagnosis only, `--failure-dir /tmp/lemon-bench-failures`
retains private failure bundles with the task repo, verifier, and CLI/test
stdout/stderr. These may contain sensitive model output; do not commit or upload
them. Without that explicit flag, every temporary repository is removed.


## Retained evaluation reports

Write a machine-readable artifact separately from diagnostic console output:

```bash
mix lemon.eval --iterations 20 \
  --output /tmp/lemon-evals/contracts.json \
  --revision "$(git rev-parse HEAD)"
```

`--output` writes schema version 1 before the task raises for failed checks, so
an ordinary evaluation failure still leaves a report. An application startup
failure, killed process, or harness exception before a report is produced does
not manufacture a success artifact. File-write failures also fail the command.
A sibling temporary file is renamed into place after writing; this is not a
power-loss durability guarantee.

The artifact contains the suite name, recording time, explicit commit SHA,
Elixir/OTP versions, configured iterations/live-model/timeout settings, total
suite duration, recomputed pass/fail counts, and each check's stable name/status.
Raw `details`, prompts, transcripts, tool arguments, errors, provider URLs,
workspace paths, and credentials are excluded. Check names are code-authored,
non-sensitive identifiers, not user-provided labels. No environment snapshot or
implicit Git command is used. Omitted `--revision` produces JSON null.

The existing `--json` flag still prints the detailed legacy report to stdout.
It is not the redacted artifact and its diagnostic details may be sensitive.
Only upload the `--output` file when sharing summary results.

`--iterations` controls existing statistical checks. It does **not** repeat
every live-model check as an independent trial. The report records contract
results, not benchmark task-success rates, dollar costs, or a Hermes comparison.
A production-path outcome suite and repeated paired trials remain separate work.

The manually dispatched Live Eval workflow retains this allowlisted report for
14 days with `if: always()`, including when checks fail. It warns when startup
or another early failure prevented artifact creation. This does not add a
schedule, an automatic paid-model run, or raw-trace uploading.
