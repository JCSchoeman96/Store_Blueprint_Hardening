# Phase 04 — Lifecycle state machines + idempotency (P0)

## Locked decisions (MUST)
- `Order` states:
  - `pending_payment`, `paid`, `payment_failed`, `cancelled`, `refunded`
- `PaymentIntent` states:
  - `created`, `submitted`, `succeeded`, `failed`, `cancelled`
- `Order` includes action `mark_payment_failed`.
- `PaymentIntent.failed` handling is explicit in this phase: order transitions to `payment_failed`.
- Retry from `order.payment_failed -> pending_payment` is deferred to a later phase and is out of scope here.
- Replay NOOP semantics are pinned:
  - return `{:ok, record}`
  - do not increment optimistic lock version
  - do not emit extra side effects/audit entries
- Provider event ingest is dedupe-safe:
  - uniqueness on `(provider, provider_event_id)`
  - duplicate ingest returns existing record deterministically
  - no mutation on duplicate conflict
- Provider event evidence fields required in this phase:
  - `received_at`
  - `payload_hash`

## Acceptance gates
- Transition tests enforced per docs/governance/state_machines.md
- Replay tests: duplicates NOOP
- Provider event uniqueness enforced
