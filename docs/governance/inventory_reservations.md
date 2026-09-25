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

## 11) Subscription renewal collection holds (governance target)

A renewal occurrence keeps one immutable `RenewalAttempt` and one Order. A later
dunning collection is a new collection attempt for that same occurrence and
Order. This section defines the required reservation behavior for that model.
It does not authorize Orders or InventoryAdmission implementation. The
current S0-ARCH-01 design remains frozen until its owner separately accepts a
compatible identity and recovery contract.

For physical subscription renewal holds, this target supersedes the one-row
`(order_id, variant_id)` identity and automatic TTL release in sections 3, 5,
6, and 7. It applies only to collection generations and leaves generic
checkout reservation identity and lifecycle unchanged. A renewal hold may be
released before provider submission only after the durable dispatch fence
below proves no worker can submit. Runtime behavior remains unchanged until
separate Orders and InventoryAdmission authority accepts and implements the
extension.

### Reservation generations

- A physical collection attempt receives a durable reservation generation tied
  to its `collection_attempt_id`, occurrence, Order, variant, and quantity.
- Its durable reservation identity must include the stable collection-attempt
  identity. A later dunning attempt creates a new row and key. It never
  reactivates or rewrites an `expired`, `cancelled`, or `consumed` row.
- At most one reservation generation for the same occurrence and variant may
  be active. A new generation must pass the normal PostgreSQL stock check. If
  stock is unavailable, do not call the provider.
- Only one collection attempt for the occurrence may be nonterminal at a time.
  Every active reservation generation on its Order must belong to that same
  collection attempt.
- Payment success consumes only the active reservation generation linked to
  the successful collection attempt. It must not consume a different
  generation merely because the Order ID matches.
- This collection identity does not change the generic checkout identity law.
  Any Orders implementation must retain checkout's existing
  `order_id + variant_id` idempotency behavior.

### Collection outcomes and holds

- A durable collection attempt in `prepared` state with no PaymentIntent, or
  with a `created` PaymentIntent, has no provider outcome yet. Its hold remains
  active while any worker can still submit it. A durable dispatch fence may
  prove the request never began and prevent future submission; only then may
  cleanup release the hold. Record `not_submitted` for that dispatch, but keep
  the same nonterminal collection attempt and identities for any resumption.
  This is not financial non-success and does not permit a new collection ID.
- A provider or transport replay with an ambiguous outcome reuses the same
  collection attempt, PaymentIntent, and provider idempotency identity. Keep
  that attempt's physical hold active. Ambiguity does not permit another
  collection attempt.
- A PaymentIntent `succeeded` result closes the occurrence as successful. It
  consumes only that collection attempt's active reservation generation and
  forbids a later collection attempt.
- A PaymentIntent `failed` result is terminal financial non-success only when
  durable verified provider/payment evidence establishes a final decline or
  equivalent final failure. A provider-confirmed cancellation or expiry is
  also terminal only when it proves that the submitted intent cannot later
  succeed. The system may then cancel and release that attempt's reservation
  generation. A later dunning attempt may create a new generation only if the
  current dunning policy permits it.
- A local `cancelled` state does not prove provider cancellation for an intent
  whose submission may have started. Local cancellation is sufficient only
  behind the durable pre-submission fence above. Local expiry and an
  authentication deadline are not financial outcomes.
- `requires_action` remains on the same PaymentIntent and collection attempt.
  Keep its reservation active while authentication or provider status remains
  unresolved. Do not release the hold when the customer-action deadline or
  local reservation TTL passes.
- At the authentication deadline, the system may request cancellation of the
  same PaymentIntent and reconcile that request. Release the hold only after
  durable provider/payment evidence proves terminal non-success. If the result
  remains unknown, retain the hold and stop further collection until
  reconciliation or manual action resolves it.
- The generic reservation TTL cleanup must not release an active generation
  linked to a prepared attempt with no PaymentIntent, a `created` PaymentIntent,
  or a submitted, `requires_action`, or outcome-unknown PaymentIntent while a
  worker could still submit or a charge could still succeed. TTL may start a
  durable dispatch fence for a pre-submission attempt, or trigger provider
  cancellation and reconciliation for a submitted attempt. Release follows
  only after the corresponding fence or verified terminal provider/payment
  evidence; TTL itself is not proof that a charge cannot still succeed. If a
  pre-submission hold is released and that same collection attempt resumes, it
  requires a new reservation generation linked to the same
  `collection_attempt_id`. If the Orders boundary cannot represent that safely,
  stop for Orders owner review.

The inspected current renewal failure path releases the reservation when a
PaymentIntent enters `requires_action`. That behavior conflicts with this target
and is a known runtime gap. This governance amendment does not change it or
authorize an Orders/Payments/provider fix. No implementation may treat the
current path as evidence that authentication-required payment cannot later
succeed.

### InventoryAdmission reconciliation gate

The frozen S0-ARCH-01 and `INV-ADM-004` contracts currently use
`order_id + variant_id` for admission, queue identity, fencing, recovery, and
the durable reservation lookup. They do not support multiple reservation
generations for one Order and variant. Before implementation, the Inventory
Admission owner must approve a bounded extension that carries the same stable
`collection_attempt_id` through queue identity, lease and recovery fencing,
PostgreSQL lookup, and reservation uniqueness. The extension must preserve
PostgreSQL as inventory truth, serialize active generations for the occurrence
and variant, and keep ambiguous database outcomes fenced until durable state is
known.

The current payment-success path consumes reservations through the Order
boundary. The one-active-collection rule must make every active generation for
that renewal Order belong to the PaymentIntent that can succeed. If the current
Orders and Payments boundaries cannot enforce that relation, obtain their
owners' authority to carry and validate the collection-attempt identity through
payment success. Order identity alone is not proof of collection-attempt
identity.

No current subscription task may change the frozen InventoryAdmission design,
reservation schema, Orders APIs, Redis gate, or cleanup behavior under this
section alone. A separate owner-approved authority grant and implementation
plan are required.
