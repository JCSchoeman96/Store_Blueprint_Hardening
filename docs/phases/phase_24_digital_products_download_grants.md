# Phase 24 — Digital Products (assets, download grants, signed URLs, revocation)

## Goal
Add **digital product fulfillment** without contaminating Orders/Payments logic.

Principle: **Orders remain product-type agnostic.** Digital delivery is a *post-payment fulfillment* concern.
We do not introduce a new order type.

This phase delivers:
- A catalog linkage between products/variants and digital assets
- Post-payment issuance of download grants (idempotent + auditable)
- Signed URL downloads (short-lived)
- Revocation on refunds (policy-driven)

## Scope
### In-scope
- `Store.Digital` domain + resources: `DigitalAsset`, `ProductDigitalLink`, `DownloadGrant`
- Issuance worker flow triggered after confirmed payment application
- Signed URL generation through a provider adapter (S3/Wasabi/etc.)
- Grant expiry + optional download counters
- Refund-driven revocation semantics (configurable policy)
- Admin CRUD for assets + links (AshPhoenix.Form)

### Out-of-scope (later)
- Streaming/video DRM
- Watermarking
- Client-side download manager
- Per-file encryption at rest beyond object storage standard
- Multi-tenant access control (single-tenant blueprint)

## Architecture
### Domain
- `Store.Digital` (new)

### Resources
#### 1) `Store.Digital.DigitalAsset`
Represents a downloadable item (file) and its storage locator.

**Recommended attributes**
- `id` (uuidv7)
- `key` (string, unique) — internal stable identifier (e.g. `ebook_nutrition_2026_pdf`)
- `title` (string)
- `content_type` (string) — `application/pdf`, etc.
- `byte_size` (integer)
- `storage_provider` (atom/string) — `:s3`
- `storage_bucket` (string)
- `storage_object_key` (string)
- `checksum_sha256` (string, optional but recommended)
- `status` (atom) — `:active | :archived`

**Policies**
- Public: no access
- User: read only via grants
- Admin: full CRUD

#### 2) `Store.Digital.ProductDigitalLink`
Links a `Catalog.Product` or `Catalog.ProductVariant` to one or more assets.

**Recommended attributes**
- `id`
- `product_id` (nullable) OR `variant_id` (nullable) — exactly one required
- `digital_asset_id`
- `quantity` (integer, default 1) — for bundles (optional)
- `position` (integer) — stable ordering

**Invariants**
- Exactly one of `product_id`/`variant_id` must be set
- Unique link per (product/variant, asset)

#### 3) `Store.Digital.DownloadGrant`
Represents a customer's right to download a specific asset derived from a paid order line.

**Recommended attributes**
- `id`
- `order_id`
- `order_line_item_id`
- `digital_asset_id`
- `actor_user_id` (or `customer_id`, depending on your auth model)
- `status` — `:active | :revoked | :expired`
- `issued_at`
- `expires_at` (nullable)
- `max_downloads` (nullable)
- `download_count` (integer, default 0)
- `revoked_reason` (nullable)
- `idempotency_key` (string) — optional, but DB uniqueness is the real safety net

**Invariants / constraints**
- Unique `(order_line_item_id, digital_asset_id)` (DB unique index)
- `download_count <= max_downloads` when `max_downloads` set
- `expires_at` in future at issue time if set

**Policies**
- User may read their own grants only
- User may generate a signed download URL only when `status == :active` and not expired and within count
- Admin may revoke

## Fulfillment flow
### Post-payment issuance (idempotent)
Issuance must happen **after** confirmed payment success has been applied via interlocks.

Pattern:
1. Payment webhook receipt → worker verifies/normalizes → calls `Store.Payments.apply_payment_success_once/…`
2. After order transitions to paid, enqueue a **DigitalGrantIssuer** worker:
   - idempotent job keyed by `order_id`
3. Issuer:
   - loads paid order lines
   - resolves digital assets via `ProductDigitalLink` (product/variant aware)
   - for each `(order_line_item_id, asset_id)`:
     - create grant with `return_notifications?: true`
     - rely on DB uniqueness to prevent duplicates on replay

### Signed URL generation
Implement a provider adapter:
- `Store.Digital.StorageProvider` behaviour
  - `sign_download_url(asset, opts) :: {:ok, url} | {:error, reason}`

Rules:
- Signed URLs must be **short-lived** (e.g. 60–300s)
- Do not expose raw bucket/object keys to clients (except via the signed URL itself)

### Download endpoint
Provide a LiveView or controller route:
- Validates actor owns the grant
- Validates not expired/revoked/over limit
- Increments download counter (optimistic lock)
- Returns a redirect to signed URL

## Refund-driven revocation
On refund transitions:
- Decide policy:
  - **strict**: revoke on any successful refund
  - **threshold**: revoke only if refunded >= (line total) or order is marked refunded
- Encode in `Store.Payments.Refunds` side-effect worker, not in web

Ensure idempotency:
- revocation action is replay-safe (`status` already revoked => no-op)

## Caching & performance
- Digital asset metadata is cold/warm data: cache in Redis (TTL 30m–24h)
- Download grants are user-specific; cache minimally (short TTL) to avoid leaks
- Signed URL generation should not hit DB more than necessary; load grant+asset once

## Tests (minimum)
- Paid order with digital-linked product creates grants exactly once
- Duplicate payment webhook / replay runs do not duplicate grants
- Download denied when revoked/expired/exceeds limit
- Refund triggers revoke according to policy
- Signed URL generation called with correct TTL

## Acceptance criteria
- Admin can create assets and link them to products/variants
- Customer buys digital product, then sees “Downloads” section and can download successfully
- Replays do not duplicate grants, and revocation works on refund

## Governance impact
No new global laws required if existing rules are respected:
- No outbound IO in web; signing happens in domain/provider modules
- State transitions happen in workers/interlocks
- Idempotency enforced via unique DB constraints + replay-safe workers
