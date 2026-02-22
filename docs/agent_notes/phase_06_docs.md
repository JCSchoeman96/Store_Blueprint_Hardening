# Phase 06 Docs Notes

## Links Consulted (Hexdocs / web search)
- https://hexdocs.pm/ash/policies.html
- https://hexdocs.pm/ash/Ash.Policy.Check.Builtins.html
- https://hexdocs.pm/ash/Ash.Policy.SimpleCheck.html
- https://hexdocs.pm/ash_authentication/integrating-ash-authentication-and-phoenix.html
- https://hexdocs.pm/ash_postgres/Mix.Tasks.AshPostgres.GenerateMigrations.html

## What the Docs Recommend Now
- Keep authorization at the Ash policy layer with deny-by-default posture.
- Use explicit custom checks for non-trivial context-based constraints (step-up recency).
- Keep policy conditions deterministic and test-backed to prevent drift.
- Use migration-backed resource schema changes for policy-required attributes.
- Keep row-visibility authorization filter-capable where possible; use runtime checks only for non-row-scoping controls.

## What We Will Implement (Decisions)
- `Order.user_id` strategy: Option 1 (nullable now with guarded own-data policies).
  - Customer own-data policies apply where `order.user_id == actor.id`.
  - Orders with `user_id = nil` are not customer-readable.
  - `orders.user_id` is indexed (`orders_user_id_index`) for own-data reads.
- Add `Admin.SiteSetting` as the provider config surface for policy testing:
  - constrained key set only
  - `value` is non-secret config only
  - API keys/secrets/tokens/passwords are banned in Phase 06
- Provider config mutation requires both:
  - role in `[:super_admin, :admin]`
  - recent step-up (`context[:step_up_at_mono_usec]` within 15 minutes)
  - `step_up_at_mono_usec` comes from trusted server-side step-up completion, not client-supplied timestamps
- `SiteSetting` mutations must emit audit entries via existing admin audit change.
- Active policy matrix enforcement applies to existing resources only:
  - Accounts, Admin, Orders, Payments
  - Content/Catalog/Pricing remain deferred-aware in tests.

## Version Pins / Breaking Changes
- `ash`: `~> 3.0`
- `ash_postgres`: `~> 2.0`
- Breaking-change watch:
  - policy check APIs and context shape in Ash minor upgrades
  - custom check behavior for `SimpleCheck` context handling

## Performance & Scaling Review
- Hot paths:
  - policy checks on read/update actions for Orders/Payments
  - role-check lookups for admin actions
- Warm paths:
  - provider config updates (low volume, high sensitivity)
- Cold paths:
  - policy drift governance tests in CI
- Indexes:
  - ensure `orders.user_id` indexed for own-data reads
  - `site_settings.key` unique index for deterministic upsert
- TTL:
  - no TTL changes in Phase 06
- Invalidation:
  - if policy-relevant cache exists later, invalidate on role assignment or setting mutation
- PubSub:
  - not required in Phase 06
