# Inventory Reservation Admission Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the smallest single-variant distributed admission tracer bullet in front of the existing PostgreSQL inventory reservation transaction, while preserving PostgreSQL durable authority, zero-oversell behavior, bounded `Store.Repo` occupancy, and replay safety.

**Architecture:** Frozen S0-ARCH-01 Option A. Redis coordinates bounded, leased admission only. The MVP freezes `K_v = 1` for every variant and uses a separate cluster-global `B_total` reservation DB-entry budget. `Store.Orders.InventoryReservations` remains the durable reservation implementation.

**Tech Stack:** Elixir, Phoenix, Ash 3.x, Ecto/PostgreSQL, Redix/Redis, Oban, Phoenix PubSub, existing `Store.Repo` and `Store.DirectRepo` split.

This is a planning artifact. It authorizes no production implementation, migration, configuration change, Redis write, PostgreSQL write, test run, or performance run.

---

## 1. Goal and fixed contract

The tracer bullet proves this exact path for one validated order and one variant:

```text
server-validated request
  -> reservation_key identity
  -> Redis enqueue-or-deduplicate
  -> atomic K_v = 1 plus B_total admission
  -> existing Store.Orders.InventoryReservations.reserve_inventory/3
  -> known commit, known rejection, or ambiguous-outcome recovery
  -> durable result or bounded recovery status
  -> idempotent, fenced Redis release
```

The capability must move waiting outside PostgreSQL without changing the existing
`InventoryItem` row lock, availability check, `InventoryReservation` lifecycle, or
counter semantics.

The implementation-facing invariants are:

1. `K_v = 1` is a compile-time/domain rule for the single-variant MVP. It is not a
   runtime setting and is not adaptive.
2. `B_total` is a separately configured, cluster-global budget for active reservation
   DB entrants. It is strictly below aggregate `Store.Repo` capacity after reviewed
   non-reservation headroom.
3. An admission requires both the variant permit and the global permit in one atomic
   Redis decision. Neither permit may be granted independently.
4. `ADMITTED` means only that a leased admission was granted. It never means stock is
   owned or that an `InventoryReservation` exists.
5. PostgreSQL remains the authority for `stock_on_hand`, `reserved_count`, reservation
   identity, reservation state, final availability, and zero-oversell protection.
6. A queued request does not retain a Phoenix request or LiveView process for the full
   queue lifetime.
7. Redis failure fails closed for new admission. There is no direct PostgreSQL
   fallback from an unavailable or uncertain Redis decision.
8. An uncertain database result enters recovery and is reconciled by PostgreSQL
   `reservation_key` before permit reuse or another durable attempt.
9. The tracer bullet accepts one variant only. Multi-variant admission is rejected at
   this boundary until a deterministic ordered or atomic multi-key design is separately
   reviewed.

## 2. Non-goals

This plan does not include:

- changing `InventoryReservation` state transitions;
- replacing or weakening the PostgreSQL `FOR UPDATE` availability guard;
- a Redis availability, stock, or hold ledger;
- multi-item or multi-variant atomic admission;
- checkout, payment, consume, release, or reservation-expiry redesign;
- waiting-room UI, LiveView UX, admin UI, analytics dashboards, or browser admission;
- a generic package or public `InventoryAdmission` API;
- a new PostgreSQL resource, column, index, or migration;
- a Redis Stream workflow;
- a user-controlled feature toggle;
- canonical S0 performance certification or a 100,000-request claim.

The existing multi-variant checkout path through
`Store.Orders.reserve_inventory_for_checkout/3` remains outside this tracer bullet.
When the protected single-variant facade is enforced, a multi-variant request must
return an explicit unsupported result rather than silently bypassing admission.

## 3. Current source baseline

The following source facts are the boundaries the implementation must preserve.

| Source | Current fact | Planning consequence |
|---|---|---|
| [`lib/store/orders/domain.ex`](../../lib/store/orders/domain.ex:162) | `Store.Orders.reserve_inventory/3` currently delegates directly to `InventoryReservations.reserve_inventory/3`. | This remains the high-level integration point. Enforced single-variant calls must delegate through admission before reaching the durable primitive. |
| [`lib/store/orders/inventory_reservations.ex`](../../lib/store/orders/inventory_reservations.ex:16) | The normal path opens `Repo.transaction/1` and reserves normalized variants. | The tracer bullet calls this existing path with exactly one variant. Its transaction body is not rewritten. |
| [`lib/store/orders/inventory_reservations.ex`](../../lib/store/orders/inventory_reservations.ex:663) | The transaction locks `InventoryItem` by `variant_id` with `FOR UPDATE`, then locks the order/variant reservation row. | This is why the MVP permit is exactly `K_v = 1`. |
| [`lib/store/orders/inventory_reservations.ex`](../../lib/store/orders/inventory_reservations.ex:692) | Availability is checked from `stock_on_hand - reserved_count`, except for the explicit `allow_oversell` setting. | Redis must never answer availability or alter these counters. |
| [`lib/store/orders/inventory_reservations.ex`](../../lib/store/orders/inventory_reservations.ex:770) | The durable key is `order:<order_id>:sku:<variant_id>`. | This is the stable reconciliation identity and must be derived server-side. |
| [`lib/store/orders/inventory_reservation.ex`](../../lib/store/orders/inventory_reservation.ex:77) | Durable states are `active`, `consumed`, `expired`, and `cancelled`; identities cover both `order_id + variant_id` and `reservation_key`. | Admission states remain separate. No admission state replaces a durable state. |
| [`priv/repo/migrations/20260224201500_phase_11_inventory_reservations.exs`](../../priv/repo/migrations/20260224201500_phase_11_inventory_reservations.exs:77) | PostgreSQL has unique indexes for `(order_id, variant_id)` and `reservation_key`, plus inventory variant lookup and reservation lifecycle indexes. | No admission migration is planned. Recovery can use `reservation_key` without inventing a schema. |
| [`lib/store/support/redis.ex`](../../lib/store/support/redis.ex:1) | The shared wrapper uses the configured Redix connection and currently exposes ordinary commands, pipelines, hashes, and sorted-set helpers. | Admission-specific EVAL/atomic handling belongs behind an internal admission adapter; generic Redis helpers do not become inventory authority. |
| [`lib/store/support/rate_limit/redix_client.ex`](../../lib/store/support/rate_limit/redix_client.ex:1) | The repository already uses Redis server-side EVAL for a compound rate-limit operation. | Lua/server-side atomicity is consistent with an existing repository convention. |
| [`lib/store_web/waiting_room.ex`](../../lib/store_web/waiting_room.ex:173) | The generic waiting room allows on Redis/rate-limit errors. | It cannot be the inventory correctness gate. Inventory admission has a stricter fail-closed policy. |
| [`config/config.exs`](../../config/config.exs:99), [`config/runtime.exs`](../../config/runtime.exs:474), [`config/test.exs`](../../config/test.exs:120) | Redis is currently configured through the rate-limit connection; test support uses a dedicated Redis DB and Oban uses `Store.DirectRepo`. | The first implementation reuses the existing environment-prefixed Redix connection. New admission settings are a separate application configuration section, not a new Redis server. |
| [`lib/store/application.ex`](../../lib/store/application.ex:50) | The Redix child is started from the configured rate-limit Redis settings. | Enforced mode is invalid unless the shared Redis connection is available. |
| [`config/config.exs`](../../config/config.exs:113), [`lib/store/workers/expire_inventory_reservations_worker.ex`](../../lib/store/workers/expire_inventory_reservations_worker.ex:1) | Oban has an `:inventory` queue and existing bounded retry workers. | Per-identity recovery can use a dedicated inventory worker without moving the synchronous reservation transaction into Oban. |
| [`priv/repo/performance_smoke_test.exs`](../../priv/repo/performance_smoke_test.exs:1), [`test/support/performance_smoke_observer_contract.ex`](../../test/support/performance_smoke_observer_contract.ex:1) | The current performance harness observes Store.Repo utilization, checkout queue behavior, expected inventory waits, and a `0.95` pool gate. | Later certification must extend or consume this evidence; this planning task does not run it. |

The current source also supports legitimate same-order/variant quantity adjustment:
the durable transaction applies a delta to an existing active reservation. The
admission identity must therefore prevent concurrent duplicate operations while
allowing a later, authorized adjustment to be serialized through the same
`reservation_key` after the preceding operation has resolved.

## 4. Frozen architecture references

The implementation plan is subordinate to:

- [`s0_inventory_reservation_admission_architecture.md`](s0_inventory_reservation_admission_architecture.md), especially the final flow, lifecycle, Option A atomic condition, lease safety, outcome classification, failure analysis, performance review, MVP contract, and implementation gate.
- [`phase_00_docs.md`](../agent_notes/phase_00_docs.md), including the S0-ARCH-01C decision record and the `NOT AUTHORIZED` status.
- [`docs/governance/performance_scaling.md`](../governance/performance_scaling.md), for Redis key prefixes, layered temperature, PubSub behavior, and performance-card requirements.
- [`docs/hardening/08_extraction_gates.md`](08_extraction_gates.md), for the later extraction gates and the prohibition on treating this plan as extraction approval.

The frozen decisions carried into implementation are:

| Decision | Normative implementation rule |
|---|---|
| Option | Option A only: distributed Redis coordination before the existing PostgreSQL reservation transaction. |
| Variant capacity | `K_v = 1` for every variant in the MVP, across all nodes. A future `K_v > 1` requires a separate measured capacity review. |
| Global capacity | `B_total` is cluster-global, bounded below aggregate `Store.Repo` capacity, and leaves reviewed headroom for all other DB traffic. |
| Authority | Redis owns admission coordination state only. PostgreSQL owns durable inventory and reservation truth. |
| Outcome | Known commit, known rollback/rejection, and ambiguous DB outcome are distinct. Ambiguity enters a recovery fence. |
| Waiting | `Q_variant_max` and `Q_global_max` are finite configuration policies. Queue state never requires a long-lived caller process. |
| Lease | The admission lease covers the bounded admission-to-commit operation plus safety margin. Expiry alone never authorizes replacement. |
| Recovery | Durable lookup by `reservation_key` decides whether PostgreSQL committed. Redis state cannot decide that question. |
| Notifications | Phoenix PubSub is read-side/status only. Redis Stream is not required for MVP correctness. |
| Schema | No PostgreSQL migration is required solely for admission while the existing unique/index guarantees remain present. |
| Extraction | `InventoryAdmission` remains an internal Store capability until the stated hardening, certification, consumer, and stable-API gates pass. |

Option B, the Redis ephemeral inventory hold allocator, remains **REJECTED FOR NOW**.
It would create a second immediate availability/hold ledger alongside PostgreSQL and
add settlement, divergence, crash, reconciliation, and replay states. Reconsider it
only after an implemented and measured Option A fails the accepted scale/latency
goals and a new architecture decision accepts that additional ledger.

## 5. Domain and resource map

Admission is coordination state, not a second inventory domain. Use the fewest
semantic modules needed to keep ownership clear.

