# Phase 01 Docs Notes

## Links Consulted (Hexdocs / web search)
- https://hexdocs.pm/ash/
- https://hexdocs.pm/ash/dsl-ash-resource.html
- https://hexdocs.pm/ash/actions.html
- https://hexdocs.pm/elixir/UUID.html
- https://hexdocs.pm/elixir/Map.html
- https://hexdocs.pm/ex_unit/ExUnit.html
- https://hexdocs.pm/stream_data/StreamData.html
- https://hexdocs.pm/phoenix/Phoenix.Naming.html

## What the Docs Recommend Now
- Keep foundational laws in isolated support modules with deterministic APIs.
- Prefer explicit, test-driven contracts for sorting, ID formatting, and error registries.
- Use property-style tests (StreamData) for invariants where practical.
- Keep naming and serialization formats stable because downstream integrations depend on them.

## What We Will Implement (Decisions)
- Create support-law modules for:
  - UUIDv7 helpers
  - deterministic binary UUID sorting
  - lock ordering helper
  - prefixed IDs
  - `order_ref` generation/validation
  - error-code registry
- Add governance tests under `test/store/governance/**` for all constitutional laws.
- Enforce BAN on UUID string sort for ordering/tie-break logic.
- Implemented API decisions:
  - canonical UUID ordering API is `sort_raw16/1` (returns only raw16)
  - optional `sort_uuids/1` encodes after raw16 canonical sort
  - lock ordering uses canonical raw16 helpers only
  - prefixed IDs are enforced as `<prefix>_<uuid-lowercase>`
  - `order_ref` default remains 9 chars total (8 payload + 1 check)
  - error code registry is pinned to governance doc and uniqueness-tested

## Version Pins / Breaking Changes
- No new package families planned beyond Phase 00 pins.
- Breaking change watch:
  - Keep UUID parsing/normalization behavior explicit to avoid library-specific sorting drift.
  - Keep error-code registry immutable-by-default to avoid API contract churn.
  - Do not change prefixed UUID case rules without a migration/update plan for external integrations.

## Performance & Scaling Review
- Hot paths:
  - Binary UUID sorting and lock ordering may run in pricing/allocation/checkout code.
  - Functions should avoid unnecessary allocations and string transforms.
- Warm paths:
  - `order_ref` generation and validation for order creation/support workflows.
- Cold paths:
  - Registry introspection tests and docs checks.
- Indexes:
  - Unique index on `orders.order_ref` becomes mandatory once schema is added.
- TTL:
  - No TTL introduced by Phase 01 itself.
- Invalidation:
  - No cache invalidation required for immutable law utilities.
- PubSub:
  - None needed in this phase.
