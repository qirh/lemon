# LemonSimUi contributor guide

This Phoenix LiveView app launches/observes simulations, owns arena/hosted-room
lifecycle and renders boards. Game rules and world transitions stay in
`lemon_sim`. See [README](README.md).

## Runtime and rendering

- `SimManager` owns model-simulation runner PIDs, checkpoint/recovery, turn budgets
  and capacity. Hosted AI work belongs to `HostedGame.RoomServer` under the
  dedicated bounded AI task supervisor, not unbounded shared provider fanout.
- Use `LemonSim.Examples.terminal?/1` for completion, recovery, retention, league
  recording and UI replay state. Different domains have different terminal values.
- Offline strategies reuse the domain's keyless decider; never resolve models or
  credentials on that path. Resume reconstructs the same persisted start options.
- Boards are stateless function components. Read mixed-key checkpoint maps safely;
  do not convert external slot/product/supplier/agent IDs into atoms while rendering.
- New domains need registered kernel contracts, initialization, summary/detection,
  board/form wiring and appropriate human/per-seat controls. Match against the
  registered model provider list rather than input-driven atom creation.
- Werewolf metadata uses stable villager actor IDs, not generic player seat IDs.
- Broadcast pacing is UI-side dwell over exact snapshots, never changes to game
  rules. Arena attempt rotation includes failures for role balance and reliability;
  failed games do not contribute game outcome ratings.
- Show evidence reliability/interpretation, not clue prose alone. Vending traces
  expose visible tool/results and domain summaries, not provider-hidden thoughts.

## Hosted Werewolf privacy and durability

- Omniscient `WerewolfBoard` is for model admin/broadcast, never hosted humans.
  Player/public/host views come from role-safe engine projections. Hiding HTML
  after sending raw world state is not a privacy boundary.
- Hosts are role-blind. Secret actors, roles, actions, votes, meetings, pack chat,
  investigations, items, journals and thoughts never enter host/public projections
  or telemetry. Private rooms stay private after stop/completion.
- Credentials stay in signed cookies and `socket.private`, never assigns,
  persisted rooms, logs/crash formatting or exported replay. Preserve parameter
  filtering and disabled lifecycle logging on sensitive routes.
- Commands carry match/state epochs and server-built legal actions. Persist before
  acknowledgement; client idempotency IDs cannot collide with system timeout/AI IDs.
- Persisted deadlines are authoritative. Late human/AI decisions enter the timeout
  path rather than winning a mailbox race. World RNG is recorded/threaded, never
  process-global provider/decider randomness.
- Waiting/pre-start cancellation is sealed: no phase/day/actor/role leakage.
  Distinguish runtime failure from host stop; finished players see final roles.
- Restart child specs contain room IDs only and reload latest stored rows, not
  captured snapshots. Disabled hosted feature fails closed and recovers no timers
  or AI. It is a runtime kill switch, not only a hidden creation button.
- SQLite/Registry/PubSub ownership is single-node. Do not advertise horizontal
  replicas without distributed ownership, storage and PubSub.

## Access and operations

- Admin pages require `RequireAccessToken`; production requires a 32-byte token.
  Browser login is the CSRF-protected form with an expiring signed marker, never
  query credentials. Admin API is bearer-only.
- Lobby, leaderboards, watchers and health endpoints are deliberately public.
  Optional public Vending launch uses validated configured presets, not arbitrary
  model/job input. Hosted creation also requires its production creation token
  and HTTPS.
- Keep runner concurrency, stored-sim retention, league record limits, hosted
  TTL/AI limits and deployment configuration coherent. See deployment instructions
  in [README](README.md) rather than duplicating environment catalogs here.
- Suite discovery accepts configured suite roots, logs/skips malformed JSON and
  remains bounded. MemoryViewer render-time reads are bounded by file count/size;
  do not turn it into unrestricted filesystem browsing.
- Build assets with `mix sim_ui.assets.build` or
  `MIX_ENV=prod mix sim_ui.assets.deploy` for release assets.

## Verification

From the umbrella root: `mix test apps/lemon_sim_ui/test`.
ConnCase starts the endpoint with the real kernel store; clean created states.
Connected LiveView tests are necessary for PubSub behavior. Board tests use minimal
worlds; dashboard navigation uses `render_patch/2` when testing an existing mount.

Hosted browser QA:

```bash
HOSTED_WEREWOLF_SMOKE_URL=http://127.0.0.1:4090 npm --prefix apps/lemon_sim_ui/assets run smoke:hosted-werewolf
```

Check secret non-leakage, timeout/reconnect, replay/rematch, keyboard/reduced-motion
behavior and phone/tablet/desktop layouts with isolated player sessions.
