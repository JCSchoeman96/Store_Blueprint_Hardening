# Phase 29 — Architecture Closure and Hot-Path Governance Alignment

## GOAL

Close the non-benchmark remainder of Phase 29 so the blueprint matches the
authoritative performance architecture contract for:

- cluster-safe hot/warm/cold caching
- Redis-backed high-velocity telemetry aggregates
- hot-path compatibility telemetry
- justified hot-path index closure
- keyset pagination on the order surfaces touched by those new indexes

This follow-up explicitly reuses the existing benchmark infrastructure from the
closed Phase 29 smoke-suite bead and does not absorb Phase 30 benchmark or
route-specific diagnosis scope.

## LINKS CONSULTED

### Project docs

- `AGENTS.md`
- `docs/phases/phase_28_production_readiness_release_checklist.md`
- `docs/phases/phase_29_performance_architecture_optimizations.md`
- `docs/governance/performance_scaling.md`
- `docs/governance/observability_slos.md`
- `docs/agent_notes/phase_28_docs.md`
- `docs/agent_notes/phase_30_docs.md`

### Key implementation files reviewed

- `lib/store/application.ex`
- `lib/store_web/telemetry.ex`
- `lib/store_web/controllers/webhook_controller.ex`
- `lib/store_web/controllers/payment_callback_controller.ex`
- `lib/store_web/payment_ingress_telemetry.ex`
- `lib/store/catalog/facade.ex`
- `lib/store/catalog/product.ex`
- `lib/store/shipping/domain.ex`
- `lib/store/shipping/facade.ex`
- `lib/store/orders/order.ex`
- `lib/store/orders/facade.ex`
- `lib/store/orders/queries/order_index_query.ex`
- `lib/store/payments/payment_intent.ex`
- `lib/store/payments/interlocks.ex`
- `lib/store/digital/facade.ex`
- `lib/store/subscriptions/facade.ex`
- `lib/store/support/rate_limit/redix_client.ex`
- `lib/store/entitlements/cache.ex`
- `priv/repo/performance_smoke_test.exs`

### External references

- https://hexdocs.pm/ash/pagination.html
- https://hexdocs.pm/phoenix_live_view/Phoenix.LiveView.html#stream/4
- https://hexdocs.pm/oban/Oban.Worker.html
- https://hexdocs.pm/oban/unique_jobs.html
- https://hexdocs.pm/oban/Oban.Telemetry.html
- https://www.postgresql.org/docs/current/indexes-ordering.html

## DECISIONS / PINS

1. The closed smoke/benchmark work under `store_blueprint-7yf.22` remains the
   Phase 29 benchmark history. The new implementation tree is a fresh follow-up
   epic:
   - `store_blueprint-7yf.26`
   - `store_blueprint-7yf.26.1` through `.26.5`
2. Phase 29 follow-up is architectural only. It must not absorb:
   - Phase 28 ops/readiness work
   - Phase 30 k6/Playwright harness work
   - route-specific latency diagnosis beyond what is required for cache,
     telemetry, or index correctness
3. Cache model is explicitly multi-layer:
   - hot: Cachex/ETS
   - warm: Redis
   - cold: Postgres
4. Catalog list and shipping quote caches must invalidate in this order:
   - clear/update Redis warm entries
   - broadcast Phoenix.PubSub invalidation
   - every node clears its hot Cachex layer
5. Hot cache misses must fall back in this order:
   - local Cachex
   - Redis warm cache
   - Postgres/domain read
6. High-velocity aggregates must bypass Postgres. Redis is the sink for:
   - rolling counters
   - event windows
   - queue helper state
   - approximate unique counts where acceptable
7. Existing low-frequency DB-backed queue/backlog polling may remain as
   fallback/verification, but it is no longer the primary spike-time aggregate
   strategy.
8. Compatibility telemetry is additive. Existing richer telemetry names stay in
   place and new governance-compatible events are emitted alongside them.
9. Public `/shop` stays offset/page based in this phase because the
   authoritative Phase 29 doc explicitly allows offset pagination for public
   lists.
10. Order surfaces touched by the new hot-path composite indexes must move to
    keyset pagination. Offset pagination is explicitly rejected for:
    - user order history
    - admin order history
11. Payment-intent provider reference closure must be the narrowest safe change:
    prefer provider-scoped uniqueness for provider payment/session references,
    aligned with the uniqueness registry already present in the repo.
12. Redis plumbing should reuse the existing Redix seam and Redis runtime
    configuration rather than adding a second Redis stack.

## PREVIOUS/NEXT PHASE BOUNDARY CHECK

### Previous phase (28) protections

- Do not re-open runtime hardening, release entrypoints, Sentry wiring, health
  probes, or production runbook scope unless directly required by the new Redis
  cache/telemetry code paths.
- Keep Phase 28 as operational hardening only; no new benchmark harness or
  route-specific load work belongs there.

### Next phase (30) protections

- Do not add new k6 or Playwright harnesses in this follow-up.
- Do not pull product-detail route diagnosis, browser join attribution, or
  durability soak work back into Phase 29; those remain documented in
  `docs/agent_notes/phase_30_docs.md`.
- Query-count reduction is only in scope where needed to support cache,
  telemetry, or pagination/index correctness.

## CURRENT-STATE AUDIT

### Already implemented

- Standalone performance smoke suite with Benchee + ExUnit exists at:
  - `priv/repo/performance_smoke_test.exs`
- CI and nightly workflows already enforce:
  - required perf smoke in CI
  - full-stress smoke in nightly
