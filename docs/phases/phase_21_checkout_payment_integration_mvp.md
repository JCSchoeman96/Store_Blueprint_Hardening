# Phase 21 — Checkout UI + Payment Integration (MVP, real money path)

## Goal
Ship the first end-to-end purchase flow where a real customer can:

1. Build a cart (Phase 20)
2. Enter address + select shipping method
3. Review totals (items + tax + shipping)
4. Pay via a single configured provider
5. Land on a confirmation page
6. Receive a receipt/confirmation notification

This phase must produce a **working purchase** for **simple products** (physical, shippable). No digital delivery yet. No variants yet. No subscriptions yet.

---

## Non‑Negotiables
- **No query logic in `lib/store_web/**`**: web must call domain facades and use typed query/input structs (Phase 15–18 laws).
- **No side effects in web**: webhook controllers may validate signature + enqueue a worker only (Phase 08 law).
- **Totals are deterministic**: pricing, tax, and shipping totals must be computed from canonical domain services and must be replay-safe (Phase 10 + Phase 13).
- **Idempotent payment processing**: duplicate webhooks, duplicate return URLs, and job retries must not double-apply payment or emit duplicated downstream actions (Phase 14).
- **Notifications are post-commit**: all Ash notifications arising from transactional writes must be handled post-commit with test-time `:missed_notifications, :raise` (Phase 14 fix).

---

## Preconditions
- Phase 19 Catalog (simple products) and Phase 20 Cart exist.
- Shipping/tax rules exist (Phase 13) — even if simplified.
- PaymentIntent + interlocks exist (Phase 14).

---

## Deliverables
### Web/UI
- Checkout LiveView (single-page or multi-step) that:
  - Collects shipping address
  - Selects shipping method
  - Presents a final order summary
  - Initiates payment (redirect or inline provider flow)
- Order confirmation LiveView/page
- A “payment return” route (success/cancel) that safely resolves to the latest order state

### Domain
- A canonical checkout orchestrator surface:
  - `Store.Checkout.start_from_cart/3` (Phase 20)
  - `Store.Checkout.set_shipping/3`
  - `Store.Checkout.finalize_totals/2`
  - `Store.Payments.create_intent_for_order/3` (provider-agnostic)
- A provider behaviour + first provider implementation (sandbox + production config)

### Workers
- Webhook processing worker already exists; ensure it is wired as the only path that transitions paid.
- Receipt/confirmation delivery worker (email) for paid orders.

### Tests
- Happy-path purchase simulation (provider test adapter)
- Replay safety: webhook retried, return URL hit multiple times, job retried
- Signature verification negative tests

---

## Domain Model

### Checkout “Session” vs “Order”
**Do not invent a second source of truth.** The durable source of truth is the **Order**.

Recommended approach for MVP:
- Order has a state representing checkout progression (example):
  - `:draft` → `:checkout_started` → `:awaiting_payment` → `:paid` → `:fulfilled`
- A `checkout_token` (opaque, random) may be stored on the Order for safe lookup on return URLs.

Avoid over-engineering a separate `CheckoutSession` resource unless you need:
- multi-device resume
- long-lived sessions with explicit expiry
- multiple payment attempts per order with full audit

If you do add a session resource later, it must be **derived** from the order, never replacing it.

---

## Checkout Flow

### 1) Start checkout
Entry: from Cart LiveView “Checkout” CTA.

- Call `Store.Checkout.start_from_cart(actor, cart_token, params)`
- Creates/updates an Order with snapshot line items, and creates inventory reservations/holds.
- Returns an Order identifier and a `checkout_token` (or order public ref).

**Idempotency:** starting checkout must be replay-safe for the same cart token.

### 2) Set shipping + address
- Call `Store.Checkout.set_shipping(actor, checkout_token, shipping_params)`
- Persist address snapshot + selected shipping method.

**Validation:**
- Address fields validated in Ash changeset.
- Shipping method must be allowed for the destination.

### 3) Finalize totals
- Call `Store.Checkout.finalize_totals(actor, checkout_token)`
- Computes:
  - items subtotal
  - tax total
  - shipping total
  - grand total
- Writes deterministic totals snapshot to order adjustments / totals snapshot.

**Hard rule:** payment intent creation must use these finalized totals.

### 4) Create payment intent
- Call `Store.Payments.create_intent_for_order(actor, checkout_token, provider: :default)`
- Provider returns either:
  - a redirect URL, or
  - inline payment metadata (provider-specific)

