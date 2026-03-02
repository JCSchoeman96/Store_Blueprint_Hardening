# Phase 18 — Ash Code Interfaces & Domain Facades (P0/P1)

**Objective:**
Make the **Ash domain/resources** the only place where authorization-meaningful query and action logic lives.
The web layer becomes a **thin adapter** (params → typed query/input structs → domain facade), and background jobs/API
surfaces call the same facade.

This phase is the missing “interface spine” that unlocks:
- removing ad-hoc `Ash.read/query` usage from `lib/store_web/**`
- consistent, auditable read/write surfaces per consumer (public/user/admin)
- safer AshPhoenix.Form adoption (forms submit to actions, not bespoke logic)
- future `ash_json_api` surfaces that reuse the same contracts

> Single-tenant note: nothing in this phase introduces multi-tenancy. All actor scoping is per-user/role only.

---

## 18.1 Non‑Negotiable Laws

### Law A — Web does not own query semantics
`lib/store_web/**` may not contain authorization-meaningful:
- `Ash.Query.filter/sort/load/limit/offset`
- inline `Ash.Query.*` chains
- ad-hoc relationship loading choices that change policy outcomes

Web may:
- parse params
- normalize them
- call domain facades
- render results

### Law B — Every externally callable operation has a named surface
No “anonymous” reads/writes:
- reads happen via **named read actions** (resource) + **named facade functions** (domain)
- writes happen via **named create/update actions** (resource) + **named facade functions** (domain)

### Law C — Facades accept typed input structs, never raw params
The contract is a struct, not a map.

---

## 18.2 Deliverables

### 1) Domain facade modules
Create one facade per domain:

- `lib/store/orders.ex` → `Store.Orders`
- `lib/store/payments.ex` → `Store.Payments`
- `lib/store/pricing.ex` → `Store.Pricing`

These modules:
- expose **public functions** for each surface
- call **resource code interfaces** or `Ash.read/create/update` using **named actions only**
- normalize errors through `Store.Support.Errors.Normalize` (or your existing error normalizer)

**Rule:** `StoreWeb` never calls resource modules directly for reads/writes; it calls these facades.

### 2) Typed query/input structs (“query contracts”)
Create structs in the domain (not in `StoreWeb`). Examples:

- `lib/store/orders/queries/order_index_query.ex` → `Store.Orders.Queries.OrderIndexQuery`
- `lib/store/orders/queries/order_show_query.ex`
- `lib/store/payments/queries/payment_intent_index_query.ex`

They define:
- allowed filters/sorts
- pagination caps
- safe defaults

### 3) Web param adapters
Web parses + normalizes into the typed structs:

- `lib/store_web/params/order_index_params.ex`
- `lib/store_web/params/order_show_params.ex`

Adapters must:
- reject unknown keys
- cap page size
- coerce types
- produce only domain structs

### 4) Resource code interfaces
For resources that are called from facades frequently, define `code_interface` entries.

Examples (naming rules):
- `:read_for_admin_index`
- `:read_for_user_index`
- `:read_for_api_show`
- `:create_from_cart`
- `:mark_paid`

**Naming constraints:**
- surface names must include the consumer (`admin`, `user`, `public`, `api`) and the intent (`index`, `show`, `export`, `transition`).
- no generic `:read` exposed through the facade.

> Where: define code interfaces in the resource modules that already exist in:
> - `lib/store/orders/order.ex`
> - `lib/store/payments/payment_intent.ex`
> - etc.

---

## 18.3 Canonical Surfaces (Minimum Set)

### Orders
- `Store.Orders.list_for_admin(actor, %OrderIndexQuery{})`
- `Store.Orders.list_for_user(actor, %OrderIndexQuery{})`
- `Store.Orders.get_for_api(actor, %OrderShowQuery{})`

### Payments
- `Store.Payments.list_intents_for_admin(actor, %PaymentIntentIndexQuery{})`
- `Store.Payments.get_intent_for_user(actor, %PaymentIntentShowQuery{})`

### Pricing (admin CRUD surfaces)
- `Store.Pricing.list_shipping_zones_for_admin(actor, %IndexQuery{})`
- `Store.Pricing.create_shipping_zone(actor, attrs)`
- `Store.Pricing.update_shipping_zone(actor, id, attrs)`

**Rule:** anything referenced by LiveView CRUD must exist here before UI work begins.

---

## 18.4 How this interacts with AshPhoenix.Form

AshPhoenix.Form stays in web, but the **action source of truth** is still the resource action.

Guidance:
- LiveView uses `AshPhoenix.Form.for_create/for_update` pointing at the resource action.
- After submit, the LiveView calls back into the domain facade only for follow-up reads/navigation.

**Avoid:**
- LiveView directly calling `Ash.create/update` outside `AshPhoenix.Form`.

---

## 18.5 Enforcement Gates (Add / Tighten)

### Gate 18.1 — `web_no_ash_query`
Fail if `lib/store_web/**` contains:
- `Ash.Query.`

Allowlist only:
- `lib/store_web/params/**` if you choose to use `Ash.Filter` helpers there (prefer not to).

### Gate 18.2 — `web_no_direct_ash_calls`
Fail if `lib/store_web/**` contains:
- `Ash.read(` / `Ash.read!(`
- `Ash.create(` / `Ash.update(` / `Ash.destroy(`

Allowlist:
- AshPhoenix.Form modules are fine; but direct `Ash.*` calls should not exist in controllers/liveviews.

### Gate 18.3 — `surface_naming`
A lightweight test that enumerates “public” facade functions and asserts their names follow:
`(list|get|create|update|delete|transition)_(for)_(public|user|admin|api)`

This prevents a slow drift into generic “do_everything” functions.

---

## 18.6 Risks & Edge Cases

1) **Admin search flexibility**
Don’t rebuild a mini query DSL. Keep the query structs small and explicit.
If you need complex search later, add a dedicated `SearchQuery` struct with a limited vocabulary.

2) **Relationship loading drift**
All `load` choices belong to the named read actions (resource), not web.

3) **Performance regressions**
Every index surface must:
- cap page size
- use explicit sorts
- avoid N+1 by defining `load` sets in the action

4) **Authorization surprises**
Never set `authorize?: false` in facades for web-facing paths.
Only background migrations/maintenance tasks may do so, and they must live outside web.

---

## 18.7 Acceptance Criteria

- `order_api_controller.ex` and `admin_live.ex` no longer contain ad-hoc Ash querying.
- All reads/writes used by web go through domain facade modules.
- Query/input structs exist and are used.
- New enforcement gates are present and `mix check` enforces them.
- No decrease in governance test coverage.

---

## 18.8 Next Phase
Once this spine exists, you can safely proceed to the **commerce expansion phases**:
- Catalog (simple products)
- Storefront pages
- Cart
- Checkout UX + payment integration

Those phases should never introduce new query patterns in web; they must reuse the surfaces defined here.