- Existing telemetry already covers:
  - cart get/mutate/merge
  - checkout start/create-intent step timing
  - payment ingress verify/persist/enqueue/response timing
  - webhook/refund worker processing timing
  - digital signed URL timing
  - backlog polling gauges
- Existing cache patterns already exist for:
  - entitlements hot cache with Cachex + PubSub
  - inventory/availability hot cache paths
- Existing uniqueness registry already expects payment-intent provider reference
  uniqueness entries.

### Missing or incomplete for Phase 29 proper

- No cluster-safe product-list hot/warm cache.
- No cluster-safe shipping quote hot/warm cache.
- No Redis-backed high-velocity telemetry aggregate spine.
- No compatibility telemetry for:
  - catalog list
  - shipping quote
  - webhook received/enqueued
  - payment apply-once
  - digital grant issuance
  - subscription tick/renewal/dunning
- `StoreWeb.Telemetry` does not yet expose all mandatory governance event
  metrics.
- Orders still use offset pagination in resource reads and facade query
  contracts.
- Hot-path order composites for keyset traversal are missing.
- `products(status, published_at)` composite is missing.
- Payment-intent provider reference uniqueness/index posture is only partially
  implemented relative to the uniqueness registry.

## PLAN

1. Update this note first, then implement the Phase 29 follow-up under
   `store_blueprint-7yf.26`.
2. Add a shared Redis support layer plus Redis-backed telemetry aggregate
   helpers.
3. Add additive compatibility telemetry and metric definitions for the missing
   Phase 29 hot paths.
4. Implement multi-layer Cachex + Redis caches for product list and shipping
   quote reads, with PubSub invalidation from domain mutation paths.
5. Add justified composite indexes and convert order list surfaces to keyset
   pagination.
6. Run focused tests, perf smoke, and `mix check`, then finalize bead notes and
   closure details.

## DONE

- Session start protocol completed:
  - `bd dolt test`
  - `bd status`
  - `bd ready`
- Reviewed the authoritative Phase 29 doc, governance docs, adjacent phase
  notes, and current implementation state.
- Created the Phase 29 follow-up bead tree:
  - `store_blueprint-7yf.26`
  - `store_blueprint-7yf.26.1`
  - `store_blueprint-7yf.26.2`
  - `store_blueprint-7yf.26.3`
  - `store_blueprint-7yf.26.4`
  - `store_blueprint-7yf.26.5`
- Added bead dependencies and claimed `store_blueprint-7yf.26.1`.
- Replaced the old smoke-suite-only Phase 29 note with this follow-up scope
  lock before implementation edits.

## NEXT

1. Implement the Redis-backed telemetry aggregate spine and compatibility event
   coverage.
2. Implement cluster-safe product-list and shipping quote caches.
3. Add order keyset pagination plus hot-path composite indexes.
4. Validate with focused tests, perf smoke, and `mix check`.

## BLOCKERS

- None at note creation time.

## COMMANDS RUN

- `bd dolt test`
- `bd status`
- `bd ready`
- `git status -sb`
- `git diff -- priv/repo/performance_smoke_test.exs`
- `sed -n ...` against phase, governance, app, domain, telemetry, cache, and
  query files
- `rg ...` across docs, config, lib, test, and deps
- `bd create ...` for `store_blueprint-7yf.26` through `.26.5`
- `bd dep add ...`
- `bd update store_blueprint-7yf.26.1 --claim`

## GATES

- Docs-first note updated before implementation edits.
- Scope pins explicitly preserve the Phase 28 and Phase 30 boundaries.
- Phase 29 follow-up pins explicitly require:
  - hot/warm/cold cache layering
  - Redis-backed high-velocity aggregates
  - additive telemetry compatibility
  - keyset pagination on touched order surfaces

## PERFORMANCE & SCALING REVIEW

### Hot / warm / cold

- Hot:
  - product list reads
  - shipping quote reads
  - webhook ingress and apply-once transition
  - digital grant issuance
  - subscription renewal orchestration
- Warm:
  - Redis cache fallback for catalog and shipping
  - Redis telemetry aggregates for rolling counters and event windows
- Cold:
  - Postgres truth for catalog, shipping rules, orders, payments, grants, and
    subscriptions

### Query count + N+1 risk

- Product list cache must prevent repeated Postgres reads on identical page keys.
- Shipping quote cache must prevent repeated rule reads on identical quote
  inputs.
- Order keyset pagination must avoid deep offset scans.
- Compatibility telemetry must not introduce request-path Postgres writes.

### Indexes

- Expected additions in this follow-up:
  - `products(status, published_at)`
  - `orders(user_id, inserted_at, id)` or equivalent deterministic keyset index
  - `orders(state, inserted_at, id)` or equivalent deterministic keyset index
- Payment-intent provider reference uniqueness/index posture must be reconciled
  with the uniqueness registry.

### Caching strategy

- Hot cache: Cachex/ETS with short TTL and single-flight protection.
- Warm cache: Redis with longer TTL and cluster-consistent values.
- Invalidation: Redis delete/update first, then PubSub fanout, then local hot
  cache clear on every node.

### Oban uniqueness / idempotency

- No new queue semantics are introduced.
- Existing unique-job/idempotency anchors remain authoritative.

### Telemetry / observability

- Compatibility telemetry events are additive on top of the existing richer
  events.
- High-velocity aggregates must land in Redis, not Postgres.
- Existing DB-backed queue polling can remain as low-frequency fallback
  verification only.
