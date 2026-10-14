# LemonSim contributor guide

LemonSim is a tool-first, fresh-context-per-decision simulation harness. Kernel
owns state/event flow; LLM modules own model/tool loops; Bench owns artifacts,
scorecards and replay; examples own domain rules. The Phoenix UI is a consumer.
See [README](README.md) and [benchmark guarantees](../../docs/benchmarks/platform.md).

## Determinism and contracts

- Keep game rules, turn ordering, chance and scoring out of generic kernel code.
  `ActionSpace` exposes candidate tools; the updater authoritatively revalidates
  actor, phase, target, ownership and bounded payloads. Prompt text is not security.
- Updaters/world bootstrap must not touch process-global `:rand`, `Enum.random`,
  shuffle or random selection. Record the seed and thread `Kernel.Rng` state
  through every world mutation. Missing RNG is an error, not a random fallback.
- Poker derives each hand shuffle from its recorded base seed/hand number; a hand
  without seed or explicit deck is rejected. Other deciders' randomness must not
  alter authoritative world transitions or replay hashes.
- Each facade declares `terminal_statuses/0` and registers in `LemonSim.Examples`.
  Cross-domain consumers use `Examples.terminal?/1`, never a literal game-over
  status. State version tracks all mutations, not only appended events.
- Normalize input keys at the boundary; use `MapHelpers.get_key/2` when consuming
  mixed JSON/internal maps, then atom-keyed reducers internally. Never create
  atoms from provider, product, actor or external identifiers.

## Runner and artifacts

- Memory is an explicitly supplied optional tool bundle, not kernel policy.
- Use `LemonSim.LLM` for reusable provider/tool-loop behavior. Tool-first deciders
  reject plain-text decisions and duplicate normalized tool names. Keep outer
  driver turn budgets separate from inner model/tool retry budgets.
- Decision adapters translate shape where needed. Preserve support-tool events
  from executed calls before terminal decisions; VendingBench uses the generic
  single-terminal/executed-call policy rather than its own copied loop.
- Scenario facades delegate to focused domain modules. Common game-log IO belongs
  in `Examples.GameLog`; common CLI parsing/startup belongs in ordinary functions
  in `Mix.Tasks.Lemon.Sim.Common`, not a macro or repeated task implementation.
- Resolve model/provider/base URL/credentials through `LLM.GameHelpers.Config` and
  registered provider names. OAuth secret payloads must become concrete runtime
  credentials before reaching providers; the Gemini CLI and AI Studio providers
  use different authentication.
- Replay verification requires manifest and hashes. Replay-capable domains record
  every updater input batch and setup config; rebuild from seed and compare events
  and final world. Use `Replay`/`Recorder`; post-step callbacks stay notify-only.
- Write artifacts atomically through `Bench.Artifacts.AtomicFile`. VendingBench
  artifact registry mutation is serialized through its owner.
- Vending supplier tools issue commands; updater quotes costs/delivery and emits
  facts. Never trust model-provided price, affordability or substitution claims.

## Werewolf information boundaries

- Player projection is authenticated/role-safe; public projection is inference-
  safe; replay/video rendering is omniscient. Never substitute one for another.
  Dead players lose future private information. Completed games reveal roles.
- Hosted event visibility is allowlist-based. New event kinds are private until
  explicitly classified. Secret-phase active actors are visible only to entitled
  actors/pack/current meeting, not hosts/spectators/dead players.
- Server supplies authenticated actor and calls available/executable legal action
  APIs, not caller-provided raw events. Rejected actions cannot consume inventory
  or write another player's journal.
- Stable generated villager IDs are engine identities; hosted display names are
  presentation metadata. Versioned story/classic presets come from `RulesConfig`,
  not UI-specific updater branches.
- Public discussion has a hard turn cap. Accusations may advance a future speaker
  for defense but cannot rewind speakers or create a two-player bounce loop.
- Five-player games use one wolf, one seer, one doctor and two villagers. Seers
  investigate on Night 1; role counts/reveals are explicit, and backstory flavor
  is not evidence. Noisy story evidence must retain reliability/source labels and
  cannot leak doctor/seer targets or compound same-night positive sightings.
- Mutual night meeting preferences resolve before directed requests. Doctors
  cannot protect the same target on consecutive nights.
- Arena roles are fixed by sorted seat while model assignments rotate each
  attempt, including failures. Failed attempts affect reliability, not game
  ratings. Compare role coverage/adjusted outcomes before treating ratings as
  established. Objective role metrics accompany team wins.
- AI-only failure fallback is deterministic/legal after bounded retry. Preserve
  output/private-thought limits and provider pacing in the LLM layer, not kernel.

## Verification

From the umbrella root: `mix test apps/lemon_sim/test`.
Test complete seeded games with unrelated process RNG activity between steps,
replay hashes, illegal transitions and private projections. Poker boundaries
include side pots, heads-up blinds/button, multi-hand progression and auto-fold.
A keyless operator walkthrough is in the [benchmark quickstart](../../docs/benchmarks/quickstart.md).
