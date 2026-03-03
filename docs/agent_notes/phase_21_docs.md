# Phase 21 - Checkout UI + Payment Integration MVP

## GOAL

Implement Phase 21 end-to-end checkout and payment MVP for simple physical products with an order-first model, deterministic totals, verified webhook ingress, replay-safe payment application, and idempotent paid-order receipt delivery.

## LINKS CONSULTED

### Project docs

- `AGENTS.md`
- `docs/phases/phase_21_checkout_payment_integration_mvp.md`
- `docs/phases/phase_20_storefront_cart_ux.md`
- `docs/governance/checkout_interlocks.md`
- `docs/governance/payment_provider_contract.md`
- `docs/governance/payment_provider_capabilities.md`
- `docs/governance/side_effects_quarantine.md`
- `docs/governance/idempotency.md`
- `docs/governance/error_codes.md`
- `docs/governance/enforcement_gates.md`
- `docs/governance/tax_shipping.md`
- `docs/governance/observability_slos.md`
- `docs/governance/performance_scaling.md`
- `docs/governance/policy_matrix.md`
- `docs/governance/route_inventory.md`
- `docs/agent_notes/phase_14_docs.md`
- `docs/agent_notes/phase_18_docs.md`
- `docs/agent_notes/phase_20_docs.md`

### Key implementation files reviewed

- `lib/store/checkout/domain.ex`
- `lib/store/checkout/checkout_draft.ex`
- `lib/store/payments/domain.ex`
- `lib/store/payments/interlocks.ex`
- `lib/store/payments/webhook_receipt.ex`
- `lib/store/payments/facade.ex`
- `lib/store/orders/domain.ex`
- `lib/store/orders/snapshot_writer.ex`
- `lib/store/orders/tax_shipping_snapshot_writer.ex`
- `lib/store/orders/inventory_reservations.ex`
- `lib/store/pricing/domain.ex`
- `lib/store/pricing/evaluator.ex`
- `lib/store/pricing/tax_shipping_evaluator.ex`
- `lib/store_web/controllers/webhook_controller.ex`
- `lib/store_web/controllers/payment_callback_controller.ex`
- `lib/store_web/live/cart_live.ex`
- `lib/store_web/live/checkout_live/placeholder.ex`
- `lib/store_web/router.ex`
- `lib/store/support/governance/uniqueness_registry.ex`
- `lib/store/support/governance/surface_registry.ex`

### External references

- https://docs.stripe.com/webhooks/signature
- https://docs.stripe.com/checkout/fulfillment
- https://docs.stripe.com/api/idempotent_requests
- https://hexdocs.pm/oban/unique_jobs.html
- https://hexdocs.pm/plug/Plug.Parsers.html

## DECISIONS / PINS

1. Order remains the durable source of truth for checkout/payment state; `CheckoutDraft` remains a handoff/access shim and points to order.
2. Phase 20 placeholder behavior is replaced with real checkout flow on `/checkout` while preserving web-thin adapter law.
3. `Store.Checkout` is extended with typed surfaces:
   - `start_from_cart/3` (order-backed)
   - `set_shipping/3`
   - `finalize_totals/3`
   - order-backed checkout summary read surface
4. Payment intent creation must use finalized order totals only; no intent creation from draft/cart subtotal.
5. A provider behavior is introduced under `Store.Payments.Providers.*`; provider modules stay pure (no `Repo`, no `Ash`, no `Oban`).
6. Stripe is pinned to Checkout Session redirect semantics for MVP; webhook remains source of truth.
7. Webhook ingress verifies signature on raw body + headers before enqueue.
8. Webhook controller remains verify + normalize + enqueue exactly one worker; all state transitions are worker/domain-owned.
9. Return/cancel routes remain read-only and never transition payment/order states.
10. Paid-order receipt delivery is implemented via domain wrapper + worker with durable idempotency key (`order_id + template_kind`).
11. Error codes added for payment ingress failures must be registry-backed in `Store.Support.Errors.ErrorCodes`.
12. Existing post-commit notification wrapper (`Store.Support.AshNotifications`) is reused where transactional notifications are returned.

## GOVERNANCE DRIFT NOTE

Resolved in this phase:
- `docs/governance/side_effects_quarantine.md` was aligned to allow inline signature verification as pure computation on cached raw body bytes.
- Controllers remain enqueue-only for domain transitions and outbound effects.

## PHASE 21 PATCH (7yf.13.8)

Patch migrations were added as part of bead `store_blueprint-7yf.13.8` and are intentionally separate from `20260303120000_phase_21_checkout_payment_integration_mvp.exs` to preserve migration reproducibility for environments that already ran earlier Phase 21 drafts.

Patch rationale:
- A subset of databases had Phase 21 marked as applied while missing final contract objects from the settled model.
- Patch migrations encode blueprint invariants and are not local-only workarounds.

Patch migrations:
- `priv/repo/migrations/20260303124000_phase_21_payment_intent_provider_session_fix.exs`
- `priv/repo/migrations/20260303124500_phase_21_email_outbox_unique_order_template_fix.exs`

