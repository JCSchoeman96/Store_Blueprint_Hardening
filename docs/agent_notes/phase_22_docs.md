# Phase 22 — Shipping + Fulfillment (Physical Products)

## GOAL

Implement Phase 22 end-to-end with a full `Store.Shipping` domain migration, deterministic quote selection and immutable quote evidence snapshotting, and replay-safe post-payment fulfillment (`Store.Fulfillment`) for physical orders.

## LINKS CONSULTED

### Project docs

- `AGENTS.md`
- `docs/phases/phase_22_shipping_fulfillment_physical_products.md`
- `docs/phases/phase_21_checkout_payment_integration_mvp.md`
- `docs/phases/phase_23_email_receipts_notifications_spine.md`
- `docs/phases/phase_24_digital_products_download_grants.md`
- `docs/governance/tax_shipping.md`
- `docs/governance/checkout_interlocks.md`
- `docs/governance/state_machines.md`
- `docs/governance/policy_matrix.md`
- `docs/governance/enforcement_gates.md`
- `docs/governance/observability_slos.md`
- `docs/governance/performance_scaling.md`
- `docs/governance/error_codes.md`
- `docs/governance/route_inventory.md`

### Key implementation files reviewed

- `lib/store/checkout/domain.ex`
- `lib/store/orders/order.ex`
- `lib/store/orders/snapshot_writer.ex`
- `lib/store/orders/tax_shipping_snapshot_writer.ex`
- `lib/store/payments/interlocks.ex`
- `lib/store/payments/domain.ex`
- `lib/store/pricing/domain.ex`
- `lib/store/pricing/shipping_zone.ex`
- `lib/store/pricing/shipping_rate.ex`
- `lib/store/support/governance/surface_registry.ex`
- `lib/store/support/governance/uniqueness_registry.ex`
- `lib/store_web/live/checkout_live/placeholder.ex`
- `lib/store_web/live/admin/shipping_zones/index_live.ex`
- `lib/store_web/live/admin/shipping_rates/index_live.ex`

### External references

- https://docs.stripe.com/checkout/fulfillment
- https://hexdocs.pm/oban/unique_jobs.html
- https://help.shopify.com/en/manual/fulfillment/managing-orders/order-status
- https://woocommerce.com/document/flat-rate-shipping/
- https://docs.easypost.com/docs/shipments/rates

## DECISIONS / PINS

1. Shipping ownership is atomic in this phase: only `Store.Shipping.*` resources own shipping tables after migration.
2. No dual resource ownership across `Store.Pricing` and `Store.Shipping` for the same shipping tables.
3. Quote evidence is persisted before finalize with explicit fields:
   - `quote_hash`, `currency_code`, `amount_minor`, `shipping_weight_grams`
   - destination country/region/postal
   - `shipping_method_code`, `shipping_rule_id`, `zone_id`
   - `effective_from`, `effective_to` (nullable)
4. `quote_hash` uses `HMAC_SHA256(secret, canonical_json)` with sorted keys and stable list ordering.
5. Quote option sorting is deterministic:
   - `amount_minor ASC`
   - `shipping_method_code ASC`
   - `shipping_rule_id` (binary UUID sort)
   - `zone_id` (binary UUID sort)
6. `Checkout.set_shipping/3` stores selected evidence and address snapshot only after server-side validation.
7. `Checkout.finalize_totals/...` validates quote integrity and must not reprice from live shipping config.
8. Shipping adjustment write is immutable and idempotent: one `OrderAdjustment(kind: "shipping")` per order.
9. Fulfillment creation is ordered behind paid + finalized checks and shipping adjustment presence.
10. Fulfillment items are derived from immutable `OrderLineItem` evidence, never live catalog records.
11. Replay safety is dual-guarded by DB uniqueness and unique Oban jobs.
12. Shipment is included in this phase; carrier APIs remain out-of-scope.
13. Caching is optional in Phase 22; correctness ships without cache.

## PREVIOUS/NEXT PHASE BOUNDARY CHECK

### Previous phase (21) protections

- Preserve Phase 21 payment/webhook contract and enqueue-only web boundaries.
- Keep paid state transition source-of-truth in verified worker/interlock flow.
- Extend paid fanout only by adding fulfillment ensure path.

### Next phase (23) protections

- Do not expand email delivery architecture in this phase.
- Reuse existing comms outbox path where needed.

### Adjacent (24+) protections

- Do not add digital grant issuance/revocation in Phase 22.
- Do not introduce product-type branching into order write semantics.

## PLAN

1. Docs + governance alignment updates (policy matrix, route inventory, error codes).
2. Shipping migration to `Store.Shipping` with methods/rules and deterministic quoting.
3. Checkout quote selection integration with immutable evidence snapshot and idempotent shipping adjustment.
4. Fulfillment domain implementation (`FulfillmentOrder`, `Shipment`, `FulfillmentItem`) with policies and state transitions.
5. Paid interlock integration via unique worker and ensure semantics.
6. Web surface updates (admin + customer order detail) through typed params and facades only.
7. Governance and integration tests + `mix check` + closure protocol.

## DONE

- Created Phase 22 bead hierarchy and dependency graph (`store_blueprint-7yf.14.*`).
- Claimed `store_blueprint-7yf.14.1`.
- Created this docs-first phase note with decision-complete pins.

## NEXT

1. Apply governance doc deltas (`policy_matrix`, `error_codes`, `route_inventory`).
2. Implement shipping domain migration and quote contract.
3. Implement checkout + fulfillment integration and tests.

## BLOCKERS

- None.

## COMMANDS RUN

- `bd dolt test`
- `bd status`
- `bd ready`
- `bd create ...` (phase 22 parent + child beads)
- `bd update ... --parent ...`
- `bd --sandbox dep add ...`
- `bd update store_blueprint-7yf.14.1 --claim`

## GATES

- Docs-first requirement satisfied before Phase 22 code edits.
- Bead workflow initialized for current session.

## PERFORMANCE & SCALING REVIEW

### Hot / warm / cold

- Hot:
  - checkout quote options
  - checkout finalize
  - paid webhook processing + fulfillment ensure worker
- Warm:
  - admin shipping config reads
  - admin fulfillment queue reads
- Cold:
  - historical fulfillment/shipment records

### Query count / N+1 risk

- Quote path should do bounded reads for zone/method/rule candidates and avoid per-option queries.
- Fulfillment detail views must preload fulfillment, shipment, and item snapshots in bounded query count.

### Indexes

- Shipping rules: compound lookup indexes for zone/method/active/effective window fields.
- Fulfillment: unique `order_id`; status/time indexes for queue operations.
- Shipment: nullable unique tracking ref index.
- Shipping adjustment idempotency: unique shipping adjustment per order.

### Caching

- Default Phase 22 correctness path: no required cache.
- If enabled later in phase: TTL 30-300s, write-trigger invalidation, stampede protection.

### Oban uniqueness / idempotency

- Unique fulfillment ensure job keyed by `order_id`.
- Ensure semantics return existing fulfillment on replay.

### Telemetry / logging

- Emit quote and fulfillment transition telemetry.
- Keep logs PII-safe and include stable error codes.
