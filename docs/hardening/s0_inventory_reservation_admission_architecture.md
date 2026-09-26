# S0-ARCH-01: Inventory reservation admission architecture

Status: FROZEN architecture. The accepted architecture decisions remain unchanged.
Canonical task authority is tracked in `active_workstreams.md`; section 20 records
the current generic IA-03 admission and its exact scope. IA-01 and IA-02 are
complete and frozen. The historical S0-IA-AUTH-03 record documented the prior
bounded IA-03 authorization. S0-IA-AUTH-03R1 corrected only that record's Redis
support file boundary for typed `status` and `abandon` primitives.

Current generic IA-03 status: `AUTHORIZED / NOT STARTED` under the fresh bounded
task-admission decision recorded in section 20 and canonical
`active_workstreams.md`. The reconciliation prerequisite for that decision was
satisfied by PR #83:

- Canonical main reconciled: `d78a916472a75c9ffebea33acf6b07f41ffe07f3`.
- Accepted S0 integration: `f4127902c3f328b76674724faa6a473c629c01ef`.
- Exact-head CI run `36250010176`, attempt 1: `PASS`.
- Independent post-integration review: `PASS`.

S0 remains `READY`. IA-04 and later remain `NOT AUTHORIZED`. PR #80's
renewal-generation path remains separately unauthorized and requires its own future
S0 governance/task-admission decision. This admission does not reopen the integration
prerequisite; its scope is limited to the generic IA-03 contract below.

This decision addresses the confirmed Store.Repo saturation in the domain reservation
thundering-herd scenario. It evaluates exactly two bounded admission designs and keeps
PostgreSQL as the durable inventory authority.

## Decision summary

Recommended: Option A, a distributed per-variant admission gate in front of the
existing PostgreSQL reservation transaction.

Option A puts the large same-variant wait outside `Store.Repo`. It does not allocate
inventory. The existing transaction still locks the inventory row, checks availability,
updates counters, inserts or reuses `InventoryReservation`, and commits the durable
result.

Option B, a Redis ephemeral inventory hold allocator, is rejected for now. It adds a
second availability ledger and a reconciliation boundary before the proven PostgreSQL
guard. It may be reconsidered only after Option A has been tested under the required
multi-node and failure conditions and measured capacity targets cannot be met.

## Scope and non-goals

This document does not change production code, migrations, pool configuration,
performance thresholds, reservation state transitions, or certification status. It does
not select Redis as inventory truth and does not authorize a Redis, GenServer, queue, or
checkout implementation.

The implementation gate is at the end of this document. The next action is independent
acceptance review of this corrected architecture decision.

## 1. Confirmed current failure

The current generic reservation path is:

```text
request
  -> Store.Orders.reserve_inventory/3
  -> Store.Orders.InventoryReservations.reserve_inventory/3
  -> Repo.transaction/1
  -> inventory_items ... FOR UPDATE
  -> inventory_reservations ... FOR UPDATE
  -> availability guard
  -> counter and reservation mutation
  -> commit or rollback
```

The implementation is in [`inventory_reservations.ex`](../../lib/store/orders/inventory_reservations.ex).
`Store.Orders.reserve_inventory/3` delegates to it. The transaction checks out a
`Store.Repo` connection before the callback and returns that connection after commit or
rollback. A losing contender therefore keeps a connection while PostgreSQL waits on
the locked inventory row.

The canonical local herd evidence is:

| Measurement | Result |
|---|---:|
| Herd users | 160 |
| Store.Repo pool | 40 |
| Whole-window active peak | 40 |
| Whole-window utilization | 1.00 |
| Generic pool threshold | 0.95 |
| Expected inventory row-lock waiters | 34 |
| Unexpected lock waiters | 0 |
| Queue time mean | about 12.158 ms per query |
| Queue time p95 | about 89.042 ms per query |
| Queue time p99 | about 110.336 ms per query |
| Queue time maximum | about 113.720 ms per query |
| Contender calls with non-zero aggregate checkout queue | 160 of 160 |
| Winners | 1 |
| Governed losers | 159 |
| Oversell | 0 |
| Deadlocks | 0 |
| Database errors | 0 |

The evidence supports inherent current row-lock architecture saturation. It does not
show a correctness failure, a long transaction, an unexpected lock, or invalid metric
attribution.

The local run used the 24-scheduler `ci_gate` setting, which derives 160 contenders.
The same configuration has a lower effective herd on a four-scheduler CI runner. The
architecture decision is independent of that scheduler-dependent test cardinality.

## 2. Current reservation and authority boundaries

`InventoryReservations.reserve_inventory/3` normalizes quantities, sorts variant IDs
using binary UUID order, and wraps `reserve_variants/5` in `Repo.transaction/1`.

For each variant, the current path:

1. Reads and locks the `InventoryItem` row with `FOR UPDATE`.
2. Reads and locks the order plus variant reservation row with `FOR UPDATE`.
3. Checks `stock_on_hand - reserved_count` unless `allow_oversell` is enabled.
4. For a new reservation, updates inventory counters and inserts an active
   `InventoryReservation`.
5. For a replay, adjusts or refreshes the existing order and variant reservation.
6. Rolls back on an unavailable item or failed guard.
7. Invalidates stock and availability hints after the transaction, not inside it.

The current database identity is `order_id + variant_id`. The resource also derives the
canonical `reservation_key` as `order:<order_id>:sku:<variant_id>`. The unique identities
on [`inventory_reservation.ex`](../../lib/store/orders/inventory_reservation.ex) are the
final durable replay barrier.

Admission success is not stock ownership. Only a known PostgreSQL commit, or recovery
that finds that committed durable result, may establish `InventoryReservation.active`.
PostgreSQL remains the durable authority for `stock_on_hand`, `reserved_count`, and the
full `InventoryReservation` lifecycle. Redis, cache projections, and PubSub may coordinate
or report state, but they cannot manufacture availability or reservation truth.

The existing lifecycle remains authoritative:

```text
InventoryReservation.active
  -> consumed
  -> expired
  -> cancelled
```

Terminal states do not transition back to active. Admission is an upstream coordination
lifecycle. It must return the durable reservation identity when settlement completes and
must never replace or bypass the existing reservation lifecycle.

The existing [`Store.Support.Redis`](../../lib/store/support/redis.ex) wrapper and
`Redix` configuration in [`Store.Application`](../../lib/store/application.ex) and
[`runtime.exs`](../../config/runtime.exs) support rate limiting, warm cache operations,
hashes, and sorted sets. No existing Redis path is inventory authority.
`StockFastPath` and `AvailabilityCache` are read projections only. The existing
[`StoreWeb.WaitingRoom`](../../lib/store_web/waiting_room.ex) limits broad public HTTP
and LiveView entry. Its current public and live defaults are 380 requests per ten-second
window with a 450 hard limit. It does not know the variant key and is not a per-variant
reservation gate.

## 3. Final target behavior

The final flow for one logical single-variant reservation is:

```text
validated, server-owned request
  -> distributed per-variant admission
  -> bounded admission wait outside Store.Repo
  -> short existing PostgreSQL reservation transaction
  -> durable InventoryReservation result
  -> release admission lease
```

The admission layer answers only whether this request may enter the reservation
critical section. It never answers whether stock exists. PostgreSQL answers that under
the existing row lock.

The target properties are:

- A large same-variant herd waits in Redis or at the user-facing waiting boundary,
  not in PostgreSQL transactions.
- For the MVP, `K_v = 1` for every variant. At most one admission holder for a
  variant may enter the PostgreSQL reservation critical section across the cluster.
- `B_total` is a separate global inventory-reservation database-entry budget. Active
  reservation database entrants must remain at or below `B_total` across variants and
  nodes.
- Every admitted worker enters the existing durable reservation boundary.
- A rejected or expired admission has no inventory side effect.
- A completed admission includes the durable `InventoryReservation` identity.
- Redis loss fails closed. It never creates an availability result.

## 4. InventoryReservationAdmission lifecycle

No database resource is selected for this lifecycle. The initial design treats it as
ephemeral coordination state with bounded TTLs. `InventoryReservation` remains the
durable record.

### States

| State | Meaning | Inventory effect |
|---|---|---|
| `REQUESTED` | The validated request has a canonical identity but has not yet joined or acquired the gate. | None |
| `QUEUED` | The request has one queue member for its variant and waits for a permit. | None |
| `ADMITTED` | The gate granted a permit and issued a lease. The request has not yet changed inventory. | None |
| `RESERVING` | The worker owns the lease and is executing the existing PostgreSQL reservation transaction. | Only the existing transaction may change inventory |
| `UNKNOWN_DB_OUTCOME` | The operation may have reached PostgreSQL, but the caller cannot establish commit or rollback. No second durable attempt is allowed yet. | None is assumed; recovery must query PostgreSQL |
| `RECOVERING` | A recovery owner holds the request's recovery fence and reconciles the durable outcome using the existing logical reservation identity. | Only a confirmed PostgreSQL result may establish inventory state |
| `COMPLETED` | The transaction committed a durable reservation result. | The returned `InventoryReservation` is authoritative |
| `REJECTED` | The durable attempt ended without a reservation, such as `OUT_OF_STOCK` or a bounded persistence failure. | No new reservation effect |
| `EXPIRED` | A queue or admission lease reached its bounded deadline before settlement. | None unless a prior durable commit is found during recovery |
| `ABANDONED` | The request was explicitly abandoned or its owner disappeared before `RESERVING` completed. | None unless a prior durable commit is found during recovery |
| `UNRESOLVED` | Bounded recovery cannot prove the operation's trusted PRE or expected POST durable facts, required recovery evidence is unavailable at the bounded recovery deadline, or the trusted operation descriptor needed for attribution is unavailable. | No outcome is inferred. The operation stays fail closed behind an operational fence; affected capacity remains held or quarantined. |

