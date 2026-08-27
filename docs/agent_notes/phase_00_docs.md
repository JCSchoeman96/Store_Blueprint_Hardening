# Phase 00 Docs Notes

## Links Consulted (Hexdocs / web search)
- https://hexdocs.pm/phoenix/Mix.Tasks.Phx.New.html
- https://hexdocs.pm/bandit/Bandit.PhoenixAdapter.html
- https://hexdocs.pm/ash/
- https://hexdocs.pm/ash_postgres/
- https://hexdocs.pm/ash_authentication_phoenix/liveview.html
- https://hexdocs.pm/petal_components/readme.html
- https://hexdocs.pm/oban/
- https://hexdocs.pm/req/Req.html
- https://hexdocs.pm/ash/Ash.Notifier.html
- https://hexdocs.pm/credo/
- https://hexdocs.pm/ex_doc/readme.html
- https://hexdocs.pm/stream_data/StreamData.html
- https://hexdocs.pm/dialyxir/readme.html
- https://hex.pm/packages/ash
- https://hex.pm/packages/ash_postgres
- https://hex.pm/packages/ash_authentication
- https://hex.pm/packages/ash_authentication_phoenix
- https://hex.pm/packages/petal_components
- https://hex.pm/packages/oban
- https://hex.pm/packages/req
- https://hex.pm/packages/credo
- https://hex.pm/packages/ex_doc
- https://hex.pm/packages/stream_data
- https://hex.pm/packages/dialyxir

## What the Docs Recommend Now
- Use `mix phx.new` with `--live` and configure Bandit as the endpoint adapter.
- Keep web concerns in `StoreWeb` and domain logic in Ash resources/actions.
- Use Ash 3.x + AshPostgres with UUID primary keys for resources.
- In transaction-bound Ash actions, use `return_notifications?: true` and dispatch with `Ash.Notifier.notify/1` only after commit.
- Prefer Oban workers for retryable/side-effectful workflows.
- Use a single HTTP wrapper around Req for outbound calls.
- Use Credo, docs, and test gates in CI for mechanical enforcement.

## What We Will Implement (Decisions)
- Generate `Store` / `:store` Phoenix LiveView app in this repo root.
- Keep single-tenant semantics only; no tenant routing, no `tenant_id`.
- Add dependencies from blueprint: Ash stack, Petal Components, Oban, Req, Credo, ExDoc, StreamData, Dialyxir.
- Add `mix check` and `mix check.ci` aliases.
- Use `STORE_DB_PORT` with default `5433` in `dev`/`test` to match local Docker Postgres setup.
- Add Phase 00 enforcement gates:
  - no Repo calls in `lib/store_web/**`
  - moduledoc required (`@moduledoc` or `@moduledoc false`)
  - required docs-first phase notes present
- Missed-notification policy:
  - transactional action paths must collect and deliver notifications post-commit
  - test env sets `config :ash, :missed_notifications, :raise` so drops fail CI
  - post-commit notify failures are logged (no worker retry loop on already-committed writes)

## Version Pins / Breaking Changes
- Requested constraint families:
  - `ash ~> 3.0`, `ash_postgres ~> 2.0`, `ash_authentication ~> 4.0`
  - `ash_authentication_phoenix ~> 2.0`, `petal_components ~> 3.0`
  - `oban ~> 2.0`, `req ~> 0.5`, `credo ~> 1.7`, `ex_doc ~> 0.37`
  - `stream_data ~> 1.1`, `dialyxir ~> 1.4`
- Resolved versions in `mix.lock`:
  - `ash 3.17.0`
  - `ash_postgres 2.6.32`
  - `ash_authentication 4.13.7`
  - `ash_authentication_phoenix 2.15.0`
  - `petal_components 3.0.1`
  - `oban 2.20.3`
  - `req 0.5.17`
  - `credo 1.7.16`
  - `ex_doc 0.40.1`
  - `stream_data 1.2.0`
  - `dialyxir 1.4.7`
