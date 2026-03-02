# Phase 20 — Storefront + Cart UX (LiveView, no query drift)

## Goal

Deliver a usable storefront flow (browse -> product detail -> cart -> checkout draft handoff) that is:
- Ash-first (resource actions + code interfaces are the truth)
- Web-thin (no authorization-meaningful query logic in `store_web`)
- Deterministic (cart mutation + merge + draft idempotency are replay-safe)
- Enterprise-safe (no side effects in cart flows; no payment/order finalization in web)

This phase targets simple products from Phase 19 only.

---

## Scope

### In scope
- Public storefront pages (LiveView):
  - `/shop` product listing
  - `/shop/:slug` product detail
  - `/cart` cart view + quantity update + remove line
- Cart persistence:
  - guest carts via `cart_token` cookie
  - authenticated carts via `user_id`
  - deterministic guest -> user merge
- Checkout start handoff:
  - cart "Start checkout" creates/reuses a checkout draft keyed by `(cart_id, cart_version)`
  - returns random opaque `checkout_key`
  - redirects to `/checkout?checkout_key=...`
- `/checkout` placeholder LiveView:
  - read-only draft summary
  - no pricing/shipping/payment logic

### Out of scope
- Inventory reservations/holds at checkout start (Phase 21)
- Priced order snapshots at checkout start (Phase 21)
- Cart conversion/locking on checkout start (Phase 21)
- Payment provider redirect/intent path (Phase 21+)
- Digital delivery, variants, subscriptions

---

## Architectural Laws (must hold)

1. No ad-hoc querying in web
   - `lib/store_web/**` must not construct `Ash.Query` or call direct `Ash.read/create/update/destroy`.
   - Web converts params -> typed query/input struct -> domain facade.

2. Cart has zero side effects
   - Cart actions must not enqueue Oban jobs, send HTTP, or send email.

3. Checkout draft idempotency is DB-keyed
   - Unique `(cart_id, cart_version)` in `checkout_drafts`.
   - `checkout_key` is random opaque token and never derived from cart lines.

4. Cart versioning is mutation-only
   - `version` increments in the same transaction on add/update/remove/merge.
   - Reads never increment `version`.
   - Optimistic lock law applies (`where version = old_version`).

---

## Domain Model

### New Domain: `Store.Carts`

**Resources**
- `Store.Carts.Cart`
  - `id` (uuid v7)
  - `token` (string; guest lookup key)
  - `user_id` (nullable)
  - `status` (`:active | :abandoned`)
  - `merged_into_cart_id` (nullable)
  - `version` (integer; starts at 1)
  - `inserted_at/updated_at`
- `Store.Carts.CartItem`
  - `id` (uuid v7)
  - `cart_id`
  - `variant_id`
  - `qty` (integer, 1..99)
  - uniqueness: `unique(cart_id, variant_id)`

### New Domain: `Store.Checkout`

**Resources**
- `Store.Checkout.CheckoutDraft`
  - `id` (uuid v7)
  - `checkout_key` (unique random opaque token)
  - `cart_id`
  - `cart_version`
  - `user_id` (nullable)
  - `status` (`:open | :consumed | :expired`)
  - `inserted_at/updated_at`

**Key invariants**
- Active cart lookup rule:
  - authenticated actor: load by `user_id`
  - guest actor: load by `token`
- Merge law:
  - merge by `variant_id`
  - sum qty and clamp to max per line
  - idempotent via `guest_cart.merged_into_cart_id`
- Draft idempotency law:
  - unique `(cart_id, cart_version)`

---

## Canonical Domain Facades (entrypoints)

### Catalog read surfaces
- `Store.Catalog.Facade.list_products_for_public(actor, query)`
- `Store.Catalog.Facade.get_product_for_public(actor, slug)`

### Cart surfaces
- `Store.Carts.Facade.get_cart_for_user(actor, token)`
- `Store.Carts.Facade.get_cart_view_for_user(actor, token, %CartLoadQuery{})`
- `Store.Carts.Facade.add_item_for_user(actor, token, %CartItemInput{})`
- `Store.Carts.Facade.update_item_qty_for_user(actor, token, %CartItemInput{})`
- `Store.Carts.Facade.remove_item_for_user(actor, token, variant_id)`
- `Store.Carts.Facade.merge_token_into_user_for_user(user, token)`

### Checkout draft surfaces
- `Store.Checkout.start_from_cart(actor, token, %CheckoutStartInput{})`
- `Store.Checkout.get_draft_for_user(actor, checkout_key)`

---

## Web UX Surfaces (LiveView)

### Storefront
- `StoreWeb.ShopLive.Index`
- `StoreWeb.ShopLive.Show`

### Cart
- `StoreWeb.CartLive`
  - ensures `cart_token` cookie exists
  - reads cart via cart facade
  - add/update/remove via typed params + facades

### Checkout placeholder
- `StoreWeb.CheckoutLive.Placeholder`
  - read-only `checkout_key` lookup
  - no payment mutations

### Auth merge trigger
- Merge guest cart into user via shared auth hook path (not controller-only).

---

## Cookie Security Pins

`cart_token` cookie must use:
- `http_only: true`
- `same_site: "Lax"`
- finite `max_age`
- `secure: true` in production
- random non-guessable token

---

## Telemetry (essential)

- `[:store, :carts, :get]`
- `[:store, :carts, :mutate]`
- `[:store, :carts, :merge]`
- `[:store, :checkout, :start_from_cart]`

No cache layer implementation is required in this phase.

---

## Tests (minimum)

### Governance-level tests
- Web boundary gates remain green.
- Uniqueness registry includes cart and checkout draft constraints.
- Policy matrix includes cart and checkout draft access rows.

### Functional tests
- Guest cart token creates stable cart.
- Add/update/remove cart items validates qty bounds.
- Merge guest cart into user is deterministic and replay-safe.
- Cart version increments on mutation only.
- Checkout draft start is idempotent for same `(cart_id, cart_version)`.
- Cart mutation yields a new checkout draft for next start.
- Checkout start rejects empty cart or unpublished sellables.

### Regression tests
- Checkout start creates no reservations.
- Checkout start writes no priced snapshot.
- Checkout start does not convert/lock cart.

---

## Acceptance Criteria (Definition of Done)

- `/shop` and `/shop/:slug` render published products.
- `/cart` supports guest + user add/update/remove.
- Start checkout returns stable `checkout_key` for same cart version and redirects to `/checkout`.
- `/checkout` placeholder is read-only.
- No `Ash.Query` or direct `Ash.*` calls in `lib/store_web/**`.
- `mix check` passes.

---

## Governance Impact

No new global law is required if this phase follows existing web-boundary and side-effects-quarantine rules.

Phase 21 will own reservation/snapshot/payment semantics.