Validation, authorization, and ownership failures happen before an admission lifecycle
is created. They do not create a fake `REJECTED` admission record.

### Transitions and ownership

The logical identity for every transition is the server-derived
`order_id + variant_id`, represented by the existing `reservation_key`. A deterministic
opaque Redis member derived from that identity prevents a replay from creating a second
queue member. A separate server-generated admission UUID and fencing token identify the
current lease owner.

| Transition | Guard and owner | Timeout | Side effects and cleanup | Crash and replay behavior |
|---|---|---|---|---|
| `REQUESTED -> QUEUED` | The request is authorized, has a valid single-variant input, and no live queued, admitted, recovery, or terminal record exists. The distributed gate owns the atomic enqueue. | Short request acknowledgement deadline, then the caller retries with the same logical identity. | Add one deterministic member to the variant queue and store bounded metadata. No inventory read or write. | A repeated request updates or returns the same queue entry. If the Redis operation is ambiguous, fail closed rather than enqueueing through a second path. |
| `REQUESTED -> ADMITTED` | A global budget slot and the `K_v = 1` variant permit are available. The Redis atomic operation owns promotion. | The admission-to-commit deadline begins immediately. | Record a lease token and expiry. The caller must begin `RESERVING` promptly. | A node crash leaves only an expiring lease. A replay returns the live admission instead of adding a member. |
| `QUEUED -> ADMITTED` | The member is the next eligible queued member, the variant has no active holder, and the global budget has capacity. The Redis gate owns promotion. | The lease deadline is derived from the bounded admission-to-commit deadline plus safety margin. | Remove the member from the waiting set, add the active lease, and return the fencing token. | A retry returns the same lease while it is valid. A stale release cannot release a newer token. |
| `QUEUED -> EXPIRED` | Queue deadline passed and no reservation is in `RESERVING` for this identity. The expiry worker or atomic acquire operation owns the transition. | Queue TTL is configured from user-facing wait policy and is finite. | Remove queue metadata and release no permit because none was held. | A late request receives the terminal result for the retention window. A later logical operation needs a new identity. |
| `QUEUED -> ABANDONED` | The trusted application owner explicitly cancels, or a bounded owner heartbeat shows the request is gone. The gate validates the member identity. | Cancellation is immediate; the queue TTL remains the fallback. | Remove the queue member and metadata. | A repeated cancel is a no-op. A client disconnect cannot directly forge another request's abandonment. |
| `ADMITTED -> RESERVING` | The worker owns the current fencing token and starts the existing local transaction. The reservation orchestrator owns the transition. | The admission-to-commit deadline covers Store.Repo checkout, transaction execution, final result handling, and commit or known rollback. Lease renewal occurs before half-life. | Mark the lease as in use. No stock mutation occurs before PostgreSQL begins its transaction. | If the node dies, the operation becomes subject to recovery after the bounded window. If the Redis lease cannot be renewed, the variant gate stops promoting replacements until recovery completes. |
| `ADMITTED -> EXPIRED` | The lease expires before the worker claims `RESERVING`. The gate reaper owns the transition. | Admission lease is finite. | Remove the lease and return the permit to the atomic gate after the safety check. | A late worker cannot use a stale fencing token. A replay may request admission again only after the terminal result is known and the durable identity is checked. |
| `RESERVING -> COMPLETED` | PostgreSQL definitively committed and the operation returns its durable `InventoryReservation` identity. The reservation orchestrator owns the transition. | The admission-to-commit deadline applies. | Store the durable reservation identity in bounded metadata, then release the admission and global permits. | If release fails after commit, PostgreSQL remains authoritative. A reaper retries release, and a replay returns the same durable reservation. |
| `RESERVING -> REJECTED` | PostgreSQL definitively rolled back or returned a governed reservation failure without a durable reservation. The reservation orchestrator owns the transition. | The known result must resolve before the admission-to-commit deadline. | Release the admission lease. Do not mutate `InventoryReservation` state for a failed reservation. | Rollback leaves PostgreSQL unchanged. A terminal rejection is replayed for the retention period; a new user operation must have a new logical identity. |
| `RESERVING -> UNKNOWN_DB_OUTCOME` | The operation may have reached PostgreSQL, but commit or rollback cannot be established. The reservation orchestrator creates the recovery fence atomically. | The admission lease is not treated as proof of rollback. Recovery starts within the bounded recovery window. | Keep the logical request fenced. Do not release capacity for same-identity retry until the safety window and durable lookup complete. | A process or connection failure leaves the request in recovery. Fence TTL expiry alone does not release capacity; a replay returns `RECOVERING` or governed unresolved status. |
| `UNKNOWN_DB_OUTCOME -> RECOVERING` | A recovery worker owns the current recovery fence and the transaction safety window has elapsed. | Recovery retry and backoff are bounded and have an absolute deadline. | Query PostgreSQL by `reservation_key`; do not use Redis state to decide the outcome. | A worker crash triggers bounded recovery retry under the same identity. TTL expiry signals reaping or escalation; if PRE/POST cannot be proven by the deadline, `UNRESOLVED` retains or quarantines the fence and affected capacity. |
| `RECOVERING -> COMPLETED` | A consistent PostgreSQL snapshot matches the operation's expected POST facts. The recovery worker owns the transition. | The recovery deadline applies. | Return the durable reservation identity and release the fenced admission/global permits idempotently. | Replays return the same durable reservation. A stale release cannot affect a newer admission. |
| `RECOVERING -> REJECTED` | A consistent PostgreSQL snapshot matches the operation's proven PRE facts, or an insert has no reservation row and its recorded inventory PRE facts still match after the safety window. The recovery worker owns the transition. The MVP does not automatically issue a second durable attempt from recovery. | The recovery deadline applies. | Mark the admission terminal and release its fenced capacity only after PRE/no-commit proof. No inventory mutation occurs. | A replay receives the same terminal or governed retryable result for the retention window. If retry is permitted later, it reuses the same `reservation_key` only after proven resolution and fence cleanup, and re-enters the same gate. |
| `RECOVERING -> UNRESOLVED` | Durable state matches neither valid trusted PRE nor expected POST facts, required recovery evidence remains unavailable at the bounded deadline, or the trusted operation descriptor is unavailable. The pure lifecycle guard records failure to prove either state as `:neither_match`. The recovery worker and operations owner hold the existing recovery fence. | The bounded recovery deadline applies. | Retain or quarantine the fence and affected admission/global capacity. Do not release, retry, promote, or infer an outcome. | Replay returns governed unresolved status. Only separately governed operational resolution may leave this condition. |

`COMPLETED`, `REJECTED`, `EXPIRED`, `ABANDONED`, and `UNRESOLVED` are terminal admission
states. `UNKNOWN_DB_OUTCOME` and `RECOVERING` are non-terminal recovery states.
`UNRESOLVED` ends the automated lifecycle but keeps the operational fence and affected
capacity held or quarantined. Terminal status does not mean that capacity is safe to
release. Resolved terminal metadata has bounded retention for replay and diagnostics,
then expires. Admission metadata is not inventory truth.

### Lease safety

The gate must not hand a permit to a replacement while the prior PostgreSQL transaction
may still be active. The implementation must establish one hard admission-to-commit
deadline, `T_db`, before accepting an MVP implementation. `T_db` starts when the request
is admitted and covers Store.Repo checkout, transaction execution, row-lock waiting,
the final database result, and commit or a known rollback. It is not only the callback
body's execution time.

The admission lease TTL, `L_admission`, is separate from `T_db`. `L_admission` must cover
the full bounded operation contract plus a configured safety margin, and it renews before
half-life while `RESERVING`. A lease expiry is never a permission to assume rollback or
to promote a replacement.

If lease renewal or Redis fencing becomes ambiguous, the gate fails closed for that
variant. It does not promote another request merely because a lease timestamp passed.
The gate keeps the variant holder and its global budget occupancy fenced until the
`T_db` safety window and recovery check complete. This is a capacity-preservation rule,
not an inventory decision. Redis cannot cancel an already-running PostgreSQL transaction.

If `T_db` expires before a known commit or known rollback is available, the operation
stops waiting for a normal result and enters `UNKNOWN_DB_OUTCOME`. A bounded watchdog
keeps both the variant occupancy and the global `B_total` occupancy fenced through the
configured database safety window while recovery reconciles PostgreSQL. Promotion is
allowed only after recovery proves the expected POST or PRE/no-commit facts and the
bounded database contract establishes that the prior operation cannot still be running,
or after separately governed operational resolution of `UNRESOLVED`. Establishing only
that the prior operation has stopped does not resolve its durable outcome or permit
capacity reuse. A lease TTL alone is never sufficient evidence for promotion.

