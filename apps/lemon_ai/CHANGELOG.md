# Changelog

All notable changes to `lemon_ai` are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
releases follow [Semantic Versioning](https://semver.org/) from `0.1.0` onward.

## [Unreleased]

First release as a standalone package. `lemon_ai` was extracted from the Lemon
umbrella, where it lives as the `:lemon_ai` application; the OTP application name and
every `LemonAi.*` module name are unchanged, so only the `mix.exs` line differs from
what in-repo code has been using.

### Fixed

- Installable from Hex. The `0.1.0` release's `mix.exs` began with
  `Code.require_file("../../hex_package.exs", __DIR__)`, a file that was not in
  the package, so it failed to load in every consumer project; `0.1.0` is
  retired. The shipped `mix.exs` is now self-contained.

### Added

- `LemonAi.stream/3` and `LemonAi.complete/3` — one API over eighteen provider modules
  (Anthropic, OpenAI completions and responses, Azure OpenAI, Google Gemini and
  Vertex, AWS Bedrock, Mistral, Groq, Fireworks, OpenRouter, Qwen, MiniMax,
  GitHub Copilot, and the Codex/Gemini CLI bridges), with streaming events
  normalized to the same shapes regardless of provider.
- `LemonAi.ProviderRegistry` for registering and resolving providers at runtime, so
  a host application can add a provider without a fork.
- Reliability layer around every call: `LemonAi.RateLimiter` (per-provider token and
  request budgets), `LemonAi.CircuitBreaker` (opens on repeated provider failure and
  half-opens on a timer), and in-provider retry for 429/529/5xx and transport errors
  (Anthropic, OpenAI Chat Completions, Responses and Codex): 4 attempts, capped
  exponential backoff with jitter from ~1s, honoring `retry-after`/`retry-after-ms`
  and Anthropic rate-limit reset headers. Server waits beyond the in-provider cap are
  returned to the caller as `AssistantMessage.retry_after_ms`
  (`config :lemon_ai, :provider_retry`).
- `LemonAi.CallDispatcher` queues callers FIFO when a provider is at its in-flight cap
  and only returns `{:error, :max_concurrency}` after a bounded wait
  (`queue_timeout_ms`, default 120s; `0` fails fast).
- `LemonAi.CompactingClient` and `LemonAi.ContextCompactor` — context-window management
  that truncates older history (the `:summarization` strategy currently falls back to
  truncation) rather than failing the call.
- `LemonAi.Tokens` and `LemonAi.Text` for token accounting and text extraction, and
  `LemonAi.calculate_cost/2` for per-call cost from the model's price table.
- `LemonAi.Models` catalogue plus `LemonAi.ModelCache`, covering model IDs, context
  windows, capabilities and pricing — including Claude Opus 5.5 / Opus 5 / Opus 4.8 /
  Opus 4.7 / Sonnet 5 / Fable 5.x and OpenAI GPT-5.5 / GPT-5.5 Pro / GPT-6 Astra, Sol
  and Luna. Explicit `adaptive_thinking` and `reasoning_efforts` capability flags on
  each model drive Anthropic adaptive thinking and reasoning-effort clamping
  (`LemonAi.Models.reasoning_effort_for/2`) instead of model-id substring checks.
- Anthropic tool results carry image blocks inside `tool_result.content` for vision
  models instead of dropping them.
- OpenAI Chat Completions and AWS Bedrock responses report cost from usage and catalog
  pricing instead of $0.
- `LemonAi.Env` declares the 28 environment variables this package reads — provider
  credentials, endpoint overrides and client tuning — each with a type, default,
  documentation string and a secret flag. It is self-describing on its own and
  is picked up automatically by `LemonCore.Env` when both packages are present.
- `mix lemon.models` lists the catalogue from the command line.

### Changed

- The 25 provider-module model catalogs moved from Elixir struct literals to 26
  JSON resources under `priv/models/`, loaded and embedded at compile time by
  `LemonAi.Models.Catalog`. Google uses a base file plus Antigravity extras;
  the `:google_antigravity` registry is derived from both, while
  `:"openai-codex"` derives from the direct OpenAI catalog plus OAuth-only IDs.
  Existing provider module names and `models/0` return values are unchanged.
  Catalog files are external compiler resources; malformed top-level data and
  entries fail with source/model context, while field types, token-size ranges,
  costs, and compatibility overrides are validated. API, provider, input, and
  compatibility keys normalize through fixed atom allowlists.

### Notes

- `lemon_ai` depends on no other Lemon package. It is usable on its own in any
  Elixir project; `lemon_agent` and the rest of the platform build on top of it.
