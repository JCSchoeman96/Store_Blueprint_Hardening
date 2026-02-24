# Governance: Inventory & Reservations (Authoritative)
Even a single-tenant store can oversell under concurrency. This document pins the inventory model so projects do not drift.

## 1) Inventory model options
This blueprint pins a conservative default suitable for most stores:

### Default: Strict no-oversell (MUST for physical limited stock)
- Inventory is tracked per SKU (variant) in `Catalog.InventoryItem`.
- Checkout must NOT oversell.
- Reservations are created during checkout and expire automatically.

### Alternative: Soft oversell (optional)
- Allowed only for digital goods or made-to-order items.
- Must be explicitly enabled per product/variant.

If you choose soft oversell, update this document + tests. No silent switch.

## 2) Terminology
- stock_on_hand: total available stock in database
- reserved_count: currently reserved but not yet sold
- available = stock_on_hand - reserved_count
- reservation: a temporary hold on N units for a specific order/cart/session

## 3) Rules (MUST)
1) Availability checks MUST occur during order creation (server-side).
2) Reservation creation MUST be atomic and concurrency-safe.
3) Reservations MUST have an expiry (TTL) and cleanup job.
4) When an order is paid, reservations are converted into a durable sale:
   - decrement stock_on_hand (or maintain sold_count), and
   - decrement reserved_count accordingly
5) If checkout is abandoned, reservations expire and stock becomes available again.
6) Reservations MUST be idempotent for retries (same order/cart does not double-reserve).

## 4) Concurrency approach (MUST)
At minimum, the system MUST be safe under concurrent checkouts for the same SKU.

### 4.1 DB-first locking (baseline, MUST)
- Use optimistic locking and/or row-level locks on InventoryItem when reserving.
- Lock ordering MUST follow the Lock Ordering Law when reserving multiple SKUs.
- Reserve calls across multiple SKUs MUST be all-or-nothing in a single DB transaction.
- Lock acquisition MUST be deterministic:
  1) lock inventory rows in variant UUID raw16 order,
  2) then lock/update reservation rows in that same order.

### 4.2 Redis reservation registry (optional performance pack)
If high volume requires it, add Redis:
- reservation registry: ZSET of reservation_id with score=expiry timestamp
- reservation details: HASH keyed by reservation_id
- per-sku reserved counts can be derived or maintained with atomic ops

If Redis is used, Postgres remains the durable source of truth.
This is a separate pack; do not half-implement it.

## 5) Reservation identity (MUST)
Reservations must have a stable idempotency key:
- reservation_key = "order:<order_id>:sku:<variant_id>" (or similar)
- unique constraint on reservation_key to prevent duplicates
- unique constraint on `(order_id, variant_id)` to pin one reservation intent row per pair

Pinned quantity behavior (MUST):
- reserve operation sets the desired quantity for `(order_id, variant_id)` (not append-only).
- if active reservation exists:
  - `delta = desired_qty - existing_qty`
  - `delta > 0`: require `available >= delta`, then increment `reserved_count` by delta and update quantity
  - `delta < 0`: decrement `reserved_count` by `abs(delta)` and update quantity
  - `delta == 0`: NOOP
- `desired_qty == 0` transitions active reservation to `cancelled` and releases held units.

## 6) Reservation lifecycle (MUST)
States:
- active
- consumed (converted to sale)
- expired
- cancelled (explicit cancel)

Transitions:
- active -> consumed (on payment success)
- active -> expired (on TTL)
- active -> cancelled (manual/admin cancel)
- expired/cancelled/consumed -> no further transitions

Replay + forbidden semantics (MUST):
- active -> consumed replay: NOOP
- active -> expired replay: NOOP
- active -> cancelled replay: NOOP
- expired -> consumed: forbidden
- consumed -> expired: forbidden
- consumed -> cancelled: forbidden

## 7) Expiry policy (defaults)
- reservation_ttl_minutes: 15 (default)
- cleanup job runs every 1–5 minutes (Oban) to release expired reservations

## 8) Error semantics (MUST)
- OUT_OF_STOCK: insufficient available inventory
- RESERVATION_CONFLICT: reservation could not be created due to concurrency
- VALIDATION_ERROR: invalid quantities

## 9) Test gates (MUST)
1) Concurrency test: two concurrent reserves for the last unit => one succeeds, one fails with OUT_OF_STOCK (or conflict).
2) Idempotency test: retrying reserve for same order/sku does not double reserve.
3) Expiry test: expired reservations release stock (via worker/job).
4) Payment consume test: on order paid, reservations become consumed and stock decreases accordingly.

## 10) Drift protocol (MUST)
If you need a different model (soft oversell, no reservations, etc.):
- Update this doc
- Add/adjust tests
- Then implement

No doc update = no behavior change.