For an active `RESERVING` lease, expiry is a reaper signal, not an automatic delete or
permit return. The reaper retains the variant and global fence, transitions the logical
request into recovery, and promotes nothing for that variant until the recovery rule
resolves it. If the finite recovery deadline is reached without proof of PRE or POST,
the admission becomes `UNRESOLVED`. The identity and affected capacity remain fail
closed behind a retained or quarantined fence. Expiry does not release capacity, authorize
a retry or promotion, or establish a durable outcome. Only separately governed operational
resolution may leave this condition.

#### PostgreSQL outcome classification

The admission layer must classify the database result before releasing capacity:

- `KNOWN_COMMIT`: PostgreSQL definitively committed. The durable reservation wins,
  admission may be released, and replay returns the existing reservation.
- `KNOWN_ROLLBACK`: PostgreSQL definitively rolled back or returned a governed
  reservation rejection. No new durable reservation exists, admission may be released,
  and normal retry or rejection policy applies.
- `AMBIGUOUS_OUTCOME`: a connection drop, timeout, process crash, or lost final response
  means the operation may have reached PostgreSQL. The system must not assume rollback,
  release the same logical request for an unrestricted retry, or report a successful
  reservation. It enters `UNKNOWN_DB_OUTCOME` and then `RECOVERING`.

Recovery queries PostgreSQL by the server-derived `reservation_key` and compares the
consistent durable snapshot with the trusted, operation-specific PRE and expected POST
facts. A full POST match proves commit; a full PRE match proves rollback. For an insert,
absence of the reservation row is insufficient unless the recorded inventory PRE facts
also match. A neither-match snapshot, required evidence unavailable at the bounded
deadline, or missing trusted descriptor resolves to `UNRESOLVED`. Retain or quarantine
the fence and affected capacity. Do not infer commit or rollback, retry, or release
capacity. Redis state never decides whether PostgreSQL committed.

#### Recovery fence

An ambiguous outcome creates an ephemeral recovery fence for the same logical
`order_id + variant_id` identity. The fence owner is the recovery worker holding the
current admission token or a successor recovery token. Its TTL covers the bounded
database safety window and recovery retry budget, with a finite absolute maximum. The
owner uses bounded lookup retry and backoff. Cleanup removes the fence only after a full
expected POST match or proven PRE/no-commit result. If the owner crashes, the fence remains
until its bounded recovery window ends; another recovery worker may resume it under the
same identity during that window. While recovery is open, replay returns its state and
cannot start another unrestricted durable attempt.

If the recovery fence reaches its finite absolute maximum without proof of PRE or POST,
the lifecycle enters `UNRESOLVED` and raises an operational recovery condition. Retain or
quarantine the fence and affected capacity. Fence TTL or ordinary cleanup does not
release that capacity or prove rollback. A new durable attempt is not allowed until
separately governed operational resolution reconciles PostgreSQL truth and the affected
capacity.

The fence prevents duplicate attempts only. It is not durable reservation truth and does
not replace the unique PostgreSQL `reservation_key` identity.

#### Fencing token scope

The admission fencing token is server-generated for the current Redis lease owner. Redis
atomic operations compare the token and owner epoch before renewing, releasing, expiring,
or replacing a lease. A stale owner therefore cannot release a newer lease, decrement a
new owner's global permit, or make a stale admission appear current. Tokens are never
client-selected.

The token protects Redis admission ownership and capacity state only. PostgreSQL does not
currently validate an admission token inside the existing `InventoryReservation`
transaction. Inventory correctness is provided by the PostgreSQL transaction, the
exclusive inventory-row lock, the availability check, and the durable identity. Admission
capacity correctness is provided by Redis ownership, lease and deadline rules, the
variant/global capacity freeze, and the recovery fence. A future database-side token
validation rule would require a separate architecture and migration decision.

Admission release is idempotent and token-checked. It is attempted after a known commit,
known rollback or rejection, a request failure before database entry, and a timeout only
after the bounded contract establishes that no transaction can still be running. An
ambiguous timeout or process crash retains the variant/global occupancy behind the
recovery fence until PostgreSQL is reconciled. If PostgreSQL committed and the process
dies before release, the durable reservation remains valid and the bounded lease cleanup
eventually recovers capacity; Redis and PostgreSQL are not treated as one distributed
transaction.

## 5. Non-negotiable invariants

| Invariant | Requirement |
|---|---|
| `INV-ADM-001` | Admission never means inventory has been reserved. Only durable reservation completion reserves stock. |
| `INV-ADM-002` | PostgreSQL remains authoritative for `InventoryItem`, `InventoryReservation`, counters, and durable reservation results. Admission terminal metadata remains ephemeral. |
| `INV-ADM-003` | No admission path may permit overselling. Every successful reservation still passes the final PostgreSQL availability guard. |
| `INV-ADM-004` | One logical `order_id + variant_id` request cannot create multiple durable reservations or multiple counter effects. |
| `INV-ADM-005` | Queue and admission leases expire automatically within bounded deadlines. |
| `INV-ADM-006` | An application-node crash cannot permanently consume an admission slot. |
| `INV-ADM-007` | Waiting for admission does not check out a `Store.Repo` connection. |
| `INV-ADM-008` | Redis failure cannot manufacture inventory availability or authorize a reservation. |
| `INV-ADM-009` | Existing `InventoryReservation` lifecycle transitions remain authoritative. |
| `INV-ADM-010` | Redis, ETS, and PubSub state are never durable inventory truth. |
| `INV-ADM-011` | Active reservation database entrants across all variants and nodes are at most `B_total`, and active entrants for any one variant are at most `K_v = 1` during the MVP. |
| `INV-ADM-012` | The admission-to-commit deadline covers Store.Repo checkout, transaction execution, final result handling, and commit or known rollback. |
| `INV-ADM-013` | An ambiguous PostgreSQL outcome enters a recovery fence and durable `reservation_key` lookup before permit reuse or retry. |
| `INV-ADM-014` | Queue lifetime is independent of Phoenix request or LiveView process lifetime. |

## 6. Option A: distributed per-variant admission gate

### Flow

```text
validated request
  -> canonical order_id + variant_id identity
  -> global budget and per-variant Redis admission
  -> queued or leased admission result
  -> existing Store.Orders.InventoryReservations.reserve_inventory/3
  -> existing PostgreSQL row-lock transaction
  -> InventoryReservation result
  -> fenced Redis release
```

The gate is a coordination boundary only. It does not decrement stock, create a hold,
or return a cached availability answer.

### Redis representation

The exact key names are an implementation concern, but the design requires these
logical structures:

- A per-variant queue-order sorted set ordered only by a server-side sequence. Its
  members are opaque, deterministic admission members derived from the server-owned
  logical request identity.
- A separate per-variant queued-expiry sorted set ordered only by the queued entry's
  server-side deadline. It removes expired entries without overloading the FIFO score or
  scanning the queue. Queue order and queued expiry are different semantics.
- A per-variant active-lease sorted set ordered only by active lease expiry. This set is
  the active-lease expiry index. A bounded metadata hash stores state, request identity
  digest, lease token, owner epoch, queue sequence, and expiry. It contains no stock
  count. No second equivalent active-lease expiry index is required.
- A recovery-fence record keyed by the logical request identity with a bounded TTL. It
  blocks duplicate attempts during `UNKNOWN_DB_OUTCOME`, `RECOVERING`, and
  `UNRESOLVED`; it is not inventory truth. Expiry alone never releases unresolved
  capacity.
- A global active-permit counter or equivalent global lease index for `B_total`. It is
  needed because independent per-variant caps could still fill the database pool across
  many hot variants.
- A global queued-entry counter or equivalent bounded aggregate for `Q_global_max`. It
  increments only for a new queue member and decrements with expiry, abandonment,
  promotion, or terminal cleanup in the same atomic operation. It is queue metadata, not
  inventory state.

Acquire, promote, renew, release, expire, and recovery operations must run as one
Redis-side atomic operation where they touch the same variant and global budget. The
global and variant keys must share one Redis atomicity domain. A Redis Cluster design
must place related keys in the same hash slot or use another single atomicity boundary;
cross-shard best-effort updates are not sufficient. A Lua script or equivalent
server-side atomic command is appropriate. A local GenServer or node-local semaphore
cannot own the decision because it would not bound multiple nodes.

### Atomic admission condition

For the single-variant MVP, the conceptual admission guard is:

```text
can_admit?(request) iff:
  server-owned request identity is valid
  and the identity is not terminal, UNKNOWN_DB_OUTCOME, RECOVERING, or UNRESOLVED
  and the request owns or receives the next permitted queue position
  and the K_v = 1 variant permit is available
  and the B_total global reservation DB-entry permit is available
  and Redis admission coordination is healthy
```

Queue-position selection, expired-member cleanup, and acquisition of the variant and
global permits must be decided in the same Redis-side atomic operation. The operation
must either acquire both capacities for the same admission owner or acquire neither;
independent variant and global semaphore grants are not safe. Client-side `GET` then
`SET` coordination is not an equivalent implementation.

Redis `TIME` or a server-side monotonic sequence should provide ordering. Application
wall clocks must not decide queue order or lease expiry.

The queue and lease operations are expected to be `O(log n)` or better. Terminal
metadata has a TTL. The design does not use a Redis counter or bitmap as stock truth.

### Permit derivation

The MVP freezes the per-variant permit rule:

```text
K_v = 1
```

