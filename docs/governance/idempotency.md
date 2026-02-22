# Governance: Idempotency & Webhooks (Authoritative)
Defines receipt-first webhook processing, event identity, and uniqueness constraints.

## Receipt-first pipeline (MUST)
1) Webhook controller computes `idempotency_key` and inserts WebhookReceipt (unique).
2) Controller enqueues Oban job with receipt id.
3) Worker verifies signature, normalizes ProviderEvent, applies transitions ONCE.

## Canonical identities (MUST)

### WebhookReceipt.idempotency_key (MUST)
Purpose: dedupe raw inbound deliveries.

Canonical:
`idempotency_key = "#{provider}:#{delivery_id}"`

delivery_id MUST be:
- provider’s event id if present (preferred), else
- deterministic SHA-256 of (provider + normalized headers subset + raw body bytes)

Uniqueness:
- DB unique index on `webhook_receipts.idempotency_key`

### ProviderEvent.provider_event_key (MUST)
Purpose: dedupe normalized events (post verification).

Canonical:
`provider_event_key = "#{provider}:#{provider_event_id}"`

Uniqueness:
- DB unique index on `(provider, provider_event_id)` OR on `provider_event_key`

## Duplicate semantics (MUST)
- Duplicate WebhookReceipt insert: NOOP and return 200/204.
- Duplicate ProviderEvent insert: worker MUST NOOP (no transitions, no side effects).
- Optional: create an AuditLog entry noting duplicate receipt/event (scrubbed metadata only).

## Required fields (recommended)
WebhookReceipt:
- provider
- idempotency_key (unique)
- received_at
- raw_body (sensitive; retention-governed)
- headers_subset (sensitive; retention-governed)
- payload_sha256 (always keep)
- verification_status

ProviderEvent:
- provider
- provider_event_id
- provider_event_key
- event_type
- occurred_at
- receipt_id (fk)
- payload_sha256
- normalized_payload (scrubbed; optional)

## Coupling to retention (MUST)
- Raw payload retention is time-limited.
- payload_sha256 and minimal metadata persist beyond raw payload purge.
