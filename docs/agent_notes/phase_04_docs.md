# Phase 04 Docs Notes

## Links Consulted (Hexdocs / web search)
- https://hexdocs.pm/ash/Ash.Resource.Change.Builtins.html
- https://hexdocs.pm/ash/Ash.Resource.Change.OptimisticLock.html
- https://hexdocs.pm/ash/Ash.Changeset.html
- https://hex.pm/packages/ash_state_machine
- https://hexdocs.pm/ash_state_machine/readme.html
- https://hexdocs.pm/oban/Oban.Worker.html

## What the Docs Recommend Now
- Use explicit, finite state transitions and reject invalid edges deterministically.
- Use optimistic locking for concurrent lifecycle writes to avoid stale overwrite races.
- Model idempotent replay behavior explicitly instead of relying on controller-level behavior.
- Enforce event dedupe with database uniqueness and deterministic conflict behavior.

## What We Will Implement (Decisions)
- Add `Store.Orders` and `Store.Payments` domains in Phase 04.
- Add `ash_state_machine` dependency and implement lifecycle actions with explicit transition validation.
- `Order` states are pinned to:
  - `pending_payment`, `paid`, `payment_failed`, `cancelled`, `refunded`
- `PaymentIntent` states are pinned to:
  - `created`, `submitted`, `succeeded`, `failed`, `cancelled`
- Phase 04 explicitly defines payment failure handling:
  - `PaymentIntent.failed` maps to `Order.payment_failed` through `mark_payment_failed`.
  - retry transition from `payment_failed` back to `pending_payment` is deferred and not implemented in Phase 04.
- Replay NOOP contract is pinned:
  - return `{:ok, record}`
  - no version bump
  - no extra side effects/audit entries
- Provider event dedupe is pinned:
  - uniqueness on `(provider, provider_event_id)`
  - duplicate ingest returns existing record deterministically
  - no mutation on duplicate conflict
- Provider event evidence fields for Phase 04:
  - `received_at`
  - `payload_hash` (digest only; no raw payload storage in this phase)

## Version Pins / Breaking Changes
- `ash`: `~> 3.0` (already pinned)
- `ash_postgres`: `~> 2.0` (already pinned)
- `ash_state_machine`: `~> 0.2.12` (new for phase)
- Breaking-change watch:
  - transition DSL surface and action options in `ash_state_machine`
  - upsert/conflict return semantics for dedupe paths in Ash create actions

## Performance & Scaling Review
- Hot paths:
  - state transitions on Orders and PaymentIntents during checkout/payment reconciliation
  - provider event ingest dedupe checks
- Warm paths:
  - operational reads for lifecycle status and recent provider events
- Cold paths:
  - long-range audit/reconciliation and incident investigations
- Indexes:
  - `orders.state`
  - `payment_intents.state`
  - `provider_events.provider_event_key`
  - unique on `(provider, provider_event_id)`
- TTL:
  - no TTL changes in Phase 04
  - payload retention and purge remain governed by retention phases
- Invalidation:
  - if cache is added later, invalidate on each successful transition
- PubSub:
  - optional future topic broadcasts on transition completion
  - not required in Phase 04