`K_v` is the cluster-wide maximum number of active reservation database entrants for one
variant. It is not adaptive during the MVP. The existing reservation path takes an
exclusive `FOR UPDATE` lock on the target `InventoryItem`, so a larger MVP value would
put additional admitted transactions back into PostgreSQL row-lock waiting without
increasing same-row critical-section throughput.

Any future `K_v > 1` requires a separate measured capacity review that proves useful
throughput improves without recreating Store.Repo saturation. The following capacity
inputs remain relevant to that future review and to the global budget, but they do not
change the MVP rule.

Define:

- `R`: the sum of the `Store.Repo` pool sizes for active application nodes.
- `H`: the reviewed number of simultaneously hot variants for the workload.
- `B_total`: a global inventory DB entrant budget below `R`, leaving measured headroom
  for checkout, payment, expiry, and other database work.

The global budget rule is:

```text
B_total = capacity-derived budget with non-inventory headroom
```

`B_total` remains authoritative when more variants are hot than the estimate `H`; queued
variants cannot collectively exceed it. It is a separate protection from `K_v` and is
not set to an arbitrary value in this document.

`B_total` must be changed through one cluster-wide configuration authority. Every node
uses the same Redis global key. A node-local calculation is invalid. When the budget is
reduced, existing leases finish under their fencing deadline and new promotions stop
until occupancy is below the new budget. When node count changes, the budget is
recomputed from the active node pool inventory or remains at the conservative configured
value until that inventory is reliable.

The generic `0.95` pool gate remains a test and infrastructure contract. It is not used
as an automatic formula for a future `K_v` value or `B_total`.

### Fairness and backpressure

The required policy is FIFO-ish ordering within one variant, bounded contention, and
expiry. Strict global fairness is not required. Redis sequence order provides a stable
best-effort order across nodes; expired or abandoned members are skipped atomically.

The gate has two finite configurable queue bounds:

```text
Q_variant_max = maximum queued requests for one variant
Q_global_max  = maximum queued requests across the admission system
```

The values are capacity and product-policy inputs, not arbitrary constants selected by
this ADR. When either bound is reached, the gate does not enqueue another member. It
returns a governed busy, retry, or waiting-room result.

A queued member is coordination state, not a long-lived Phoenix request or LiveView
process. The server returns a bounded status result or retry token. A client may retry
with the same logical identity using bounded backoff, or the application may publish a
read-side status update. Queue lifetime is never the lifetime of a blocked request
process. The web/application layer owns waiting-room UX and retry presentation. The
inventory domain owns queue correctness, identity, capacity, lease state, and
retry-safe status.

The gate allows one member per logical request identity. Repeated requests do not gain
priority. Admission members are server-derived and cannot be supplied by a client.

### Notifications and streams

Phoenix PubSub has no admission-correctness authority. It may carry queue-status
notifications, waiting-room updates, or operational read-side projections. PubSub loss
must not grant or release a permit, create or reject a reservation, or alter durable
stock. Redis admission state and PostgreSQL durable state remain the authorities defined
above.

No Redis Stream is required for admission correctness in the MVP. A later asynchronous
waiting or admission-processing design may choose Streams only through a separate
architecture decision; a Stream is not an implicit replacement for the bounded queue or
the atomic admission gate.

### Idempotency and replay

The domain must pass the existing server-owned `order_id` and `variant_id` after
ownership validation. The gate derives:

```text
logical_request_key = order_id + variant_id
reservation_key = order:<order_id>:sku:<variant_id>
admission_member = HMAC(server_admission_secret, logical_request_key)
```

The HMAC member is opaque and stable. Redis metadata maps it to the current admission
UUID and fencing token. A retry while queue or lease metadata exists returns that same
state. A retry while `UNKNOWN_DB_OUTCOME` or `RECOVERING` exists returns the same
recovery state and cannot start a second unrestricted durable attempt. After durable
settlement, the existing unique `reservation_key` returns the same
`InventoryReservation` rather than creating a second row.

A replay while `UNRESOLVED` returns governed unresolved status. It cannot claim success,
infer rollback, start another durable attempt, or release the recovery fence or affected
capacity. Only separately governed operational resolution may leave this condition.

Redis is ephemeral. If it loses queue metadata, the safe response is to fail closed
until the recovery fence and transaction safety window complete. A replay after recovery
may create the same deterministic member again, but it cannot create a second durable
reservation. Strong recovery of a pre-settlement queue position across total Redis data
loss would require a durable admission ledger, which is outside this MVP and is not
silently assumed here.

### Existing transaction integration

The MVP calls the existing single-variant reservation path only after admission. It does
not move the PostgreSQL row lock, change counter arithmetic, add a cache decision, or
change the `InventoryReservation` state machine. The admission wrapper must enforce
`K_v = 1` and the separate `B_total` budget before the existing transaction begins.

The current multi-variant path sorts variant UUIDs before locking. A future multi-variant
admission must use deterministic binary UUID acquisition ordering for a bundle or use a
single atomic multi-key gate. It must not acquire independent variant permits in arbitrary
order. That bundle problem is outside the MVP.

## 7. Option B: Redis ephemeral inventory hold allocator

### Flow

```text
validated request
  -> Redis atomic hold allocation
  -> ephemeral hold with expiry
  -> PostgreSQL durable settlement and final availability validation
  -> release or reconcile the Redis hold
```

Option B uses Redis for an immediate high-concurrency availability or hold decision. It
does not make Redis durable inventory truth. PostgreSQL must still lock and validate the
current `InventoryItem` before writing the durable reservation.

### Redis representation and authority boundary

The likely structures are:

- A hash containing a derived, rebuildable availability projection or held quantity.
- A sorted set containing hold IDs ordered by expiry.
- Per-hold metadata with the logical request identity, quantity, expiry, owner token,
  and settlement status.

The current integer stock semantics do not justify a bitmap. A Redis count is a mirror,
not authority. The only authoritative statement is the PostgreSQL transaction that
validates and persists the reservation.

If Redis allocates a hold and PostgreSQL persistence fails, the application releases the
hold. If release fails, the hold expires and a bounded reconciliation worker retries the
release. The request returns no successful reservation.

If PostgreSQL commits and Redis acknowledgement or release fails, PostgreSQL wins. The
hold remains conservatively present until TTL or reconciliation removes it. It must not
be reused to create a second reservation. Durable reconciliation needs a stable hold ID
linked to the durable result, which adds a new persistence and migration decision.

Redis restart or data loss invalidates the hot projection. The system must rebuild it
from PostgreSQL before serving hold decisions. During rebuild it fails closed. It cannot
infer available stock from an empty Redis hash.

### Why this is more ambitious

Option B changes the immediate availability path, creates a second representation of
hot inventory, and makes every failure between hold allocation and durable settlement a
reconciliation case. It also needs lease fencing strong enough to prevent a hold from
expiring while its settlement transaction remains active. PostgreSQL still has to reject
stale or conflicting holds, so the durable row lock remains necessary.

This can reduce the number of requests that reach PostgreSQL when Redis state is healthy,
but it increases the number of state transitions and recovery paths before the durable
truth is known.

## 8. Failure analysis

The following tables state the intended safe outcome, owner, durable truth, and manual
reconciliation requirement for every requested failure case.

### Option A failure analysis

