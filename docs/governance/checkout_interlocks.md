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

### 3.3 Renewal collection identity exception

For an admitted SBH-10-04 renewal collection, the typed Payments path may use:

```text
payment_intent_key = "renewal-collection:<collection_attempt_id>"
```

The durable collection record is created first. Replays of that collection reuse the same PaymentIntent and key. A later collection may use a new key only after the prior collection has verified terminal financial non-success and current dunning policy permits another collection. The occurrence `renewal_key` remains metadata and does not replace the collection key.

The current PaymentIntent resource and indexes already permit distinct keys for terminal history on one Order. Existing preflight checks continue to reject a conflicting `submitted`, `requires_action`, or `succeeded` intent. This exception needs no PaymentIntent schema migration or new Payments resource. Generic checkout continues to use the deterministic Order/amount/currency/provider key above.

The collection must durably link the exact PaymentIntent. The existing `PaymentApplication` continues to apply the Order once and record the exact PaymentIntent used for the successful application. Renewal-specific collection validation and exact reservation-generation selection belong in the bounded payment/Subscription/Orders orchestration. Generic PaymentApplication does not gain Subscription rules. See [the SBH-10-04 cross-domain authority amendment](sbh_10_04_cross_domain_authority_amendment.md).

Before physical renewal success reaches reservation consumption, the renewal path must prove the exact local PaymentIntent-to-collection relationship and the exact expected active reservation-key set. It then uses the exact-key Orders consume operation within the paid-Order transaction. If an order-level PaymentApplication already exists, the renewal path verifies that its `payment_intent_id` matches the successful intent before treating the result as a replay. This validation stays outside generic checkout semantics.

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