| Concept | Recommended representation | Durable PostgreSQL resource? | Owner and responsibility |
|---|---|---:|---|
| `Store.Orders.InventoryAdmission` | Internal domain service/facade in `lib/store/orders/inventory_admission.ex`. Holds the lifecycle transition contract, orchestration, feature-gate branch, telemetry calls, and the only normal entry into the protected path. | No | `Store.Orders`. It validates state transitions and delegates Redis transitions and the existing durable reservation primitive. It does not read cached stock or write inventory counters. |
| `Store.Orders.InventoryAdmission.Request` | Pure typed Elixir struct in `lib/store/orders/inventory_admission/request.ex`. Contains trusted `order_id`, normalized `variant_id`, desired quantity, `reservation_key`, request fingerprint, and actor/ownership context as appropriate. | No | Created only after server-side validation. It is not persisted as an Ash resource. |
| `Store.Orders.InventoryAdmission.Lease` | Pure typed Elixir value in `lib/store/orders/inventory_admission/lease.ex`, decoded from the current Redis lease record. Contains admission member, variant, lease token, owner epoch, server deadlines, and logical identity digest. | No | `InventoryAdmission` consumes it; `InventoryAdmission.Redis` stores and compares it. It is never a PostgreSQL authority token. |
| `Store.Orders.InventoryAdmission.Recovery` | Internal recovery service in `lib/store/orders/inventory_admission/recovery.ex`. Performs bounded PostgreSQL reconciliation and asks the Redis adapter to resolve or retain the fence. | No | The recovery service owns the durable lookup decision; Redis only protects recovery ownership and capacity. |
| Admission status | Closed status map/typespec returned by `InventoryAdmission`, not another resource/module. It carries state, opaque status reference, retry guidance, and durable reservation identity when known. | No | Status is a read projection of Redis plus PostgreSQL durable lookup where required. |
| Redis records | Versioned ZSET/HASH/string records described in Section 8. | No | `InventoryAdmission.Redis` is an adapter, not a lifecycle authority. Multi-key transitions are server-side atomic. |
| `InventoryReservation` | Existing Ash/PostgreSQL resource in `lib/store/orders/inventory_reservation.ex`. | Yes | Existing resource and `Store.Orders.InventoryReservations` retain state, identity, counters, and the final reservation transaction. |

Do not create `InventoryAdmissionRequest`, `InventoryAdmissionLease`, or
`InventoryAdmissionRecovery` tables. Do not add a generic `manager`, `handler`,
`helper`, or package layer. State atoms and transition guards remain in the main
admission service; the Redis adapter only translates atomic results.

### Recommended future file tree

```text
lib/store/orders/
├── domain.ex                                      # existing high-level facade; narrow gate delegation
├── inventory_admission.ex                         # internal service, lifecycle, API, orchestration
├── inventory_admission/
│   ├── request.ex                                 # trusted request and identity value
│   ├── lease.ex                                   # lease value and internal handle
│   ├── redis.ex                                   # names, EVAL contracts, Redis result decoding
│   └── recovery.ex                                # PostgreSQL reconciliation and fence resolution
└── inventory_reservations.ex                      # existing durable tx; narrow reservation_key read only if needed

lib/store/workers/
├── inventory_admission_recovery_worker.ex          # one bounded recovery job per logical identity
└── inventory_admission_reaper_worker.ex            # bounded expiry/fence maintenance, no full scans

test/store/orders/
├── inventory_admission_state_test.exs              # pure state and deadline rules
├── inventory_admission_redis_test.exs              # atomic Redis contracts and idempotency
├── inventory_admission_test.exs                    # domain boundary and failure policy
└── inventory_admission_recovery_test.exs           # durable reconciliation and crash outcomes

test/store/workers/
└── inventory_admission_recovery_worker_test.exs    # Oban execution/retry contract

test/store/governance/
└── inventory_admission_concurrency_test.exs        # K_v, B_total, multi-node and herd invariants
```

The exact files above are future implementation outputs. None are created by
S0-PLAN-01.

## 6. Admission identity and internal API

### Canonical identity

The server derives one stable logical identity from the trusted order context and
normalized UUIDs:

```text
reservation_key = "order:<order_id>:sku:<variant_id>"
admission_identity = reservation_key
```

`order_id` and `variant_id` are validated before admission. UUID normalization and
any ordering/tie-break use binary UUID representation, consistent with the repository
ID law. The client never supplies a Redis key, queue member, sequence, lease token,
owner epoch, or expiry timestamp.

The Redis queue member is an opaque server-derived HMAC digest of the logical identity
plus a key version. It is not the raw `reservation_key`. Admission metadata stores a
digest and server-owned fields; raw commercial identity is not exposed in Redis keys
or browser responses.

`reservation_key` is the durable identity. An exact replay has the same normalized
identity and request fingerprint. The existing source permits a later desired
quantity adjustment for the same order and variant, so the rules are:

- An exact replay while `QUEUED`, `ADMITTED`, `RESERVING`, `UNKNOWN_DB_OUTCOME`, or
  `RECOVERING` returns or joins the existing logical operation. It creates no second
  queue member or permit.
- A changed request fingerprint while a logical operation is live returns the
  registry-backed idempotency mismatch/conflict result. It does not silently replace
  a queued quantity or start a second operation.
- After a terminal operation has resolved and its bounded admission metadata has
  expired or explicitly permits a new operation, an authorized quantity adjustment
  may reuse the same `reservation_key` as a new serialized operation. The existing
  PostgreSQL path then applies its current active-reservation delta semantics.
- A replay after `COMPLETED` first returns the existing durable reservation outcome for
  an exact request. The durable row, not terminal Redis metadata, wins.
- A replay after `REJECTED`, `EXPIRED`, or `ABANDONED` follows the frozen retention and
  retry policy. It does not create a second live operation during terminal retention.

The atomic request operation must distinguish an exact terminal replay from a new
authorized operation on the same durable identity. A terminal record within its
retention window is returned for an exact fingerprint. A later server-authorized
quantity adjustment, after the terminal policy permits a new operation, clears only
the terminal admission metadata and creates a new operation epoch under the same
`reservation_key`; it never creates a second durable identity or a concurrent permit.
An untrusted or mismatched attempt cannot use terminal retention to bypass this rule.

### Smallest internal API

The implementation should expose these operations only inside the Store application:

```text
InventoryAdmission.reserve(%Request{}, trusted_context)
InventoryAdmission.status(%Identity{}, trusted_context)
InventoryAdmission.abandon(%Identity{}, trusted_context)
InventoryAdmission.recover(%RecoveryRef{}, system_context)
```

`reserve/2` is the normal high-level operation. It deduplicates/enqueues, returns a
bounded queued status when needed, and runs the existing transaction only after an
atomic lease claim. `status/2` is a short-lived status/retry interaction and may
trigger bounded promotion for the identity. `abandon/2` is an explicit server-owned
operation for a queued request. `recover/2` is restricted to the recovery worker and
system context.

Lease release, `ADMITTED -> RESERVING`, unknown-outcome marking, and Redis transition
calls are internal functions of the service. Do not expose a general
`reserve_when_admitted/3` or a raw lease API to web callers. A signed/opaque status or
retry reference may cross the web boundary later, but it must not contain a usable
Redis key or raw fencing token.

Results use the repository's `Store.Support.Errors.Error` envelope and registry-backed
codes. The contract needs explicit registry entries for admission busy, admission
unavailable, and single-variant unsupported outcomes if no existing code has the
right meaning. Existing `OUT_OF_STOCK`, `RESERVATION_CONFLICT`,
`IDEMPOTENCY_KEY_REUSE_MISMATCH`, and `INTERNAL_ERROR` retain their existing meanings.
No admission error may be represented as `OUT_OF_STOCK` merely because Redis or
PostgreSQL is unavailable.

The result shape is:

```text
{:ok, %{admission_state: :queued, admission_ref: opaque_ref, retry_after_ms: n}}
{:ok, %{admission_state: :completed, reservations: rows, inventory_items: rows}}
{:ok, %{admission_state: :recovering, admission_ref: opaque_ref, retry_after_ms: n}}
{:error, %Store.Support.Errors.Error{...}}
```

The exact web response mapping is out of scope. Domain callers must be able to make a
short call, retain or receive a status reference, and retry idempotently.

## 7. Lifecycle and transition contract

Admission state is separate from the durable `InventoryReservation` states
`active`, `consumed`, `expired`, and `cancelled`.

### State definitions

| State | Entry condition and owner | Allowed transitions and guards | Side effects and timeout | Replay and terminal meaning |
|---|---|---|---|---|
| `REQUESTED` | A trusted, single-variant request has a canonical `reservation_key`. `InventoryAdmission` owns validation. | `QUEUED` or immediate `ADMITTED`, only through the Redis atomic request operation. | No inventory read/write. Request acknowledgement is short-lived; it is not a queue wait. | Same identity returns the existing operation. Non-terminal. |
| `QUEUED` | Redis created exactly one queue member under both queue bounds. Redis owns membership; the domain owns the meaning. | `ADMITTED` only when this member is eligible and both budgets are acquired atomically; `EXPIRED` by queued deadline; `ABANDONED` by explicit trusted cancellation. | Queue ZSET membership and metadata only. Finite queue TTL. No `Store.Repo` checkout. | Retry returns the same queue status/member. No inventory effect. Non-terminal. |
| `ADMITTED` | Redis atomically owns `K_v = 1` and one `B_total` slot and records a lease token. | `RESERVING` only after the current owner claims the token; `EXPIRED` only before claim and after safe lease expiry handling. A lease in active DB execution cannot be replaced by expiry. | Starts one `T_db` deadline. Lease is finite and renewed only under the bounded contract. No inventory effect yet. | Retry returns the same opaque admission status; it cannot create another permit. Non-terminal. |
| `RESERVING` | The lease owner atomically changed `ADMITTED` to `RESERVING` before entering the existing reservation transaction. | `COMPLETED` on definitive commit; `REJECTED` on definitive rollback/governed rejection; `UNKNOWN_DB_OUTCOME` if commit or rollback cannot be established. | The existing PostgreSQL transaction is the only inventory side effect. `T_db` includes checkout, row-lock wait, execution, final result, and commit/known rollback. | Retry returns in-progress status. Never starts a second durable attempt. Non-terminal. |
| `UNKNOWN_DB_OUTCOME` | A timeout, dropped connection, process crash, or lost final result leaves PostgreSQL outcome uncertain. The service creates a recovery fence atomically when possible; the reaper handles a crashed owner. | `RECOVERING` only after the safety window and a recovery owner claim. No direct retry, release, or promotion based on lease expiry. | Retains variant and global capacity; starts bounded recovery. | Replay joins/returns recovery. Non-terminal and explicitly unsafe to treat as rollback. |
| `RECOVERING` | A recovery worker owns the current fence and is reconciling PostgreSQL. | `COMPLETED` if `reservation_key` exists; `REJECTED` only after the safe lookup window establishes no committed row under the bounded policy. A lookup uncertainty remains `RECOVERING`. | PostgreSQL lookup is authoritative. Resolution releases the fenced capacity only through a token-checked atomic operation. Recovery has finite retry/deadline policy. | Replay returns recovery or its resolved durable result. Non-terminal until a definite outcome or operational escalation. |
| `COMPLETED` | PostgreSQL definitively committed or recovery found the durable reservation row. | No further admission transition. Later exact replay returns the durable row; a separately authorized quantity adjustment begins a new serialized operation. | Stores bounded result metadata and performs idempotent fenced release. | Terminal admission state. Durable `InventoryReservation` is authoritative. |
| `REJECTED` | PostgreSQL definitively rolled back or returned a governed rejection, or bounded recovery resolves no committed row as rejected. | No further live transition during terminal retention. A later permitted request re-enters through the same gate. | No new inventory effect; fenced capacity is released. | Terminal admission state. Exact replay receives the governed rejection for retention. |
| `EXPIRED` | A queued entry or unclaimed `ADMITTED` lease reaches its bounded deadline without a DB operation in flight. The atomic reaper owns it. | No live transition. A late request receives terminal status; later retry follows policy and the same identity. | Removes queue/lease membership and releases only capacity actually held. | Terminal admission state. It must never be inferred for `RESERVING`. |
| `ABANDONED` | A trusted owner explicitly abandons a queued request, or a bounded owner-liveness rule proves it is gone before reservation starts. | No transition from active DB execution. A disconnect during `RESERVING` becomes normal completion or unknown recovery. | Removes queued metadata and no permit is released if none was held. | Terminal admission state. Repeated abandon is a no-op. |