| Failure | Safe outcome | Recovery owner | Durable truth and manual work |
|---|---|---|---|
| Redis unavailable | Do not admit new reservation work. Return bounded busy or retry behavior without entering `Repo.transaction`. Existing durable reservations remain queryable through PostgreSQL. | Gate client and operations team | PostgreSQL is unchanged. No manual inventory reconciliation. |
| Redis response is partial or uncertain | Treat the coordination result as failed closed. Do not issue a second enqueue, permit, or release path until the same identity and token are reconciled. | Gate recovery and operations | Redis state cannot decide a PostgreSQL outcome; no inventory action is inferred. |
| PostgreSQL unavailable | If rollback is known, release the lease and return a rejected infrastructure result. If commit or rollback is ambiguous, enter `UNKNOWN_DB_OUTCOME` and then `RECOVERING`. If full PRE/POST proof remains unavailable at the deadline, mark `UNRESOLVED` and retain or quarantine affected capacity. | Reservation orchestrator and recovery worker | PostgreSQL decides whether a reservation exists. `UNRESOLVED` does not infer an outcome or release capacity; no new attempt starts before separately governed operational resolution and the same gate. |
| App node dies while queued | The queue member expires or is abandoned. | Redis expiry worker | No database state exists. No manual work. |
| App node dies while admitted | If the database operation did not begin, the lease expires after its bounded deadline. If it may have begun, create or retain the recovery fence and reconcile after the safety window. | Redis expiry and recovery worker | Query the durable request identity before reuse. No rollback is inferred from process death. |
| App node dies after DB commit before release | The durable reservation remains. The lease is cleaned later with its fencing token. | Recovery worker | PostgreSQL reservation identity and unique key win. No duplicate effect; manual work is not expected. |
| Redis lease expires while DB transaction is active | Keep the variant holder and its global budget occupancy fenced. Do not admit a same-variant replacement until the bounded database safety window and recovery check complete. | Gate recovery worker | PostgreSQL commit or rollback remains authoritative. If bounded recovery cannot prove PRE or POST, mark `UNRESOLVED` and retain or quarantine capacity for operational resolution. |
| Duplicate or replayed request | Return the existing queue, lease, terminal result, or durable reservation for the same logical identity. | Gate and reservation domain | Redis deduplicates the live admission; PostgreSQL unique identity prevents duplicate durable effect. No manual work. |
| Queued client disconnects | Mark the queue member abandoned when the trusted owner detects it, or let its finite queue TTL expire. No request process remains blocked for queue lifetime. | Application owner and gate expiry | No database state exists. No manual work. |
| Admitted client disconnects before DB entry | The lease remains bounded and is released or expires through the gate; a socket disconnect cannot forge a release or force a replacement. | Admission owner and gate expiry | No inventory effect is inferred. No manual work. |
| Client disconnects during DB transaction | The server operation continues under `T_db` or enters `UNKNOWN_DB_OUTCOME`; disconnect does not cancel a transaction by guessing. | Reservation orchestrator and recovery worker | PostgreSQL decides any started reservation. No manual work. |
| PostgreSQL commit succeeds but Redis release fails | Keep the durable result and let a token-checked reaper or lease TTL recover Redis capacity. | Recovery worker and gate reaper | PostgreSQL reservation truth remains valid; replay resolves through `reservation_key`, with no duplicate reservation. |
| Network partition between app and Redis | Non-holder requests fail closed. A holder may finish only while its valid fenced lease remains known. | Gate recovery and operations | No new database work is admitted during ambiguity. PostgreSQL remains truth. |
| Redis restart or data loss | Enter recovery-fenced mode. Rebuild only coordination metadata and wait through the maximum lease safety window before promotion. | Operations and recovery worker | Inventory is read from PostgreSQL if needed. A bounded set of ambiguous request identities is reconciled; manual work is an escalation, not a normal path. |
| PostgreSQL transaction rollback | When rollback is known, mark the admission rejected, release its lease, and return the domain error. | Reservation orchestrator | No reservation or counter effect survives rollback. No manual work. |
| Admission queue stampede | The Redis atomic operation promotes only within global and variant budgets. Excess requests wait in bounded Redis state or are rejected at the edge. | Gate and web/application policy | No inventory effect occurs before PostgreSQL. No manual work. |
| Hot SKU with no remaining stock | Let the durable guard reject contenders. Do not treat a Redis hint as proof that stock is zero. | Reservation domain, then gate worker | PostgreSQL stock and reservation rows decide. No manual work. |
| Many hot SKUs simultaneously | Per-variant gates share the global admission budget. Hot variants queue independently without exceeding the database budget. | Global gate and operations | PostgreSQL remains the source of truth for each variant. No manual work. |

### Option B failure analysis

| Failure | Safe outcome | Recovery owner | Durable truth and manual work |
|---|---|---|---|
| Redis unavailable | Do not allocate holds and do not fall back to unbounded PostgreSQL settlement. | Hold allocator and operations | PostgreSQL remains unchanged. No manual work. |
| PostgreSQL unavailable | Keep or release the ephemeral hold until TTL, but report no durable reservation. | Hold reconciler | PostgreSQL has no committed reservation. A failed release is retried; manual work may be needed after repeated reconciliation failure. |
| App node dies while queued | The queue entry expires without a hold. | Redis expiry worker | No database state. No manual work. |
| App node dies while admitted or holding | The hold expires. If settlement may have started, query the durable request identity before reusing the hold. | Hold reconciler | PostgreSQL wins if it committed. Ambiguous hold-to-row linkage may require manual review. |
| App node dies after DB commit before hold release | The durable reservation stays. The Redis hold conservatively reduces projected availability until expiry or reconciliation. | Reconciler | PostgreSQL is truth. No duplicate reservation, but stale Redis capacity can require operational cleanup. |
| Redis hold expires while DB transaction is active | A second hold may be allocated unless lease fencing and settlement coordination are perfect. PostgreSQL must reject any conflict. | Hold allocator and reservation transaction | PostgreSQL prevents oversell, but DB entrants and reconciliation can grow. This is a direct capacity risk. |
| Duplicate or replayed request | A live deterministic hold may be reused; after Redis loss, a second ephemeral hold may be created. | Hold allocator and durable reservation identity | PostgreSQL uniqueness prevents duplicate durable rows. Redis may need reconciliation. |
| Client disconnects | Release or expire the hold. A settlement already in progress must complete or roll back by database rules. | Hold owner and reconciler | PostgreSQL decides durable state. Failed release is recoverable by TTL. |
| Network partition between app and Redis | Fail closed for new holds. Any uncertain hold is treated as unavailable until TTL or reconciliation. | Hold allocator and operations | PostgreSQL remains truth, but the mirror cannot be trusted during the partition. |
| Redis restart or data loss | Rebuild counters and active holds from PostgreSQL before accepting new hold decisions. | Rebuild worker and operations | PostgreSQL is truth. Rebuilding active holds requires durable hold linkage; otherwise manual reconciliation can be required. |
| PostgreSQL transaction rollback | Release or expire the Redis hold and return no reservation. | Hold reconciler | No durable reservation. A stale hold only reduces projected availability until cleanup. |
| Admission queue stampede | Redis can atomically create many holds quickly, but memory, expiry work, and settlement backlog still need independent caps. | Hold allocator and application policy | PostgreSQL remains truth. Reconciliation backlog can become an operational incident. |
| Hot SKU with no remaining stock | The Redis projection may reject early, but a stale positive projection may still allocate a hold. PostgreSQL must reject it. | Reservation domain and projection rebuild | PostgreSQL decides. Redis projection repair is required after divergence. |
| Many hot SKUs simultaneously | Each hash and hold set must be maintained and rebuilt. Durable settlement still needs a DB budget. | Hold allocator and reconciliation workers | PostgreSQL remains truth, but Redis memory and recovery cardinality increase with active holds. |

## 9. State-machine integration

Admission success does not create an `InventoryReservation` directly. The relationship is:

```text
InventoryReservationAdmission.RESERVING
  -> existing Store.Orders.InventoryReservations.reserve_inventory/3
  -> committed InventoryReservation.active
  -> InventoryReservation identity returned
```

Admission `COMPLETED` must carry the durable reservation ID and the logical request key.
Admission `REJECTED`, `EXPIRED`, `ABANDONED`, and `UNRESOLVED` must not call a reservation
transition or decrement a counter. `UNKNOWN_DB_OUTCOME`, `RECOVERING`, and `UNRESOLVED`
must not start a second durable attempt or release ambiguous capacity. The unresolved
fence may leave only through separately governed operational resolution.

The existing `active -> consumed`, `active -> expired`, and `active -> cancelled`
transitions remain unchanged. Payment success, release, and expiry continue to use their
existing domain boundaries. Admission must not become a shortcut around those paths.

The current source contains direct reservation mutation helpers alongside the declared
Ash state machine. This architecture does not widen that gap or attempt to repair it.
An implementation must use the existing approved reservation facade and preserve the
current no-oversell, replay, and terminal-state tests.

## 10. Concurrency behavior without benchmarks

The table describes the intended shape, not measured capacity.

| Same-variant contenders | Current architecture | Option A | Option B |
|---:|---|---|---|
| 40 | Up to 40 connections can be occupied by row-locking transactions. | Requests queue outside PostgreSQL. At most `K_v = 1` entrant for the variant and at most `B_total` entrants overall enter the transaction. | Healthy Redis can create bounded holds, but settlement still needs a DB budget and hold fencing. |
| 160 | The confirmed 40/40 saturation occurs with the remaining contenders waiting for pool checkout. | Redis holds the excess queue. Store.Repo occupancy is bounded by `B_total`, not herd size, and same-variant entrants remain at `K_v = 1`. | Redis holds can absorb the initial herd, but every failed or stale hold adds reconciliation work. |
| 1,000 | A large pool checkout backlog and row-lock wait set form. | Queue depth and user-facing backpressure decide whether excess requests wait or receive busy behavior. DB entrants remain bounded. | Hold memory and settlement backlog grow. A Redis fault requires fail-closed rebuild before recovery. |
| 100,000 | Direct admission is not safe or certified. | A bounded Redis queue plus admission policy can keep PostgreSQL work within `B_total`; requests beyond policy limits are rejected or kept in bounded waiting-room state without one indefinitely blocked BEAM process per queued request. | It can reduce direct DB entry while healthy, but counter/hold recovery and lease errors can reintroduce DB pressure. It is not safe to claim without reconciliation and failure tests. |

Option A changes the scarce resource from PostgreSQL connections to bounded Redis queue
state and admission status. Queue depth is limited by `Q_variant_max` and `Q_global_max`,
and queued status is not implemented as a blocked Phoenix request or LiveView process.
It does not make 100,000 direct synchronous reservations certified by itself.

## 11. Performance and scaling review

### Temperature and authority

| Data | Classification | Authority |
|---|---|---|
| Inventory reservation admission | HOT coordination state | Redis gate state is ephemeral and never stock truth |
| `InventoryItem` counters | HOT durable state | PostgreSQL |
| `InventoryReservation` lifecycle | COLD/DURABLE after the hot write | PostgreSQL and existing state machine |
| Availability projection | HOT derived state | ETS/cache projection only |
| Admission telemetry aggregates | WARM operational data | Redis or bounded telemetry storage; historical reporting uses PostgreSQL or derived aggregates |

Option A adds two or more Redis operations to the normal reservation path. The gain is
that a queued request does not occupy a PostgreSQL connection. Uncontended latency can
remain within the platform target only after measurement; this document does not claim
the target is met.