- Breaking change watch:
  - Ash 3.x APIs differ from Ash 2.x; avoid older DSL/examples.
  - AshAuthentication/AshAuthenticationPhoenix options can shift by minor versions; verify docs on each bump.
  - `stream_data` must not be test-only in this stack because Ash depends on it at runtime.
  - `mix check` in `:test` requires `ex_doc` available in `:test` for the `mix docs` gate.

## Performance & Scaling Review
- Hot paths:
  - Request path stays thin in web; no direct Repo calls in web.
  - Side effects deferred to workers to avoid slow request latency.
- Warm paths:
  - CI gates (`mix check`) run per PR; optimized with simple file scans.
  - Docs and credo checks are deterministic and cached by CI where available.
  - Post-commit notification delivery adds negligible overhead versus write latency and prevents ghost-state risk.
- Cold paths:
  - Docs generation and dialyzer are slower, mainly CI/nightly concerns.
- Indexes:
  - No new Phase 00 data indexes yet; uniqueness/index strategy starts in later phases.
- TTL:
  - No TTL behavior in Phase 00.
- Invalidation:
  - No cache invalidation in Phase 00.
- PubSub:
  - Phoenix PubSub baseline only; no domain PubSub contracts yet.

## Dialyzer Cold Path (Update)
- `mix check.types` is a separate cold-path check and is not part of `mix check`.
- `mix check.types` runs in `MIX_ENV=test` via Mix `preferred_envs` mapping, matching main gate compilation surface.
- Local bootstrap and usage:
  - `MIX_ENV=test mix dialyzer --plt` (one-time/bootstrap when PLT cache is cold)
  - `mix check.types` (normal local run)
- CI policy:
  - Dialyzer runs advisory first (`--ignore-exit-status`).
  - Move to required after baseline cleanup by removing `--ignore-exit-status`.

## S0-05 Test Strategy (2026-08-27)

### Links Consulted
- [`docs/hardening/00_current_state.md`](../hardening/00_current_state.md)
- [`docs/hardening/01_domain_map.md`](../hardening/01_domain_map.md)
- [`docs/hardening/02_lifecycle_registry.md`](../hardening/02_lifecycle_registry.md)
- [`docs/hardening/02_1_lifecycle_registry_gaps.md`](../hardening/02_1_lifecycle_registry_gaps.md)
- [`docs/hardening/03_invariant_registry.md`](../hardening/03_invariant_registry.md)
- [`docs/hardening/04_dependency_map.md`](../hardening/04_dependency_map.md)
- [`mix.exs`](../../mix.exs), [`config/test.exs`](../../config/test.exs), [`test/test_helper.exs`](../../test/test_helper.exs), and [`test/support`](../../test/support)
- [`test`](../../test), [`.github/workflows/ci.yml`](../../.github/workflows/ci.yml), [`.github/workflows/nightly-hardening.yml`](../../.github/workflows/nightly-hardening.yml)
- [`docs/governance`](../governance), and [`priv/repo/performance_smoke_test.exs`](../../priv/repo/performance_smoke_test.exs)

### Decisions and Pins
- This phase records current test evidence and gaps only. It does not add tests or alter test/application behaviour.
- Qualitative confidence is used because no line-coverage or branch-coverage reporting is configured in the inspected Mix aliases or workflows.
- The application is single-tenant. Ownership and privilege tests are in scope; tenant-isolation coverage is not a current implementation guarantee.
- Provider calls remain stubbed in the current test harness. Live provider integration is recorded as a gap rather than inferred from adapter tests.
- Postgres remains the source of truth for financial and lifecycle state. Cache and queue tests are treated as supporting-path evidence.

### Plan
- Inventory domain, lifecycle, invariant, worker, security, performance, and CI tests.
- Map current harness configuration and workflow execution, then separate current coverage from future extraction gates.
- Verify documentation links and wording, run repository checks, and confirm no application or test files changed.

### Performance & Scaling Review
- Hot paths reviewed: checkout, payment confirmation, entitlement lookup, and subscription renewal.
- Current evidence includes the standalone performance smoke harness, query/lock/pool telemetry, Cachex/ETS/Redis tests, and bounded subscription/entitlement query tests.
- Missing evidence includes generic webhook/renewal/entitlement soak, multi-node cache/PubSub behaviour, production-like Oban execution, and live-provider load.
