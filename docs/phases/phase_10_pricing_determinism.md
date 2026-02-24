# Phase 10 — Pricing determinism & stacking (P0)

## Goal
Lock money correctness so totals are deterministic, auditable, and free of penny leaks.

## Must deliver
- `docs/governance/pricing_determinism.md`
- `docs/governance/immutable_snapshots.md` pin for denormalized line-item evidence fields (`sku_snapshot`, `product_title_snapshot`, variant descriptors) used by pricing/order snapshot writes
- Test suite enforcing determinism + allocation + stacking rules

## Acceptance gates
- Pricing evaluation is deterministic for identical inputs
- Discount allocation sums exactly to the discount amount (no penny leak)
- Tie-breaks select the same promotion consistently
- Applied discounts stored in deterministic order
- Pricing snapshot evidence writes are create-only (no runtime updates/backfills of existing snapshot rows)