Option A operations should remain `O(log n)` or better for queue insertion, promotion,
lease expiry, and removal. Queue and lease TTLs must prevent unbounded state. No peak
path may scan reservation history or an unbounded Redis collection. The gate must not
create an unbounded BEAM process mailbox.

Queue entries have a finite queued-wait TTL. Active leases have a finite
`L_admission` TTL and recovery fences have a finite recovery TTL with an absolute
maximum. Recovery TTL expiry signals reaping or escalation; it does not release an
unresolved fence or affected capacity. Unresolved capacity remains held or quarantined
until separately governed operational resolution. Resolved terminal admission metadata
has bounded retention. The queued-expiry and active-lease indexes are cleaned by bounded
Redis-side operations; cleanup never relies on scanning an entire FIFO queue.

The existing PostgreSQL transaction remains short and local. Provider I/O, analytics,
notifications, and heavy side effects remain outside it.

The admission path has no PubSub or Redis Stream correctness dependency. PubSub may carry
queue-status or read-side UI updates, but loss cannot grant, release, or alter admission
or durable stock. No Redis Stream is required for the MVP. A later stream-based waiting
design needs a separate decision.

Option A requires no new PostgreSQL migration solely for admission. It relies on the
existing unique `inventory_items.variant_id` lookup, unique
`inventory_reservations(order_id, variant_id)` identity, and unique
`inventory_reservations.reservation_key` identity. The existing reservation state and
expiry indexes support the unchanged reservation lifecycle and expiry worker. If these
durable lookup or uniqueness guarantees are absent in a deployed schema, implementation
must stop for a separate schema review.

### Pool and admission interaction

`B_total` is the explicit admission budget for reservation transaction entrants. It is
not the Store.Repo pool size and does not replace the generic `0.95` observer gate. The
pool remains a final safety boundary for all database traffic.

The desired relation is:

```text
large external herd
  -> bounded Redis admission wait
  -> small reservation worker set
  -> short PostgreSQL critical section
```

The current HTTP and LiveView waiting room can reduce broad public entry, but it does
not know the variant key or protect a popular inventory row. It remains a separate
user-facing admission layer. If its generic rate-limit backend fails open, that behavior
must not bypass the stricter fail-closed InventoryAdmission gate.

### PgBouncer transaction mode

The selected design must work with future PgBouncer transaction pooling. It must not use
session variables, temporary tables, session advisory locks, connection ownership
across Redis waits, or a session-local permit. Lease tokens and request identities travel
as normal application values. PostgreSQL row locks remain inside one database
transaction. No PgBouncer configuration is changed here.

### Current architecture at 100,000 users

The current architecture relies on a bounded Store.Repo pool and PostgreSQL
serialization, but it has no per-variant admission before `Repo.transaction`. That is
not safe or certified for 100,000 direct concurrent payment or reservation initiations.
Option A supplies bounded upstream coordination. It does not remove the need for
application policy, queue limits, timeout handling, and capacity measurement.

## 12. Security and abuse review

- Admission identity is derived from trusted, server-validated `order_id` and
  `variant_id`. Clients do not choose Redis keys, queue members, fencing tokens, queue
  positions, or lease expiries.
- Opaque HMAC-derived members or server-generated UUIDs prevent enumeration and make
  unrelated requests harder to interfere with.
- The gate checks order ownership and authorization before creating `REQUESTED`.
- One logical request gets one live queue member. Repeated floods do not create extra
  positions for the same order and variant.
- Queue depth, per-identity admission rate, and client disconnect behavior need limits
  at the admission and web/application policy layers. Rate limiting controls abuse; it
  does not replace the inventory correctness guard.
- Queue entries and leases have hard TTLs. A malicious client cannot hold a permit
  forever by keeping a socket open.
- Client disconnects do not authorize a client to cancel another order's admission.
- Redis keys remain server-side. No Redis command, key, hold token, or fencing token is
  exposed to a browser.
- An admission secret must rotate under an explicit key version. Rotation cannot make a
  live permit reusable by an untrusted caller.
- No cache, PubSub message, or client-provided stock value is accepted as inventory
  proof.

## 13. Observability and analytics

Both options require the following event names. Option A emits them for queue and lease
operations. Option B emits them for queue, hold, and settlement operations.

Events:

- `admission_requested`
- `admission_queued`
- `admission_admitted`
- `admission_expired`
- `admission_abandoned`
- `admission_released`
- `admission_recovery_started`
- `admission_recovery_resolved`
- `reservation_started`
- `reservation_completed`
- `reservation_rejected`

Required metrics:

- queue depth per hot variant
- admission wait p50, p95, and p99
- active leases, active global permits, and global budget occupancy
- queue expiry and abandonment counts
- recovery fence count and recovery latency
- durable reservation entrants per variant
- Store.Repo utilization and checkout queue time
- reservation transaction latency
- Redis latency, errors, and recovery-fence duration
- PostgreSQL lock waits and deadlocks
- oversell count, which must remain zero

Global metrics must not attach an unbounded raw variant ID label. Individual hot-SKU
diagnostics may use sampled or explicitly enabled tags. Operational dashboards may use
Redis or cached aggregates. Historical analytics should use PostgreSQL, materialized
views, or bounded aggregate snapshots, not raw reservation-history scans during a sale.

## 14. Comparison matrix

| Criterion | Option A: distributed admission gate | Option B: Redis ephemeral hold allocator |
|---|---|---|
| Zero-oversell safety | Strongest fit. Existing PostgreSQL final guard remains unchanged. | Possible only if every settlement rechecks PostgreSQL; Redis must never be trusted as final stock. |
| Change to current DB transaction | Small. Put admission before the existing transaction and release afterward. | Larger. Add hold settlement, hold IDs, reconciliation, and projection rebuild behavior. |
| DB connection protection | Direct. Queued requests do not enter `Repo.transaction`; global and variant budgets cap entrants. | Conditional. Healthy Redis helps, but lease expiry and settlement failures can create pressure. |
| 100k herd behavior | Bounded queue or policy rejection outside PostgreSQL. | Bounded only if hold allocation, expiry, and settlement recovery all remain healthy. |
| Multi-node safety | One Redis global and per-variant atomic gate; no local semaphore. | One Redis atomic hold allocator, plus distributed reconciliation and durable linkage. |
| Redis dependency | Required for new admission. Failure fails closed without changing inventory. | Required for both availability coordination and holds. Failure also invalidates the hot projection. |
| Redis failure behavior | No new admissions; recovery fence protects old leases. | No new holds; full counter and hold rebuild is required before recovery. |
| Crash recovery | Expiring queue and lease state, with PostgreSQL request identity as final barrier. | Expiring holds plus durable hold-to-settlement reconciliation. |
| Reconciliation complexity | Low to moderate. Reconcile bounded ambiguous leases and releases. | High. Reconcile counters, holds, durable reservations, expiries, and divergence. |
| Idempotency complexity | Existing `reservation_key` plus deterministic admission member. | Existing key plus hold identity, hold replay, and settlement linkage. |
| State-machine complexity | Adds an upstream ephemeral lifecycle without changing reservation states. | Adds ephemeral ownership and settlement states around a second availability ledger. |
| Operational complexity | Redis gate, lease reaper, budget configuration, and recovery fence. | All of Option A concerns plus projection rebuild and divergence repair. |
| Latency | Adds gate round trips but removes pool waiting under contention. | Can be fast when healthy, but reconciliation and rebuild add degraded paths. |
| Implementation risk | Lower. Existing durable transaction is preserved. | Higher. More state exists before durable truth is known. |
| Extraction suitability | Internal Store boundary only for the MVP; extraction is deferred until the stated hardening and second-consumer gates. | Lower initially. Extraction must own a hold ledger and settlement reconciler. |
| Migration risk | No schema migration is required for the MVP. | Durable hold linkage may require a resource, columns, or migration. |
| Observability | Queue, lease, DB entrant, and pool metrics map directly to the failure. | Must also measure projection drift, hold age, rebuild lag, and settlement divergence. |
| Future extensibility | Supports waiting-room policy and later coordination without changing stock truth. | Supports high-volume holds, but only after reconciliation and durability boundaries are proven. |

## 15. Architecture decision

### Recommended

Option A: distributed per-variant admission gate in front of the existing PostgreSQL
reservation transaction.

### Why

Option A solves the confirmed failure at the correct boundary. The 160-request herd can
wait without occupying 40 PostgreSQL connections, while the existing row lock remains
the final no-oversell guard. It works across nodes when the global and per-variant gates
are Redis-atomic. Its crash state is a bounded lease, and its durable outcome is already
represented by the existing order and variant reservation identity.

It also gives the smallest internal extraction boundary. The first implementation can
wrap one single-variant call, preserve the current transaction, and be disabled without
changing inventory semantics. Redis coordinates entry; PostgreSQL continues to decide
stock.

`InventoryAdmission` remains an internal Store capability during initial hardening. This
ADR does not authorize a public package or generic API. Extraction requires implementation
hardening, deterministic concurrency tests, Redis failure tests, crash/recovery
certification, canonical performance certification, a second real consumer, and a
proven stable API.

### Rejected for now

Option B: Redis ephemeral inventory hold allocator.

