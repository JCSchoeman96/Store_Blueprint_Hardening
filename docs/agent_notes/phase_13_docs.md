# Phase 13 - Tax and shipping determinism

## GOAL

Implement deterministic shipping selection and tax computation with immutable order evidence snapshots so identical inputs always produce identical outputs with no penny leaks.

## LINKS CONSULTED

- Project docs:
  - `docs/phases/phase_13_tax_shipping.md`
  - `docs/governance/tax_shipping.md`
  - `docs/governance/enforcement_gates.md`
  - `docs/governance/pricing_determinism.md`
  - `docs/governance/error_codes.md`
  - `docs/governance/immutable_snapshots.md`
  - `docs/agent_notes/phase_10_docs.md`
  - `docs/agent_notes/phase_12_docs.md`
- External references:
  - https://www.postgresql.org/docs/current/queries-order.html
  - https://docs.stripe.com/api/shipping_rates/object
  - https://docs.stripe.com/api/tax/calculations
  - https://hexdocs.pm/decimal/Decimal.html
  - https://www.rfc-editor.org/rfc/rfc8785

## WHAT DOCS RECOMMEND NOW

- Shipping and tax must use explicit, deterministic sort tuples and explicit `as_of`.
- Money values and rounding must remain integer minor units with deterministic half-up behavior.
- Shipping and tax evidence should be snapshotted on orders and never recomputed for historical records.
- Deterministic tie-breaks must use UUID binary sort semantics rather than UUID string order.

## DECISIONS TAKEN (PINS)

- Shipping model for Phase 13 is pinned to:
  - flat-rate
  - destination-zone matching
  - weight-bounded eligibility
  - free-shipping via subtotal threshold or free-shipping coupon toggle
- Tax model is pinned to internal deterministic tax-rate tables with jurisdiction keys:
  - `country_code`
  - `region_code` (optional)
  - `product_tax_category` (optional)
- Shipping winner tuple is pinned:
  - `effective_shipping_cost_minor ASC`
  - `rate_id_raw16 ASC` (non-raising normalization path)
  - `rate_code ASC`
- Tax line-rate selector tuple is pinned:
  - specificity rank (more specific first)
  - `precedence_rank ASC`
  - `rate_id_raw16 ASC` (non-raising normalization path)
  - `rate_code ASC`
- Tax basis is pinned to priced snapshot line values:
  - `order_line_items.net_line_total_minor` (post-discount), not recomputed catalog prices.
- Shipping evidence fields pinned on `orders`:
  - `shipping_cost_minor_original`
  - `shipping_cost_minor_effective`
  - `free_shipping_applied`
  - `free_shipping_reason`
  - selected rate id/code and destination snapshot.

## PLAN

1. Add migration for shipping zones/rates, tax rates, and order tax/shipping snapshot fields.
2. Add pricing resources (`ShippingZone`, `ShippingRate`, `TaxRate`) and register in `Store.Pricing`.
3. Implement pure `TaxShippingContract` + `TaxShippingEvaluator` deterministic logic.
4. Add `Store.Orders.TaxShippingSnapshotWriter` and `Store.Orders.write_tax_shipping_snapshot/3`.
5. Add governance tests for determinism, tie-breaks, no-penny-leak, and snapshot immutability.
6. Run `mix check` and execute closure protocol.

## DONE

- Created and advanced Phase 13 bead tree:
  - `store_blueprint-7yf.3` parent
  - `store_blueprint-7yf.3.1` docs-first (closed)
  - `store_blueprint-7yf.3.2` resources + migration (closed)
  - `store_blueprint-7yf.3.3` shipping engine (closed)
  - `store_blueprint-7yf.3.4` tax engine (closed)
  - `store_blueprint-7yf.3.5` snapshot integration (closed)
  - `store_blueprint-7yf.3.6` governance tests + closure (in progress)
- Added dependency chain and verified no cycles.
- Added migration `20260225113000_phase_13_tax_shipping.exs`.
- Added pricing resources:
  - `Store.Pricing.ShippingZone`
  - `Store.Pricing.ShippingRate`
  - `Store.Pricing.TaxRate`
- Added pure contract/evaluator:
  - `Store.Pricing.TaxShippingContract`
  - `Store.Pricing.TaxShippingEvaluator`
- Added orders integration:
  - `Store.Orders.TaxShippingSnapshotWriter`
  - `Store.Orders.write_tax_shipping_snapshot/3`
  - `Order.write_tax_shipping_snapshot` action + snapshot attributes
- Added line tax snapshot attributes on `OrderLineItem` and snapshot writer defaults.
- Added non-raising UUID normalization path:
  - `Store.Support.ID.UUIDv7.decode/1`
  - `Store.Support.ID.BinaryUuidSort.normalize_raw16/1`
- Added governance tests:
  - `test/store/governance/tax_shipping_determinism_test.exs`
- Updated governance doc pins in `docs/governance/tax_shipping.md`.
- Full `mix check` passes.

## NEXT

- Complete closure bead `store_blueprint-7yf.3.6` and close parent bead.
- Commit Phase 13 implementation changes.

## BLOCKERS

- `bd export` commands from AGENTS.md are not available in this installed `bd` version (`unknown command "export"`).

## COMMANDS RUN

- `bd status`
- `bd ready`
- `bd create ...` for `store_blueprint-7yf.3` and child beads
- `bd dep add ...`
- `bd dep cycles`
- `bd update store_blueprint-7yf.3.1 --claim`
- `bd close store_blueprint-7yf.3.1 ...`
- `bd update/close store_blueprint-7yf.3.2`
- `bd update/close store_blueprint-7yf.3.3`
- `bd update/close store_blueprint-7yf.3.4`
- `bd update/close store_blueprint-7yf.3.5`
- `bd update store_blueprint-7yf.3.6 --claim`
- `mix test test/store/support/id/uuid_v7_test.exs test/store/support/id/binary_uuid_sort_test.exs test/store/governance/tax_shipping_determinism_test.exs`
- `mix format`
- `mix check`
- `git pull --rebase --autostash`
- `git push`
- `git status -sb`
- `bd sync`

## GATES

- Acceptance checks:
  - Determinism: pass
  - Shipping tie-break determinism: pass
  - No penny leak: pass
  - Snapshot evidence immutability: pass
  - `mix check`: pass
- Closure caveat:
  - `bd export` unavailable in current CLI; fallback `bd sync` executed.

## PERFORMANCE REVIEW

- Hot path:
  - deterministic shipping/tax evaluation at checkout quote/finalization boundaries.
- Warm path:
  - tax/shipping snapshot write path on order finalization.
- Cold path:
  - historical order evidence read and support/audit investigations.
- Indexes:
  - rate lookup indexes by currency, active window, jurisdiction, and zone.
  - order query indexes on shipping/tax snapshot identifiers where needed.
- TTL:
  - no new TTL in Phase 13 baseline.
- Invalidation:
  - no cache invalidation layer introduced in Phase 13 baseline.
- PubSub:
  - no new PubSub fanout introduced in Phase 13 baseline.
