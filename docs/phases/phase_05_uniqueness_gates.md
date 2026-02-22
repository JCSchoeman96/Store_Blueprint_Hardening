# Phase 05 — Single-tenant uniqueness gates (P0)

## Goal
Prevent accidental drift into tenant-scoped uniqueness assumptions.

## Locked decisions (MUST)
- Bead chain is fixed for this phase:
  1) docs lock
  2) uniqueness registry
  3) orders.order_ref uniqueness
  4) webhook_receipts uniqueness and NOOP dedupe
  5) governance tests
  6) full gates + closeout
- Webhook receipt duplicates MUST be NOOP:
  - `WebhookReceipt.ingest` uses upsert on identity `:unique_idempotency_key`
  - no updates on conflict
  - duplicate ingest returns existing receipt deterministically
- Email uniqueness is case-insensitive and enforced at DB layer:
  - Ash type: `:ci_string`
  - Postgres storage/enforcement: `citext` + unique index
- Uniqueness registry is governance/test manifest only (no runtime business logic).
- Active-now constraints must exist now; deferred constraints are table-aware gates and become mandatory once their tables exist.

## Acceptance gates
Assert unique constraints exist for:
- users.email
- products.slug
- posts.slug
- variants.sku
- coupons.code
- orders.order_ref
- webhook_receipts.idempotency_key
- provider_events(provider, provider_event_id)
