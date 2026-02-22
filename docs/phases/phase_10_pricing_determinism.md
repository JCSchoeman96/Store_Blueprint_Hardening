# Phase 10 — Pricing determinism & stacking (P0)

## Goal
Lock money correctness so totals are deterministic, auditable, and free of penny leaks.

## Must deliver
- `docs/governance/pricing_determinism.md`
- Test suite enforcing determinism + allocation + stacking rules

## Acceptance gates
- Pricing evaluation is deterministic for identical inputs
- Discount allocation sums exactly to the discount amount (no penny leak)
- Tie-breaks select the same promotion consistently
- Applied discounts stored in deterministic order