### Transition table

| Transition | Guard | Owner | Required side effect |
|---|---|---|---|
| `REQUESTED -> QUEUED` | Valid single variant, trusted identity, no live/terminal/recovery record, `Q_variant_max` and `Q_global_max` both available. | Atomic Redis operation. | Add one member to the per-variant queue, global dispatch index, queued-expiry index, and metadata. |
| `REQUESTED -> ADMITTED` | The request is the next eligible member or an empty-queue immediate request; variant is free, `ZCARD(global_active) < B_total`, namespace is healthy. | Atomic Redis operation. | Acquire both capacities, write lease token/deadlines, and remove any queue membership atomically. |
| `QUEUED -> ADMITTED` | Member is eligible under per-variant FIFO-ish order; no recovery freeze/active holder; global budget is available. | Atomic promotion operation. | Remove all queued indexes, add active variant ownership and global active-expiry membership, mark `ADMITTED`. |
| `QUEUED -> EXPIRED` | Queued deadline is due and no `RESERVING` owner exists for the identity. | Atomic prune/reaper operation. | Remove queued indexes, decrement the bounded queue population, mark terminal metadata. |
| `QUEUED -> ABANDONED` | Trusted server context owns the identity and the request is still queued. | `InventoryAdmission` through atomic Redis operation. | Remove queued indexes and mark terminal metadata. |
| `ADMITTED -> RESERVING` | The lease token and owner epoch match the active record, and the hard `T_db` deadline has not passed. | `InventoryAdmission` owner. | Mark in-use before calling `InventoryReservations.reserve_inventory/3`; no DB call occurs before this claim. |
| `ADMITTED -> EXPIRED` | Lease deadline is due, the request was never claimed `RESERVING`, and the bounded safety check permits removal. | Atomic reaper. | Release both held capacities and promote only through the same atomic operation. |
| `RESERVING -> COMPLETED` | The existing transaction definitively returns committed durable rows. | Reservation orchestrator. | Record durable reservation ID/key, fenced release, emit completion telemetry. |
| `RESERVING -> REJECTED` | The existing transaction definitively rolls back or returns a governed reservation failure. | Reservation orchestrator. | Do not mutate durable reservation state for the failure; fenced release and rejection telemetry. |
| `RESERVING -> UNKNOWN_DB_OUTCOME` | A final commit/rollback answer cannot be established. | Reservation orchestrator or reaper. | Retain both capacities, create/retain recovery fence, enqueue one recovery job if possible. |
| `UNKNOWN_DB_OUTCOME -> RECOVERING` | Safety window has elapsed and a recovery worker atomically owns the fence. | Recovery worker. | Query PostgreSQL by `reservation_key`; no second durable attempt. |
| `RECOVERING -> COMPLETED` | PostgreSQL lookup finds the unique durable reservation. | Recovery worker plus atomic resolver. | Return/reconstruct durable result and release fenced capacity. |
| `RECOVERING -> REJECTED` | PostgreSQL lookup is definitive, no row exists after the safety window, and the bounded policy resolves rejection. | Recovery worker plus atomic resolver. | Release capacity and preserve governed retry/retention policy. |

`COMPLETED`, `REJECTED`, `EXPIRED`, and `ABANDONED` are terminal. `UNKNOWN_DB_OUTCOME`
and `RECOVERING` are not terminal and cannot be treated as rollback, timeout success,
or permission for an unrestricted retry.

### Durable reservation relationship

The only successful settlement relationship is:

```text
InventoryAdmission.RESERVING
  -> existing Store.Orders.InventoryReservations.reserve_inventory/3
  -> committed InventoryReservation.active
  -> InventoryReservation durable identity returned
```

Admission `COMPLETED` carries the durable reservation ID and `reservation_key`.
Admission `REJECTED`, `EXPIRED`, and `ABANDONED` do not call a durable reservation
transition. Existing `active -> consumed`, `active -> expired`, and
`active -> cancelled` operations remain unchanged and are not moved into admission.

## 8. Configuration, permit budgets, and rollout

### Immutable MVP rule

```text
K_v = 1
```

The value is not in application configuration. No MVP branch, test override, or
deployment setting may make it greater than one. Any future `K_v > 1` requires a
separate architecture/performance review proving useful throughput improvement
without returning same-variant waiters to the PostgreSQL pool.

### Global `B_total`

The configuration owner is a new `:inventory_admission` application configuration
section, loaded from the deployment's cluster-wide configuration authority. Every
node must use the same value and topology view. The plan does not choose a final
numeric value.

Define:

```text
R = aggregate Store.Repo pool capacity across active application nodes
H = reviewed headroom for non-reservation Store.Repo traffic
B_total <= R - H
```

Validation requires a positive `B_total`, a positive explicitly reviewed `H`, and
`B_total < R`. `B_total = Store.Repo pool_size` is never an automatic default. A
safe derivation strategy is `R - H` only when the deployment supplies an explicit
headroom value and the capacity review approves that result. If topology/headroom
inputs are missing or invalid, enforced admission remains disabled/fails closed; it
does not guess a pool-sized budget.

`B_total` counts only active entrants into the inventory reservation transaction.
Other `Store.Repo` traffic remains protected by the pool and the existing generic
performance observer. The budget is not a license to consume all connections.

Test configuration may override `B_total` with a small positive value strictly below
the test pool capacity so that global-cap tests are deterministic. Test overrides
must pass the same validation and must never change `K_v`.

### Deadline configuration

The same configuration section owns finite values for:

- `db_operation_deadline_ms` (`T_db`), beginning at `ADMITTED`;
- `admission_lease_margin_ms`, making `L_admission` longer than the bounded operation;
- queue wait TTL and terminal metadata retention;
- recovery safety window, retry budget, and absolute recovery deadline;
- bounded cleanup batch size and Redis restart quarantine window;
- `Q_variant_max` and `Q_global_max`.

Production values are deployment-reviewed, not arbitrary constants in this plan.
`T_db` should be set from measured reservation transaction and checkout behavior plus
a safety margin during later certification. Initial implementation tests use explicit
small values and injected barriers/clocks where the operation can remain deterministic.

The validated relationship is:

```text
L_admission >= T_db + lease_safety_margin
recovery_deadline > database_safety_window
terminal_retention > the maximum status/replay handoff window
```

Renewal is attempted before half-life while `RESERVING`, but it never extends the
hard operation contract indefinitely. A lease token is not a database cancellation
mechanism.

### Feature gate

Use a server-side `DISABLED | ENFORCED` mode for the tracer bullet. Do not add
`SHADOW` unless a separate design gives it meaningful, measurable semantics; a
shadow Redis decision that does not gate PostgreSQL would add coordination load and
would not prove pool protection.

- `DISABLED`: preserve the current direct behavior for controlled rollout and legacy
  paths; this mode does not claim to solve the herd.
- `ENFORCED`: the protected `Store.Orders.reserve_inventory/3` single-variant path
  must pass through `InventoryAdmission`; Redis errors fail closed.

The mode is deployment/server controlled. It is not read from a client, order, or
browser parameter. `ENFORCED` is invalid unless the Redis connection, budget,
queue bounds, deadlines, and secret configuration validate at startup.

## 9. Redis data model

### Namespace and cluster atomicity

The existing environment/application prefix is the source of truth for key prefixes:
`prod:store`, `dev:store`, or `test:store` through the existing Redis configuration.
The admission adapter uses a relative namespace under that prefix:

```text
<existing_prefix>:inventory_admission:v1:{inventory_admission}:...
```

The common hash tag `{inventory_admission}` is deliberate. It places global and
variant keys in one Redis Cluster hash slot and therefore one atomicity domain. On a
standalone Redis deployment it remains a harmless namespace component. If the
deployment cannot provide one atomic domain for the global and variant state, the
gate cannot be enforced with this design.

Variant IDs in keys use server-normalized binary UUID hex, not client text. Queue
members use the versioned HMAC digest. Raw Redis keys and fencing tokens never cross
the web boundary.

### Structures

| Logical key | Type and member/value | Semantic owner | TTL/expiry contract | Maximum and cleanup |
|---|---|---|---|---|
| `variant:<variant_hex>:queue_order` | ZSET; member is the opaque admission member, score is a server-issued monotonic sequence. | Per-variant FIFO-ish order only. | Container retention is longer than the latest finite queue deadline plus cleanup grace. The score is never an expiry. | `ZCARD <= Q_variant_max`; remove on admission, expiry, abandonment, or terminal cleanup. |
| `global:queue_dispatch` | ZSET; same member, score is the server-issued sequence. | Global bounded dispatch candidate index so a freed `B_total` slot can wake another queued variant without scanning keys. It is not a second authority. | Container retention follows the finite queue window. Score is never an expiry. | `ZCARD <= Q_global_max`; maintained atomically with every per-variant membership change. |
| `global:queue_expiry` | ZSET; member is the opaque admission member, score is the Redis-server deadline for queued expiry. | Queued expiry only. | Score is the semantic queued deadline; container is retained beyond the latest member deadline. | At most the live global queue population; bounded `ZRANGEBYSCORE` cleanup. |
| `variant:<variant_hex>:active` | HASH with one active holder: member, state, token, owner epoch, sequence, `T_db` deadline, lease deadline, and identity digest. | Current `K_v = 1` ownership record. | Lease/operation metadata is retained through the bounded recovery window; never expires while it may be needed for recovery. | At most one holder per variant. No stock or availability fields. |
| `global:active_expiry` | ZSET; member is the active admission member, score is active lease expiry. | Global active lease index and `B_total` occupancy. `ZCARD` is the active global permit count. | Member score is the active lease-expiry semantic. Do not independently expire the key while active members exist. | `ZCARD <= B_total`; bounded due-member pruning. |
| `request:<member>:meta` | HASH with state, identity digest, variant, queue sequence, deadlines, owner epoch/token, durable reservation ID when known, and terminal reason. | Request/lease status and idempotency metadata only. | `T_queue` while queued; `L_admission + T_recovery` while active/recovering; finite terminal retention after resolution. | Live metadata is bounded by `Q_global_max + B_total`; terminal retention is finite and memory-budgeted. No stock. |
| `request:<member>:recovery_fence` | HASH/string with recovery owner token, fence epoch, safety deadline, recovery deadline, and status. | Duplicate-attempt prevention and recovery ownership. | Finite recovery TTL covering the recovery budget plus cleanup grace. Fence expiry never itself releases capacity. | At most one fence per ambiguous logical identity. |
| `global:sequence` | STRING incremented only by the atomic admission operation. | Server ordering/tie-break source. | Retained for namespace lifetime; it is not a stock counter. | Monotonic server-side sequence; no client clocks. |
| `global:namespace` | HASH with namespace generation and a fail-closed `frozen_until`/health epoch. | Redis restart/partition quarantine. | Generation is retained while the namespace is active; freeze deadline is finite. | One namespace record; no inventory data. |

All records are internal coordination state. No structure contains
`stock_on_hand`, `reserved_count`, cached availability, or a claim that inventory is
held. PubSub messages and browser state are projections only.

No node-local GenServer, ETS semaphore, or application process may authorize a
permit. Local processes may assist with telemetry, batching, or read projections,
but every admission decision and every global/variant capacity change goes through
the cluster-global Redis atomic boundary.

The global dispatch index is justified by `B_total`: a release in variant A must be
able to promote an eligible request in variant B without a full key scan. It does not
replace per-variant FIFO order. Within a variant, the lowest sequence member remains
the only eligible head. There is no promise of mathematically perfect global fairness.

### Ordering and cleanup

The atomic script obtains ordering/deadline information from Redis server time and a
server-side sequence. Application wall clocks and client clocks do not decide queue
order or expiry. Queue order, queued expiry, and active lease expiry are separate
semantics and separate indexes. One score is never overloaded to mean both position
and expiry.

