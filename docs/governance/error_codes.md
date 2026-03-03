# Governance: Error Codes (Authoritative)
This document pins stable, registry-backed error codes referenced across governance docs.

## Rules (MUST)
1) All error codes MUST be **SCREAMING_SNAKE_CASE**.
2) Every error code returned from policies/validations/actions/webhook idempotency MUST exist in `Store.Support.Errors.ErrorCodes`.
3) Semantics MUST be stable. If meaning changes, introduce a NEW code.

## Canonical auth/error semantics (MUST)
- UNAUTHORIZED: actor missing / not signed in
- FORBIDDEN: actor present, but not allowed by policy
- NOT_FOUND: requested resource not found
- STEP_UP_REQUIRED: sensitive op without recent step-up
- INVALID_STATE_TRANSITION: forbidden lifecycle transition
- STALE_RECORD: optimistic lock failure / concurrent write
- WEBHOOK_DUPLICATE: duplicate receipt/event detected (often NOOP)
- VALIDATION_ERROR: generic validation failure when no more specific code fits
- INTERNAL_ERROR: unexpected internal failure (non-leaky, used as a safe fallback)

## Ecommerce correctness codes (MUST)
Pricing/discounts:
- INVALID_COUPON: coupon invalid/expired/ineligible

Checkout replay safety:
- CHECKOUT_DUPLICATE: duplicate begin_checkout detected (returns existing order)
- PAYMENT_INTENT_DUPLICATE: duplicate payment intent creation (returns existing intent)
- PAYMENT_ALREADY_SUCCEEDED: attempting to create/attach payment after success

Inventory/reservations:
- OUT_OF_STOCK: insufficient available inventory
- RESERVATION_CONFLICT: concurrency conflict creating reservation

Refunds:
- REFUND_NOT_ALLOWED: wrong order/payment state
- REFUND_EXCEEDS_REFUNDABLE: refund amount exceeds refundable amount
- REFUND_DUPLICATE: duplicate refund request (returns existing refund / NOOP)
- IDEMPOTENCY_KEY_REUSE_MISMATCH: same idempotency key used with different refund payload/fingerprint
- CURRENCY_MISMATCH: refund currency does not match payment intent currency
- PAYMENT_PROVIDER_REFUND_FAILED: provider refund failed/declined

Tax/shipping:
- INVALID_ADDRESS: missing/invalid destination fields
- SHIPPING_RATE_NOT_FOUND: no eligible shipping rate
- TAX_RATE_NOT_FOUND: tax enabled but no applicable rate

## Baseline domain codes (recommended)
Orders:
- ORDER_NOT_FOUND
- ORDER_NOT_OWNED

Payments:
- PAYMENT_PROVIDER_VERIFICATION_FAILED
- PAYMENT_SIGNATURE_MISSING
- PAYMENT_SIGNATURE_INVALID
- PAYMENT_PAYLOAD_INVALID
- PAYMENT_EVENT_UNKNOWN
- PAYMENT_EVENT_DUPLICATE
- PAYMENT_PROVIDER_DOWN
- PAYMENT_PROVIDER_TIMEOUT
- PAYMENT_PROCESSING_FAILED
- PAYMENT_EVENT_UNVERIFIED

Catalog/Content:
- SLUG_TAKEN
- SKU_TAKEN

Digital fulfillment:
- DIGITAL_GRANT_NOT_FOUND
- DIGITAL_GRANT_DENIED
- DIGITAL_GRANT_EXPIRED
- DIGITAL_GRANT_REVOKED
- DIGITAL_REDIRECT_UNSAFE
- DIGITAL_DOWNLOAD_RATE_LIMITED

## Drift protocol (MUST)
1) Update registry first.
2) Update tests.
3) Only then use the code.

## Test gates (MUST)
- Registry uniqueness test (no duplicates)
- Core codes exist test (all codes in this document)
