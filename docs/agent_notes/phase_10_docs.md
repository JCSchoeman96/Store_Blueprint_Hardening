# Phase 10 — Pricing determinism & stacking

## GOAL

Implement deterministic pricing evaluation and immutable snapshot evidence writes so the same inputs always produce the same outputs and no historical order evidence is mutated.

## LINKS CONSULTED

- Project docs:
  - `docs/phases/phase_10_pricing_determinism.md`
  - `docs/governance/pricing_determinism.md`
  - `docs/governance/immutable_snapshots.md`
  - `docs/governance/enforcement_gates.md`
  - `docs/governance/error_codes.md`
  - `docs/phases/phase_11_inventory_reservations.md`
  - `docs/phases/phase_12_refund_semantics.md`
  - `docs/phases/phase_13_tax_shipping.md`
- External references:
  - https://docs.stripe.com/currencies#minor-units-in-api-amounts
  - https://docs.adyen.com/development-resources/currency-codes/
  - https://www.postgresql.org/docs/current/queries-order.html
  - https://hexdocs.pm/elixir/Map.html
  - https://www.rfc-editor.org/rfc/rfc8785
  - https://hexdocs.pm/decimal/Decimal.html

## WHAT DOCS RECOMMEND NOW

- Money amounts should use integer minor units with explicit currency.
- Deterministic behavior requires explicit ordering and final tie-break keys.
- Evaluator logic should not depend on DB query order or map iteration order.
- Discount allocation should be proportional with deterministic remainder distribution.
- Historical order evidence must be immutable and stored at creation time.

## DECISIONS TAKEN (PINS)

- Evaluator boundary is pure and DTO-based (no DB struct input/output).
- Final deterministic tie-break key is UUID raw16 bytes (`id_bytes ASC`) in applicable sort tuples.
- `inserted_at` is never the final tie-break key.
- Promotion winner tuple: `(exclusive_priority DESC, discount_minor DESC, inserted_at ASC, id_bytes ASC)`.
- Applied adjustments tuple: `(source_kind ASC, precedence_rank ASC, discount_minor DESC, inserted_at ASC, id_bytes ASC)`.
- Snapshot evidence writes are create-only and idempotent; no runtime backfills/updates of existing snapshot rows.

## PLAN

1. Lock evaluator contract and deterministic sort/allocation rules.
2. Implement deterministic evaluator (normalization, stacking, allocation, canonical output ordering).
3. Add persisted coupon/promotion resources with explicit fields and unique coupon code.
4. Integrate create-only priced snapshot writer with denormalized line evidence fields.
5. Add governance tests for determinism, no penny leak, ordering stability, tie-break stability, and historical immutability.

## DONE

- Phase 10 bead tree created with dependency fanout and cycle check.
- This docs-first phase note created and pinned with external and project references.

## NEXT

- Implement evaluator contract types and pure evaluator module.
- Add pricing resources and snapshot integration.
- Add governance gates and run `mix check`.

## BLOCKERS

- None currently.

## GATES

- Determinism test gate
- Allocation no-penny-leak gate
- Tie-break stability gate
- Applied ordering stability gate
- Historical immutability gate

## PERFORMANCE REVIEW

- Hot path:
  - Evaluator execution during quote/checkout with deterministic sorting and allocation.
- Warm path:
  - Snapshot evidence writes during order creation/checkout finalization.
- Cold path:
  - Historical audit reads and support evidence inspection.
- Indexes:
  - Keep/extend snapshot read indexes by `order_id`.
  - Add coupon code uniqueness index and supporting active-window indexes if needed.
- TTL:
  - No TTL added in Phase 10.
- Invalidation:
  - No cache invalidation introduced in Phase 10 baseline.
- PubSub:
  - No new PubSub fanout introduced in Phase 10 baseline.

## COMMANDS RUN

- `bd prime --json`
- `bd ready --json`
- `bd create ...` (Phase 10 parent + child fanout)
- `bd dep add ...`
- `bd dep cycles`
