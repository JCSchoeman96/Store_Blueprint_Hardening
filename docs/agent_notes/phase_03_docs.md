# Phase 03 Docs Notes

## Links Consulted (Hexdocs / web search)
- https://hexdocs.pm/ash/policies.html
- https://hexdocs.pm/ash/dsl-ash-policy-authorizer.html
- https://hexdocs.pm/ash/Ash.Type.Enum.html
- https://hexdocs.pm/ash_authentication/integrating-ash-authentication-and-phoenix.html
- https://hexdocs.pm/ash_authentication_phoenix/liveview.html
- https://hexdocs.pm/ash_authentication_phoenix/AshAuthentication.Phoenix.Router.html

## What the Docs Recommend Now
- Keep role authorization explicit with deny-by-default policy posture.
- Use Ash policy authorizer checks as the primary authorization gate.
- Keep audit evidence append-only with create/read-only resources.
- Scrub sensitive fields before persistence and avoid storing raw provider payloads in generic audit metadata.
- Use authenticated actor/session context in web routes and LiveView mounts while keeping web logic thin.

## What We Will Implement (Decisions)
- RBAC source of truth is `RoleAssignment`; do NOT add `role` column to `Store.Accounts.User`.
- Pin role enum values: `super_admin`, `admin`, `editor`, `support`, `customer`.
- `RoleAssignment` must enforce uniqueness on `(user_id, role)`.
- `RoleAssignment.assigned_by` is nullable for bootstrap/system contexts only; admin operations must set it.
- `AuditLog` is append-only (`create` + `read` only) and includes:
  - `actor_id`, `action`, `resource`, `record_id`, `request_id`, `meta`, `payload_sha256`, timestamps.
- `AuditLog.meta` must be scrubbed and bounded:
  - max serialized bytes: 8192
  - max keys: 50
  - sensitive key denylist scrubbed
  - oversized/unknown large values dropped.
- Audit insertion occurs via an `after_action` change on admin mutations so the resulting `record.id` is available.
- `after_action` audit change fails closed when actor is absent, except explicit system/bootstrap context.
- Bootstrap contract uses a mix task to create `RoleAssignment(super_admin)` and write `AuditLog`; it never mutates `User.role`.
- Admin web flows remain thin and call Ash actions only.

## Version Pins / Breaking Changes
- No new package families planned beyond Phase 00 pins.
- Breaking change watch:
  - Ash policy DSL/check behavior should be re-verified on Ash minor upgrades.
  - Audit metadata shape is a contract; changes require governance doc + test updates.
  - Role enum set is pinned; adding roles requires policy matrix update and drift tests.

## Performance & Scaling Review
- Hot paths:
  - Role checks on admin mutations and support tooling.
  - Audit writes on every admin mutation.
- Warm paths:
  - Audit reads by actor/action/time in admin UI.
- Cold paths:
  - Long-range investigation and export queries.
- Indexes:
  - `audit_logs`: indexes on `inserted_at`, `actor_id`, `action`, `resource`, `request_id`.
  - `role_assignments`: unique index on `(user_id, role)` and read index on `role`.
- TTL:
  - No TTL in Phase 03; retention policy handled in retention phase governance.
- Invalidation:
  - If role or audit feeds are cached later, invalidate on new role assignments/audit entries.
- PubSub:
  - Optional admin activity feed can broadcast minimal audit events; not required in Phase 03.