Lazy cleanup runs as part of enqueue, status, promotion, release, and recovery
operations. A bounded Oban reaper handles entries that receive no traffic. It uses
bounded `ZRANGEBYSCORE`/member operations on the known expiry indexes. It never uses
`KEYS`, an unbounded Redis scan, or a loop proportional to historical request count.

## 10. Redis atomic transition contracts

Every operation that touches a variant record and a global budget/index is one Lua or
equivalent Redis server-side atomic operation. The Elixir adapter may decode the
result, but it must not perform a client-side `GET` then `SET` decision.

All operations fail closed on a Redis error, timeout, malformed reply, or uncertain
command outcome. A retry uses the same server-derived identity and the same atomic
operation; it never falls back to the durable reservation function directly.

| Atomic operation | Inputs | Atomic work and invariant | Result/error contract |
|---|---|---|---|
| `enqueue_or_return_existing` | Identity digest, variant, request fingerprint, `Q_variant_max`, `Q_global_max`, `B_total`, namespace epoch. | Prune bounded queued expiry; return an exact live/terminal/recovery record; reject a mismatched live identity; or, only when the terminal retry/adjustment policy permits, advance the operation epoch under the same `reservation_key`. For a new operation, validate both queue bounds. If both capacities are available and the request is the eligible head, acquire both and create `ADMITTED`; otherwise insert exactly one member in all queue indexes and metadata. | `existing`, `queued`, `admitted`, `busy`, `mismatch`, `frozen`, or `unavailable`. It never partially increments a queue or grants one budget. |
| `promote_next` | Namespace epoch, optional releasing member, `B_total`, bounded candidate limit. | Prune due queued records, select an eligible global candidate whose per-variant member is the variant head, verify no active/recovery freeze, verify `ZCARD(global:active_expiry) < B_total`, then remove queue indexes and create the one active lease. | A complete lease, no eligible candidate, global-full, variant-frozen, or fail-closed error. Variant and global capacity change together. |
| `claim_reserving` | Member, variant, lease token, owner epoch. | Compare token/epoch/state and atomically change `ADMITTED` to `RESERVING`. No database call is allowed before this succeeds. | `claimed`, `already_reserving`, terminal/recovering, stale-owner, or unavailable. Replays cannot claim a second owner. |
| `renew_lease` | Member, variant, token, owner epoch, server time. | Compare current ownership; renew only while `RESERVING`, before the hard `T_db` deadline, and within the configured lease window. Update active expiry index and metadata together. | `renewed`, `deadline_reached`, `stale_owner`, `frozen`, or unavailable. It cannot extend indefinitely. |
| `release_known_outcome` | Member, variant, token, owner epoch, `COMPLETED` or `REJECTED`, optional durable reservation ID. | Compare current ownership; mark terminal metadata; remove variant active and global active-expiry membership; promote the next eligible request in the same atomic operation. Repeated release is a no-op for the same terminal result and cannot affect a newer token. | `released` with optional next lease, `already_resolved`, stale-owner, frozen, or unavailable. A Redis error after known commit does not undo PostgreSQL. |
| `mark_unknown_and_fence` | Member, variant, token, owner epoch, recovery deadline. | Compare current ownership; change `RESERVING` to `UNKNOWN_DB_OUTCOME`; create/retain one recovery fence; retain both variant and global capacity. | `fenced`, already fenced, stale-owner, or unavailable. It never marks rollback or releases for an unrestricted retry. |
| `claim_recovery` | Member, fence token, worker owner, server time. | Verify the safety window, namespace, logical state, and fence ownership; atomically set `RECOVERING` and one recovery owner. Capacity remains held. | `claimed`, already recovering, not safe yet, terminal, or unavailable. Oban uniqueness is secondary to this fence. |
| `resolve_recovery` | Member, fence token, recovery owner, durable lookup result, server time. | The durable lookup result is produced outside Redis. If a row exists, mark `COMPLETED`; if no row is definitive after the safety window, mark `REJECTED`; release only the fenced active/global capacity atomically. If lookup is uncertain, retain `RECOVERING`. | `resolved`, `retry_recovery`, stale fence, terminal, or unavailable. Redis never determines whether PostgreSQL committed. |
| `abandon_queued` | Member, trusted owner context, identity digest. | Compare identity and state; remove only queued membership and mark `ABANDONED`. It cannot abandon `RESERVING`. | `abandoned`, already terminal, not queued, unauthorized, or unavailable. |
| `prune_due` | Namespace epoch, bounded count, server time. | Remove due queued members; for an unclaimed admitted lease, expire and release both permits; for `RESERVING`, create/retain unknown recovery and freeze promotion. | Counts of expired/fenced entries and any complete promotions; no unsafe release. |
| `quarantine_namespace` | Observed Redis generation/health event, server time, quarantine duration. | Advance namespace epoch and set `frozen_until`; reject all new admission and promotion until the old operation/recovery safety window has passed. Old tokens cannot mutate the new epoch. | `frozen` or `healthy_after_quarantine`. It is coordination safety, not stock truth. |

Atomic invariants tested for every operation:

```text
active_variant_holders(variant) <= 1
active_global_holders <= B_total
queued_members(variant) <= Q_variant_max
queued_members(all_variants) <= Q_global_max
one logical identity => at most one queue member and one active lease
stale token => no release, renew, promotion, or global decrement
```

## 11. Lease, deadline, and fencing semantics

### Admission-to-commit deadline

`T_db` starts when the request becomes `ADMITTED`, not when the transaction callback
begins. It covers:

1. `Store.Repo` checkout wait;
2. transaction start and all PostgreSQL work;
3. row-lock wait;
4. final availability/result handling; and
5. definitive commit or known rollback handling.

The future implementation must pass the remaining deadline to the repository-supported
checkout/transaction timeout mechanisms and prove through instrumentation that pool
checkout is included. A callback timeout that starts after checkout is not sufficient.
The existing transaction remains synchronous; it is not moved to Oban.

The request process may disappear after admission. The operation owner must either
complete under `T_db` or classify its result as ambiguous. The deadline is a hard
capacity contract, not a best-effort timer.

### Lease relationship

`L_admission` is separate from `T_db` but must cover the complete bounded operation
plus a safety margin:

```text
L_admission >= T_db + lease_safety_margin
```

The holder renews before half-life while `RESERVING`, with the same owner token and
epoch, and never past the hard operation/recovery contract. A Redis timeout during
renewal is lease uncertainty, not permission to continue indefinitely and not
permission to promote a replacement.

When renewal or Redis connectivity is lost while a PostgreSQL transaction may be
running:

- the holder stops treating its lease as renewable and lets the bounded DB operation
  resolve or enter recovery;
- the variant and global occupancy remain fenced;
- no same-variant replacement is promoted;
- the reaper marks `UNKNOWN_DB_OUTCOME` after the safety window if needed;
- PostgreSQL is never cancelled by pretending Redis owns the DB session;
- a known commit or known rollback can release through a token-checked atomic retry;
- an ambiguous result retains recovery fencing until durable reconciliation or explicit
  fail-closed operational escalation.

An active `RESERVING` lease reaching its timestamp is a reaper signal, not an automatic
permit return. The only safe release after that point is a known database outcome or a
recovery decision that has completed its safety policy.

### Fencing scope

The server-generated lease token and owner epoch protect only Redis coordination:

- current admission ownership;
- renewal of the current lease;
- release of the current lease and global permit;
- stale-owner rejection; and
- replacement/promotion operations.

They do not make a PostgreSQL transaction invalid and do not provide the zero-oversell
guarantee. The MVP PostgreSQL transaction does not validate a Redis token. Inventory
correctness is protected by the PostgreSQL transaction, row lock, availability check,
durable identity, and unique indexes. Admission capacity correctness is protected by
Redis ownership, deadlines, promotion freeze, and recovery fencing. DB-side fencing
validation would be a separate architecture and migration decision.

### Redis restart and partition quarantine

If Redis restarts, loses its namespace, or returns uncertain command results, the
adapter enters a namespace quarantine. No new admission, promotion, or direct
PostgreSQL fallback is allowed. The namespace gets a new epoch and remains frozen
through the maximum configured old lease/DB/recovery safety window. Existing durable
reservations remain queryable from PostgreSQL. Queued admission state may be lost in
this failure; a status/retry call returns a governed unavailable result until the
quarantine ends, then reuses the same server-derived identity. It never claims a
lost queued request completed or treats missing keys as available stock. After the
quarantine, the fresh Redis namespace may admit only through its empty/reconciled
state.

This sacrifices liveness during Redis uncertainty to preserve capacity semantics. It
does not infer stock availability from missing Redis keys and does not claim Redis and
PostgreSQL form a distributed transaction.

## 12. Ambiguous database outcome and recovery

### Outcome classification

The reservation orchestrator must classify results before releasing capacity:

| Category | Examples | Required behavior |
|---|---|---|
| `KNOWN_COMMIT` | `Repo.transaction` definitively returns success and the durable reservation result is available. | PostgreSQL truth wins. Mark `COMPLETED`, return the durable result, and release Redis idempotently. Replay resolves to the existing reservation. |
| `KNOWN_ROLLBACK` / rejection | A pre-DB checkout failure is known not to have entered the DB, or the transaction definitively rolls back/returns `OUT_OF_STOCK` or another governed rejection. | Mark `REJECTED`, release the lease, and follow ordinary retry/rejection policy. Do not mutate a reservation on failure. |
| `AMBIGUOUS_DB_OUTCOME` | Connection loss after a query/transaction may have been sent, timeout after transaction start, process crash during final handling, or lost commit/rollback confirmation. | Do not assume rollback. Mark/retain `UNKNOWN_DB_OUTCOME`, fence the identity, retain capacity, and recover by PostgreSQL `reservation_key`. Do not immediately retry. |

An error tuple is not automatically a known rollback. The operation boundary must
know whether DB entry was attempted. A checkout timeout before a connection was
obtained can be a known pre-DB failure; a connection drop after transaction start is
ambiguous.

### Recovery lookup

`Store.Orders.InventoryAdmission.Recovery` calls a narrow read-only durable lookup,
preferably through an internal `InventoryReservations.find_by_reservation_key/1`
boundary or equivalent domain-owned read. That lookup uses the existing unique
`inventory_reservations.reservation_key` index. It does not use Redis state to answer
whether the transaction committed.

Recovery behavior is:

1. Claim the recovery fence after the database safety window.
2. Query PostgreSQL by the server-derived `reservation_key`.
3. If a durable row exists, reconstruct the durable result regardless of whether its
   current lifecycle state is `active`, `consumed`, `expired`, or `cancelled`; the
   existing durable lifecycle remains authoritative.
4. If no row exists but the safety window has not elapsed, retain `RECOVERING` and
   retry with bounded backoff.
5. If no row exists after the safety window and the bounded recovery policy is
   definitive, resolve `REJECTED` and release the fenced capacity.
6. If the lookup itself is uncertain, retain the fence and retry until the finite
   recovery deadline. At the deadline, remain fail closed for operational escalation;
   do not authorize an unrestricted second attempt.

The MVP does not automatically issue a second durable attempt from recovery. A later
caller retry may reuse the same `reservation_key` only after the recovery fence is
resolved/cleaned and the request re-enters the same admission gate. The PostgreSQL
unique identity prevents a second durable reservation row.

### Recovery owner choice

Use a bounded Oban recovery worker for MVP recovery, with a small inline operation
only to mark the Redis fence and enqueue the job. Oban is preferred over a caller
waiting inline because:

- the repository already uses Oban workers and a dedicated `:inventory` queue;
- Oban job persistence survives the caller process ending;
- worker retries can be bounded by the recovery deadline;
- the synchronous final reservation transaction remains in the caller/short-lived
  admission owner and is not moved to an unbounded job queue.

