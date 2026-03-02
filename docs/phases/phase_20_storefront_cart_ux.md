# Phase 20 — Storefront + Cart UX (LiveView, no query drift)

## Goal

Deliver a **usable storefront** (browse → product detail → cart → start checkout) that is:
- **Ash-first** (resource actions + code interfaces as the truth)
- **Web-thin** (no authorization-meaningful query logic in `store_web`)
- **Deterministic** (cart → order snapshot is stable and replay-safe)
- **Enterprise-safe** (no side effects in cart flows; checkout start is idempotent)

This phase intentionally targets **simple products only** (from Phase 19). Digital, variants, and subscriptions come later.

---

## Scope

### In scope
- Public storefront pages (LiveView):
  - `/shop` product listing (search/sort/filter within a vetted “browse query contract”)
  - `/shop/:slug` product detail
  - `/cart` cart view + quantity update + remove line
- Cart persistence:
  - Guest carts via `cart_token` cookie
  - User carts via `user_id` linkage (merge guest → user on login)
- Checkout start (handoff):
  - “Start checkout” creates an **Order draft** (immutable line snapshots) from cart and transitions into the existing checkout interlock pipeline (Phase 14).
- Inventory safety:
  - **No inventory decrement** during browsing/cart
  - **Inventory reservation** created at checkout start (Phase 11 semantics), with expiration

### Out of scope (explicit)
- Payment provider UI/redirect screens (gateway-specific) — Phase 21+
- Digital delivery, variants, subscriptions — later phases
- Advanced promotions/coupons — later phases
- Multi-tenant marketplace behaviors — not applicable (single-tenant blueprint)

---

## Architectural Laws (must hold)

1. **No ad-hoc querying in web**
   - `lib/store_web/**` must not construct `Ash.Query` or call `Ash.read/create/update/destroy` directly.
   - Web converts params → domain query contract struct → calls domain facade functions.

2. **Cart has zero side effects**
   - Cart actions must never enqueue Oban jobs, send HTTP, or send email.
   - Cart must not mutate payment/order state.

3. **Order is created once**
   - Checkout start must be **idempotent** per cart + actor (e.g., `idempotency_key` or `cart_id` uniqueness on “converted”).

4. **Reservations are created at checkout start**
   - Reservations expire.
   - Payment success interlock must confirm reservation validity (or fail safely).

---

## Domain Model

### New Domain: `Store.Carts`

**Resources**
- `Store.Carts.Cart`
  - `id` (uuid v7)
  - `token` (string, unique; used for guests)
  - `user_id` (nullable)
  - `status` (`:active | :converted | :abandoned`)
  - `converted_order_id` (nullable)
  - `inserted_at/updated_at`
- `Store.Carts.CartItem`
  - `id` (uuid v7)
  - `cart_id`
  - `product_id`
  - `qty` (integer, >= 1)
  - Uniqueness: `unique(cart_id, product_id)`

**Key invariants**
- CartItem.qty must be >= 1
- CartItem.qty must not exceed a configured max per line (anti-abuse, e.g., 99)
- Only one active cart per user (optional but recommended)
- Only one active cart per token (required)

**Policies**
- Guest access: token-scoped only (actor may be nil, token proves scope)
- User access: user owns cart
- Admin: read-only (unless you want support tooling later)

### Query Contracts (domain-owned)

- `Store.Catalog.Queries.ProductBrowseQuery`
  - `q` (search string)
  - `category_slug`
  - `sort` (`:newest | :price_asc | :price_desc`)
  - `page`, `page_size` (bounded)
- `Store.Carts.Queries.CartLoadQuery`
  - `token`
  - `preload` (strict allowlist: items + product minimal fields)

Web modules parse/normalize params into these structs. Domain validates them.

---

## Canonical Domain Facades (entrypoints)

These functions are the only things the web layer should call.

### Catalog read surfaces
- `Store.Catalog.list_products_for_storefront(actor, %ProductBrowseQuery{})`
- `Store.Catalog.get_product_for_storefront(actor, slug)`

