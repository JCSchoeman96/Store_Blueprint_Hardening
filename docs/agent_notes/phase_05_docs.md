# Phase 05 Docs Notes

## Links Consulted (Hexdocs / web search)
- https://hexdocs.pm/ash/identities.html
- https://hexdocs.pm/ash_postgres/Mix.Tasks.AshPostgres.GenerateMigrations.html
- https://hexdocs.pm/ash/Ash.Type.CiString.html
- https://www.postgresql.org/docs/current/citext.html
- https://elixirforum.com/t/upsert-on-postgres-without-migrating-an-identiy/70742

## What the Docs Recommend Now
- Enforce uniqueness at the data layer using Ash identities that generate DB unique constraints.
- Use Postgres-backed upsert semantics for idempotent duplicate ingest flows.
- Keep email identity case-insensitive using `:ci_string` and DB-side case-insensitive storage (`citext`).
- Treat uniqueness drift as a governance gate with tests that fail when expected unique constraints are missing.

## What We Will Implement (Decisions)
- Active uniqueness constraints enforced in this phase:
  - `users.email` (case-insensitive)
  - `orders.order_ref`
  - `webhook_receipts.idempotency_key`
  - `provider_events(provider, provider_event_id)`
- Deferred constraints are enforced by table-aware tests:
  - `products.slug`, `posts.slug`, `variants.sku`, `coupons.code`
- `WebhookReceipt.ingest` duplicate behavior is pinned:
  - upsert on identity `:unique_idempotency_key`
  - conflict is NOOP
  - duplicate returns existing row deterministically
- `Order.order_ref` is generated and uniqueness-protected with bounded retry-on-conflict.
- Uniqueness registry is a governance test manifest, not runtime business logic.

## Version Pins / Breaking Changes
- `ash`: `~> 3.0`
- `ash_postgres`: `~> 2.0`
- Breaking-change watch:
  - identity/upsert behavior across Ash and AshPostgres minor upgrades
  - `citext` behavior and extension availability in deployment environments

## Performance & Scaling Review
- Hot paths:
  - order creation (`order_ref` generation + uniqueness check)
  - webhook receipt ingest dedupe path
- Warm paths:
  - provider event and receipt reconciliation queries
- Cold paths:
  - governance introspection queries in test/CI
- Indexes:
  - unique index `users.email` (case-insensitive via `citext`)
  - unique index `orders.order_ref`
  - unique index `webhook_receipts.idempotency_key`
  - unique index `provider_events(provider, provider_event_id)`
- TTL:
  - no TTL behavior changes in Phase 05
- Invalidation:
  - no cache invalidation introduced in this phase
- PubSub:
  - not required for uniqueness enforcement in this phase
