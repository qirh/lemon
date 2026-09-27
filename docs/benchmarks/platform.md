# Benchmark Platform Guarantees

LemonSim benchmarks are designed to leave auditable artifacts, not just printed
scores. VendingBench is the richest bundle today, and the shared verifier also
supports registered scorecard scenarios across LemonSim.

## Artifact Bundle Contract

A VendingBench run emits:

- `final_world.json`
- `events.jsonl`
- `actions.jsonl`
- `commands.jsonl`
- `facts.jsonl`
- `tool_calls.jsonl`
- `supplier_messages.json`
- `worker_history.json`
- `operator_transcript.json`
- `reminders.json`
- `scorecard.json`
- `usage.json`
- `config.json`
- `inputs.jsonl`
- `manifest.json`
- `hashes.json`
- `prompts/operator.system.md`
- `prompts/operator.initial.md`
- `report.md`
- `replay.json`
- `replay.html`

`manifest.json` uses `lemon_sim.run.v1`. It records the simulation id, version,
seed, ruleset hash, model descriptor, runtime metadata, and integrity hashes for
events, scorecard, usage, prompts, and tool schema. VendingBench computes its
ruleset hash from the world, updater, action space, supplier, arena, and demand
model source files.

`hashes.json` uses `lemon_sim.hashes.v1` and stores the file hashes that make the
bundle tamper-evident.

`inputs.jsonl` records every batch of input events the updater folded, one
`{"events": [...]}` object per ingest, with the exact timestamps and metadata
that were applied. Together with the seed and setup options in `config.json` it
makes the run replayable. VendingBench, Werewolf, and Poker bundles all carry
it; Werewolf and Poker bundles come from `mix lemon.sim.werewolf` /
`mix lemon.sim.poker` with `--artifact-dir` (keyless with
`--offline-strategy heuristic`).

## Verification

```bash
LEMON_STORE_PATH=/tmp/lemon-docs-store mix lemon.sim.verify /tmp/lemon-vb-ci-baseline-docs
```

The verifier checks:

- `manifest.json` and `hashes.json` exist (there is no unhashed fallback)
- manifest and hash schema
- required files for the scenario
- manifest integrity fields against `hashes.json`
- every hashed file's current SHA-256
- for VendingBench, Werewolf, and Poker: rebuilds the initial state from
  `config.json`, re-folds `inputs.jsonl` through the scenario updater, and
  requires the appended events to reproduce `events.jsonl` line for line and
  the final world to equal `final_world.json`
- registered scorecard recomputation from `final_world.json`

A tampered `scorecard.json`, `events.jsonl`, `usage.json`, or other hashed file
fails verification; because hashes are self-attested, the replay step is what
catches a bundle whose files were edited and re-hashed consistently.
`mix lemon.sim.score` runs the same verification before printing the
scorecard, and suite recompute excludes every run that fails it.

## Suites And Leaderboards

`mix lemon.sim.suite` writes:

- `suite.json`
- `leaderboard.md`
- `runs/<competitor>/<seed>/...` artifact bundles

`suite.json` uses `lemon_sim.suite.v1` and contains:

- `spec`: scenario, preset, seeds, and competitors
- `primary_metric`: metric key, display name, and direction
- `runs`: one result per competitor and seed
- `rankings`: verified aggregate rows with token and cost totals
- `failures`: runs that were reported but excluded from rankings

```bash
LEMON_STORE_PATH=/tmp/lemon-docs-store mix lemon.sim.leaderboard /tmp/lemon-vb-suite-docs --recompute
```

`--recompute` re-verifies existing bundles and rewrites the leaderboard. Failed
or tampered runs remain visible in `suite.json` and `leaderboard.md`, but they
are excluded from rankings. The public LiveView leaderboard renders these under
`Reported Not Ranked`.

## Usage And Cost Accounting

Every run writes `usage.json` with schema `lemon_sim.usage.v1`, total input,
output, cache-read, cache-write tokens, decision count, and per-actor rows.

Cost is computed from the `LemonAi.Models` pricing metadata. If pricing is unknown,
`cost_usd` is `null` rather than `0`; CLI output prints unknown cost and the
LiveView UI renders it as an unknown value. Suite aggregation preserves unknown
cost instead of silently treating it as free.

## Ratings

`mix lemon.sim.ratings` consumes one or more `suite.json` files and writes:

- `ratings.json`
- `ratings.md`

Ratings use a deterministic Bradley-Terry fit over pairwise seed-level
comparisons. The implementation adds one pseudo draw per active pair so sparse
suite sets do not produce unstable infinite ratings.

## Replay And Public UI

Each VendingBench run includes `replay.html`, a static browser replay bundle
that can be opened directly from the artifact directory.

The LiveView app also exposes:

- `/` for the public LemonSim lobby
- `/watch/:sim_id` for public read-only spectator views
- `/leaderboards` for verified suite leaderboards
- `/admin` and `/admin/sims/:sim_id` for private admin surfaces when an access token is configured

The spectator route supports VendingBench, Werewolf, and TCG Shop. For
artifact-backed VendingBench runs, it can refresh from `final_world.json` and
render `usage.json` totals.