### Cart surfaces
- `Store.Carts.get_or_create_cart_for_token(actor, token)`
- `Store.Carts.merge_cart_token_into_user(token, user)` (on login)
- `Store.Carts.add_item(actor, token, product_id, qty)`
- `Store.Carts.update_item_qty(actor, token, product_id, qty)`
- `Store.Carts.remove_item(actor, token, product_id)`
- `Store.Carts.get_cart_view(actor, token)` (returns read model for rendering)

### Checkout handoff surface
- `Store.Checkout.start_from_cart(actor, token, %CheckoutStartInput{})`
  - Creates order snapshots from cart
  - Creates inventory reservations for each line
  - Marks cart as converted (idempotent)
  - Returns `order_id` + next-step metadata

---

## Web UX Surfaces (LiveView)

### Storefront
- `StoreWeb.ShopLive.Index`
  - Uses `StoreWeb.Params.ProductBrowseParams` → `%ProductBrowseQuery{}`
  - Calls `Store.Catalog.list_products_for_storefront/2`
- `StoreWeb.ShopLive.Show`
  - Calls `Store.Catalog.get_product_for_storefront/2`

### Cart
- `StoreWeb.CartLive`
  - Ensures `cart_token` cookie exists (generate if missing)
  - Reads cart via `Store.Carts.get_cart_view/2`
  - Uses AshPhoenix.Forms **only** if it reduces duplication (qty update/remove). Otherwise call domain facade functions.

### Checkout start
- Cart “Start checkout” action calls `Store.Checkout.start_from_cart/3`
- Redirect to checkout route you already have (or a placeholder if not yet built)

---

## Reservation Strategy (Phase 11 alignment)

At checkout start:
- Create one reservation per order line:
  - `reservation_scope`: `product_id`
  - `qty`
  - `expires_at` (e.g., 10–15 minutes)
  - `order_id` reference

On payment success:
- The payment interlock must:
  - verify reservations exist and are not expired
  - atomically convert reservations → decrements (or finalize inventory ledger entries)
  - only then mark order paid

Failure mode:
- If payment succeeds after reservation expiry:
  - the interlock must **not** mark order paid
  - follow refund flow or mark payment as “requires_review” (policy choice)

---

## Performance & Caching (pragmatic defaults)

Storefront reads will be hot.

- Cache product listing results (hot cache) for short TTL (e.g., 10–30s)
- Cache product detail by slug for short TTL (e.g., 30–120s)
- Invalidation triggers:
  - product publish/unpublish
  - price change
  - inventory on_hand change (only if you display stock counts)

Avoid caching anything actor-sensitive unless the actor is part of the cache key.

---

## Tests (minimum)

### Governance-level tests
- Web boundary (already gated): ensure no `Ash.Query` in web.
- Cart has no side effects: no Oban enqueue, no HTTP client in cart flows (static gate + test optional).

### Functional tests
- Guest cart token creates cart and is stable across requests.
- Add/update/remove cart items works and validates qty.
- Merge guest cart into user on login:
  - merges quantities (defined rule) or prefers user cart (defined rule), but deterministic.
- Checkout start is idempotent:
  - repeated calls return same `order_id` and do not duplicate reservations or order lines.
- Checkout start fails if:
  - product is unpublished
  - requested qty exceeds available/reservable inventory

---

## Acceptance Criteria (Definition of Done)

- `/shop` lists published products with paging and stable sorting.
- `/shop/:slug` shows product detail for published products.
- `/cart` supports guest + user, add/update/remove items.
- “Start checkout” produces:
  - an Order with immutable snapshots (Phase 09)
  - Reservations created (Phase 11)
  - Cart marked converted with a stable `converted_order_id`
- No missed notifications regressions in checkout path (already gated).
- No `Ash.Query` or direct `Ash.*` calls exist in `lib/store_web/**`.

---

## Governance Impact

- No new global governance laws required **if** you follow existing boundary rules and gates.
- If you later add “inventory display” or “low-stock warnings” to storefront, consider adding a **cache invalidation policy** to governance docs.
