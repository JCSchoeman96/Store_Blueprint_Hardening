# Phase 03 Docs Notes

## Links Consulted (Hexdocs / web search)
- https://hexdocs.pm/ash/policies.html
- https://hexdocs.pm/ash/authorizers.html
- https://hexdocs.pm/phoenix/Phoenix.Controller.html
- https://hexdocs.pm/oban/
- https://hexdocs.pm/elixir/Logger.html
- https://hexdocs.pm/phoenix_live_view/Phoenix.LiveView.html
- https://hexdocs.pm/ash_postgres/
- https://hexdocs.pm/ecto/Ecto.Changeset.html

## What the Docs Recommend Now
- Keep role authorization explicit and deny-by-default in policy definitions.
- Store audit events as append-only evidence; avoid mutable audit records.
- Keep sensitive metadata redacted/minimized in logs and audit payloads.
- Enforce sensitive operations with stronger proofs (step-up window + actor role checks).

## What We Will Implement (Decisions)
- Define role model (`super_admin`, `admin`, `editor`, `support`, `customer`) and policy matrix alignment.
- Implement append-only `AuditLog` resource (create/read only; no update/destroy actions).
- Add redaction rules to prevent raw webhook payloads or secrets in audit metadata.
- Keep admin web flows thin and delegated to Ash actions only.

## Version Pins / Breaking Changes
- No new package families planned beyond Phase 00 pins.
- Breaking change watch:
  - Authorization DSL behavior should be re-verified on Ash minor upgrades.
  - If audit schemas evolve, preserve backward-compatible event metadata contracts.

## Performance & Scaling Review
- Hot paths:
  - Authorization checks on admin actions and high-volume support tooling.
  - Audit writes for every sensitive mutation must stay lightweight.
- Warm paths:
  - Audit searches by actor/action/time window in admin UI.
- Cold paths:
  - Long-range audit investigations and export jobs.
- Indexes:
  - Add indexes on audit fields likely queried (`inserted_at`, `actor_id`, `action`, `resource`).
- TTL:
  - No immediate TTL for audit rows in P0; retention policies are governance-driven and phased.
- Invalidation:
  - If cached admin views are introduced later, invalidate on new audit events.
- PubSub:
  - Optional admin activity feeds can publish lightweight audit notifications via PubSub.

