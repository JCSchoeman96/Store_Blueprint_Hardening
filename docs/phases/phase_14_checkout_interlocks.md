# Phase 14 — Checkout interlocks & replay safety (P0)

## Goal
Eliminate double-orders, double-charges, and duplicate side effects under retries and replays.

## Must deliver
- `docs/governance/checkout_interlocks.md`
- begin_checkout idempotency (checkout_key)
- payment_intent idempotency (payment_intent_key)
- exactly-once paid side effects guard

## Acceptance gates
- Same checkout_key => same pending_payment order
- Same payment_intent_key => same payment intent
- Duplicate success webhook => no double side effects
- Callback/redirect controller is enqueue-only
