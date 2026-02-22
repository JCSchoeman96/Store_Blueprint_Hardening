# Phase 11 — Inventory & reservations (P0)

## Goal
Prevent overselling and inconsistent stock under concurrency.

## Must deliver
- `docs/governance/inventory_reservations.md`
- Reservation lifecycle + TTL cleanup worker
- Test suite enforcing concurrency/idempotency/expiry/consume rules

## Acceptance gates
- Concurrent reserve last unit -> one success, one OUT_OF_STOCK/RESERVATION_CONFLICT
- Retry reserve for same order/sku does not double reserve
- Expiry releases inventory
- Paid order consumes reservations and stock decreases
