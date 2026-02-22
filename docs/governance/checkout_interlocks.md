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
- `checkout_key = "checkout:user:<user_id>:cart:<cart_fingerprint>:as_of:<as_of_iso>"`

cart_fingerprint MUST be deterministic:
- product/variant UUIDs normalized to raw16 and sorted (binary sort)
- quantities included
- coupon codes normalized uppercase
- hash the canonical byte representation (sha256)

DB uniqueness (MUST):
- unique index on `orders.checkout_key` (nullable allowed, but when present must be unique)

Behavior (MUST):
- If an order with checkout_key already exists in pending_payment, return it (NOOP), do not create a new one.

### 3.2 PaymentIntent create/attach
payment_intent_key MUST be stable:
- `payment_intent_key = "pi:order:<order_id>:amount:<grand_total_minor>:currency:<currency>:provider:<provider>"`

DB uniqueness (MUST):
- unique index on `payment_intents.payment_intent_key`

Behavior (MUST):
- If PaymentIntent with key exists, return it (NOOP).
- Only one PaymentIntent may be in submitted state per order at a time:
  - additional attempts must either reuse the same intent (provider-dependent) or create a new intent after failing/cancelling the previous one.

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
- Create a `Payments.ProviderEvent` or `Orders.OrderEvent` record with unique key.
- Worker checks if the event already applied; if yes, NOOP.

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