Option B is not rejected because Redis cannot be used for coordination. It is rejected
because it makes Redis an immediate availability ledger and requires reconciliation for
every hold-to-durable-settlement gap. It adds state before the database has confirmed
stock and carries higher migration, replay, and recovery risk.

### What would cause reconsideration

Reconsider Option B only after an Option A implementation has passed deterministic
multi-node and Redis-failure tests and measured performance evidence shows one of these
conditions:

1. The bounded admission queue cannot meet the accepted flash-sale wait and backpressure
   policy even when the PostgreSQL entrant budget is safe.
2. The existing durable transaction itself cannot provide the required throughput after
   admission is bounded, and product requirements need an ephemeral hold before durable
   settlement.
3. The team accepts a durable hold-to-settlement record and has an approved design for
   rebuilding Redis projections entirely from PostgreSQL after loss.

Those are review triggers, not implementation instructions in this document.

## 16. Smallest viable implementation slice

The MVP, if independently approved, is limited to one single-variant reservation path:

```text
one validated order and variant
  -> deterministic per-variant admission acquire
  -> existing Store.Orders.InventoryReservations.reserve_inventory/3
  -> durable result or existing rejection
  -> fenced admission release
```

The MVP must include only the coordination primitive, the lifecycle contract, bounded
queue and lease cleanup, deterministic request identity, and the wrapper around the
existing reservation call. It must prove:

- waiting requests do not check out `Store.Repo` connections;
- one logical request has one admission member;
- one durable reservation effect exists for a replay;
- PostgreSQL still decides availability;
- one winner and governed losers remain correct under same-variant contention;
- Redis failure fails closed;
- a node crash cannot permanently consume a permit;
- a lease cannot expire into a replacement while the database transaction may still be
  active;
- all global and per-variant permits are shared across nodes.

The MVP excludes consume, release, expiry redesign, checkout refactoring, multi-variant
bundle admission, admin UI, analytics dashboards, and a Redis stock mirror.

### MVP contract after corrections

The frozen MVP contract is:

1. Single-variant admission only.
2. Globally coordinated `K_v = 1` for each variant.
3. A separate global reservation DB-entry budget `B_total`.
4. Redis coordinates bounded admission only.
5. PostgreSQL remains final availability and durable reservation authority.
6. Admission success does not imply reservation success.
7. Per-variant and global queue depth are finite and bounded.
8. Queue lifetime is independent of Phoenix request or LiveView process lifetime.
9. Redis failure is fail-closed for new admission.
10. Admission ownership is leased, fenced, and idempotent.
11. The admitted database operation has one bounded admission-to-commit deadline.
12. Ambiguous database outcomes enter recovery before permit reuse or retry.
13. Recovery checks durable PostgreSQL truth using `reservation_key`.
14. The existing final PostgreSQL transaction remains the zero-oversell guard.
15. No production implementation is authorized by this ADR.

## 17. High-level future phases

These are design phases only. They are not implementation micro-prompts.

### Phase A: admission primitive and lifecycle contract

Define the Redis atomic operations, deterministic identity, lease fencing, queue limits,
budget derivation inputs, terminal retention, and recovery-fence behavior. Review the
state machine and failure tables independently.

### Phase B: single-variant integration

Wrap the existing single-variant reservation call. Keep the PostgreSQL transaction and
all `InventoryReservation` behavior unchanged. Prove that admission wait produces no
Store.Repo checkout occupancy.

### Phase C: failure recovery and lease expiry

Test queued node death, admitted node death, post-commit release failure, Redis
unavailability, lease renewal loss, PostgreSQL rollback, replay, and client disconnect.
Prove bounded recovery and no duplicate durable effect.

### Phase D: multi-node and Redis-failure testing

Run the gate across multiple application nodes. Test global budget changes, hot variants,
Redis restart and data loss, recovery fencing, and queue backpressure. Do not certify
capacity until the failure behavior is deterministic.

### Phase E: performance certification

Measure admission wait, DB entrants per variant, Store.Repo occupancy, pool queue time,
reservation latency, Redis latency, queue depth, and correctness at approved workloads.
Only an accepted capacity review may change the derived permit budget.

## 18. Explicit implementation gate

No implementation may begin until this design is independently reviewed and accepted.
The design has now been independently accepted and is frozen. That acceptance does
not authorize the implementation plan. The historical S0-IA-AUTH-03 record
documented separate, bounded IA-03 authorization, as corrected by S0-IA-AUTH-03R1
for the minimum typed Redis `status`/`abandon` support boundary. That record does not
grant current execution authority. IA-01 and IA-02 are complete and frozen.

The acceptance review must specifically confirm:

- PostgreSQL remains the only durable inventory authority.
- The final PostgreSQL availability guard remains in both options and in the selected
  implementation.
- The selected gate is globally bounded across nodes, with `K_v = 1` per variant and a
  separate `B_total` reservation DB-entry budget.
- Variant and global capacity are granted atomically, not by independent race-prone
  checks.
- The admission-to-commit deadline covers Store.Repo checkout through known commit or
  known rollback, and ambiguous outcomes enter a bounded recovery fence.
- A Redis failure fails closed without manufacturing availability.
- Lease expiry cannot admit a replacement while a database transaction may still run.
- Replays cannot create duplicate durable reservation effects.
- Queue depth and request-process lifetime are independently bounded.
- Queued expiry, active lease expiry, PubSub notifications, and any future Stream use
  retain their separate non-authoritative responsibilities.
- Existing PostgreSQL identity and index guarantees are sufficient; no migration is
  required solely for the admission layer.
- `InventoryAdmission` remains internal until the stated extraction gates are met.
- Existing `InventoryReservation` lifecycle and payment/order behavior remain unchanged.
- The implementation scope remains limited to the approved MVP.

IMPLEMENTATION STATUS:
IA-01 COMPLETE / FROZEN
IA-02 COMPLETE / FROZEN
IA-03 NOT AUTHORIZED

IA-01 COMPLETION RECORD:
- Initial implementation: `7fd2e88fec286d9e216c865d26ef28b1a8c69438`
- IA-01R1 accepted head: `f252fcf1d27d22be92a0bffdc88e7306e3c84e4c`
- Exact-head CI: `33754973403` — SUCCESS
- IA-01 established: pure admission lifecycle/state vocabulary; exact legal transition
  matrix; terminal and `UNRESOLVED` fail-closed semantics; server-derived reservation
  identity; stable logical identity digest; deterministic mutation request fingerprint;
  server-generated operation identity; operation epoch semantics; internally coherent
  PRE/POST operation descriptor; pure Lease/deadline values; distinct DB and lease
  deadline semantics; immutable `K_v = 1`; no Redis/PostgreSQL/config/migration/runtime
  orchestration.

IA-02 COMPLETION RECORD:
- Final certified branch head: `b860b355d3a94f7d27a9895f229bb91e74428109`
- IA-02 lineage: `47e124a925439165a83d9544ec122862fe6e022a`,
  `d798fb9d964eff82c70439f5b61af097c2e84280`,
  `c0b27208347accb94f21f830d228d9539ced447c`,
  `f78f04e98cb483cc512c70dae3c2e4317f25d5a0`
- Security-leg integration ancestor: `d5d8dd93026026c245c612369b034f8d3d62d1c4`
- Final governance head: `b860b355d3a94f7d27a9895f229bb91e74428109`
- Post-integration review: IA-02 POST-INTEGRATION REVIEW = PASS
- Exact-head CI: `33873401924` — SUCCESS
- IA-02 established: versioned Redis coordination namespace; common atomic Redis hash
  tag; opaque admission member; enqueue/deduplicate behavior; finite per-variant and
  global queue bounds; immutable `K_v = 1`; bounded `B_total` global admission; atomic
  dual-budget decision; monotonic `operation_epoch` allocation; replay/mismatch/busy
  epoch discipline; bounded queued expiry cleanup; expiry evidence retention;
  process-independent exact-key test cleanup; O(1) namespace-global sequence;
  fail-closed Redis behavior; no Redis stock authority; no `Store.Repo`/PostgreSQL
  mutation; no IA-03+ behavior.

HISTORICAL AUTHORIZATION BOUNDARY (S0-IA-AUTH-03 / R1):
The historical IA-03 authorization covered only the internal caller-independent
admission orchestration listed in the implementation-plan gate (frozen plan DL-01),
plus the S0-IA-AUTH-03R1 minimum typed Redis support required by that orchestration.
Its historical coding boundary listed these files:

```text
lib/store/orders/inventory_admission.ex
lib/store/orders/inventory_admission/redis.ex
test/store/orders/inventory_admission_test.exs
test/store/orders/inventory_admission_redis_test.exs
```

Under that historical boundary, the Redis-file allowance was limited to typed Redis
primitives for `status` and `abandon` (`QUEUED -> ABANDONED` under
`trusted_pre_reservation_abandonment`). Status must not create, enqueue, or admit.
Abandon must not invent atomic next-head promotion; frozen `abandon_queued` removes
only queued membership and marks `ABANDONED`, and next-head promotion remains the
`promote_next`/`promote_queued` path described in that record.

That historical authorization did not include IA-04 or later, PostgreSQL reservation
execution, recovery, workers, checkout, shared lifecycle fences, lease
renewal/release machinery, DL-02 telemetry/rate-limit expansion, configuration
beyond IA-03 needs, or certification.
Section 16 describes the future MVP and remains a frozen design, not the current
IA-03 coding boundary.

