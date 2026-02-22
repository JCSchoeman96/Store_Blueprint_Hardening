# Phase 13 — Tax + Shipping determinism (P0/P1 depending on store)

## Goal
Make shipping selection and tax calculation deterministic, auditable, and free of penny leaks.

## Must deliver
- `docs/governance/tax_shipping.md`
- Deterministic selection rules for shipping rates
- Deterministic tax computation rules
- Evidence snapshots stored on orders (shipping and tax fields)

## Acceptance gates
- Same inputs => identical shipping/tax outputs
- Tie-break determinism for multiple matching shipping rates
- No penny leak (sum of parts equals totals)
- Order snapshots retain shipping/tax evidence without recomputation
