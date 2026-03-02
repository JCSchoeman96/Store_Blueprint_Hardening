# Phase 20 - Storefront + cart UX (checkout draft handoff)

## GOAL

Implement Phase 20 with persistent carts, deterministic guest->user merge, and checkout draft handoff to a read-only `/checkout` placeholder, while explicitly deferring reservations/snapshots/payment path to Phase 21.

## LINKS CONSULTED

- `AGENTS.md`
- `docs/phases/phase_20_storefront_cart_ux.md`
- `docs/phases/phase_21_checkout_payment_integration_mvp.md`
- `docs/governance/policy_matrix.md`
- `docs/governance/route_inventory.md`
- `docs/governance/performance_scaling.md`
- `docs/governance/observability_slos.md`
- `docs/governance/enforcement_gates.md`
- `docs/governance/side_effects_quarantine.md`
- `docs/governance/checkout_interlocks.md`
- `docs/governance/inventory_reservations.md`
- `docs/agent_notes/phase_19_docs.md`
- `lib/store_web/router.ex`
- `lib/store_web/live/shop_live/index.ex`
- `lib/store_web/live/shop_live/show.ex`
- `lib/store/catalog/facade.ex`
- `lib/store/orders/domain.ex`
- `lib/store/support/governance/surface_registry.ex`

External references:
- https://hexdocs.pm/ash/code-interfaces.html
- https://hexdocs.pm/phoenix_live_view/Phoenix.LiveView.html#module-streams
- https://hexdocs.pm/plug/Plug.Conn.html#put_resp_cookie/4
- https://hexdocs.pm/oban/2.18.3/Oban.html#module-unique-jobs

## DECISION PINS

1. Cart line identity is `variant_id` only.
2. Guest->user merge law is deterministic sum with clamp (max line qty 99) and no silent line drop.
3. Merge idempotency is modeled via guest-cart marker (`carts.merged_into_cart_id`) rather than a separate merge-events table in Phase 20.
4. Checkout draft idempotency key is DB unique `(cart_id, cart_version)`.
5. `checkout_key` is random opaque token and is never derived from cart-line contents.
6. Cart `version` is mutation-only and increments in the same transaction as line writes.
7. `/checkout` in Phase 20 is read-only placeholder by `checkout_key`; no pricing/shipping/payment side effects.
8. Reservations, priced snapshots, and cart conversion remain Phase 21 scope.
9. Web layer remains adapter-only and uses typed params -> domain facade interfaces.
10. Essential telemetry for this phase: `carts.get`, `carts.mutate`, `carts.merge`, `checkout.start_from_cart`.
11. CheckoutDraft access: user drafts require matching actor.user_id; guest drafts require matching cart_token. checkout_key is not bearer auth.

## PLAN

1. Docs-first alignment:
   - rewrite Phase 20 phase doc to legislative lock scope
   - update policy matrix for carts/checkout drafts
   - update route inventory for `/cart` and `/checkout`
   - update observability telemetry list for cart reads/merge
2. Implement data model/resources/contracts:
   - carts/cart_items/checkout_drafts schema + constraints
   - `Store.Carts` domain resources and typed contracts
   - `Store.Checkout` domain resource/contracts
3. Implement facades/orchestration:
   - cart CRUD + merge + versioning
   - checkout draft `start_from_cart` and `get_draft_for_user`
4. Implement web adapters and LiveViews:
   - cart token cookie plumbing
   - `/cart` LiveView
   - `/checkout` placeholder LiveView
   - shared auth hook merge trigger
5. Add domain/web/governance tests and run `mix check`.

## DONE

- Created Phase 20 bead tree and claimed docs-first bead.
- Added phase note and locked scope/decision pins.
- Rewrote `docs/phases/phase_20_storefront_cart_ux.md` to final scope:
  - checkout draft handoff only
  - no reservations/snapshots/cart conversion in this phase
- Updated `docs/governance/policy_matrix.md` with carts/checkout drafts matrix rows.
- Updated `docs/governance/route_inventory.md` to list `/cart` and `/checkout` as active public routes.
- Updated `docs/governance/observability_slos.md` telemetry list to include `carts.get` and `carts.merge`.

## NEXT

1. Implement migrations/resources/contracts for carts and checkout drafts.
2. Implement domain facades + orchestration with optimistic cart versioning.
3. Implement web routes + LiveViews + shared auth merge trigger.
4. Add/adjust tests and run `mix check`.

## BLOCKERS

- None currently.

## COMMANDS RUN

- `bd dolt test`
- `bd status`
- `bd ready`
- `bd --sandbox create ...`
- `bd --sandbox update ... --parent ...`
- `bd --sandbox dep add ...`
- `bd --sandbox update store_blueprint-7yf.12.1 --claim`
- `sed ...`
- `rg ...`
- `mix phx.routes`
- `mix check`

## GATES

- Docs-first requirement satisfied before Phase 20 code mutations.
- Bead claimed before implementation work.

## PERFORMANCE & SCALING REVIEW

- Hot paths touched in this phase:
  - `/shop` list/read integration with add-to-cart
  - `/cart` read and mutation path
  - checkout draft start from cart
- Query/load posture:
  - cart read path must avoid N+1 by loading cart lines + minimal variant/product snapshot fields intentionally.
- Index requirements pinned:
  - active cart uniqueness by token and user
  - `cart_items(cart_id, variant_id)` unique
  - `checkout_drafts(cart_id, cart_version)` unique
  - `checkout_drafts(checkout_key)` unique
- Caching:
  - no new cache layer in Phase 20 (explicit deferral).
- Idempotency/concurrency:
  - merge idempotency via guest marker
  - draft idempotency via `(cart_id, cart_version)`
  - cart mutation guarded by optimistic version law.
- Telemetry:
  - `[:store, :carts, :get]`
  - `[:store, :carts, :mutate]`
  - `[:store, :carts, :merge]`
  - `[:store, :checkout, :start_from_cart]`