HISTORICAL NEXT-STEP NOTE:
The original sequence called for independent review/merge of S0-IA-AUTH-03R1 and then
a separate IA-03 coding prompt. Canonical governance later required main-to-S0
reconciliation and a fresh bounded task-admission decision before IA-03 implementation.
PR #83 completed the reconciliation prerequisite, and the separate generic IA-03
task-admission decision is recorded in section 20. This note is historical. Completion
of IA-03 does not authorize IA-04 or any later slice.

## 19. Approved bounded amendment for SBH-10-04

This addendum amends S0-ARCH-01 only to admit server-derived reservation generations for physical subscription renewals. In the base architecture, generic checkout uses `order_id + variant_id` as its logical identity and recovery-fence identity. For a physical renewal generation, the full server-derived `reservation_key` is the logical durable-operation and recovery-fence identity. `INV-ADM-004` continues to require at most one durable effect per logical identity: the generic key remains one `(order_id, variant_id)` pair, while each renewal generation has its own exact key. `K_v` still serializes entrants by variant and `B_total` still bounds total database entrants. All other lease, PostgreSQL, ambiguity, recovery, and fail-closed requirements remain in force. This section grants no runtime implementation authority by itself.

The renewal contract requires the exact key through a server-owned typed request, operation descriptor, Lease, recovery fence, and PostgreSQL lookup. It does not authorize adding caller-supplied keys to the existing generic request. The S0 implementation plan still freezes the IA-01 `Request`, `Operation`, and `Lease` contracts and forbids reopening them. Before SBH-10-04 can be marked `READY`, a separate S0 governance/task admission must authorize the minimum new typed renewal path and the exact-key propagation/recovery changes to those contracts. That S0 admission must preserve the generic path and the invariants below. If the S0 authority cannot be granted without weakening those invariants, stop and return to governance.

Generic checkout continues to derive:

```text
order:<order_id>:sku:<variant_id>
```

The renewal-specific server path may derive a generation key in this form:

```text
order:<order_id>:sku:<variant_id>:renewal_collection:<collection_attempt_id>:generation:<reservation_generation_id>
```

The collection and generation IDs are trusted server identities. Generic request construction still rejects caller-supplied reservation keys. The renewal-specific typed path must carry the exact generation key through request identity, request fingerprint, operation descriptor, Lease value, Redis recovery metadata, and PostgreSQL recovery. The Lease may also retain the identity digest used for coordination.

The full reservation key is the logical durable-operation identity. Redis continues to gate by variant for `K_v = 1` and keeps the existing global `B_total` limit. Redis remains a coordination and recovery-fencing layer. It cannot establish stock availability, reservation existence, or commit outcome.

PostgreSQL remains the sole durable reservation authority. Recovery must query by the exact generation key and compare the operation's trusted PRE/POST facts. An ambiguous database outcome retains the existing recovery fence. Lease expiry, Redis loss, a local timeout, or missing evidence cannot authorize another durable mutation. The [cross-domain authority amendment](../governance/sbh_10_04_cross_domain_authority_amendment.md) assigns the separate Orders migration for historical generations and the partial unique active-row index.

This addendum does not change `K_v`, `B_total`, Redis structures outside the exact-key metadata needed by the request, the generic reservation key, or the PostgreSQL stock check. It does not authorize unrelated InventoryAdmission stages. At the canonical main base, the full PostgreSQL recovery service and worker remain planned work. The later SBH-10-04 re-admission must verify their current source compatibility and must obtain any separate S0 task authority needed to implement missing recovery stages.

## 20. Fresh generic IA-03 task admission

This governance record admits only the generic caller-independent IA-03 Redis
orchestration against task base
`f4127902c3f328b76674724faa6a473c629c01ef`. S0 remains `READY`. Generic IA-03 is
`AUTHORIZED / NOT STARTED`. IA-04 and later remain `NOT AUTHORIZED`, and IA-03
completion does not authorize them. This admission adds no lifecycle state and does
not change the frozen lifecycle.

Generic IA-03 uses only the existing identity form:

```text
order:<order_id>:sku:<variant_id>
```

The exact implementation boundary is:

```text
lib/store/orders/inventory_admission.ex
lib/store/orders/inventory_admission/redis.ex
test/store/orders/inventory_admission_test.exs
test/store/orders/inventory_admission_redis_test.exs
```

No fifth file is authorized. These frozen contracts are read-only:

```text
lib/store/orders/inventory_admission/request.ex
lib/store/orders/inventory_admission/operation.ex
lib/store/orders/inventory_admission/lease.ex
test/store/orders/inventory_admission_state_test.exs
```

IA-03 may implement only:

- `InventoryAdmission.reserve`, `InventoryAdmission.status`, and
  `InventoryAdmission.abandon`.
- Construction and validation of the frozen generic `Request`.
- Calls to frozen IA-02 `enqueue_or_return_existing/2` and
  `promote_queued/2`.
- The minimum new typed Redis `status` and `abandon` operations.
- Immediate return for queued work, with bounded busy, mismatch, and unavailable
  handling.
- Exact replay convergence, finite deadline and lease metadata propagation,
  caller-independent Redis queue lifetime, and server-owned operation identity
  returned from frozen IA-02 state.
- Low-cardinality transition or status observability only when required within the
  four authorized files.

The typed Redis `status` operation:

- Never creates a request or operation, queues a missing request, or grants admission
  because status was requested.
- Validates exact trusted reservation identity, request fingerprint, and
  metadata/fence/index coherence.
- Returns typed lifecycle information and fails closed on missing, contradictory,
  malformed, or uncertain evidence.
- Uses only bounded queued-expiry or promotion behavior already authorized by IA-02.
- Performs no PostgreSQL work.

The typed Redis `abandon` operation authorizes only `QUEUED -> ABANDONED` under
guard `trusted_pre_reservation_abandonment`. It must validate exact trusted identity
and fingerprint, reject mismatch or stale state, atomically remove only the exact
queued member, write coherent terminal `ABANDONED` evidence, and retain finite replay
evidence. Repeated abandon is idempotent and remains governed by the same typed
contract. It must not abandon
`ADMITTED`, `RESERVING`, `UNKNOWN_DB_OUTCOME`, `RECOVERING`, or `UNRESOLVED`;
infer a PostgreSQL outcome; release active durable-operation capacity; or invent
next-head promotion. Existing `promote_queued/2` remains the promotion mechanism.
InventoryAdmission must not use raw Redis, `KEYS`, or unbounded `SCAN`.

The legal lifecycle transition `ADMITTED -> EXPIRED` remains unchanged. IA-03 may
observe and report `ADMITTED`, but its operational unclaimed-lease expiry and release
mechanism is excluded. A later separately authorized lease/reaper phase owns
operational recovery of stale unclaimed admitted leases. IA-03 must not invent an
admitted-expiry Redis transition, release an admitted variant permit
because time elapsed, decrement `B_total` for an admitted lease because time elapsed,
implement lease release or renewal machinery, or add a reaper.

The existing lifecycle states remain:

```text
REQUESTED
QUEUED
ADMITTED
RESERVING
UNKNOWN_DB_OUTCOME
RECOVERING
UNRESOLVED
COMPLETED
REJECTED
EXPIRED
ABANDONED
```

Terminal states remain `COMPLETED`, `REJECTED`, `EXPIRED`, `ABANDONED`, and
`UNRESOLVED`.

IA-03 must not add or modify `Store.Repo` usage, PostgreSQL reads or writes,
`InventoryReservation` or `InventoryItem` mutation, `ADMITTED -> RESERVING`,
durable reservation execution, PRE/POST PostgreSQL collection, ambiguous database
outcome handling, `InventoryAdmission.Recovery`, Oban, workers, a reaper, active
lease renewal or release, shared reservation fences, `Store.Orders.reserve_inventory/3`
integration, checkout, payment, or subscription integration, multi-variant admission,
migrations, schema, configuration, dependencies, CI, performance certification,
DL-02 rate-limit or telemetry expansion, or IA-04+.

PR #80's renewal-generation InventoryAdmission work is not part of this admission. It
remains separately `NOT AUTHORIZED` and requires its own future S0 governance/task
admission for the new typed identity contract and exact-key recovery. Do not modify
`Request`, `Operation`, or `Lease` to accommodate renewal-generation keys. The
renewal path does not change the generic identity above.

### Performance & Scaling Review

- HOT: bounded Redis admission, status, and abandon coordination.
- WARM: none required.
- COLD: PostgreSQL remains the durable authority and IA-03 does not enter it.
- Database query count: zero; N+1 risk: none.
- Indexes and caching: unchanged; IA-03 adds no cache, invalidation, or stampede path.
- Redis uses only the existing HASH/ZSET and O(1) sequence. Redis has no stock or
  availability ledger.
- TTLs retain queue, evidence, and terminal records for finite periods.
- Cleanup uses bounded exact-key and index operations only.
- PubSub is optional and limited to a read/status projection.
- Store.Repo entrants for queued, status, and abandon paths: zero.
- Oban: no enqueue or uniqueness path is added.
- Telemetry and logging: no expansion; any required transition/status events stay
  low-cardinality and inside the four authorized files.
- No process or timer per queued waiter and no waiter state proportional to queue
  length in a GenServer.
- No 100k certification claim.