Invariants enforced:
- `payment_intents.provider_session_id` exists, is indexed for webhook/payment lookup, and is uniquely constrained per `(provider, provider_session_id)` when non-null.
- `email_outboxes` enforces unique `(order_id, template_kind)` for receipt idempotency.

## PLAN

1. Extend checkout data model and typed inputs for order-backed checkout progression.
2. Rework checkout orchestration so `start_from_cart/3` establishes order+draft only, while `finalize_totals/3` creates/reuses priced snapshot + inventory holds idempotently.
3. Add provider behavior/resolver and Stripe adapter for intent creation, webhook verification, and canonical receipt normalization.
4. Add payment intent creation facade (`create_intent_for_order`) bound to finalized totals.
5. Harden webhook ingress with signature verification and canonical receipt processing.
6. Replace checkout placeholder LiveView with shipping + summary + payment initiation + confirmation states.
7. Add read-only return/cancel route behavior and status rendering.
8. Add minimal comms/outbox receipt pipeline and idempotent worker delivery.
9. Add governance, domain, web, and worker tests for happy path + replay safety + signature negatives.
10. Run `mix check`, then closure protocol and bead closure updates.

## DONE

- Added order-first checkout orchestration and typed inputs:
  - `Store.Checkout.start_from_cart/3`
  - `Store.Checkout.set_shipping/3`
  - `Store.Checkout.finalize_totals/3`
  - order-backed checkout summary reads
- Checkout sequencing adjusted for hold minimization:
  - `start_from_cart/3` no longer creates line-item snapshots or inventory holds
  - `finalize_totals/3` now performs priced snapshot creation + reservation creation idempotently
- Added payment provider boundary and Stripe adapter:
  - provider capability/intents/webhook verification/normalization
  - Checkout Session style redirect metadata + stable idempotency key input
  - `Store.Payments.create_intent_for_order/3` with finalized-total enforcement
- Hardened webhook ingress and processing:
  - controller verify + normalize + single enqueue behavior
  - strict raw-body evidence requirement from Plug `body_reader` cache
  - replay-safe worker/domain receipt processing and status marking
- Added paid-order receipt delivery:
  - `Store.Comms.EmailOutbox` resource
  - outbox delivery worker
  - idempotent enqueue on payment success
- Updated governance docs for phase scope:
  - `docs/governance/error_codes.md`
  - `docs/governance/route_inventory.md`
- Added/updated tests for checkout, payment intent creation, webhook signature negatives, worker replay behavior, and return/cancel read-only behavior.
- Completed bead lifecycle and closed:
  - `store_blueprint-7yf.13.1` through `store_blueprint-7yf.13.7`
  - parent phase bead `store_blueprint-7yf.13`
- Full gate run passed: `mix check` (compile + tests + credo + docs).

## NEXT

1. Optional: perform git commit/push and beads Dolt remote sync as release/phase-close transport steps.

## BLOCKERS

- None currently.

## COMMANDS RUN

- `bd dolt test`
- `bd status`
- `bd ready`
- `bd update store_blueprint-7yf.13.1 --claim`
- `bd create ...` (phase 21 parent and child beads)
- `bd --sandbox dep add ...` (dependency wiring)
- `bd --sandbox dep cycles`
- `bd show store_blueprint-7yf.13`
- `mix check`
- `mix test`
- `elixir -e 'Code.format_file!/1 ...'`
- `git status -sb`
- `bd close store_blueprint-7yf.13.* --reason ... --suggest-next`
- `bd close store_blueprint-7yf.13 --reason ... --suggest-next`

## GATES

- Docs-first requirement satisfied before implementation edits.
- Web boundary and governance checks passed (`check.web_no_ash_query`, `check.no_repo_in_web`, etc.).
- `mix check` passed fully.
- ExUnit: `235 tests, 0 failures`.
- Credo: no issues.

## PERFORMANCE & SCALING REVIEW

### Hot paths

- Checkout start/finalize read/write path
- Payment intent creation path
- Webhook verify + enqueue + worker apply path
- Paid-order receipt enqueue/delivery path

### Query count / N+1 posture

- Checkout summary and finalization must load cart/order lines and variant/product snapshots with explicit batched loads.
- Avoid per-line DB lookups in LiveViews/controllers; all aggregation in domain surfaces.

### Indexes

- Keep and leverage existing interlock indexes:
  - `orders.checkout_key`
  - `payment_intents.payment_intent_key`
  - in-flight payment intent partial unique index
  - webhook/provider event uniqueness indexes
- Add indexes for new lookup fields only where new query paths require them.

### Caching

- No new cache dependency for MVP correctness.
- Maintain deterministic pricing/tax/shipping from explicit inputs and persisted snapshots.

### Oban uniqueness / idempotency

- Webhook worker uniqueness by receipt identity.
- Receipt delivery worker uniqueness by outbox/idempotency key.
- Replay-safe NOOP for duplicate events and retries.

### Telemetry / logging

- Emit/retain telemetry for:
  - checkout start/finalize
  - payment intent creation
  - webhook verification success/failure
  - webhook processing applied/duplicate/failed
  - receipt enqueue/sent/failed
- Ensure logs are PII-safe and contain registry error codes.