**Idempotency:** Creating an intent must be replay-safe for the same order + attempt key.

### 5) Provider redirects user + webhook arrives
- Webhook controller:
  - verifies signature
  - maps payload → canonical receipt
  - enqueues `ProcessWebhookReceiptWorker`

Worker:
- Uses payment interlocks (Phase 14):
  - mark payment_intent succeeded
  - mark order paid
  - insert payment_application once
  - trigger post-commit notifications

### 6) Return URL + confirmation page
- Return URL should **not** apply payment state.
- It should lookup order by `checkout_token` and render:
  - “processing” (if not yet paid)
  - “paid” (if paid)
  - “failed/canceled” (if provider indicates)

**No polling:** prefer PubSub updates where possible. If you must poll, keep it short-lived and bounded.

---

## Payment Provider Integration

### Provider behaviour
Create a small behaviour that all providers implement.

Responsibilities:
- Create a payment intent for an Order total
- Verify webhook signature
- Normalize provider webhook payload to a canonical receipt struct

Non-responsibilities:
- Provider modules do **not** write to DB
- Provider modules do **not** transition orders

### Canonical receipt struct
Normalize webhook payloads into a single internal struct containing:
- provider
- provider_event_id
- provider_payment_id
- provider_idempotency_key (if available)
- status (succeeded/failed)
- amount + currency
- order_ref or metadata linking back to your Order
- occurred_at

**Gate:** mismatch between receipt amount/currency and order’s finalized totals must be rejected.

---

## Email / Notifications

### Rule
Email sending is an outbound side effect.

Recommended MVP approach:
- When order transitions to `:paid`, enqueue `SendOrderReceiptWorker` (idempotent by order_id).
- Worker renders email and calls your configured provider adapter.

Design constraints:
- Email provider must be called from a single wrapper module (similar to outbound HTTP wrapper rule).
- If enqueue fails post-commit, log + continue (order is paid). Provide admin “resend receipt” action.

---

## Security Requirements
- Webhooks must be verified with provider-specific signature scheme.
- Reject unsigned or invalid-signature webhooks with 401/403.
- Webhook endpoint must be rate-limited.
- Do not log raw webhook bodies in production (PII/PCI concerns).
- Store only minimal provider identifiers needed for audit and replay protection.

---

## Observability
Minimum required logs/metrics:
- Payment intent created (provider + order_ref)
- Webhook verified/failed verification
- Webhook processed (idempotent skip vs applied)
- Order paid transition
- Receipt email enqueued/sent/failed

Prefer emitting telemetry events from:
- payment intent creation
- webhook verification
- post-commit notify wrapper (success/failure/unsent)

---

## Test Plan

### Unit / Domain tests
- Creating a payment intent uses **finalized** totals and correct currency
- Receipt with amount mismatch is rejected
- Receipt with currency mismatch is rejected
- Duplicate receipt event id is replay-safe

### Integration tests (Oban testing)
- ProcessWebhookReceiptWorker is replay-safe:
  - order becomes paid once
  - one payment_application inserted
- Return URL hit multiple times does not change state

### Webhook security tests
- invalid signature → rejected
- missing signature → rejected

---

## Acceptance Criteria
- A user can complete a purchase end-to-end in a sandbox environment.
- Order totals are consistent between:
  - checkout summary
  - payment intent amount
  - stored order totals
  - receipt email
- Webhook replay cannot double-apply payment.
- Return URL replay cannot double-apply payment.
- Email receipt is sent once per paid order (idempotent).
- No direct Ash querying or direct persistence logic exists in `lib/store_web/**`.

---

## Performance & Scaling Review (Blueprint)
- Treat product + catalog reads as **warm-cache** eligible (Redis, 30m–24h TTL) once Phase 19 is live.
- Checkout totals computation must avoid N+1 loads; use explicit loads in domain read surfaces.
- Webhook processing must be fast; heavy work (email rendering, external provider calls) must be async (Oban).

---

## Governance Impact (Check)
This phase introduces **one new law** that may warrant a governance doc update later:

- **Webhook signature verification is mandatory** for any configured provider.

If not already captured in your governance docs, add a follow-up governance doc update in a later step:
- `docs/governance/webhooks.md` (new) or extend `docs/governance/outbound_http.md` to include inbound webhook verification rules.

(Do not update governance docs in this step — keep scope focused.)
