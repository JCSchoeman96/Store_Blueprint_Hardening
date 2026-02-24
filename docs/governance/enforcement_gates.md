# Governance: Enforcement Gates (Authoritative)

## mix check gates (MUST)
mix check MUST include:
- format check
- compile warnings-as-errors
- tests
- credo strict
- docs
- blueprint gates:
  1) No Repo in web gate
  2) moduledoc gate
  3) docs-first phase notes gate

## No Repo in web gate (MUST)
Fail if any file under lib/store_web/** references:
- Store.Repo
- any Ecto.Repo module

Preferred: Credo custom check (reports file+line)
Fallback: mix task running ripgrep denylist

## moduledoc gate (MUST)
Fail if any module under lib/** lacks @moduledoc (allow explicit @moduledoc false).

## docs-first notes gate (MUST)
Required (at minimum for release-1):
- docs/agent_notes/phase_00_docs.md
- docs/agent_notes/phase_01_docs.md
- docs/agent_notes/phase_02_docs.md
- docs/agent_notes/phase_03_docs.md


## Policy matrix test gate (MUST)
- The pinned policy matrix must have an accompanying test suite under `test/store/governance/`.
- CI must fail if authorization drift occurs.


## No raw Req usage gate (MUST)
- CI must fail if `Req.` is referenced outside the HTTP wrapper module.
- Scope: `lib/store/**`.
- Allowlist: wrapper file only.


## Error code registry gate (MUST)
- The error code registry must contain all pinned codes from `docs/governance/error_codes.md`.
- Add tests that assert core codes exist and remain unique.


## Side effects quarantine gates (MUST)
- CI must fail if `Store.Support.HTTP.ReqClient` or `Req.` is referenced under `lib/store_web/**`.
- CI must fail if `Oban.insert`/`Oban.insert_all` is referenced under `lib/store_web/**`.
- Allowlist: `lib/store_web/controllers/webhook_controller.ex` may enqueue only.
- See `docs/governance/side_effects_quarantine.md`.


## Immutable snapshot gates (MUST)
- Snapshot resources (Orders.OrderLineItem, Orders.OrderAdjustment) must not define update/destroy actions.
- Add a test gate under `test/store/governance/` that asserts action absence.
- See `docs/governance/immutable_snapshots.md`.


## Pricing determinism gates (MUST)
- Pricing evaluation must be deterministic for identical inputs.
- Discount allocation must have no penny leak and remainder distribution must be deterministic.
- Applied discount ordering must be deterministic.
- Pricing evidence writes must be create-only (no runtime updates/backfills of existing snapshot rows).
- See `docs/governance/pricing_determinism.md`.


## Inventory reservation gates (MUST)
- Order creation must enforce no-oversell for inventory-tracked SKUs.
- Reservation creation must be concurrency-safe and idempotent.
- Expired reservations must be released by a scheduled worker.
- See `docs/governance/inventory_reservations.md`.


## Refund semantics gates (MUST)
- Refund actions require role + step-up.
- Refunds must be idempotent (unique idempotency_key).
- Refund amount must not exceed refundable amount.
- Order status must only transition to refunded when refund evidence confirms.
- See `docs/governance/refund_semantics.md`.


## Tax & shipping gates (MUST)
- Shipping selection and tax calculation must be deterministic and use explicit as_of.
- Rounding/allocation must have no penny leak.
- Evidence must be stored in order snapshot fields.
- See `docs/governance/tax_shipping.md`.


## Checkout interlock gates (MUST)
- begin_checkout must be idempotent (checkout_key uniqueness).
- payment_intent creation must be idempotent (payment_intent_key uniqueness).
- Paid side effects must be exactly-once under webhook and redirect replays.
- See `docs/governance/checkout_interlocks.md`.
