# Payment Provider Integration Contract (Authoritative)

**Status:** Governance law (mandatory for any payment provider integration)  
**Last updated:** 2026-02-27

This document defines the non-negotiable contract for integrating **any** payment provider (PayFast/Yoco/Stripe/etc.) into the Store Blueprint.

It standardizes:
- boundaries (what may run where)
- webhook verification and replay safety
- idempotency keys and receipt storage
- error taxonomy and observability
- operational safety under retries, duplication, and provider downtime

It applies to:
- one-time purchases (checkout)
- renewals (subscriptions)
- refunds (request + provider callbacks)

---

## 1) Core law: Provider code must not mutate domain state

### Provider adapter responsibilities (allowed)
Provider modules are **pure boundary code**. They MAY:
- build provider requests (create intent, capture, refund)
- validate/verify inbound webhook signatures (given raw headers + raw body)
- normalize provider payloads into **canonical internal structs**
- map provider error codes into internal error codes

Provider modules MUST NOT:
- call `Repo`, `Ecto`, or `Ash.*`
- enqueue Oban jobs
- write to any tables/resources
- make authorization decisions

**Reason:** keeps provider logic swappable and prevents hidden side effects.

---

## 2) Web boundary: verify + enqueue only

### Webhook controller (allowed)
Webhook endpoints in `store_web/**` MAY do **only** the following:

1) **Read raw request** (headers + raw body)
2) **Verify signature** (pure computation)
3) **Reject invalid/missing signature** (HTTP 401/403)
4) **Normalize minimal receipt envelope** (safe fields)
5) (Recommended) **Persist a WebhookReceipt** record (or equivalent) with verification status
6) **Enqueue exactly one Oban worker** to process the receipt
7) Return a provider-appropriate HTTP response (usually 200/202)

Webhook controller MUST NOT:
- apply order/payment/refund state transitions
- call external HTTP
- compute pricing/shipping
- send emails

**Reason:** controllers are not replay-safe workers; all transitions must be centralized and idempotent.

### Return/cancel routes (customer redirect)
Return/cancel URLs MUST be **read-only**:
- never mark paid/refunded
- never trust query params as payment truth
- at most: display latest state and optionally enqueue a lightweight “refresh” read/verify job (no transitions)

---

## 3) Canonical entities: WebhookReceipt + CanonicalReceipt

A robust integration needs a durable **ingress ledger**.

### Required: `WebhookReceipt` (or equivalent durable record)
Store at minimum:
- `id` (uuid)
- `provider` (atom/string)
- `received_at`
- `verification_status` (`:verified | :rejected`)
- `provider_event_id` (string, unique within provider)
- `provider_object_id` (string, optional)
- `event_type` (string)
- `payload_hash` (sha256 of raw body)
- `raw_headers` (optional, redacted)
- `raw_body` (optional; see retention policy)
- `processing_status` (`:new | :processing | :processed | :failed`)
- `error_code` / `error_detail` (PII safe)

**Uniqueness law**
- unique: `(provider, provider_event_id)`
This prevents duplicate receipt records under replay.

### Required: Canonical normalized receipt (internal struct)
All workers operate on a canonical receipt:
- `provider`
- `provider_event_id`
- `event_type`
- `occurred_at`
- `payment_intent_ref` / `charge_ref`
- `order_ref` (if present)
- `amount_minor`
- `currency`
- `status` (`:succeeded | :failed | :refunded | :chargeback` etc.)
- `idempotency_key` (see next section)

This struct must be **the only input** to state transition orchestration.

---

## 4) Idempotency contract (must be deterministic)

### Inbound webhook idempotency
- Primary dedupe key: `(provider, provider_event_id)` (receipt layer)
- Canonical apply key: `idempotency_key` derived from provider data, e.g.:
  - `prov:{provider}:evt:{provider_event_id}`

Worker must:
- mark receipt `:processing`
- normalize → canonical receipt
- apply transitions through your interlocks (already replay-safe)
- mark receipt `:processed`
- if duplicate receipt arrives, return early and do nothing

### Outbound requests idempotency (create intent / refund)
All provider calls MUST include an idempotency key when provider supports it.

Key derivation examples:
- Create payment intent:
  - `intent:{order_id}:{attempt_no}`
- Refund request:
  - `refund:{refund_id}`

**Law:** the idempotency key must be stable across retries.

---

## 5) Signature verification requirements

### Verification must occur on raw body + headers
- Verification MUST use the **exact** raw body bytes the provider signed.
- Do not JSON-decode then re-encode and verify; that breaks signatures.
- Header names and algorithm are provider-specific, but enforcement is universal.

