# Phase 19 — Catalog (Simple Products Only)

## Objective
Establish a **production-grade product catalog** for a single-tenant ecommerce store using **Ash 3.x** as the source of truth for:

- Product lifecycle (draft → published → archived)
- Pricing inputs for checkout (not order truth — orders remain snapshot-based)
- Inventory-on-hand inputs for reservation logic
- Storefront-safe read surfaces (no ad-hoc querying in `store_web/**`)

This phase unlocks a working storefront for **simple physical products** (no variants, no digital delivery, no subscriptions yet).

---

## Scope
### In-scope
- Catalog domain with simple products
- Categories and images/media references
- Inventory-on-hand per product (as an input to reservation/availability)
- Admin CRUD surfaces (forms pattern), but **keep the UI minimal**
- Storefront read surfaces: list/search/view product

### Explicitly out-of-scope (later phases)
- Digital products (license / download grants)
- Variable products (variants)
- Subscriptions
- Promotions/discounts beyond existing pricing determinism rules
- Full-text search engine (use Postgres ILIKE + indexes for now)

---

## Domain Model

### Domain
- `Store.Catalog` (new)

### Resources

#### `Store.Catalog.Product`
Simple product that can be sold as a line item.

**Key fields (suggested):**
- `id` (UUIDv7 PK)
- `slug` (unique, lowercase, URL-safe)
- `sku` (unique, optional but recommended)
- `title` (required)
- `subtitle` (optional)
- `description` (optional; store as plain text or sanitized HTML)
- `status` (state machine: `:draft | :published | :archived`)
- `currency_code` (ISO 4217)
- `list_price_minor` (integer; minor units, e.g. cents)
- `compare_at_price_minor` (optional)
- `taxable?` (boolean)
- `requires_shipping?` (boolean; true for physical)
- `weight_grams` (optional)
- `is_featured?` (boolean)
- `published_at` (nullable; set on publish)

**Relationships:**
- `belongs_to :category, Store.Catalog.Category`
- `has_many :images, Store.Catalog.ProductImage`
- `has_one :inventory_item, Store.Catalog.InventoryItem`

#### `Store.Catalog.Category`
Product grouping.

**Key fields (suggested):**
- `id`
- `slug` (unique)
- `name`
- `position` (integer; for ordering)
- `is_active?` (boolean)

Relationships:
- `has_many :products, Store.Catalog.Product`

#### `Store.Catalog.ProductImage`
Media reference.

**Key fields (suggested):**
- `id`
- `product_id`
- `url` (string)
- `alt` (string)
- `position` (int)

#### `Store.Catalog.InventoryItem`
On-hand quantity for a product.

**Key fields (suggested):**
- `id`
- `product_id` (unique; 1:1)
- `on_hand` (int; >= 0)
- `track_inventory?` (boolean)

**Important:** Inventory reservation/holds are governed elsewhere (Phase 11). This resource is the *input state* used to decide whether reservations can be created.

---

## Lifecycle & State Machines

### Product status
Use `ash_state_machine` for an explicit lifecycle (simple and auditable):

- `:draft` → `:published` (action: `publish`)
- `:published` → `:draft` (action: `unpublish`) **only if no active carts/reservations** (enforced via check)
- `:draft` → `:archived` (action: `archive`)
- `:published` → `:archived` (action: `archive`)
- `:archived` is terminal

**Why terminal archive?** Traditional and safe: you never “resurrect” historical catalog identities; if you must reintroduce a product, create a new SKU/slug.

---

## Actions

### Product actions
**Write (admin only):**
- `create_draft`
- `update_draft`
- `publish`
- `unpublish`
- `archive`

**Read surfaces (public/user/admin):**
- `read_for_storefront` (published only)
- `read_for_admin` (all statuses)
- `list_for_storefront` (published only, pagination)
- `list_for_admin` (filterable/pagination)

### Inventory actions
- `set_on_hand` (admin)
- `adjust_on_hand` (admin; +/−)

### Category actions
- CRUD + activate/deactivate

### Image actions
- add/update/remove/reorder

---

## Interfaces & Query Contracts (MANDATORY)

### Rule
`lib/store_web/**` must not build queries. Web can only:

1) Parse params → typed query struct
2) Call domain facade

### Domain facades (examples)
Add canonical read/write entrypoints:

- `Store.Catalog.list_products_for_storefront(actor, %Store.Catalog.Queries.ProductIndex{})`
- `Store.Catalog.get_product_for_storefront(actor, slug_or_id)`
- `Store.Catalog.list_products_for_admin(actor, %Store.Catalog.Queries.ProductAdminIndex{})`

### Query structs
Create typed query structs in domain:

- `Store.Catalog.Queries.ProductIndex`
  - `q` (search string)
  - `category` (slug)
  - `sort` (enum: newest/price_asc/price_desc)
  - `page` / `page_size`

- `Store.Catalog.Queries.ProductAdminIndex`
  - includes status filters

**No arbitrary filter passthrough.** Only allow a bounded set of filters/sorts.

---

## Storefront Surfaces (Minimum to be “working ecommerce”)

You do not need a fancy theme yet. You need **real flows**.

### Public pages
- `/shop` — product list (paged)
- `/shop/:slug` — product detail

### Cart integration
- Add-to-cart should reference `product_id` (simple) and create/update cart line.
- Availability check uses:
  - `Product.status == :published`
  - `InventoryItem.on_hand` (if `track_inventory?`)

**Reminder:** Do not decrement on-hand here. Reservations/holds belong to the inventory system (Phase 11) and checkout interlocks (Phase 14).

---

## Data Integrity (DB constraints + indexes)

### Product
- unique index: `slug`
- unique index: `sku` (nullable unique)
- index: `category_id`
- index: `status`
- optional: trigram index on `title` if you want fast search later

### ProductImage
- index: `product_id`
- unique: `(product_id, position)`

### InventoryItem
- unique index: `product_id`
- constraint: `on_hand >= 0`

---

## Performance & Scaling Review
Single-tenant does not mean low traffic. Keep reads fast.

- Storefront reads should be cache-friendly:
  - **Hot**: ETS/Cachex for most-hit product list pages (short TTL)
  - **Warm**: Redis cache for product list + product detail (30–300s TTL)
  - **Cold**: Postgres
- Avoid heavy loads:
  - Storefront list should not `load` deep relationships by default
  - Product detail loads images; avoid category->products recursion
- Pagination required. No “load everything” pages.

---

## Tests (additive)

### Governance/behavior tests
- Only `:published` products appear in storefront read/list
- Archived products are never purchasable
- `unpublish` fails if there are active holds/reservations (stub check if holds not yet wired)
- Inventory on-hand cannot go negative

### Gate alignment
- No `Ash.Query` and no direct `Ash.*` in `store_web/**` for catalog surfaces

---

## Acceptance Criteria
This phase is complete when:

- Admin can create a draft product, set price/currency, add images, set on-hand
- Admin can publish/unpublish/archive products
- Storefront list and detail pages display **published** products only
- Add-to-cart uses product_id and validates published + available
- All access goes through domain facades + typed query structs
- Tests cover storefront visibility + lifecycle + non-negative inventory

---

## Governance Impact
No new global governance document changes are required **if** this phase follows existing rules:

- Web boundary discipline (Phase 15/18)
- Pricing determinism via order snapshots (Phase 10)
- Inventory reservations remain the only decrement/hold mechanism (Phase 11)

If you later introduce product-type branching or bypass reservations, that becomes a governance update (and a new enforcement gate).
