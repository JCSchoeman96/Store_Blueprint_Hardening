# Phase 12 - Refund semantics

## GOAL

Implement refund semantics that prevent double refunds and inconsistent order/payment states through durable evidence, strict idempotency, and worker-driven processing.

## LINKS CONSULTED

- Project docs:
  - `docs/phases/phase_12_refund_semantics.md`
  - `docs/governance/refund_semantics.md`
  - `docs/governance/enforcement_gates.md`
  - `docs/governance/idempotency.md`
  - `docs/governance/step_up.md`
  - `docs/governance/policy_matrix.md`
  - `docs/governance/error_codes.md`
  - `docs/governance/immutable_snapshots.md`
  - `docs/phases/phase_13_tax_shipping.md`
- External references:
  - https://docs.stripe.com/api/idempotent_requests
  - https://docs.stripe.com/webhooks#handle-duplicate-events
  - https://docs.stripe.com/api/refunds/object
  - https://hexdocs.pm/oban/unique_jobs.html
  - https://www.postgresql.org/docs/current/indexes-partial.html

## WHAT DOCS RECOMMEND NOW

- Refunds are evidence-first, idempotent, and worker-finalized.
- Sensitive refund actions require role + recent step-up.
- Duplicate webhook deliveries and provider events must be replay-safe NOOPs.
- Refundable bounds must be enforced before dispatching provider side effects.

## DECISIONS TAKEN (PINS)

- Phase 12 evidence model includes all three resources:
  - `Store.Payments.Refund`
  - `Store.Payments.RefundAttempt`
  - `Store.Orders.RefundAdjustment`
- Concurrency pin:
  - refund request flow runs in one transaction and acquires `FOR UPDATE` lock on `payment_intents` row before computing remaining refundable and creating/upserting refund evidence.
- Idempotency mismatch pin:
  - existing `idempotency_key` with mismatched immutable request fingerprint returns `IDEMPOTENCY_KEY_REUSE_MISMATCH` and performs no side effects.
- Refundable base pin (Phase 12):
  - `snapshot_total_minor_excl_tax_shipping = sum(order_line_items.net_line_total_minor) + sum(order_adjustments.amount_minor)`
  - `refundable_base_minor = min(payment_intent.amount_received_minor, snapshot_total_minor_excl_tax_shipping)`
  - currency must match payment intent currency; mismatch returns `CURRENCY_MISMATCH`
  - tax/shipping refunds are deferred to Phase 13.
- Refund webhook processing pin:
  - dedicated refund worker queue/path; dedupe identity remains `(provider, provider_event_id)` via provider event evidence.

## PLAN

1. Add Phase 12 data model and migration for refund evidence resources and unique constraints.
2. Implement refund service with deterministic idempotency keying, lock-based overshoot prevention, and bounds/authorization enforcement.
3. Add dedicated refund webhook worker and replay-safe finalization.
4. Add governance and worker tests for all phase acceptance scenarios.
5. Run `mix check` and close phase beads with gate evidence.

## DONE

- Created and claimed Phase 12 beads:
  - `store_blueprint-7yf.1` (parent)
  - `store_blueprint-7yf.1.1` docs-first (claimed)
  - `store_blueprint-7yf.1.2` resources + DB
  - `store_blueprint-7yf.1.3` orchestration + idempotency mismatch
  - `store_blueprint-7yf.1.4` dedicated webhook worker
  - `store_blueprint-7yf.1.5` governance tests
  - `store_blueprint-7yf.1.6` verification/closure
- Added dependency chain and verified cycles: none.
- Added this docs-first Phase 12 note with authoritative pins.

## NEXT

- Implement `Refund`, `RefundAttempt`, and `RefundAdjustment` resources and migration.
- Add refund orchestration module and update domains/interfaces.
- Implement dedicated refund webhook worker and tests.

## BLOCKERS

- None currently.

## COMMANDS RUN

- `bd prime --json`
- `bd ready --json`
- `bd create ...` for `store_blueprint-7yf.1` and child beads
- `bd dep add ...`
- `bd dep cycles`
- `bd update store_blueprint-7yf.1.1 --claim`

## GATES

- Pending implementation gate run:
  - `mix check`
  - refund semantics governance tests
  - worker replay/idempotency tests

## PERFORMANCE REVIEW

- Hot path:
  - refund request path under concurrent admin retries.
- Warm path:
  - webhook-driven refund finalization and reconciliation.
- Cold path:
  - audit and support reads of refund evidence chain.
- Indexes:
  - unique `refunds.idempotency_key`
  - partial unique `(provider, provider_refund_id) where provider_refund_id is not null`
  - lookup indexes on `refunds.order_id`, `refunds.payment_intent_id`, `refund_attempts.refund_id`, `refund_adjustments.order_id`
- TTL:
  - no new TTL in Phase 12 baseline.
- Invalidation:
  - no cache invalidation introduced in Phase 12 baseline.
- PubSub:
  - no new PubSub fanout introduced in Phase 12 baseline.
