# Phase 05 — Single-tenant uniqueness gates (P0)

## Goal
Prevent accidental drift into tenant-scoped uniqueness assumptions.

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
