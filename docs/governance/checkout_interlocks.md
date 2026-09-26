# Governance: Checkout Interlocks & Replay Safety (Authoritative)
Checkout is a replay minefield: double-clicks, refreshes, provider retries, duplicate redirects, and webhook replays.
This document pins the interlocks so the system cannot double-charge or double-create orders.

## 1) Core principles (MUST)
1) An Order MUST be created exactly once per checkout attempt.
2) A PaymentIntent MUST be created/attached deterministically and idempotently.
3) “Paid” side effects MUST be applied exactly once (inventory consume, emails, fulfillment).
4) Redirect/callback handlers MUST be enqueue-only (side effects in workers).

## 2) Canonical linking model (MUST)
- Orders.Order is the durable record of “what was bought”.
- Payments.PaymentIntent represents the “attempt group” for paying that order.
- Payments.PaymentAttempt represents a provider attempt (optional but recommended).

Constraints (MUST):
- Order has 0..N payment_intents (but only ONE active submitted at a time).
- PaymentIntent belongs to exactly one order.

## 3) Idempotency keys (MUST)
### 3.1 Begin checkout (cart -> order)
When creating an order from cart/session:
- checkout_key MUST be stable for the checkout attempt.
Canonical:
- `checkout_key = "ck:" <> base32(sha256(canonical_checkout_payload))`

cart_fingerprint MUST be deterministic:
- product/variant UUIDs normalized to raw16 and sorted (binary sort)
- quantities included
- currency included
- explicit as_of included
- pricing contract/version pin included
- tax/shipping deterministic input set (or explicit digest) included
- hash the canonical byte representation (sha256)

DB uniqueness (MUST):
- unique index on `orders.checkout_key`

Behavior (MUST):
- If an order with checkout_key already exists in pending_payment, return it (NOOP), do not create a new one.

### 3.2 PaymentIntent create/attach
payment_intent_key MUST be stable:
- `payment_intent_key = "pi:" <> base32(sha256("order:<order_id>|amount:<grand_total_minor>|currency:<currency>|provider:<provider>"))`

DB uniqueness (MUST):
- unique index on `payment_intents.payment_intent_key`
- partial unique index on `payment_intents(order_id)` for in-flight states (`submitted`, `requires_action`)

Behavior (MUST):
- If PaymentIntent with key exists, return it (NOOP).
- Only one PaymentIntent may be in submitted state per order at a time:
  - additional attempts must either reuse the same intent (provider-dependent) or create a new intent after failing/cancelling the previous one.

### 3.3 Blocked Subscription renewal collection target (v0.1.27)

This section records a future renewal target only. It does not amend the
effective PaymentIntent rules in sections 3.1–3.2, authorize runtime behavior,
or assign Payments, provider, Orders, InventoryAdmission, or Subscription
implementation authority. Those owners must explicitly approve any change to
their contracts before this target can become effective. SBH-10-04 remains
blocked pending those decisions.

Under the target, the occurrence-level `renewal_key` would identify the one
RenewalAttempt and Order, not every provider collection against that
occurrence. A durable collection-attempt record would be created before
PaymentIntent or provider work and would have a UUIDv7
`collection_attempt_id`. Any monotonic collection ordinal would have a
separate durable meaning and would not reuse or reinterpret the existing
`RenewalAttempt.attempt_no` without a later explicit authority decision.

The target local PaymentIntent key is
`renewal-collection:<collection_attempt_id>`. It would be distinct for each
collection attempt against the same Order and reused only for replay of that
same collection. The target provider idempotency key is also
`renewal-collection:<collection_attempt_id>`; it would remain stable for
ambiguous transport/provider replay. A pre-submission dispatch fence could
release a reservation hold after proving no worker can submit, but recovery
would remain on the same collection attempt and keys. A new key and
PaymentIntent would be allowed only after verified provider/payment evidence
proves final financial non-success and dunning policy permits another attempt.
An ambiguous result, `requires_action`, local timeout, or local cancellation
after submission would not allow a new collection key.

Every PaymentIntent would need durable attribution to its exact collection
attempt and RenewalAttempt occurrence. Successful reconciliation would need to
identify the exact successful collection evidence without ambiguity or
destructive history rewriting. The meaning of the legacy single
`RenewalAttempt.payment_intent_id` remains unresolved for a later explicit
Subscription, Payments, and SBH-10-05 authority decision. One PaymentIntent
may be in flight per Order as required above. The target does not change
generic checkout key derivation. The v0.1.27 Subscription register records
this as a blocked target, not current runtime behavior or effective
cross-domain law.

## 4) State interlocks (MUST)
### 4.1 Order state transition to paid
Order transitions to paid only when:
- a verified provider event indicates payment success, AND
- PaymentIntent transitions to succeeded (or equivalent)

### 4.2 Replay behavior (MUST)
- Duplicate provider success event: NOOP (do not re-run side effects)
- Duplicate redirect/callback: enqueue-only and NOOP if already processed
- Duplicate begin_checkout: returns existing pending_payment order

## 5) Side effects exactly-once (MUST)
All “paid” side effects must be guarded by a durable idempotency record:
- inventory reservation consume
- email receipt send
- fulfillment creation

Approach (MUST):
- Create `Orders.PaymentApplication` record with unique `application_key` per order paid transition.
- Worker inserts `PaymentApplication` first:
  - insert winner applies side effects
  - replay sees existing row and NOOPs

## 6) Error semantics (MUST)
- CHECKOUT_DUPLICATE: duplicate begin_checkout detected (returns existing order)
- PAYMENT_INTENT_DUPLICATE: duplicate intent creation (returns existing intent)
- PAYMENT_ALREADY_SUCCEEDED: attempting to create new intent after success
- FORBIDDEN / UNAUTHORIZED: auth failures
- STALE_RECORD: optimistic lock hit

## 7) Test gates (MUST)
1) begin_checkout idempotency:
   - same checkout_key => same order returned
2) payment_intent idempotency:
   - same payment_intent_key => same intent returned
3) paid side effects exactly-once:
   - duplicate success webhook => side effects happen once
4) redirect/callback enqueue-only:
   - controller does not call provider or mutate order/payment directly

## 8) Drift protocol (MUST)
Any change to keys/interlocks requires:
- doc update
- test update
- implementation update
No doc update = no change.
