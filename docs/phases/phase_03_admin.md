# Phase 03 — Admin RBAC + Audit (P0)

## Acceptance gates
- Customer denied admin
- Admin mutation creates audit entry
- AuditLog has no update/destroy actions
- Audit metadata is scrubbed (no raw webhook payload)
