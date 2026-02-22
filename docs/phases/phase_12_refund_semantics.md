# Phase 12 — Refund semantics (P0)

## Goal
Prevent double refunds and inconsistent order/payment states.

## Must deliver
- `docs/governance/refund_semantics.md`
- Refund evidence resources (Refund/RefundAttempt/RefundAdjustment as needed)
- Idempotency via unique idempotency_key
- Step-up enforcement for refund actions
- Worker-driven processing (receipt-first)

## Acceptance gates
- Duplicate refund request => NOOP (returns existing refund)
- Refund cannot exceed refundable amount
- Refund requires step-up and correct role
- Webhook replay => NOOP
- Order transitions to refunded only when refundable reached
