# Governance: Refund Semantics (Authoritative)
Refunds are high-risk. This document pins refund behavior, evidence, idempotency, and order/payment interlocks.

## 1) Refund principles (MUST)
1) Refunds MUST be **evidence-based**: every refund produces durable records that explain what happened.
2) Refunds MUST be **idempotent**: retrying the same refund request MUST NOT double-refund.
3) Refunds MUST be **authorized**: require role + step-up.
4) Refunds MUST be **consistent** with order/payment state machines.

## 2) Refund types
- full_refund: refund entire paid amount
- partial_refund: refund a portion (by amount and/or by line items)
- shipping_refund: refund shipping component (may be part of partial)

## 3) State machine interlocks (MUST)

### 3.1 Order interlock
An order may transition to `refunded` only when:
- the payment provider confirms refund success (or refund is otherwise finalized), AND
- the sum of successful refunds equals the refundable amount (definition below)

### 3.2 PaymentIntent interlock
A refund is allowed only when:
- PaymentIntent state is `succeeded` (or equivalent paid state), AND
- the refund amount does not exceed refundable amount

Forbidden:
- refunds on pending/failed/cancelled payment intents

## 4) Refundable amount definition (MUST)
Phase-12 refundable base is computed from immutable evidence and captured amount:
- `snapshot_total_minor_excl_tax_shipping = sum(order_line_items.net_line_total_minor) + sum(order_adjustments.amount_minor)`
- `refundable_base_minor = min(payment_intent.amount_received_minor, snapshot_total_minor_excl_tax_shipping)`
- `refundable_remaining_minor = refundable_base_minor - sum(successful_refunds_minor)`

Refund requests MUST NOT exceed `refundable_remaining_minor`.
Tax/shipping refund semantics are deferred to Phase 13.
Refund currency MUST match payment intent currency; mismatch returns `CURRENCY_MISMATCH`.

## 5) Evidence model (MUST)
Introduce refund evidence resources (names may vary, but semantics must hold):

### 5.1 Payments.Refund
Fields (baseline):
- id (uuidv7)
- order_id
- payment_intent_id
- refund_ref (customer-facing ref optional)
- requested_amount_minor
- currency
- reason (enum/string)
- status: requested | submitted | succeeded | failed | cancelled
- provider_refund_id (nullable, unique per provider)
- idempotency_key (unique)
- requested_by_user_id (actor)
- requested_at

### 5.2 Payments.RefundAttempt (optional)
If providers require multi-step or retries, store attempts separately.

### 5.3 Orders.RefundAdjustment (optional)
Record refund as an additive adjustment evidence record (recommended) rather than mutating historical totals.

## 6) Idempotency keys (MUST)
Refund requests MUST have deterministic idempotency keys.
Canonical:
- `idempotency_key = "refund:order:<order_id>:amount:<amount_minor>:reason:<reason>:scope:<scope_hash>"`

Where scope_hash is deterministic based on:
- line item ids (if refund-by-lines) sorted by UUID binary sort and hashed
- else a stable sentinel for “order-level refund”

DB uniqueness:
- unique index on refunds.idempotency_key
- unique constraint on (provider, provider_refund_id) if provider ids exist

Mismatch rule:
- if same `idempotency_key` is reused with different immutable refund fingerprint
  (scope_hash + requested_amount_minor + currency + reason),
  return `IDEMPOTENCY_KEY_REUSE_MISMATCH` and perform no side effects.

## 6.1 Concurrency lock (MUST)
Refund request flow MUST serialize concurrent requests by locking the target payment intent row:
- open transaction
- `SELECT ... FOR UPDATE` on `payment_intents` row
- compute remaining refundable and write/refetch refund evidence while lock is held

This is mandatory to prevent concurrent overshoot of refundable bounds.

## 7) Authorization + step-up (MUST)
- Refund actions require roles: admin or super_admin
- Refund actions MUST require step-up (see step_up.md)
- Support role is forbidden from initiating refunds (read-only)

## 8) Webhook processing (MUST)
- Provider refund events MUST be processed receipt-first and idempotently (same as payments).
- Refund state transitions MUST happen in Oban worker, not in controller.

## 9) Partial refund allocation (MUST)
If refund is line-item scoped:
- Use deterministic allocation rules similar to pricing_determinism:
  - allocate by line totals or explicit line targets
  - remainder pennies distributed by line item id UUID binary sort

## 10) Error semantics (MUST)
- STEP_UP_REQUIRED: no recent step-up
- FORBIDDEN: role not allowed
- REFUND_NOT_ALLOWED: wrong order/payment state
- REFUND_EXCEEDS_REFUNDABLE: amount too high
- REFUND_DUPLICATE: idempotent duplicate request (NOOP or returns existing refund)
- IDEMPOTENCY_KEY_REUSE_MISMATCH: idempotency key reused with non-equivalent payload
- CURRENCY_MISMATCH: refund currency does not match payment intent currency
- PAYMENT_PROVIDER_REFUND_FAILED: provider declined/failed
- VALIDATION_ERROR: bad inputs

## 11) Test gates (MUST)
1) Refund requires step-up and correct role.
2) Duplicate refund request with same idempotency key does not double-refund.
3) Partial refund cannot exceed refundable amount.
4) Refund webhook replay is NOOP (no double transitions).
5) Order transitions to refunded only when refunds reach refundable_total.
6) Refund evidence records exist and are immutable after success (no update/destroy beyond state machine transitions).

## 12) Drift protocol (MUST)
If refund semantics change:
- update this doc
- update test gates
- then update implementation

No doc update = no behavior change.