Recommended worker:
`Store.Workers.InventoryAdmissionRecoveryWorker`, using `Store.DirectRepo` for job
storage as configured by Oban and `Store.Repo` for the durable reservation lookup.
The job is unique by worker plus logical recovery identity/args, but the Redis
recovery fence remains the correctness authority for one active recovery owner.
Redis enqueue uncertainty is retried by the bounded reaper; it never produces a
direct reservation fallback.

Recommended maintenance worker:
`Store.Workers.InventoryAdmissionReaperWorker`, using known expiry indexes and bounded
batches to prune queued entries, freeze expired active reservations, and re-enqueue
recoveries. It must not use `KEYS`, a full key scan, or an unbounded loop.

## 13. Integration boundary

The dependency direction is:

```text
Store.Orders public facade
  -> InventoryAdmission
    -> InventoryAdmission.Redis
    -> existing InventoryReservations.reserve_inventory/3
      -> Store.Repo transaction
```

The admission service does not depend on web waiting-room modules, payments,
checkout, or PubSub for correctness. `InventoryReservations` does not call the
waiting room or Redis. The Redis adapter does not decide domain lifecycle outcomes.

When the gate is `ENFORCED`:

1. `Store.Orders.reserve_inventory/3` normalizes and validates the request as exactly
   one variant, derives `reservation_key`, and invokes `InventoryAdmission.reserve/2`.
2. A queued result returns before any `Store.Repo` checkout. The caller can later call
   the same high-level operation or `status/2` with the same trusted identity.
3. An admitted result is claimed atomically as `RESERVING` by one owner.
4. Only then does the service call the existing
   `InventoryReservations.reserve_inventory/3` with one item and the remaining `T_db`
   budget.
5. The service classifies the result and releases or recovers as Section 12 states.

The existing `reserve_inventory_for_checkout/3` multi-variant CTE remains unchanged
and out of scope. If the enforced protected facade receives multiple variants, it
returns `INVENTORY_ADMISSION_UNSUPPORTED`; it does not silently direct the request to
the unbounded path. Future multi-variant admission must use deterministic binary UUID
ordering or an atomic multi-key design before it can be enabled.

The durable primitive is not a public web API. Because Elixir does not provide a
caller-based module visibility boundary, the integration phase must add a focused
call-site/boundary test and an explicit internal/test-only bypass policy if current
tests need the disabled direct path. A bypass must be server-controlled, named, and
unavailable to normal web input. It must never be a client-provided flag.

## 14. Request lifetime and waiting boundary

The required invariant is:

```text
queue lifetime != Phoenix request-process lifetime
```

The domain contract is short interaction based:

```text
request admission
  -> immediate completed or queued/admitted status
  -> opaque status/retry reference
  -> later status/retry call or optional push notification
  -> short reservation interaction when admitted
```

No queued entry stores a PID, monitor, socket ownership, or expectation that a
Phoenix/LiveView process remains blocked. A queued client disconnect leaves the
entry until explicit trusted abandonment or finite expiry. An admitted client
disconnect does not cancel PostgreSQL by assumption; the owner completes or becomes
ambiguous and recovery handles it.

The inventory domain owns queue identity, bounds, lease state, retry-safe status, and
cleanup. The web/LiveView layer owns waiting-room presentation, retry/backoff, user
messaging, and optional status subscription. The existing generic waiting room may
rate-limit or reduce broad traffic, but its fail-open Redis behavior cannot bypass
`InventoryAdmission`.

At 100,000 external requests, requests above finite queue policy receive governed
busy/retry behavior. Requests within the policy occupy bounded Redis/status state,
not one DB connection or indefinitely blocked BEAM process each.

## 15. Failure policy

| Failure | Domain result and state | Capacity/authority rule |
|---|---|---|
| Redis unreachable or timeout before admission | `INVENTORY_ADMISSION_UNAVAILABLE` or governed retry; no new queue/admission result is claimed. | Fail closed. Never call the existing PostgreSQL reservation transaction as a fallback. |
| Redis command result uncertain | Retry the same identity after health/quarantine; do not repeat a non-idempotent client sequence. | Atomic operation deduplication and namespace quarantine protect against double grant. |
| Redis restarts or loses keys | Enter namespace quarantine; existing durable rows remain queryable from PostgreSQL. | No promotion until old lease/DB safety windows pass. Missing Redis state never means stock is free. |
| Queue bound reached | `INVENTORY_ADMISSION_BUSY` with governed retry/waiting semantics. | Do not enqueue, spin, or create a blocked caller process. |
| PostgreSQL unavailable before DB entry | Known pre-DB infrastructure rejection if the boundary proves no transaction was sent. | Release both permits idempotently; no durable reservation exists. |
| PostgreSQL error after transaction may have begun | `UNKNOWN_DB_OUTCOME` then `RECOVERING`. | Do not translate to `OUT_OF_STOCK` or immediately retry. Query `reservation_key`. |
| PostgreSQL definitively rolls back/rejects | `REJECTED`, existing governed error. | Release the current fenced lease and permit; no reservation mutation is created. |
| PostgreSQL commits, Redis release succeeds | `COMPLETED` with durable row. | Release and promote atomically; replay returns the durable row. |
| PostgreSQL commits, process or Redis release fails | Durable success is returned/retained; release remains pending for reaper. | PostgreSQL truth remains valid. Stale release cannot touch a newer lease. |
| Holder crashes before `RESERVING` | `ADMITTED` reaches safe expiry and becomes `EXPIRED`. | No DB call is assumed; capacity is released only by token/epoch-checked pruning. |
| Holder crashes after `RESERVING` | Reaper moves to unknown/recovery after the bounded safety window. | Capacity remains fenced until durable resolution/escalation. |
| Lease renewal lost inside transaction | Continue only within the already bounded operation; classify final result or ambiguity. | Freeze same-variant promotion; Redis cannot cancel the running transaction. |
| Queued client disconnects | Entry remains queued until explicit trusted abandonment or queue expiry. | No long-lived process cleanup is assumed. |
| Admitted client disconnects | The operation continues under its deadline or enters recovery. | Disconnect is not proof of rollback and cannot release a live permit by guess. |
| Recovery worker crashes | Fence and `RECOVERING` metadata remain until finite TTL/deadline. | Another worker may resume; fence expiry alone never releases capacity. |
| Recovery lookup remains unavailable at deadline | Fail-closed operational escalation. | No automatic second durable attempt or promotion based on uncertainty. |

No Redis/PostgreSQL distributed transaction is simulated. The design relies on
PostgreSQL durable identity for truth and token-checked, retryable Redis coordination
for capacity.

## 16. PubSub, Redis Stream, and cache boundaries

Phoenix PubSub has no admission-correctness authority. It may broadcast a status
projection after a Redis/ PostgreSQL transition or help a LiveView refresh. PubSub loss
must not grant, renew, release, promote, reject, or mutate stock. A missed event is
recovered by a status read/retry.

No Redis Stream is required for MVP admission correctness. Queue order and promotion
remain in the bounded atomic Redis structures above. A later asynchronous waiting or
admission-processing design may choose Streams only through a new architecture
decision.

ETS/Cachex/browser/CDN data may hold local/read projections or telemetry aggregates.
None is accepted as admission ownership or inventory truth. Cached availability may
be stale; only the PostgreSQL transaction decides reservation success.

## 17. Security and abuse controls

The implementation must enforce these controls at the domain boundary:

- derive identity from a trusted, authorized order context and normalized variant;
- bind ownership and status reads to the same trusted order/customer context;
- use server-generated versioned HMAC members and lease tokens;
- keep Redis keys, raw reservation identity where sensitive, fencing tokens, and queue
  positions server-side;
- enforce `Q_variant_max` and `Q_global_max` before inserting a new member;
- deduplicate repeated identities before consuming queue capacity;
- apply rate limiting at the web/domain integration point as abuse control, while
  retaining the separate fail-closed inventory gate;
- bound lease duration and renewal so a client cannot hoard a slot by keeping a socket
  open;
- allow only the current owner/recovery fence owner to renew, release, abandon, or
  resolve;
- reject client-selected variant/order combinations that fail authorization or
  identity binding;
- prevent cross-order admission manipulation by comparing the server-derived digest;
- rotate the admission HMAC key by version without making a live lease reusable by an
  untrusted caller; accept old key versions only for bounded live TTLs;
- do not add fake `tenant_id` fields or namespaces; the application is single-tenant.

No client may call Redis or directly grant, renew, release, promote, or clear an
admission state.

## 18. PostgreSQL indexes and migration boundary

The current schema is sufficient for Option A MVP, subject to deployment verification
of the same migration set:

- `inventory_items.variant_id` unique index supports the durable inventory lookup;
- `inventory_reservations.reservation_key` unique index supports ambiguous-outcome
  reconciliation;
- `inventory_reservations(order_id, variant_id)` unique index preserves the existing
  order/variant identity and quantity-adjustment path;
- existing `(order_id, state)`, `(variant_id, state)`, `(state, expires_at)`, and
  active-expiry indexes support the unchanged reservation lifecycle and worker.

The implementation plan requires no PostgreSQL migration solely for admission and no
admission state table. If a deployed schema lacks the `reservation_key` unique/index
guarantee or the inventory lookup guarantee, the implementation gate stops for a
separate schema review. This plan does not create or authorize a migration.

Future PgBouncer transaction mode remains compatible: no session variables, session
advisory locks, temporary tables, connection ownership across Redis waits, or
session-local permits. Lease and identity values travel as normal application data;
PostgreSQL row locks live only inside the existing transaction.

## 19. Observability contract

Emit these events once per meaningful transition, with a result/error outcome and
bounded metadata:

```text
admission_requested
admission_queued
admission_admitted
admission_expired
admission_abandoned
admission_released
admission_recovery_started
admission_recovery_resolved
reservation_started
reservation_completed
reservation_rejected
```

Required measurements:

- per-variant and global queue depth, with hot-variant diagnostics sampled or
  explicitly enabled;
- active variant leases and active global permits;
- admission wait p50/p95/p99;
- queue expiry count and abandoned count;
- recovery fence count and recovery latency;
- Redis operation latency, timeout/error rate, quarantine count, and command result
  uncertainty;
- `Store.Repo` utilization, checkout queue latency, and reservation transaction
  latency;
- reservation outcome counts, PostgreSQL lock waits/deadlocks, and oversell count.

Globally aggregated metrics must not use unbounded raw `variant_id` labels. Use a
bounded hot-variant list, hashes, sampling, or a controlled diagnostic switch. Do not
include reservation keys, customer identifiers, raw Redis tokens, or payloads in
telemetry labels/logs.

## 20. Performance and scaling review

### Data classification

| Layer/data | Classification | Authority and allowed role |
|---|---|---|
| InventoryAdmission request/lease | HOT transient coordination | Redis plus short-lived Elixir values; no durable stock meaning. |
| Redis queue/lease indexes | HOT/WARM operational coordination | Bounded, leased, expiring admission state; no availability truth. |
| `InventoryItem` | COLD/DURABLE PostgreSQL truth with a hot row under contention | Final counters and availability; ETS/Cachex stock hints remain derived only. |
| `InventoryReservation` | COLD/DURABLE PostgreSQL truth after the write | Existing lifecycle and unique identities. |
| Phoenix/browser | UX/status interaction | No admission or inventory authority. |
| PubSub | Optional warm/read-side notification | Loss is harmless to correctness. |
| Oban recovery job | Warm operational retry | Durable job scheduling only; it does not become inventory truth. |

### Expected behavior by scale

