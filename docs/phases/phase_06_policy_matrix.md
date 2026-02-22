# Phase 06 — Policy matrix pinning (P0)

## Goal
Freeze authorization rules so every client build stays consistent.

## Must deliver
- `docs/governance/policy_matrix.md` (authoritative)
- `test/store/governance/policy_matrix_test.exs` (gates drift)

## Acceptance gates
- Tests prove: customer own-data access only
- Support cannot mutate catalog/pricing/provider settings
- Editor can only manage content
- Admin can manage catalog/pricing/orders, but refund/provider config requires step-up
- super_admin can do all (still audited)
