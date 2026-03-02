# Phase 19 — Catalog (Simple Products, Variant-First Identity)

## Objective
Establish a production-grade catalog in `Store.Catalog` for simple products while preserving sellable identity laws for later variant phases.

Phase 19 must deliver:
- Product lifecycle (`draft -> published -> archived`) with precise publish semantics.
- Storefront-safe read surfaces (`/shop`, `/shop/:slug`) via domain facades only.
- Variant-first inventory identity now (base variant per product), without introducing Phase 20/21 hold semantics.

## Scope
### In-scope
- Product, base Variant, Category, ProductImage resources.
- Product create flow that atomically creates one default/base variant and one inventory item.
- Admin CRUD surfaces (minimal) and storefront list/detail surfaces.
- Typed query/input contracts and additive governance gates/tests.

### Out-of-scope
- Variant selection UX and multiple variants per product (Phase 25).
- Persistent cart domain and merge semantics (Phase 20).
- Reservation/hold enforcement in cart/add-to-cart (Phase 21).
- Stock messaging in storefront UI.

## Domain Model

### `Store.Catalog.Product`
Key fields:
- `id` (UUIDv7)
- `slug` (required, lowercase, URL-safe, unique)
- `title` (required)
- `subtitle` (optional)
- `description` (optional)
- `status` (`:draft | :published | :archived`)
- `published_at` (`utc_datetime_usec`, nullable)
- `category_id` (nullable)
- `default_variant_id` (required once created)

Relationships:
- `belongs_to :category`
- `belongs_to :default_variant, Store.Catalog.Variant`
- `has_many :variants`
- `has_many :images`

### `Store.Catalog.Variant`
Phase 19 uses exactly one base/default variant per product.

Key fields:
- `id` (UUIDv7)
- `product_id` (required)
- `is_default` (required boolean)
- `sku` (required, unique)
- `title` (optional)
- `currency_code` (required ISO 4217)
- `price_minor` (required integer minor units)
- `compare_at_price_minor` (optional integer minor units)
- `status` (`:active | :archived`)

Relationships:
- `belongs_to :product`
- `has_one :inventory_item, Store.Catalog.InventoryItem` (via `variant_id`)

### `Store.Catalog.Category`
Key fields:
- `id`, `slug`, `name`, `position`, `is_active`

### `Store.Catalog.ProductImage`
Key fields:
- `id`, `product_id`, `url`, `alt`, `position`

### `Store.Catalog.InventoryItem`
Inventory identity remains `variant_id` (no `product_id` identity path).

## Lifecycle Rules

### Product publish semantics (pinned)
- Storefront visibility: `status == :published AND published_at IS NOT NULL`.
- `publish`: sets `status = :published` and `published_at = now()`.
- `unpublish`: sets `status = :draft` and `published_at = NULL`.
- `archive`: allowed from `:draft`/`:published`, terminal afterward.

No hold/reservation blockers are added in Phase 19 lifecycle transitions.

## Slug and SKU Laws
- `products.slug` is required, lowercase, URL-safe, unique.
- `variants.sku` is required and unique in Phase 19 (no nullable SKU behavior).
- Storefront product detail lookup resolves by slug only.

## Variant-First Identity Law
- Product create action must atomically create:
  - Product
  - Exactly one base Variant (`is_default = true`)
  - InventoryItem linked to that variant (`inventory_items.variant_id` unique)
- Action sets `products.default_variant_id` from the created variant.
- Web must not orchestrate multi-step create logic.

## Default Variant Invariants
- `variants.is_default` is required.
- DB partial unique index enforces exactly one default variant per product:
  - unique on `variants(product_id)` where `is_default = true`.
- Domain validation enforces `products.default_variant_id` belongs to the same product.

## Interfaces and Query Contracts
Web boundary remains adapter-only:
1) parse params
2) build typed struct
3) call domain facade
4) render

Facade reads:
- `Store.Catalog.Facade.list_products_for_public/2`
- `Store.Catalog.Facade.get_product_for_public/2`
- `Store.Catalog.Facade.list_products_for_admin/2`
- `Store.Catalog.Facade.get_product_for_admin/2`

Query structs:
- `Store.Catalog.Queries.ProductIndexQuery`
- `Store.Catalog.Queries.ProductAdminIndexQuery`

Input struct:
- `Store.Catalog.Inputs.CartLineInput`
  - accepts `variant_id` or `product_id`
  - if both are present, they must match ownership or return `VALIDATION_ERROR`
  - normalized output is always `variant_id`

## Storefront Surfaces
- `/shop` (list)
- `/shop/:slug` (detail)

UI scope in Phase 19:
- product title, price, images, metadata
- no stock messaging
- no reservation/hold behavior

## Data Integrity (DB)
- `products.slug` unique index
- `products.default_variant_id` is `NOT NULL` with deferred FK to `variants(id)` so product + base variant can be created atomically in one transaction while enforcing referential integrity at commit
- `variants.sku` unique index
- `variants(product_id)` index
- partial unique index on `variants(product_id)` for `is_default = true`
- `products.category_id` index
- `products.status` index
- `product_images(product_id, position)` unique
- `inventory_items.variant_id` unique (existing authoritative index)

## Tests (must exist)
- publish/unpublish/archive transition matrix + storefront visibility predicate
- slug validation/uniqueness + slug detail lookup
- SKU required + unique enforcement
- exactly one default variant invariant
- atomic product create flow (product + base variant + inventory + default_variant_id)
- cart line normalization/mismatch rejection (`VALIDATION_ERROR`)
- no web-boundary drift (`Ash.Query`/direct `Ash.*` in scoped web paths)

## Acceptance Criteria
Phase 19 is complete when:
- Admin can create/update/publish/unpublish/archive products.
- Product create flow consistently creates one default variant and one inventory item.
- Storefront `/shop` and `/shop/:slug` show published products only.
- Cart-line normalization resolves product identifiers to variant identifiers only.
- Governance and gate tests pass with additive surface naming constraints.

## Governance Impact
This phase updates governance documentation and tests to pin:
- variant-first identity for simple products
- canonical `/shop` storefront routing
- additive `_for_public` facade naming allowance only for catalog surfaces