| Load | Required architecture behavior | Evidence status |
|---:|---|---|
| 40 same-variant contenders | At most one `RESERVING` entrant for the variant; queued contenders do not checkout `Store.Repo`. | Must be proven by deterministic integration evidence later. |
| 160 contenders | One winner on the last unit and governed losers, with no same-variant row-lock herd. Queue bounds must be set high enough for the test or excess requests must be explicitly busy. | Not run by this plan. |
| 1,000 contenders | Finite Redis queue/backpressure, bounded `B_total` DB entrants, bounded caller interactions, and no unbounded cleanup. | Not certified. |
| 100,000 requests | Requests primarily consume bounded Redis queue/status capacity or receive busy/retry. They do not become 100,000 PostgreSQL transactions, 100,000 DB connections, or 100,000 indefinitely blocked BEAM processes. | Architectural expectation only; no measured claim. |

Queue insertion, promotion, release, and expiry should be `O(log n)` or better with
bounded batches. `B_total` remains distinct from `Store.Repo` pool size and must leave
headroom. The existing whole-window pool gate, provider-fault gates, normal 3/3 gate,
chaos 3/3 gate, zero-oversell gate, and unexpected-lock thresholds are not weakened.

### Cache, invalidation, and streams

- Cache: none in the correctness path. Existing stock/availability projections may
  invalidate after durable reservation outcomes, as they do today.
- Redis structures: ZSET queue order, global dispatch, queued expiry, global active
  lease expiry, per-variant active HASH, request metadata HASH, recovery fence, and
  namespace epoch as specified above.
- TTL: all queued, active, recovery, and terminal metadata windows are finite and
  configuration-validated; queue and active expiry scores carry the semantic deadline.
- Invalidation/cleanup: atomic release/expiry/recovery transitions plus bounded
  reaper; no full key scan.
- PubSub: status/read-side broadcast only, after the authoritative state transition;
  no correctness dependency.
- Redis Stream: not required for the MVP.

### Final certification sequence, later only

After implementation hardening, run the existing harness and focused additions in this
order:

1. disabled-mode baseline and existing reservation correctness;
2. enforced single-variant unit/integration and Redis failure gates;
3. deterministic 160-contender herd with `K_v = 1` and one last-unit winner;
4. many-hot-variant test proving `B_total` bounds DB entry independently of `K_v`;
5. multi-node Redis tests proving global permits, lease fencing, restart quarantine,
   and ambiguous recovery;
6. provider-fault and ordinary performance gates with the existing `0.95` whole-window
   Store.Repo threshold;
7. normal performance 3/3, chaos 3/3, and approved scale workloads;
8. only then consider a separate measured 100k study.

No performance certification is run by S0-PLAN-01.

## 21. Test strategy before implementation

Tests are designed before production work and map to the frozen invariants. These are
future test outputs; no test file is changed by this plan.

### Pure state and value tests

Target `test/store/orders/inventory_admission_state_test.exs`:

- every state and transition in Section 7;
- terminal-state rejection and replay behavior;
- `ADMITTED` not implying reservation;
- `K_v = 1` as a non-configurable rule;
- deadline relationships and monotonic remaining-budget calculations;
- stale owner/fence cannot transition a newer lease;
- request fingerprint rules preserve quantity-adjustment semantics.

### Redis atomic-contract tests

Target `test/store/orders/inventory_admission_redis_test.exs`:

- enqueue deduplication and one-member identity;
- exact `Q_variant_max` and `Q_global_max` rejection;
- atomic acquisition of both `K_v = 1` and `B_total`;
- no partial permit on failure or uncertain response;
- per-variant FIFO-ish sequence and global dispatch behavior;
- separate order/queued-expiry/active-expiry semantics;
- renew/release token checks and idempotent repeats;
- stale release cannot decrement a newer global permit;
- active expiry freezes `RESERVING` rather than promoting a replacement;
- namespace restart quarantine and bounded reaper cleanup;
- no Redis Stream/PubSub dependency.

### Domain and idempotency tests

Target `test/store/orders/inventory_admission_test.exs`:

- queued call returns immediately without a Store.Repo checkout;
- status/retry uses the same identity and does not create another member;
- duplicate calls in `QUEUED`, `ADMITTED`, `RESERVING`, and `RECOVERING` converge;
- exact replay after `COMPLETED` returns the durable row;
- governed replay after rejection/expiry/abandonment;
- authorized later quantity adjustment remains serialized and uses existing delta
  semantics;
- multi-variant input returns unsupported under the enforced tracer boundary;
- Redis timeout/restart/unavailable is fail closed;
- generic waiting-room fail-open behavior cannot bypass inventory admission;
- server-controlled ownership, rate-limit integration, and forged identity rejection.

### Durable integration and recovery tests

Target `test/store/orders/inventory_admission_recovery_test.exs` and the existing
inventory governance suite:

- existing row lock and final availability check remain active;
- one winner and governed losers preserve zero oversell;
- known commit releases and replays the durable `InventoryReservation`;
- known rollback releases with no row/counter side effect;
- commit-then-response-loss finds `reservation_key` and creates no duplicate row;
- ambiguous timeout does not become `OUT_OF_STOCK` or unrestricted retry;
- lookup uncertainty retains the fence and retries within a bounded deadline;
- no row after the safety window resolves according to the documented rejection policy;
- process crash before DB versus after DB entry has distinct cleanup behavior;
- commit followed by Redis release failure leaves durable success valid.

### Multi-node and concurrency tests

Target `test/store/governance/inventory_admission_concurrency_test.exs`:

- 160 same-variant contenders across at least two application nodes prove only one
  enters the DB critical section at a time;
- 159 governed losers and one winner on one unit preserve zero oversell;
- queued contenders hold no Store.Repo connections;
- active DB entrants never exceed `B_total` across many hot variants;
- two nodes cannot independently grant the same variant or global slot;
- lease-holder crash and Redis restart recover capacity without unsafe promotion;
- duplicate same-identity calls converge to one queue member/permit/reservation.

Testing two tasks on one BEAM node is not sufficient for the multi-node gate. Use a
focused distributed harness with separate application nodes sharing the same Redis
namespace and PostgreSQL test database. If the harness cannot run, multi-node safety
remains a required pre-certification gate rather than being waived.

### Final performance tests

Later tests extend the existing performance smoke/observer contract rather than
weakening it. They record admission events, queue depth, active permits, DB entrants,
checkout queue time, Store.Repo utilization, lock classification, Redis latency, and
durable outcome counts. They preserve the existing `0.95` pool threshold, zero
oversell requirement, provider-fault gates, normal 3/3, and chaos 3/3 requirements.

## 22. Exact tracer bullet

The smallest implementation slice is:

```text
one trusted order + one normalized variant
  -> derive existing reservation_key
  -> request/deduplicate bounded Redis admission
  -> atomically acquire K_v = 1 and B_total
  -> claim ADMITTED -> RESERVING
  -> run existing InventoryReservations.reserve_inventory/3 unchanged
  -> classify known commit / known rejection / ambiguous DB outcome
  -> complete and fenced-release, or fence and recover by reservation_key
  -> return durable result or bounded status
```

It includes only the contract/types, Redis atomic primitive, internal service, one
single-variant facade integration, bounded lease/reaper machinery, recovery worker,
telemetry, and deterministic tests needed to prove the primitive. It does not include
any of the horizontal expansions below.

## 23. Future horizontal expansion

These are explicitly later:

- multi-variant orders, using deterministic binary UUID acquisition order or an atomic
  multi-key admission mechanism;
- waiting-room UX, HTTP status mapping, LiveView push/poll presentation, and product
  messaging;
- broader global rate-limit policy and anti-abuse operations;
- admin inspection/repair tools and analytics dashboards;
- consume/release coordination changes if later requirements need them;
- package extraction or a generic admission framework.

No implementation may acquire one variant permit and wait indefinitely for another.
No later consumer may be used to justify package extraction until the extraction gates
in the frozen ADR have all passed.

## 24. Phased implementation plan

Each phase is outcome-oriented and must stop at its completion gate. A future coding
agent must not begin a later phase when its predecessor's gate is incomplete.

### PHASE IA-01: contracts, state values, errors, and configuration

**Files:**

- `lib/store/orders/inventory_admission.ex`
- `lib/store/orders/inventory_admission/request.ex`
- `lib/store/orders/inventory_admission/lease.ex`
- `lib/store/support/errors/error_codes.ex` only for registry-backed admission codes
- `config/config.exs`, `config/runtime.exs`, and `config/test.exs` only in the future
  implementation task
- `test/store/orders/inventory_admission_state_test.exs`

**Tasks:**

- [ ] Define the typed request/lease values and closed state/transition contract.
- [ ] Freeze `K_v = 1` outside runtime configuration.
- [ ] Add validated `B_total`, queue, deadline, recovery, namespace, and feature-gate
      settings without selecting an arbitrary production `B_total`.
- [ ] Define domain result/error codes and the `reserve/status/abandon` contract.
- [ ] Add pure state/deadline/idempotency tests.

**Completion gate:** State ownership, terminal behavior, identity rules, config
relationships, error meanings, and no-migration boundary are reviewable and tested;
the code still performs no Redis or PostgreSQL admission.

### PHASE IA-02: atomic Redis admission primitive

**Files:**

- `lib/store/orders/inventory_admission/redis.ex`
- `test/store/orders/inventory_admission_redis_test.exs`

**Tasks:**

- [ ] Implement the versioned environment-prefixed key model and common hash tag.
- [ ] Implement server-side atomic enqueue/deduplicate, promotion, dual-budget
      acquisition, lease claim, renewal, release, expiry, fencing, and quarantine
      contracts from Section 10.
- [ ] Keep queue order, queued expiry, and active expiry semantically separate.
- [ ] Return typed atomic results; never make a client-side check-then-set decision.
- [ ] Enforce `K_v = 1`, `B_total`, `Q_variant_max`, and `Q_global_max` atomically.

**Completion gate:** Redis tests prove no partial dual-budget grant, no stale-owner
mutation, bounded membership, idempotent repeats, and fail-closed error results.

### PHASE IA-03: internal admission service and caller-independent waiting

**Files:**

- `lib/store/orders/inventory_admission.ex`
- `lib/store/orders/inventory_admission/request.ex`
- `lib/store/orders/inventory_admission/lease.ex`
- `test/store/orders/inventory_admission_test.exs`

**Tasks:**

- [ ] Orchestrate request/deduplication, immediate admission, queued status, retry,
      explicit abandonment, lease claim, and bounded deadlines.
- [ ] Keep normal callers on the single high-level domain operation; do not expose raw
      Redis handles or an unrestricted admitted-operation function.
- [ ] Emit the admission telemetry contract with cardinality controls.
- [ ] Make queue lifetime independent of Phoenix/LiveView process lifetime.
- [ ] Ensure Redis errors never call the direct durable reservation primitive.

**Completion gate:** Domain tests show short queued interactions, exact replay
convergence, bounded busy behavior, no web waiting-room dependency, and no inventory
side effect before PostgreSQL settlement.

### PHASE IA-04: single-variant integration with the existing reservation transaction

**Files:**

- `lib/store/orders/domain.ex`
- `lib/store/orders/inventory_admission.ex`
- `lib/store/orders/inventory_reservations.ex` only for a narrow durable lookup/helper
      if required by recovery
- `test/store/governance/inventory_reservations_test.exs` and focused admission tests

**Tasks:**

- [ ] Route the enforced one-variant `Store.Orders.reserve_inventory/3` path through
      admission.
- [ ] Pass exactly one item to the unchanged existing reservation transaction after
      `ADMITTED -> RESERVING`.
- [ ] Return explicit unsupported behavior for multi-variant input under this gate;
      do not route it around admission.
- [ ] Preserve existing durable quantity adjustment, lifecycle, notification, and
      invalidation behavior.
