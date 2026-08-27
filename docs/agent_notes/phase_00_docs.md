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

## S0-06 Performance Data Map (2026-08-27)

### Links Consulted
- [`docs/hardening/06_performance_data_map.md`](../hardening/06_performance_data_map.md)
- [`docs/governance/performance_scaling.md`](../governance/performance_scaling.md)
- [`docs/phases/phase_29_performance_architecture_optimizations.md`](../phases/phase_29_performance_architecture_optimizations.md)
- [`priv/repo/migrations`](../../priv/repo/migrations)
- [`lib/store/catalog`](../../lib/store/catalog), [`lib/store/carts`](../../lib/store/carts), and [`lib/store/checkout`](../../lib/store/checkout)
- [`lib/store/orders`](../../lib/store/orders), [`lib/store/payments`](../../lib/store/payments), [`lib/store/subscriptions`](../../lib/store/subscriptions), and [`lib/store/entitlements`](../../lib/store/entitlements)
- [`lib/store/workers`](../../lib/store/workers) and [`config/config.exs`](../../config/config.exs)

### Decisions and Pins
- The implementation and migrations are the source of truth; governance guidance is recorded as comparison context only.
- Postgres remains authoritative for orders, payment application, subscriptions, entitlements, and inventory reservations. Catalog, stock, and entitlement caches are derived projections or hints.
- Hot/warm/cold classification is based on access pressure and correctness sensitivity, not data retention.
- Candidate query/index gaps and cache opportunities are observations for measurement, not approved changes.
- S0-06 makes no code, query, schema, cache, Redis, or infrastructure change.

### Plan
- Map table ownership, relationships, constraints, indexes, and query-critical columns from migrations.
- Trace checkout, payment webhook, subscription renewal, entitlement, inventory, and worker paths through the domain facades.
- Record current cache TTLs/invalidation, concurrency boundaries, queue limits, retry/idempotency anchors, and evidence gaps.
- Verify the document structure, links, diff scope, and repository gates before updating PR #1.

### Performance & Scaling Review
- Hot paths: catalog browse/detail, active carts, checkout finalization, payment webhooks, entitlement checks, inventory reservation, and due renewal rows.
- Warm/cold paths: recent customer/order/subscription views, settled payment evidence, renewal history, outboxes, fulfillment history, provider events, and audit/metric records.
- Query/N+1 risks: admin catalog filtering in Elixir, per-item cart merge work, per-grant entitlement revocation, branch-dependent payment lookups, and per-subscription renewal work.
- Index evidence: Phase 29 product/order keyset indexes, inventory active-expiry indexes, payment/provider idempotency constraints, entitlement user/status indexes, and Phase 27 partial renewal tick indexes were recorded; candidate gaps require `EXPLAIN` and cardinality data.
- Cache review: existing Cachex/ETS/Redis paths were documented with TTL, invalidation, per-node/shared behavior, and stampede risks. No cache tier was added.
- Oban review: five-minute renewal fan-out, one-minute inventory/provider sweeps, bounded batches, worker uniqueness where present, retry counts, and webhook/refund replay protection were documented.
- Telemetry gaps: no production p95/p99, lock-wait, cache-hit, multi-node invalidation, queue-lag, or 100k-concurrency result was inferred from static inspection.

## S0-07 Security Model (2026-08-27)

### Links Consulted
- [`docs/hardening/07_security_model.md`](../hardening/07_security_model.md)
- [`docs/hardening/00_current_state.md`](../hardening/00_current_state.md), [`docs/hardening/02_1_lifecycle_registry_gaps.md`](../hardening/02_1_lifecycle_registry_gaps.md), and [`docs/hardening/05_test_strategy.md`](../hardening/05_test_strategy.md)
- [`docs/phases/phase_02_auth.md`](../phases/phase_02_auth.md), [`docs/phases/phase_03_admin.md`](../phases/phase_03_admin.md), and [`docs/phases/phase_06_policy_matrix.md`](../phases/phase_06_policy_matrix.md)
- [`docs/governance/policy_matrix.md`](../governance/policy_matrix.md), [`docs/governance/payment_provider_contract.md`](../governance/payment_provider_contract.md), [`docs/governance/payment_provider_capabilities.md`](../governance/payment_provider_capabilities.md), [`docs/governance/idempotency.md`](../governance/idempotency.md), [`docs/governance/refund_semantics.md`](../governance/refund_semantics.md), [`docs/governance/step_up.md`](../governance/step_up.md), and [`docs/governance/audit_and_pii.md`](../governance/audit_and_pii.md)
- Authentication, policy, facade, provider, webhook, worker, cache, and migration sources under [`lib`](../../lib) and [`priv/repo/migrations`](../../priv/repo/migrations), plus targeted security and performance tests under [`test`](../../test)

### Decisions and Pins
- This is architecture discovery only. No resource policy, authorization behavior, authentication flow, tenancy model, or application code was changed.
- Implementation and migrations are current-state evidence. Governance and phase documents are comparison context unless the implementation confirms the behavior.
- Authentication is AshAuthentication with password and Google identity strategies, stored signed tokens, browser sessions, bearer API actors, and explicit optional/required/admin route boundaries.
- Authorization is resource-specific. It combines Ash policies, database-backed role assignments, owner filters, parent-resource preparations, facade checks, and trusted system contexts.
- The application is single-tenant. No tenant identifier, tenant routing, tenant-qualified cache key, or PostgreSQL RLS policy was found.
- Stripe is the implemented payment provider boundary. Other provider adapters are not evidence of production-ready signature verification, normalization, or recurring operations.
- Guest cart and checkout tokens are bearer capabilities. Payment proof comes from verified provider evidence and worker reconciliation, not customer return parameters.

### Plan
- Map authentication/session/token boundaries and the role/policy locations for catalog, orders, payments, subscriptions, entitlements, and inventory.
- Trace user ownership from cart through order, payment, subscription, entitlement, and digital download grant, including guest checkout paths.
- Trace payment webhook verification, receipt deduplication, worker replay handling, refund checks, and subscription renewal authority.
- Inspect database foreign keys, unique/check constraints, cache keys, rate limits, queue uniqueness, and evidence-retention behavior.
- Record extraction readiness as READY, PARTIAL, or NOT READY without implementing a hardening change.

### Performance & Scaling Review
- Hot paths reviewed: catalog and availability reads, cart/checkout ownership checks, webhook verify-persist-enqueue, payment/refund reconciliation, entitlement lookup, digital URL issuance, inventory reservation, and subscription renewal.
- Current cache interactions: public catalog projections use catalog/availability caches; effective entitlement sets use a per-user Cachex key with a 60-second TTL and PubSub invalidation. Missing invalidation can leave stale access state.
- Query/N+1 risks: role lookups on repeated policy checks, parent-order child reads, cart merge, digital revocation, and per-subscription renewal work. PostgreSQL remains authoritative for security-sensitive state.
- Queue/security interaction: bounded webhook/refund/subscription queues and retries can delay payment, revocation, or renewal state during bursts. Receipt and renewal identities limit duplicate work but do not eliminate queue lag.
- Rate-limit interaction: webhook limits are IP-keyed and may use per-node ETS or shared Redis; the current limiter fails open on backend errors. No production load, multi-node cache, queue-lag, or webhook-storm result was inferred.
