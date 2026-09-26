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
Generic checkout reservations must have a stable idempotency key:
- reservation_key = "order:<order_id>:sku:<variant_id>" (or similar)
- unique constraint on reservation_key to prevent duplicates
- unique constraint on `(order_id, variant_id)` to pin one reservation intent row per pair

The physical subscription-renewal exception is bounded by Section 5.1.

Pinned quantity behavior (MUST):
- reserve operation sets the desired quantity for `(order_id, variant_id)` (not append-only).
- if active reservation exists:
  - `delta = desired_qty - existing_qty`
  - `delta > 0`: require `available >= delta`, then increment `reserved_count` by delta and update quantity
  - `delta < 0`: decrement `reserved_count` by `abs(delta)` and update quantity
  - `delta == 0`: NOOP
- `desired_qty == 0` transitions active reservation to `cancelled` and releases held units.

### 5.1 Physical subscription-renewal generations

The later, separately admitted SBH-10-04 implementation may use multiple historical reservation rows for one physical renewal Order/variant. This exception applies only to renewal collection generations. Generic checkout keeps the single-row `(order_id, variant_id)` behavior and the key `order:<order_id>:sku:<variant_id>`.

Each renewal generation uses a server-derived key that includes the exact collection and reservation-generation identities:

```text
order:<order_id>:sku:<variant_id>:renewal_collection:<collection_attempt_id>:generation:<reservation_generation_id>
```

The global unique `reservation_key` remains the durable generation identity. Replace the unconditional `(order_id, variant_id)` uniqueness rule with a unique partial index on `(order_id, variant_id) WHERE state = 'active'`. Keep the global `reservation_key` unique index. The task-specific Orders migration and Ash snapshot must retain every old row and enforce at most one active generation for each Order/variant.

The Orders Ash resource must remove its global `unique_order_variant` identity and retain the globally unique `unique_reservation_key` identity. The migration owns the partial active-row index; the Ash snapshot must not claim that `(order_id, variant_id)` is globally unique. Because current Orders helpers use pair-only lookups, the admitted change must make generic checkout reserve/release/consume resolve only its canonical `order:<order_id>:sku:<variant_id>` key and make generic order-wide enumeration exclude renewal-generation keys. `maybe_reload_reservation` and pair-lock helpers must not query by `(order_id, variant_id)` alone. Renewal-generation reserve/release/consume operations must resolve and validate the exact full `reservation_key`.

For every new generation, lock the PostgreSQL inventory row and check stock again. Provider work may start only after every physical hold required by the collection is active. A pre-submission fence may release its active generation while keeping the same collection attempt. If that collection resumes, it gets a new `reservation_generation_id` and a new key. A later collection also gets a new generation. Neither case reactivates an old row.

`consumed`, `expired`, and `cancelled` rows remain terminal and historical. A verified terminal non-success releases only the active generation for that collection. A successful collection consumes only the generation whose exact `reservation_key` is linked to that collection. `requires_action`, local TTL, process death, timeout, transport failure, provider 5xx, or local cancellation after possible submission does not release the hold or permit another collection.

The generic lifecycle and TTL rules in Sections 6 and 7 continue to apply to generic checkout. Ordinary expiry candidate selection and cleanup must skip physical renewal generation rows even when their `expires_at` has passed. TTL is not proof that the collection is safe to release. The exact-key Orders release path may release a renewal generation only after a durable pre-submission fence or verified terminal financial non-success; otherwise an unresolved or `requires_action` generation stays active until payment evidence or separately governed recovery resolves it. Virtual renewals without physical holds do not create reservation generations.

Before payment-success consumption for a physical renewal, Subscription validation must prove that every expected active hold belongs to the exact successful collection. The Orders consume operation then targets only those exact generation keys. The renewal-specific request, release, recovery, and consume paths must use the exact generation key. PostgreSQL remains the inventory authority. Redis admission continues to bound entry by variant and by the existing global budget; it does not establish reservation truth. See [the SBH-10-04 cross-domain authority amendment](sbh_10_04_cross_domain_authority_amendment.md) and [S0-ARCH-01](../hardening/s0_inventory_reservation_admission_architecture.md).

## 6) Reservation lifecycle (MUST)
The transitions below describe generic checkout. Physical renewal generations follow Section 5.1: ordinary TTL cleanup cannot move an active renewal row to `expired`, and a renewal success consumes only validated exact generation keys.

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