- [ ] Keep any disabled/test/system bypass explicit and unavailable to untrusted input.

**Completion gate:** Existing reservation tests and focused integration tests prove
the final row lock, availability guard, durable identity, and zero-oversell behavior
remain intact. No schema change is needed.

### PHASE IA-05: ambiguous-outcome recovery

**Files:**

- `lib/store/orders/inventory_admission/recovery.ex`
- `lib/store/workers/inventory_admission_recovery_worker.ex`
- `test/store/orders/inventory_admission_recovery_test.exs`
- `test/store/workers/inventory_admission_recovery_worker_test.exs`

**Tasks:**

- [ ] Classify definitive commit, definitive rollback/rejection, pre-DB failure, and
      ambiguous database outcomes at the operation boundary.
- [ ] Add the read-only `reservation_key` reconciliation boundary using existing
      PostgreSQL uniqueness/index support.
- [ ] Mark unknown/fence before recovery and retain both capacities until resolution.
- [ ] Use one unique, bounded Oban recovery job per identity; keep the final reservation
      transaction synchronous and outside Oban.
- [ ] Resolve found-row and definitive-no-row outcomes atomically; retain uncertain
      lookup outcomes through bounded retry/escalation.

**Completion gate:** Fault-injected commit-loss, rollback, process-crash, worker-crash,
and Redis-release-loss tests prove no duplicate durable reservation and no unsafe
permit reuse.

### PHASE IA-06: lease expiry, reaper, and Redis failure recovery

**Files:**

- `lib/store/workers/inventory_admission_reaper_worker.ex`
- `lib/store/orders/inventory_admission/redis.ex`
- `config/config.exs` and Oban schedule only in the future implementation task
- focused cleanup/failure tests

**Tasks:**

- [ ] Prune queued expiry with bounded expiry-index operations.
- [ ] Freeze `RESERVING` holders on lease loss/expiry and enqueue recovery rather than
      returning permits by timestamp alone.
- [ ] Recover unclaimed `ADMITTED` leases only after the safe check.
- [ ] Quarantine Redis restart/namespace loss and prevent promotion during the old
      operation safety window.
- [ ] Re-enqueue missing recovery work without full Redis scans or unbounded loops.

**Completion gate:** Crash, disconnect, lease-loss, Redis timeout, restart, and stale
token tests prove bounded capacity safety and fail-closed behavior.

### PHASE IA-07: deterministic concurrency, security, and multi-node hardening

**Files:**

- `test/store/governance/inventory_admission_concurrency_test.exs`
- focused domain/Redis/security tests
- performance observer extensions only if the existing harness needs new admission
  measurements

**Tasks:**

- [ ] Run the 160 same-variant deterministic herd and last-unit zero-oversell matrix.
- [ ] Prove `K_v = 1` and `B_total` are global across separate application nodes.
- [ ] Prove queued work does not occupy Store.Repo connections and pool headroom is
      retained across many hot variants.
- [ ] Test forged identities, replay, queue flooding, slot hoarding, and cross-order
      manipulation.
- [ ] Verify PubSub loss and generic waiting-room fail-open behavior cannot alter
      admission correctness.

**Completion gate:** All correctness, failure, identity, security, and multi-node
gates pass deterministically. This is still not performance certification.

### PHASE IA-08: performance certification

**Files:**

- Existing `priv/repo/performance_smoke_test.exs` and observer support only if required
  by the accepted test design
- new focused performance scenario/report files only after review

**Tasks:**

- [ ] Establish disabled-mode baseline and compare enforced-mode DB entrants,
      Store.Repo utilization, checkout queue time, lock waits, Redis latency, and
      reservation latency.
- [ ] Run same-variant 40/160 and many-hot-variant `B_total` workloads.
- [ ] Preserve zero oversell, expected/unexpected lock gates, pool `<= 0.95`, provider
      fault gates, normal 3/3, and chaos 3/3.
- [ ] Produce measured scale evidence before making any capacity or 100k statement.

**Completion gate:** A separate performance/capacity review accepts the evidence. It
may tune `B_total` and deadlines; it may not change `K_v = 1` without a new
architecture review. This phase is not part of S0-PLAN-01 execution.

## 25. TOON micro-prompts

Each prompt below is one focused future coding task. These prompts are not production
instructions for the current session and contain no implementation code.

### Config / Contracts

#### TOON CC-01

Task: Define the typed single-variant admission request, lease value, closed states,
and transition contract.

Objective: Give the service one source of truth for identity, `K_v = 1`, deadlines,
terminal states, and replay behavior before Redis or PostgreSQL integration.

Output: `lib/store/orders/inventory_admission.ex`,
`lib/store/orders/inventory_admission/request.ex`,
`lib/store/orders/inventory_admission/lease.ex`, and pure state tests.

Note: DATA LAYER: HOT transient Elixir values only; durable truth stays PostgreSQL.
INDEXES: preserve the existing `reservation_key` and inventory indexes; no migration.
CACHE: none. REDIS STRUCTURE: values mirror the versioned ZSET/HASH model. TTL: use
finite configured queue, lease, and recovery windows; do not make `K_v` configurable.
INVALIDATION/CLEANUP: transition contract must leave cleanup to atomic Redis/reaper
operations. PUBSUB: none. STORE.REPO EFFECT: no DB entry before an admitted claim.
100K SAFETY: status values must support bounded queue interactions, not blocked
processes; no certification claim.

#### TOON CC-02

Task: Define and validate the admission configuration, error codes, and server-side
`DISABLED | ENFORCED` rollout gate.

Objective: Make `B_total`, queue bounds, deadlines, Redis quarantine, and governed
busy/unavailable/unsupported outcomes explicit without selecting arbitrary production
capacity constants.

Output: Future configuration sections in `config/config.exs`, `config/runtime.exs`,
`config/test.exs`, registry-backed entries in
`lib/store/support/errors/error_codes.ex`, and configuration tests.

Note: DATA LAYER: configuration controls HOT Redis coordination and durable PostgreSQL
entry budgets. INDEXES: existing reservation/inventory indexes only; no migration.
CACHE: none. REDIS STRUCTURE: shared environment-prefixed admission namespace.
TTL: validate finite `T_db`, `L_admission`, queue, recovery, terminal, and quarantine
relationships. INVALIDATION/CLEANUP: invalid config keeps ENFORCED closed. PUBSUB: no
gate authority. STORE.REPO EFFECT: enforce `B_total < aggregate pool minus headroom`.
100K SAFETY: queue bounds and fail-closed Redis are required; no measured claim.

### Redis Primitive

#### TOON RP-01

Task: Define the internal Redis key namespace and record encoding for admission.

Objective: Give every future atomic operation one non-ambiguous key and semantic owner,
including the global/variant same-slot requirement.

Output: `lib/store/orders/inventory_admission/redis.ex` key builders/decoders and
focused structure tests.

Note: DATA LAYER: Redis is HOT/WARM ephemeral coordination, never inventory truth.
INDEXES: PostgreSQL lookup/indexes remain unchanged. CACHE: no stock cache. REDIS
STRUCTURE: per-variant queue ZSET, global dispatch ZSET, global queued-expiry ZSET,
variant active HASH, global active-expiry ZSET, metadata HASH, recovery fence, and
namespace epoch. TTL: semantic score deadlines are separate from container retention.
INVALIDATION/CLEANUP: bounded expiry-index cleanup only; no KEYS. PUBSUB: none.
STORE.REPO EFFECT: queued entries must not checkout connections. 100K SAFETY: bounded
queue/status state only; no certification claim.

#### TOON RP-02

Task: Implement the atomic enqueue/deduplicate and dual-budget promotion contract.

Objective: Prove one Redis decision grants both `K_v = 1` and `B_total`, or grants
neither, across nodes.

Output: Atomic server-side operations and result decoding in
`lib/store/orders/inventory_admission/redis.ex`, plus Redis contract tests.

Note: DATA LAYER: Redis coordinates only; PostgreSQL still decides stock. INDEXES:
reuse existing durable identity, no migration. CACHE: none. REDIS STRUCTURE: queue
order/dispatch/expiry ZSETs plus variant active and global active-expiry records.
TTL: queue deadlines and active lease deadlines are separate finite scores.
INVALIDATION/CLEANUP: prune bounded expired queue members before admission. PUBSUB:
not involved. STORE.REPO EFFECT: at most one same-variant DB entrant and at most
`B_total` globally. 100K SAFETY: excess requests return governed busy/retry; no DB
herd and no process-per-waiter claim.

#### TOON RP-03

Task: Implement token-checked lease claim, renewal, release, stale-owner rejection,
and promotion-after-release.

Objective: Preserve capacity correctness when owners replay, crash, or release after a
newer lease exists.

Output: Lease transition operations in `redis.ex` and tests for renew/release,
idempotency, stale tokens, and active expiry.

Note: DATA LAYER: transient Redis lease over durable PostgreSQL transaction. INDEXES:
existing `reservation_key` uniqueness remains the durable duplicate guard. CACHE: none.
REDIS STRUCTURE: variant active HASH and global active-expiry ZSET, with metadata HASH.
TTL: `L_admission` covers `T_db` plus margin; renewal cannot extend indefinitely.
INVALIDATION/CLEANUP: release and next promotion are one atomic transition; active
RESERVING expiry freezes instead of releasing. PUBSUB: none. STORE.REPO EFFECT: no
replacement enters while the prior DB operation may run. 100K SAFETY: stale holders
cannot multiply DB entrants; not certified.

#### TOON RP-04

Task: Implement unknown-outcome fencing, recovery ownership, and Redis namespace
quarantine transitions.

Objective: Make Redis uncertainty fail closed without allowing a stale holder or
restart to grant unsafe capacity.

Output: Fence/quarantine operations in `redis.ex` and failure-contract tests.

Note: DATA LAYER: Redis fence is duplicate-prevention state, not durable outcome.
INDEXES: durable recovery uses existing `reservation_key` unique index; no migration.
CACHE: none. REDIS STRUCTURE: recovery fence HASH and namespace epoch HASH alongside
active lease records. TTL: recovery and quarantine TTLs are finite and safety-window
validated. INVALIDATION/CLEANUP: fence expiry never releases capacity by itself;
reaper resumes or escalates bounded recovery. PUBSUB: no correctness role.
STORE.REPO EFFECT: uncertainty freezes variant/global promotion. 100K SAFETY: Redis
outage rejects new admission instead of bypassing to PostgreSQL; no certification.

### Domain Logic

#### TOON DL-01

Task: Build the internal `InventoryAdmission.reserve/status/abandon` orchestration.

Objective: Separate short caller interactions from queue lifetime and keep lifecycle
decisions out of the Redis adapter.

Output: `lib/store/orders/inventory_admission.ex` and domain tests.

Note: DATA LAYER: HOT admission coordination precedes COLD/DURABLE PostgreSQL.
INDEXES: use existing durable identities; no migration. CACHE: none in correctness
path. REDIS STRUCTURE: call only typed atomic operations, never ad hoc commands.
TTL: pass bounded queue/lease/deadline values. INVALIDATION/CLEANUP: emit transition
events and leave cleanup to atomic/reaper owners. PUBSUB: optional status projection
only. STORE.REPO EFFECT: queued calls return before checkout. 100K SAFETY: status/retry
contract avoids one blocked BEAM process per queue member.

#### TOON DL-02

Task: Add admission telemetry and server-side ownership/rate-limit enforcement at the
domain boundary.

Objective: Make operational evidence and abuse controls part of the capability without
making UI or PubSub authoritative.

Output: telemetry calls/metadata in `inventory_admission.ex` and focused ownership,
cardinality, and error tests.

