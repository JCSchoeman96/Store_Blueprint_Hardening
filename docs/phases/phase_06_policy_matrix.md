# Phase 06 — Policy matrix pinning (P0)

## Goal
Freeze authorization rules so every client build stays consistent.

## Locked decisions (MUST)
- `Order.user_id` uses Option 1 in this phase:
  - add nullable `user_id`
  - enforce customer own-data policy where `user_id == actor.id`
  - orders with `user_id = nil` are not customer-readable
  - migration MUST create `orders_user_id_index` on `orders.user_id`
- `Admin.SiteSetting` is introduced as provider-config surface with strict constraints:
  - key must be constrained to approved non-secret settings
  - value must be non-secret payloads only
  - API keys/secrets/tokens/passwords are banned in this resource in Phase 06
  - mutation requires role (`admin` or `super_admin`) + recent step-up
  - mutation writes audit evidence
- Visibility law:
  - row visibility MUST be expressed as filter-capable policy checks where possible
  - runtime checks are allowed only for non-row-scoping constraints (role/step-up)
- Step-up context source:
  - `context[:step_up_at_mono_usec]` must come from trusted server-side step-up completion only
  - client-provided timestamps are not trusted
  - missing/stale step-up must deny the action
- Policy enforcement scope in this phase is active resources only:
  - Accounts, Admin, Orders, Payments
  - Content/Catalog/Pricing checks remain deferred-aware until resources exist.

## Must deliver
- `docs/governance/policy_matrix.md` (authoritative)
- `test/store/governance/policy_matrix_test.exs` (gates drift)

## Acceptance gates
- Tests prove: customer own-data access only
- Support cannot mutate catalog/pricing/provider settings
- Editor can only manage content
- Admin can manage catalog/pricing/orders, but refund/provider config requires step-up
- super_admin can do all (still audited)
