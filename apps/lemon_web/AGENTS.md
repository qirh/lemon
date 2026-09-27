# LemonWeb contributor guide

The assistant's Phoenix LiveView app provides chat/resume and authenticated
management. It calls shared runtime/lifecycle services, not a Web-only router,
store or settings implementation. See [README](README.md) and
[user guide](../../docs/user-guide/web.md).

## Chat lifecycle

- `/` creates an isolated tab session; `/sessions/:session_key` resumes a validated
  key. Derive agent identity from that key, not an independent client claim.
- Subscribe only on connected mount. Scope session events and approvals to the
  session key. Preserve streaming/final dedupe so completion does not append the
  same answer twice. Transcript streams are bounded.
- Setup readiness fails closed before uploads are consumed, messages appended or
  router calls made. Setup mutations belong to shared CLI/provider services.
- Private chat resume may use `SessionLifecycle.history(..., redact: false)` only
  in-process. Management inspection, download and JSON-RPC history stay redacted.
- Reconcile active run on mount and before active controls. Only exact `:none`
  means idle; errors/unexpected responses are unavailable. A later lookup failure
  preserves known running/stopping state and the draft rather than falsely idle.
- Follow-up/steer/redirect use existing queue modes. Bounded guidance is text-only.
  Successful guidance keeps the original active run as stop target, not the newly
  returned submission ID. Refusal preserves drafts and exposes fixed safe text.
- Uploads retain configured count/size limits; do not submit while uploading.
  Display filenames, not managed filesystem paths. Keep readiness checks before
  consuming upload entries.

## Authentication

- Optional chat auth and required management auth are different pipelines. No
  configured token may allow local chat, but required management returns 503.
  Never move management routes into the optional pipeline.
- Valid bearer/query auth establishes a hashed session marker. Query-token login
  redirects server-side to the same path with only the token removed before
  rendering; JavaScript cleanup is too late for history/referrer leakage.
- Production cookie signing needs the configured secret key base. Avoid putting
  credentials, private paths or raw service failures into assigns, logs or HTML.

## Management boundaries

- Sessions use `SessionLifecycle` for bounded/redacted list/history/export and
  lifecycle changes. Prune previews default archived-only/unpinned, show exact
  candidate keys, keep confirmation server-side and invalidate on mutations.
- Provider settings use `LemonAgent.ModelRuntime.ProviderConfiguration`. Preview
  precedes every write; apply checks a server-held revision, destructive actions
  require exact confirmation. Credentials use password fields and filtered logs;
  never retain secret values in socket drafts. Re-entry hashes bind preview.
- Profiles use `ProfileStore` and sanitize before assignment. IDs, names, model/
  node/status/availability and canonical keys are allowed; paths/system prompts
  are not. Clone/rename/delete recheck opaque revision; delete also confirms exact
  ID and inherits trash-first rollback. Refused/stale writes keep safe drafts.
- Memory uses `LemonMemory.Lifecycle`: only bounded Safety-redacted summaries,
  allowlisted provenance, counts and digests. No raw URLs/workspace keys/paths,
  provider details, secret names or store errors. Delete previews bind exact
  document ID and every persisted-field revision; transactional stale refusal
  mutates neither document nor FTS row.
- Blueprints use `LemonAutomation.Blueprint.Catalog`; Web never reads manifests,
  copies skills, resolves paths or writes cron stores. State admits bounded IDs,
  counts, parsed schedule/action fields, audit enums and digest, not free-form
  names, prompts, skill bodies, commands, env values or paths. Activation requires
  retyping the fresh exact digest; drift clears preview, replay stays unchanged.
- All service projections are allowlists, not raw maps with a few keys removed.
  Redaction is additional defense, not a substitute for narrow projections.

## Verification

From the umbrella root: `mix test apps/lemon_web/test`.
Use connected LiveView tests for bus events, `file_input`/`render_upload` for
uploads and explicit session routes for stable keys. Verify initial and live
unavailable states, stale preview refusal, private-chat versus management
redaction, query-token redirect and required auth without credentials.
For UI changes, exercise actual browser interaction and responsive rendering;
static disconnected HTML alone cannot prove subscriptions or upload behavior.