Note: DATA LAYER: HOT Redis coordination with COLD PostgreSQL outcomes. INDEXES:
existing identity/index guarantees only. CACHE: derived projections only. REDIS
STRUCTURE: request metadata HASH and opaque HMAC member. TTL: finite terminal and lease
retention. INVALIDATION/CLEANUP: bounded identity/queue cleanup and no raw key logs.
PUBSUB: status broadcast after transition only. STORE.REPO EFFECT: abuse controls must
not add DB work for queued requests. 100K SAFETY: bounded labels and queue limits, no
unbounded per-variant metric dimensions.

### Integration

#### TOON IN-01

Task: Route the enforced single-variant `Store.Orders.reserve_inventory/3` facade
through `InventoryAdmission`.

Objective: Put the gate before the existing transaction while making multi-variant
accidental bypass explicit and preserving disabled-mode rollout.

Output: Narrow future changes to `lib/store/orders/domain.ex`,
`lib/store/orders/inventory_admission.ex`, and focused integration tests.

Note: DATA LAYER: HOT admission then existing COLD/DURABLE `InventoryReservation`.
INDEXES: existing `inventory_items.variant_id` and reservation identities; no
migration. CACHE: no admission decision from cache. REDIS STRUCTURE: atomic K_v/B_total
lease before transaction. TTL: pass remaining `T_db` and `L_admission`.
INVALIDATION/CLEANUP: preserve existing inventory invalidation after durable outcome.
PUBSUB: no correctness dependency. STORE.REPO EFFECT: no queued checkout; direct
herd is removed only in ENFORCED mode. 100K SAFETY: multi-variant is unsupported,
not partially admitted; no certification claim.

#### TOON IN-02

Task: Add the narrow durable `reservation_key` reconciliation read boundary.

Objective: Let recovery query PostgreSQL authority without adding an admission schema or
letting Redis decide commit status.

Output: A read-only internal function in `lib/store/orders/inventory_reservations.ex`
or the repository-consistent domain boundary, plus identity/index tests.

Note: DATA LAYER: COLD/DURABLE PostgreSQL lookup. INDEXES: require the existing unique
`inventory_reservations.reservation_key` index and `inventory_items.variant_id`; no
migration. CACHE: none for recovery truth. REDIS STRUCTURE: Redis supplies only fence
ownership. TTL: recovery retries remain bounded. INVALIDATION/CLEANUP: no stock/cache
mutation from the read. PUBSUB: none. STORE.REPO EFFECT: recovery uses bounded reads,
never a queued reservation transaction. 100K SAFETY: ambiguous requests do not create
unrestricted DB retries; no certification claim.

### Recovery

#### TOON RC-01

Task: Implement durable ambiguous-outcome reconciliation by `reservation_key`.

Objective: Resolve commit versus no-commit without assuming rollback and without
starting a second durable attempt automatically.

Output: `lib/store/orders/inventory_admission/recovery.ex` and recovery fault tests.

Note: DATA LAYER: PostgreSQL is final durable authority; Redis is the recovery fence.
INDEXES: use the existing unique `reservation_key` lookup; no migration. CACHE: none.
REDIS STRUCTURE: recovery fence HASH and active lease records. TTL: bounded safety
window, retry budget, and absolute recovery deadline. INVALIDATION/CLEANUP: only a
definitive durable result releases capacity; uncertainty remains fenced. PUBSUB: no
correctness role. STORE.REPO EFFECT: one bounded recovery read, not an unrestricted
reservation retry. 100K SAFETY: ambiguous workload cannot multiply DB attempts; no
measured claim.

#### TOON RC-02

Task: Add the unique Oban recovery worker and bounded expiry/reaper owner.

Objective: Survive caller/worker crashes and clean stale coordination without tying
admission correctness to a long-lived request process.

Output: `lib/store/workers/inventory_admission_recovery_worker.ex`,
`lib/store/workers/inventory_admission_reaper_worker.ex`, and worker tests.

Note: DATA LAYER: Oban is operational retry; PostgreSQL reservation remains durable
truth. INDEXES: recovery worker relies on existing `reservation_key`; no migration.
CACHE: none. REDIS STRUCTURE: expiry ZSETs, active lease index, recovery fence.
TTL: finite Oban/recovery attempts and Redis safety TTLs. INVALIDATION/CLEANUP:
bounded ZRANGEBYSCORE/member cleanup, no KEYS or full scans. PUBSUB: optional status
projection only. STORE.REPO EFFECT: reaper/recovery never opens one transaction per
queued request. 100K SAFETY: bounded jobs and queue state, no blocked BEAM process per
waiter; not certified.

### Tests

#### TOON TS-01

Task: Add pure state, idempotency, deadline, queue-bound, and `K_v = 1` tests.

Objective: Prove the contract without external Redis/PostgreSQL timing noise before
integration work begins.

Output: `test/store/orders/inventory_admission_state_test.exs`.

Note: DATA LAYER: pure HOT coordination rules only. INDEXES: assert the durable
`reservation_key` dependency but do not change schema. CACHE: none. REDIS STRUCTURE:
test the abstract ZSET/HASH contract. TTL: use injected finite clocks/deadlines.
INVALIDATION/CLEANUP: assert every terminal transition removes live membership.
PUBSUB: none. STORE.REPO EFFECT: pure tests must require zero DB checkouts. 100K
SAFETY: assert bounded queue/status semantics, not load capacity.

#### TOON TS-02

Task: Add Redis integration tests for atomic dual budgets, stale leases, expiry, and
Redis failure behavior.

Objective: Prove server-side atomicity and fail-closed coordination across concurrent
clients before durable integration.

Output: `test/store/orders/inventory_admission_redis_test.exs` using the repository's
dedicated test Redis configuration, with no production configuration changes.

Note: DATA LAYER: Redis coordination only. INDEXES: no migration; durable identity is
asserted by contract. CACHE: none. REDIS STRUCTURE: all namespace keys share the
atomic hash tag; queue/queued-expiry/active-expiry semantics remain separate. TTL:
exercise finite queue and lease windows. INVALIDATION/CLEANUP: verify atomic release,
promotion, bounded prune, and quarantine. PUBSUB: none. STORE.REPO EFFECT: queued
clients produce no reservation DB entrants. 100K SAFETY: test bounded rejection, not
100k certification.

#### TOON TS-03

Task: Add PostgreSQL integration tests for known outcomes, ambiguous recovery, replay,
and existing reservation lifecycle preservation.

Objective: Prove Redis admission never replaces the final PostgreSQL guard or creates a
duplicate durable reservation.

Output: `test/store/orders/inventory_admission_recovery_test.exs` and focused additions
to the existing inventory governance tests.

Note: DATA LAYER: COLD/DURABLE PostgreSQL reservation truth behind HOT admission.
INDEXES: verify existing unique `reservation_key`, `(order_id, variant_id)`, and
`inventory_items.variant_id`; no migration. CACHE: none. REDIS STRUCTURE: fence/lease
state only. TTL: recovery safety and retry windows are bounded. INVALIDATION/CLEANUP:
preserve existing stock projection invalidation after durable outcomes. PUBSUB: no
correctness role. STORE.REPO EFFECT: only admitted work checks out; ambiguous outcomes
do not retry unrestricted. 100K SAFETY: no claim beyond bounded entrant behavior.

#### TOON TS-04

Task: Add the focused separate-node concurrency and security harness.

Objective: Prove `K_v` and `B_total` are global across nodes and that untrusted callers
cannot manipulate coordination state.

Output: `test/store/governance/inventory_admission_concurrency_test.exs` and any
dedicated test support needed for two application nodes.

Note: DATA LAYER: shared PostgreSQL durable rows plus shared Redis coordination.
INDEXES: existing inventory/reservation indexes only. CACHE: no authority. REDIS
STRUCTURE: one cluster-global variant/global budget namespace. TTL: crash/restart
tests use bounded lease/recovery windows. INVALIDATION/CLEANUP: prove capacity returns
only through fenced atomic cleanup. PUBSUB: loss must not change outcomes.
STORE.REPO EFFECT: assert per-variant one entrant, global `B_total`, and retained
headroom. 100K SAFETY: harness proves architecture shape at focused scale; it does
not certify 100k.

### Performance

#### TOON PF-01

Task: Extend observability for admission and DB-capacity evidence.

Objective: Make later certification able to distinguish queue pressure, Redis pressure,
DB entrant pressure, and durable reservation outcomes without high-cardinality labels.

Output: Admission telemetry and bounded observer/report additions in the existing
performance support paths, only after the concurrency gates pass.

Note: DATA LAYER: HOT Redis/Elixir admission, durable PostgreSQL reservation, WARM
metrics. INDEXES: no migration; report existing lookup/index assumptions. CACHE: no
correctness cache. REDIS STRUCTURE: queue/lease depth and latency measurements.
TTL: report configured queue/lease/recovery windows. INVALIDATION/CLEANUP: include
expiry/abandon/recovery cleanup counts. PUBSUB: status-only metrics if used.
STORE.REPO EFFECT: report utilization, checkout queue, entrants, and lock waits.
100K SAFETY: metrics must support bounded-backpressure evidence, not a certification
claim.

#### TOON PF-02

Task: Run the separate performance/capacity certification sequence for enforced
admission.

Objective: Verify the architecture under approved workloads without weakening existing
correctness, pool, provider-fault, or chaos gates.

Output: Performance reports and an independent capacity-review record; no architecture
or implementation changes are implied by a passing run.

Note: DATA LAYER: HOT admission, HOT row contention, COLD durable reservation result.
INDEXES: use existing inventory/reservation indexes and record plans if required; no
unreviewed migration. CACHE: projections only. REDIS STRUCTURE: measure queue/lease
depth, dual-budget occupancy, expiry, and latency. TTL: test configured deadlines and
recovery behavior. INVALIDATION/CLEANUP: verify queues and leases drain. PUBSUB: must
remain non-authoritative. STORE.REPO EFFECT: retain the existing `0.95` whole-window
gate and prove no 40/40 same-variant herd. 100K SAFETY: 100k remains unmeasured until
its own evidence is accepted.

## 26. Plan self-review

Before handing this plan to an implementation-planning reviewer, confirm:

- [ ] The tracer bullet has exactly one variant and one durable reservation call.
- [ ] `K_v = 1` is normative and cannot be configured higher in the MVP.
- [ ] `B_total` is global, separately bounded, and never defaults to the full pool.
- [ ] Variant and global capacity are one Redis atomic decision.
- [ ] Queue bounds and request-process lifetime are independently finite.
- [ ] Queue order, queued expiry, and active expiry have separate semantics.
- [ ] Admission success never implies stock ownership or durable reservation.
- [ ] Known commit, known rollback/rejection, and ambiguous DB outcomes are distinct.
- [ ] Recovery queries PostgreSQL by the existing unique `reservation_key`.
- [ ] Recovery fences preserve capacity and do not pretend to fence PostgreSQL.
- [ ] Redis outage/restart/uncertainty fails closed and cannot bypass PostgreSQL.
- [ ] PubSub and Redis Stream have no correctness authority in the MVP.
- [ ] Existing durable lifecycle and no-oversell guard remain unchanged.
- [ ] No migration, Redis inventory ledger, multi-variant path, or package extraction is
      required.
- [ ] The test plan includes deterministic same-variant, global-budget, replay,
      crash/recovery, Redis-failure, and separate-node evidence.
- [ ] The performance plan retains all existing thresholds and makes no 100k claim.

## 27. Implementation authorization gate

This plan is not implementation authorization. A future coding agent must wait for an
independent review of this plan and an explicit implementation task. The architecture
remains frozen, and any discovery that requires changing `K_v`, moving inventory truth
to Redis, weakening the PostgreSQL guard, adding a migration, or introducing
multi-variant admission must stop and reopen the appropriate architecture review.

IMPLEMENTATION STATUS:
NOT AUTHORIZED

NEXT:
Independent implementation-plan review