### Failure behavior (mandatory)
- Missing signature header → reject (401/403)
- Invalid signature → reject (401/403)
- Malformed body → reject (400), do not enqueue worker
- Verification exceptions → reject (500) but log and alarm (possible attack or misconfig)

### Defense-in-depth (optional)
If you persist raw body, the worker MAY re-verify, but:
- controller verification remains mandatory
- worker re-verify must not block processing if receipt already marked verified

---

## 6) Error taxonomy (standardized)

Implement a small internal error code set for payment boundaries:

- `PAYMENT_SIGNATURE_MISSING`
- `PAYMENT_SIGNATURE_INVALID`
- `PAYMENT_PAYLOAD_INVALID`
- `PAYMENT_EVENT_UNKNOWN`
- `PAYMENT_EVENT_DUPLICATE`
- `PAYMENT_PROVIDER_DOWN`
- `PAYMENT_PROVIDER_TIMEOUT`
- `PAYMENT_PROCESSING_FAILED`

**Law:** log these codes, not raw provider messages (avoid PII).

---

## 7) Worker processing contract (Oban)

### Processing worker rules (mandatory)
- Must be replay-safe (Oban retry + provider resend)
- Must never double-apply payment success/refund effects
- Must operate inside a transaction where needed, using the post-commit notification pattern

Suggested flow:
1) Fetch receipt by id
2) If `verification_status != :verified` → mark failed and stop
3) If `processing_status == :processed` → stop
4) Normalize provider payload to canonical receipt
5) Apply via domain interlocks:
   - payment success → `apply_payment_success_once`
   - refund succeeded → refund interlock flow
6) Emit notifications (post-commit)
7) Mark receipt `:processed`

### Uniqueness
- Worker jobs should be unique on `(provider, provider_event_id)` to reduce churn.

---

## 8) Rate limiting & abuse posture

Even for single-tenant:
- Apply rate limiting on webhook endpoints (at the edge if possible, otherwise in app).
- Reject invalid signatures quickly.
- Never include raw provider secrets in logs.

Minimum guidance:
- allow bursts, but cap sustained rate
- alarm on spikes of invalid signatures (attack indicator)

---

## 9) Sandbox vs production configuration

### Runtime configuration (required)
Provider credentials must live in `runtime.exs` and never in code:
- api keys / merchant ids
- webhook secret
- environment mode (`:sandbox | :live`)
- base URL (if applicable)
- timeout settings
- idempotency key prefix (optional)

**Law:** code must support sandbox and live in the same artifact by config only.

---

## 10) Refund integration specifics (MVP)
Refunds have two parts:
1) internal refund request (admin/step-up, invariants)
2) provider result notification (webhook/callback)

Law:
- Refund request creates a durable Refund record (already in your blueprint)
- Provider callback is the truth for “refund completed”
- Provider callback must be processed via the receipt worker (same contract as payments)

---

## 11) Required governance tests (must exist when provider is implemented)

1) Signature enforcement
- missing signature rejected
- invalid signature rejected
- valid signature accepted and enqueues worker only

2) Replay safety
- duplicate event id does not double-apply paid/refund effects

3) Worker correctness
- receipt processed once
- failed processing is retried safely without duplicates

4) Read-only return URL
- return route does not mutate domain state

5) Idempotent outbound calls (if supported)
- retry of create intent/refund uses same idempotency key

---

## 12) Observability requirements
Emit telemetry/logs for:
- webhook received (count by event_type, provider)
- signature rejected counts
- worker processing duration
- processed vs failed receipts
- duplicate event counts
- provider timeouts/down events

Minimum alerts:
- spike in signature failures
- receipt backlog growing
- worker failures above threshold
- provider down/timeout sustained

---

## 13) Retention policy (PII-safe)
Default posture:
- store `payload_hash` always
- store raw body only if needed for disputes/debugging and with a retention window
- never store full card details (should not be present anyway)

Recommended:
- retain raw body max 7–30 days (configurable)
- retain receipt metadata longer for audit

---

## 14) Implementation note (where this lives)
- `Store.Payments.Providers.*` (pure boundary adapters)
- `StoreWeb.Webhooks.*Controller` (verify + enqueue only)
- `Store.Payments.WebhookReceipts` (resource + durable ingress ledger)
- `Store.Workers.ProcessWebhookReceiptWorker` (canonical processing)

---

## Appendix: Minimal checklist for new provider onboarding
- [ ] Provider adapter implements verify + normalize
- [ ] Webhook controller verifies signature and enqueues
- [ ] Receipt resource exists with unique provider_event_id
- [ ] Worker is idempotent and marks receipts processed
- [ ] Governance tests for signature + replay + read-only return URL
- [ ] Telemetry/alerts configured
- [ ] Sandbox/live config present in runtime.exs
