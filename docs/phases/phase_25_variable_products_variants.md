# Phase 25 — Variable Products (variants + options, without contaminating Orders)

## Goal
Add **variable products** (variants such as Size/Color) while preserving the core blueprint law:

> Orders/Payments remain product-type agnostic.  
> Variants are resolved before checkout; order lines reference the *sellable unit*.

This phase delivers:
- Variant modeling in `Store.Catalog`
- Option/attribute modeling for variant selection
- Inventory and price overrides per variant
- Storefront selection UX (minimal but correct)
- Admin CRUD using AshPhoenix.Forms
- Query surfaces and typed query contracts to keep web clean

## Non-goals (later phases)
- Subscription variants (handled in subscription phases)
- Complex bundle/configurator products
- Per-customer negotiated pricing
- Marketplace multi-tenant (not applicable)

---

## Architecture

### Domain
- Extend `Store.Catalog` (do **not** create a new domain unless you have strong reasons)

### Key concept: “Sellable”
The customer buys a **sellable unit**:
- For simple products: `Product` is the sellable
- For variable products: `ProductVariant` is the sellable

**Order lines must reference:**
- `sellable_type` (`:product | :variant`) OR a single `sellable_id` via polymorphic ref pattern you already use elsewhere
- In UI and checkout, always resolve to the concrete sellable before pricing snapshots.

---

## Resources

### 1) `Store.Catalog.Product` (existing)
Add / confirm:
- `has_variants?` (boolean) or infer from relationships
- `default_variant_id` (nullable) — optional, but improves UX and deep links
- `variant_selection_mode` (atom, optional): `:required | :optional` (default required when variants exist)

### 2) `Store.Catalog.ProductOption`
Defines an option axis (e.g., “Size”, “Color”) for a given product.

**Attributes**
- `id`
- `product_id`
- `name` (string) — display label
- `slug` (string) — stable key (e.g. `size`)
- `position` (integer)
- `selection_required` (boolean, default true)

**Constraints**
- Unique `(product_id, slug)`
- Position index for stable rendering

### 3) `Store.Catalog.ProductOptionValue`
Defines values for an option (e.g., “Small”, “Medium”).

**Attributes**
- `id`
- `product_option_id`
- `name` (string)
- `slug` (string) — stable key (e.g. `m`)
- `position` (integer)

**Constraints**
- Unique `(product_option_id, slug)`

### 4) `Store.Catalog.ProductVariant`
Concrete sellable unit.

**Attributes**
- `id`
- `product_id`
- `sku` (string, unique)
- `title` (string) — optional override (e.g. “T-Shirt / Black / M”)
- `status` (atom) — `:active | :archived`
- `price_override_minor` (integer, nullable) — in minor units (cents)
- `compare_at_price_minor` (integer, nullable)
- `inventory_item_id` (nullable or required based on stock strategy)
- `image_id` (nullable) — variant-specific image

**Constraints / invariants**
- Unique `sku`
- If `product` is `published`, variant must be `active` to be sellable
- If price override set, it must be >= 0
- If inventory tracked, variant must have inventory item

### 5) `Store.Catalog.VariantOptionSelection`
Join table mapping variant to chosen option values.

**Attributes**
- `id`
- `variant_id`
- `product_option_id`
- `product_option_value_id`

**Invariants**
- Unique `(variant_id, product_option_id)` (one value per option per variant)
- Option and value must belong to the same product
- Variant and option must belong to the same product

---

## Actions & policies

### Products
- `create_draft`, `publish`, `unpublish`, `archive`
- `read_published` (public)
- `read_for_admin`

### Variants
- `create` (admin), `update` (admin), `archive`
- `read_sellable` (public but only when product published AND variant active)
- `set_price_override`
- `set_inventory_item` (or manage via `InventoryItem` actions)

### Option axes/values
- admin-only CRUD
- public read via product read surface

### Policy notes
- Public cannot see drafts/archived
- Admin can mutate
- User can only read published/sellable

---

## Query surfaces (keep web clean)

Introduce/confirm domain facade surfaces:
- `Store.Catalog.list_products_for_shop/2` (uses typed `Catalog.ShopQuery`)
- `Store.Catalog.get_product_for_shop!/2` (by slug, loads options, variant availability summary)
- `Store.Catalog.resolve_variant_for_selection/3`
  - inputs: `product_id`, `selection_map` (option_slug => value_slug), `actor`
  - output: `{:ok, variant}` or `{:error, :invalid_selection | :out_of_stock}`

### Typed query contracts
Add structs in domain (not web):
- `Store.Catalog.Queries.ShopQuery`
- `Store.Catalog.Queries.ProductDetailQuery`

Web only parses params → structs.

---

## Storefront UX (minimal but correct)

### Product detail (`/shop/:slug`)
If product has variants:
- Render option selectors in stable order
- Selection must resolve to a variant before enabling “Add to cart”
- Deep link support:
  - `?size=m&color=black` resolves to variant

### Availability summary
For fast UX, provide a “variant availability matrix summary”:
- list all option axes/values
- mark values as selectable based on current selection + stock

Implementation guidance:
- Build a resolver in domain that:
  - loads variants (ids + option selections + in_stock boolean)
  - computes allowed values per axis
- Cache this summary for published products (warm cache TTL 5–30m), invalidate on variant/stock changes

---

## Cart and checkout integration

### Cart items
CartItem should reference the sellable:
- For variable products, cart item must store `variant_id` (not product_id)
- For simple products, cart item stores `product_id`

At checkout:
- pricing snapshots and inventory reservations must operate on the concrete sellable (variant/product)
- no special-case logic in Orders beyond “resolve sellable” abstraction

---

## Data integrity & DB indexes (required)
- `product_options(product_id, slug)` unique
- `product_option_values(product_option_id, slug)` unique
- `product_variants(product_id)` index
- `product_variants(sku)` unique
- `variant_option_selections(variant_id, product_option_id)` unique
- `variant_option_selections(product_option_value_id)` index
- If inventory is per variant: `inventory_items(variant_id)` unique or FK index depending on model

---

## Tests (minimum)
- Variant resolution:
  - valid selection resolves correct variant
  - invalid/partial selection rejected when required
- Stock:
  - out-of-stock variant cannot be added to cart
  - changing stock invalidates cached availability summary
- Pricing:
  - variant price override used in checkout pricing snapshot
  - base product price used when override absent (if allowed)
- Policy:
  - public cannot read drafts/archived variants
- Determinism:
  - selection map sorting is deterministic (no map iteration randomness)

---

## Acceptance criteria
- Admin can create product options, values, variants, and assign selections
- Storefront product detail allows selecting options and adds the correct variant to cart
- Checkout uses variant price/stock correctly
- No `Ash.Query` logic appears in `lib/store_web/**`; everything routes through domain read surfaces

---

## Governance impact
No new laws are required **if** you maintain existing blueprint discipline:
- web adapter only
- domain read/write surfaces only
- deterministic selection + snapshot pricing
- inventory reservations operate on concrete sellable units
