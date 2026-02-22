# Phase 03 — Admin RBAC + Audit (P0)

## Goal
Add policy-first admin governance with append-only audit evidence.

## Locked decisions
- RBAC source of truth is `RoleAssignment`; do NOT add `role` to `Store.Accounts.User`.
- Role enum values are pinned: `super_admin`, `admin`, `editor`, `support`, `customer`.
- `RoleAssignment` must enforce unique `(user_id, role)`.
- `assigned_by` may be nil only for bootstrap/system context.
- `AuditLog` schema includes: `actor_id`, `action`, `resource`, `record_id`, `request_id`, `meta`, `payload_sha256`, timestamps.
- `AuditLog` remains append-only (create/read only).
- `meta` is scrubbed and bounded:
  - max bytes: 8192
  - max keys: 50
  - sensitive key denylist scrubbed
  - oversized large values dropped.
- Audit writes are enforced via Ash `after_action` changes on admin mutations.
- `after_action` audit changes fail closed if actor is missing, except explicit bootstrap/system context.
- Bootstrap uses `mix store.bootstrap.super_admin` to create `RoleAssignment(super_admin)` and write `AuditLog`.

## Acceptance gates
- Customer denied admin
- Admin mutation creates audit entry
- AuditLog has no update/destroy actions
- Audit metadata is scrubbed (no raw webhook payload)
- Audit metadata caps enforced (<= 8KB, <= 50 keys)
