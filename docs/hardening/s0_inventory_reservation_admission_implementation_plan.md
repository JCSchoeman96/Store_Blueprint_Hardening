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
  -> server-generated operation_id/operation_epoch and request_fingerprint
  -> Redis enqueue-or-deduplicate
  -> atomic K_v = 1 plus B_total admission
  -> outcome-preserving existing Store.Orders.InventoryReservations reservation seam
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
   `reservation_key` plus operation-specific durable PRE/POST facts before permit
   reuse or another durable attempt. `reservation_key` identifies the durable
   reservation row/aggregate, not one mutation attempt.
9. The tracer bullet accepts one variant only. Multi-variant admission is rejected at
   this boundary until a deterministic ordered or atomic multi-key design is separately
   reviewed.
10. Only one non-terminal operation may exist for a `reservation_key`. A later
    authorized adjustment gets a new server-generated operation identity only after the
    earlier operation has reached a terminal, resolved state.

## 2. Non-goals

This plan does not include:

- changing `InventoryReservation` state transitions;
- replacing or weakening the PostgreSQL `FOR UPDATE` availability guard;
- a Redis availability, stock, or hold ledger;
- multi-item or multi-variant atomic admission;
- checkout, payment, consume, release, or reservation-expiry redesign;
- waiting-room UI, LiveView UX, admin UI, analytics dashboards, or browser admission;
- a generic package or public `InventoryAdmission` API;
- a new PostgreSQL resource, mutation column, index, or migration;
- a Redis Stream workflow;
- a user-controlled feature toggle;
- canonical S0 performance certification or a 100,000-request claim.

The existing multi-variant checkout path through
`Store.Orders.reserve_inventory_for_checkout/3` remains outside this tracer bullet.
It is still a capable durable writer. The frozen writer matrix in Section 6 makes it
unavailable while the admission gate is `ENFORCED`; it must never silently bypass
admission. A later checkout integration needs its own architecture decision.

## 3. Current source baseline

The following source facts are the boundaries the implementation must preserve.

| Source | Current fact | Planning consequence |
|---|---|---|
| [`lib/store/orders/domain.ex`](../../lib/store/orders/domain.ex:162) | `Store.Orders.reserve_inventory/3` currently delegates directly to `InventoryReservations.reserve_inventory/3`. | This remains the high-level integration point. Enforced single-variant calls must delegate through admission before reaching the durable primitive. |
| [`lib/store/orders/inventory_reservations.ex`](../../lib/store/orders/inventory_reservations.ex:16) | The normal path opens `Repo.transaction/1` and reserves normalized variants. | The tracer bullet calls this existing path with exactly one variant. Its transaction body is not rewritten. |
| [`lib/store/orders/inventory_reservations.ex`](../../lib/store/orders/inventory_reservations.ex:663) | The transaction locks `InventoryItem` by `variant_id` with `FOR UPDATE`, then locks the order/variant reservation row. | This is why the MVP permit is exactly `K_v = 1`. |
| [`lib/store/orders/inventory_reservations.ex`](../../lib/store/orders/inventory_reservations.ex:692) | Availability is checked from `stock_on_hand - reserved_count`, except for the explicit `allow_oversell` setting. | Redis must never answer availability or alter these counters. |
| [`lib/store/orders/inventory_reservations.ex`](../../lib/store/orders/inventory_reservations.ex:770) | The durable key is `order:<order_id>:sku:<variant_id>`. | This is the stable reconciliation identity and must be derived server-side. |
| [`lib/store/orders/inventory_reservation.ex`](../../lib/store/orders/inventory_reservation.ex:67) | Durable states are `active`, `consumed`, `expired`, and `cancelled`; identities cover both `order_id + variant_id` and `reservation_key`; the durable row has `quantity`, `expires_at`, and a monotonic `version`. | Admission states remain separate. No admission state replaces a durable state. The existing row/version fields are part of the operation-specific recovery proof. |
| [`lib/store/catalog/inventory_item.ex`](../../lib/store/catalog/inventory_item.ex:24) | The durable inventory row has `stock_on_hand`, `reserved_count`, `allow_oversell`, and a monotonic `version`, with one row per variant. | An operation descriptor can compare the existing inventory PRE and POST counters/version without adding a mutation marker. |
| [`priv/repo/migrations/20260224201500_phase_11_inventory_reservations.exs`](../../priv/repo/migrations/20260224201500_phase_11_inventory_reservations.exs:77) | PostgreSQL has unique indexes for `(order_id, variant_id)` and `reservation_key`, plus inventory variant lookup and reservation lifecycle indexes. | No admission migration is planned. Recovery can use `reservation_key` and compare operation-specific durable PRE/POST facts without inventing a schema. |
| [`lib/store/orders/inventory_reservations.ex`](../../lib/store/orders/inventory_reservations.ex:16), [`deps/ecto/lib/ecto/repo.ex`](../../deps/ecto/lib/ecto/repo.ex:2382), [`deps/db_connection/lib/db_connection.ex`](../../deps/db_connection/lib/db_connection.ex:1756) | The current public path maps non-`Store.Support.Errors.Error` transaction failures to `RESERVATION_CONFLICT`. Ecto reports `{:ok, result}` only after commit, explicit rollback values as `{:error, value}`, and exceptions can escape the transaction boundary. | Admission must call a future internal outcome-preserving seam before the compatibility mapper. Raw failures are classified with a phase/rollback-evidence contract rather than consumed as `RESERVATION_CONFLICT`. |
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
| Recovery | Durable lookup by `reservation_key` supplies the operation-specific PRE/POST snapshot used to decide whether PostgreSQL committed. Redis state cannot decide that question. |
| Notifications | Phoenix PubSub is read-side/status only. Redis Stream is not required for MVP correctness. |
| Schema | No PostgreSQL migration is required solely for admission because existing reservation/inventory fields, versions, counters, atomic transaction semantics, and unique/index guarantees support an operation-specific PRE/POST proof. This conclusion depends on the normative same-`reservation_key` serialization rule and is void if that rule cannot be enforced. |
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
| `Store.Orders.InventoryAdmission.Operation` | Pure typed Elixir descriptor in `lib/store/orders/inventory_admission/operation.ex`. Contains the server-generated `operation_id`, monotonic `operation_epoch`, `reservation_key`, request fingerprint, mutation kind, trusted durable PRE facts, and expected POST facts. | No | Created by `InventoryAdmission` for one authorized mutation attempt and retained in Redis metadata/fence state. It is not a durable mutation record and never replaces `reservation_key`. |
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
│   ├── request.ex                                 # trusted request and durable identity value
│   ├── operation.ex                               # one server-generated mutation descriptor and PRE/POST facts
│   ├── lease.ex                                   # lease value and internal handle
│   ├── redis.ex                                   # names, EVAL contracts, Redis result decoding
│   └── recovery.ex                                # PostgreSQL PRE/POST reconciliation and fence resolution
└── inventory_reservations.ex                      # existing durable tx; outcome seam and narrow read boundary

lib/store/workers/
├── inventory_admission_recovery_worker.ex          # one bounded recovery job per logical identity
└── inventory_admission_reaper_worker.ex            # bounded expiry/fence maintenance, no full scans

test/store/orders/
├── inventory_admission_state_test.exs              # pure state and deadline rules
├── inventory_admission_redis_test.exs              # atomic Redis contracts and idempotency
├── inventory_admission_test.exs                    # domain boundary and failure policy
└── inventory_admission_recovery_test.exs           # durable reconciliation and crash outcomes

test/store/workers/
├── inventory_admission_recovery_worker_test.exs    # Oban recovery execution/retry contract
└── inventory_admission_reaper_worker_test.exs      # bounded expiry/cleanup contract

test/support/
└── inventory_admission_multi_node.ex               # focused separate-application-node test support

test/store/governance/
└── inventory_admission_concurrency_test.exs        # K_v, B_total, multi-node and herd invariants
```

The exact files above are future implementation outputs. None are created by
S0-PLAN-01.

## 6. Admission identity and internal API

### Canonical identity

The server derives one stable durable identity from the trusted order context and
normalized UUIDs:

```text
reservation_key = "order:<order_id>:sku:<variant_id>"
durable_reservation_identity = reservation_key
```

`order_id` and `variant_id` are validated before admission. UUID normalization and
any ordering/tie-break use binary UUID representation, consistent with the repository
ID law. The client never supplies a Redis key, queue member, sequence, lease token,
owner epoch, or expiry timestamp.

The Redis queue member is an opaque server-derived HMAC digest of the durable identity
plus a key version. It is not the raw `reservation_key`. Admission metadata stores a
digest and server-owned fields; raw commercial identity is not exposed in Redis keys
or browser responses.

`reservation_key` identifies one durable `InventoryReservation` row/aggregate. It does
not identify one mutation attempt. Every admitted mutation also has the following
internal values:

```text
operation_id       = server-generated UUIDv7/opaque operation value
operation_epoch    = server-issued monotonic epoch for this reservation_key
request_fingerprint = deterministic digest of the trusted normalized mutation payload
```

`operation_id` and `operation_epoch` are never client supplied and never replace the
PostgreSQL `reservation_key`. The fingerprint includes the intended quantity and
controlled expiry/mutation policy, but never client clocks, Redis keys, lease tokens, or
other coordination fields. The operation descriptor also carries the minimum trusted
durable PRE and expected POST facts described in Section 12.

The existing source permits a later desired quantity adjustment for the same order and
variant, so the rules are:

- An exact replay while `QUEUED`, `ADMITTED`, `RESERVING`, `UNKNOWN_DB_OUTCOME`, or
  `RECOVERING` returns or joins the existing `operation_id`/`operation_epoch`. It
  creates no second queue member or permit.
- A changed request fingerprint while a logical operation is live returns the
  registry-backed idempotency mismatch/conflict result. It does not silently replace
  a queued quantity or start a second operation. Only one live operation may exist for
  a `reservation_key`.
- After an operation has reached a resolved terminal state, an authorized quantity
  adjustment may reuse the same `reservation_key` with a new server-generated
  `operation_id` and `operation_epoch`. The existing PostgreSQL path then applies its
  current active-reservation delta semantics.
- A new operation for the same `reservation_key` is forbidden while the prior
  operation is `QUEUED`, `ADMITTED`, `RESERVING`, `UNKNOWN_DB_OUTCOME`, `RECOVERING`,
  or `UNRESOLVED`. This same-reservation serialization is a correctness precondition
  for state-based ambiguous-outcome recovery.
- A replay after `COMPLETED` first returns the existing durable reservation outcome for
  an exact request. The durable row, not terminal Redis metadata, wins.
- A replay after `REJECTED`, `EXPIRED`, or `ABANDONED` follows the frozen retention and
  retry policy. It does not create a second live operation during terminal retention.
- A replay during `UNRESOLVED` returns a governed fail-closed result. It cannot start a
  later mutation or release the recovery fence.

The atomic request operation distinguishes an exact terminal replay from a new
authorized operation on the same durable identity. A terminal record within its
retention window returns its original operation. A later authorized adjustment, after
the terminal policy permits it, advances the operation epoch and replaces only the
ephemeral operation descriptor. It never creates a second durable identity or a
concurrent permit. An untrusted or mismatched attempt cannot use terminal retention to
bypass this rule.

### Operation descriptor and same-reservation serialization

Before `ADMITTED -> RESERVING` and before the protected mutation transaction, the
admitted owner prepares one `Operation` value. It contains `reservation_key`,
`operation_id`, `operation_epoch`, `request_fingerprint`, mutation kind, the trusted
durable PRE facts, and the expected durable POST facts. The bounded preflight read that
captures those facts is performed only after admission, while both `K_v` and `B_total`
are held, and is included in `T_db`. Queued requests never perform this read.

The protected path has one live mutation per `reservation_key`. The enforced admission
facade is the only normal reserve entry point. Section 6 freezes the policy for every
other capable writer. There is no implementation-time choice between fencing and
exclusion. PostgreSQL row locks still serialize durable writes, but row locks alone do
not identify which operation produced a later state.

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
trigger bounded promotion for the identity. `Identity` is a typed internal reference
containing the server-derived member/digest, `reservation_key`, `operation_id`, epoch,
and fingerprint needed for replay checks. It never contains a client-selected Redis
key or fencing token. `abandon/2` is an explicit server-owned operation for a queued
request. `recover/2` is restricted to the recovery worker and system context.

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

### Capable-writer matrix and frozen serialization policy

A focused source search found the following durable writers. The matrix is normative
for `ENFORCED` mode. The policy column is not a menu for implementation selection.

| Writer | Mutates `InventoryReservation`? | Mutates `InventoryItem` counters? | Can target the same `reservation_key`? | Can target the same variant row? | Current entry point | MVP policy |
|---|---:|---:|---:|---:|---|---|
| `Store.Orders.reserve_inventory/3` and its `InventoryReservations.reserve_inventory/3` implementation | YES | YES | YES | YES | [`lib/store/orders/domain.ex`](../../lib/store/orders/domain.ex:169) -> [`lib/store/orders/inventory_reservations.ex`](../../lib/store/orders/inventory_reservations.ex:16) | `ADMISSION_REQUIRED`: one normalized variant enters `InventoryAdmission`, owns `K_v = 1`, `B_total`, and the shared reservation fence. A multi-variant input is rejected. |
| `Store.Orders.reserve_inventory_for_checkout/3` and its CTE | YES | YES | YES | YES | [`lib/store/orders/domain.ex`](../../lib/store/orders/domain.ex:176), called by [`lib/store/checkout/domain.ex`](../../lib/store/checkout/domain.ex:767) and [`lib/store/subscriptions/facade.ex`](../../lib/store/subscriptions/facade.ex:2627) | `ENFORCED_UNAVAILABLE`: return `INVENTORY_ADMISSION_UNSUPPORTED` before `run_checkout_reservation_transaction/4` for every item count, including one. The CTE never runs while the tracer gate is enforced. It is not partially routed through multi-variant admission. |
| `Store.Orders.consume_reservations_for_order/2` | YES | YES | YES | YES | [`lib/store/orders/domain.ex`](../../lib/store/orders/domain.ex:184) -> [`lib/store/orders/inventory_reservations.ex`](../../lib/store/orders/inventory_reservations.ex:100); payment-success caller [`lib/store/payments/interlocks.ex`](../../lib/store/payments/interlocks.ex:595) | `SHARED_RESERVATION_FENCE`: acquire the server-owned fence for every target key before the existing transaction. This is not an admission queue and does not claim `B_total`. Busy or unavailable Redis produces a governed error and no durable mutation. |
| `Store.Orders.release_reservations_for_order/2` | YES | YES | YES | YES | [`lib/store/orders/domain.ex`](../../lib/store/orders/domain.ex:192) -> [`lib/store/orders/inventory_reservations.ex`](../../lib/store/orders/inventory_reservations.ex:112); callers [`lib/store/payments/interlocks.ex`](../../lib/store/payments/interlocks.ex:709) and [`lib/store/subscriptions/facade.ex`](../../lib/store/subscriptions/facade.ex:2816) | `SHARED_RESERVATION_FENCE`: acquire the same fence set before the existing transaction. A busy or unavailable fence returns a governed error; the caller's surrounding order/payment transaction does not commit a competing state change. |
| Pending-provider/order cleanup release | YES | YES | YES | YES | [`lib/store/orders/domain.ex`](../../lib/store/orders/domain.ex:699), reached by [`lib/store/workers/expire_pending_provider_setup_orders_worker.ex`](../../lib/store/workers/expire_pending_provider_setup_orders_worker.ex:31) | `SHARED_RESERVATION_FENCE`: inherit the release policy. A busy or Redis-unavailable result rolls back the cleanup transaction and lets bounded Oban retry; it never cancels the order while release is unguarded. |
| `Store.Orders.expire_reservations/2` | YES | YES | YES | YES | [`lib/store/orders/domain.ex`](../../lib/store/orders/domain.ex:200) -> [`lib/store/orders/inventory_reservations.ex`](../../lib/store/orders/inventory_reservations.ex:124) | `SHARED_RESERVATION_FENCE`: fence each candidate key before its durable expiry mutation. A busy candidate is skipped for a later bounded pass; Redis uncertainty fails the pass closed. Expiry does not enter the admission queue. |
| `ExpireInventoryReservationsWorker` | YES | YES | YES | YES | [`lib/store/workers/expire_inventory_reservations_worker.ex`](../../lib/store/workers/expire_inventory_reservations_worker.ex:11) | `SHARED_RESERVATION_FENCE`: it has no separate authority and inherits `expire_reservations/2`. It retries a governed fence/unavailable result and never uses a raw system bypass. |
| Direct `InventoryReservation` Ash actions (`create`, `set_quantity`, `mark_consumed`, `mark_expired`, `mark_cancelled`) | YES | NO | YES | YES | Action definitions in [`lib/store/orders/inventory_reservation.ex`](../../lib/store/orders/inventory_reservation.ex:95); no direct production caller was found in the focused search. | `ENFORCED_UNAVAILABLE`: direct Ash action invocation is not a protected writer path. Only the guarded `InventoryReservations` operations or the recovery owner may mutate durable reservation state while enforced. Test/setup calls happen before enforcement or use the guarded path. |
| `InventoryItem.create` during product creation | NO | YES | NO | NO | [`lib/store/catalog/product.ex`](../../lib/store/catalog/product.ex:336) | `PROVABLY_NON_OVERLAPPING`: the source caller creates inventory for a newly created variant before any reservation can reference that variant. The unique `variant_id` identity remains the guard. |
| Direct `InventoryItem.update_counts/3`, `set_on_hand/3`, or `adjust_on_hand/3` maintenance action | NO | YES | NO | YES | Action definitions in [`lib/store/catalog/inventory_item.ex`](../../lib/store/catalog/inventory_item.ex:83); no direct production update caller was found. Test setup uses `set_on_hand` in [`test/store_web/live/cart_checkout_live_test.exs`](../../test/store_web/live/cart_checkout_live_test.exs:170), [`test/store/checkout/domain_test.exs`](../../test/store/checkout/domain_test.exs:458), and [`test/store/governance/catalog_phase_25_test.exs`](../../test/store/governance/catalog_phase_25_test.exs:125) (also at lines 212 and 228). | `ENFORCED_UNAVAILABLE`: no unversioned inventory-only writer may run during a protected operation. A future maintenance writer needs a separately reviewed variant fence; it cannot use a raw Ash/system bypass. |
| `InventoryAdmissionRecoveryWorker` (read/reconcile only) | NO | NO | NO (read only) | NO (read only) | Future worker in `lib/store/workers/inventory_admission_recovery_worker.ex` | `RECOVERY_ONLY`: it may read PostgreSQL truth and resolve the existing fence. It cannot start another durable mutation or act as an inventory writer. |

The focused search found no other production caller that directly mutates these two
resources, no pending-provider cleanup path that bypasses the release wrapper, and no
raw SQL mutation outside `InventoryReservations`. The action definitions themselves
remain capabilities that the `ENFORCED_UNAVAILABLE` policy must close. A new caller is
not permitted to add a third policy.

The fixed policy names mean the following:

- `ADMISSION_REQUIRED` routes through the single-variant admission service. The
  variant permit, global budget, and reservation fence are acquired before the
  PostgreSQL transaction.
- `SHARED_RESERVATION_FENCE` acquires the same server-owned
  `reservation_key` exclusion before the existing lifecycle transaction. It does not
  create a queued admission member, does not receive `K_v` or `B_total`, and does not
  change `active -> consumed`, `active -> expired`, or `active -> cancelled`.
  Order-scoped lifecycle calls first perform a bounded PostgreSQL read of their exact
  eligible reservation-key set, record that set in the operation descriptor, and then
  acquire the complete set atomically. The existing transaction uses only that fenced
  set; it may revalidate each row but may not rediscover newly appearing active rows.
  A row that appears after the snapshot is deferred to a later lifecycle pass, so it
  cannot be mutated without its reservation fence. Expiry uses the same rule for its
  bounded candidate set. An uncertain target read returns
  `INVENTORY_ADMISSION_UNAVAILABLE` before durable mutation.
- `ENFORCED_UNAVAILABLE` returns a governed error before any durable mutation. It is
  not a caller-controlled bypass and is not conditional on a best-effort Redis read.
- `PROVABLY_NON_OVERLAPPING` is limited to creating the inventory row for a new
  variant. It does not authorize updates to an existing variant.
- `RECOVERY_ONLY` can reconcile durable state and Redis ownership, but cannot create a
  reservation or alter stock counters.

#### INV-PLAN-SER-001

While an operation `O` for `reservation_key = R` is in `QUEUED`, `ADMITTED`,
`RESERVING`, `UNKNOWN_DB_OUTCOME`, `RECOVERING`, or `UNRESOLVED`, no second writer may
mutate `R`. The exact enforcement is:

1. `ADMISSION_REQUIRED` owns the reservation fence as part of its admission lease.
2. A `SHARED_RESERVATION_FENCE` writer must acquire that same fence with a new
   server-generated operation identity before entering its existing transaction. The
   Redis atomic operation acquires the complete target set or none of it. A live fence
   returns `INVENTORY_ADMISSION_BUSY`; Redis failure or an uncertain command returns
   `INVENTORY_ADMISSION_UNAVAILABLE`. Neither result enters PostgreSQL.
3. `ENFORCED_UNAVAILABLE` writers cannot enter PostgreSQL at all while the gate is
   enforced. This includes the checkout CTE, direct Ash mutation actions, and direct
   maintenance/test calls.
4. The owning writer releases its fence only after a known commit or known rollback.
   An ambiguous result keeps the fence and operation descriptor and enters the same
   bounded Oban recovery path. A neither-match result is `UNRESOLVED`, retains or
   quarantines the fence, and cannot promote another mutation.
5. The recovery worker may read and reconcile `R`, but it is not a second durable
   writer. It releases capacity only after the operation-specific durable evidence
   resolves.

The owner is `InventoryAdmission` for an admitted reserve operation and the guarded
`InventoryReservations` caller for a lifecycle operation. `InventoryAdmission.Redis`
owns token comparison and atomic fence transitions. The fence is coordination state,
not PostgreSQL truth. A mode change from `DISABLED` to `ENFORCED`, or the reverse, is a
deployment operation that requires all live protected operations to reach a terminal
or quarantined state. It cannot be selected per request to bypass this invariant.

### Same-variant writers and conservative recovery

`K_v = 1` serializes every `ADMISSION_REQUIRED` reserve mutation for a variant across
the cluster. It does not claim that lifecycle work is an admission entrant. A
`SHARED_RESERVATION_FENCE` lifecycle writer for a different `reservation_key` may
change the same `InventoryItem` row while an operation is being recovered. The
existing lifecycle counter updates increment `InventoryItem.version`; the operation
descriptor therefore compares the exact counter and version PRE/POST facts. If that
unrelated writer changes the evidence, recovery must return `UNRESOLVED` rather than
guess `COMMITTED` or `ROLLED_BACK`. Version changes prevent a later coincidental
counter value from becoming false proof. Direct inventory updates that do not advance
the version are unavailable in `ENFORCED` mode. This is the complete same-variant
policy; it does not promise automatic recovery after unrelated durable changes.

## 7. Lifecycle and transition contract

Admission state is separate from the durable `InventoryReservation` states
`active`, `consumed`, `expired`, and `cancelled`.

### State definitions

| State | Entry condition and owner | Allowed transitions and guards | Side effects and timeout | Replay and terminal meaning |
|---|---|---|---|---|
| `REQUESTED` | A trusted, single-variant request has a canonical `reservation_key` and fingerprint. `InventoryAdmission` validates it and creates the server-owned operation identity. | `QUEUED` or immediate `ADMITTED`, only through the Redis atomic request operation. | No inventory read/write. Acknowledgement is short-lived; it is not a queue wait. | Same identity returns the same live operation. Non-terminal. |
| `QUEUED` | Redis created exactly one queue member under both queue bounds. Redis owns membership; the domain owns the request meaning. | `ADMITTED` only when the member is eligible and both budgets are acquired atomically; `EXPIRED` by queued deadline; `ABANDONED` by explicit trusted cancellation. | Queue indexes and metadata only. Finite queue TTL. No `Store.Repo` checkout or preflight read. | Retry returns the same operation and queue member. No inventory effect. Non-terminal. |
| `ADMITTED` | Redis atomically owns `K_v = 1` and one `B_total` slot and records the lease token/epoch. | `RESERVING` only after the current owner has prepared the operation descriptor and atomically claims the token; `EXPIRED` only before claim and after safe lease handling. A valid DB window cannot be replaced by expiry. | Starts `T_db`. The admitted owner captures trusted PRE/POST facts under the held budgets. No mutation has occurred yet. | Retry returns the same operation status; it cannot create another permit. Non-terminal. |
| `RESERVING` | The lease owner atomically changed `ADMITTED` to `RESERVING` with the complete operation descriptor before calling the outcome-preserving reservation seam. | `COMPLETED` through `KNOWN_COMMIT`; `REJECTED` through `KNOWN_ROLLBACK`/governed rejection; `UNKNOWN_DB_OUTCOME` when the definitive outcome is unavailable. | The existing PostgreSQL transaction is the only inventory mutation. `T_db` includes preflight, checkout, row-lock wait, execution, final result, and commit/known rollback. | Replay returns in-progress status for the same operation. It never starts a second durable attempt. Non-terminal. |
| `UNKNOWN_DB_OUTCOME` | A timeout, dropped connection, process crash, or lost final result leaves PostgreSQL outcome uncertain. The service atomically retains the operation descriptor and creates/retains a recovery fence when possible. | `RECOVERING` only after the safety window and a recovery worker claim. No direct retry, release, or promotion based on lease expiry. | Retains variant and global capacity and starts bounded recovery. | Replay joins/returns recovery. It is not rollback, rejection, or permission for a new operation. Non-terminal. |
| `RECOVERING` | The bounded Oban recovery worker owns the current fence and has the operation PRE/POST descriptor. | `COMPLETED` through durable POST match; `REJECTED` through durable PRE match or a definitive governed no-commit result; `UNRESOLVED` if durable truth matches neither or required evidence remains unavailable. | A consistent PostgreSQL read compares the descriptor with durable truth. Only a resolved PRE/POST result releases capacity atomically. | Replay returns recovery or the resolved operation result. It remains fenced until resolution or explicit escalation. |
| `COMPLETED` | The reservation seam returned `KNOWN_COMMIT`, or recovery proved the durable POST state for this operation. | No further admission transition. A later authorized adjustment starts a new operation only after terminal retention/serialization permits it. | Stores bounded result metadata and performs idempotent token-checked release. | Terminal admission state. PostgreSQL durable state wins; admission does not replace it. |
| `REJECTED` | The reservation seam returned `KNOWN_ROLLBACK`/governed rejection, or recovery proved the durable PRE state/no committed insert. | No further live transition during terminal retention. A later permitted request re-enters through the same gate with a new operation identity if it is a new mutation. | No new durable effect; fenced capacity releases only after the known result. | Terminal admission state. Exact replay receives the governed result for retention. |
| `EXPIRED` | A queued entry or unclaimed `ADMITTED` lease reaches its bounded deadline with no DB operation in flight. The atomic reaper owns it. | No live transition. It is never inferred for `RESERVING`, `UNKNOWN_DB_OUTCOME`, or `RECOVERING`. | Removes queue/lease membership and releases only capacity actually held. | Terminal admission state. A late request follows the same identity policy. |
| `ABANDONED` | A trusted owner explicitly abandons a queued request, or a bounded owner-liveness rule proves it is gone before reservation starts. | No transition from active DB execution. A disconnect during `RESERVING` becomes completion or unknown recovery. | Removes queued metadata and releases no absent permit. | Terminal admission state. Repeated abandon is a no-op. |
| `UNRESOLVED` | Recovery finds durable state matching neither the trusted PRE nor expected POST facts, or loses required recovery evidence at its bounded deadline. The recovery/operations owner records the fence. | No normal retry, promotion, release, or new operation for the `reservation_key`. Only an explicit operational resolution can leave this state. | Remains fail closed. The recovery fence and affected capacity remain held or quarantined; no Redis expiry alone releases them. | Terminal admission result with an operational fence. Replay returns governed unresolved status and cannot claim success. |

### Transition table

| Transition | Guard | Owner | Required side effect |
|---|---|---|---|
| `REQUESTED -> QUEUED` | Valid single variant, trusted identity, no live/terminal/recovery record, `Q_variant_max` and `Q_global_max` both available. | Atomic Redis operation. | Add one member to the per-variant queue, global dispatch index, queued-expiry index, and metadata. |
| `REQUESTED -> ADMITTED` | The request is the next eligible member or an empty-queue immediate request; variant is free, `ZCARD(global_active) < B_total`, namespace is healthy. | Atomic Redis operation. | Acquire both capacities, write lease token/deadlines, and remove any queue membership atomically. |
| `QUEUED -> ADMITTED` | Member is eligible under per-variant FIFO-ish order; no recovery freeze/active holder; global budget is available. | Atomic promotion operation. | Remove all queued indexes, add active variant ownership and global active-expiry membership, mark `ADMITTED`. |
| `QUEUED -> EXPIRED` | Queued deadline is due and no `RESERVING` owner exists for the identity. | Atomic prune/reaper operation. | Remove queued indexes, decrement the bounded queue population, mark terminal metadata. |
| `QUEUED -> ABANDONED` | Trusted server context owns the identity and the request is still queued. | `InventoryAdmission` through atomic Redis operation. | Remove queued indexes and mark terminal metadata. |
| `ADMITTED -> RESERVING` | The lease token/owner epoch match, the hard `T_db` deadline has not passed, and the owner has captured the complete operation PRE/POST descriptor. | `InventoryAdmission` owner through an atomic Redis operation. | Persist the descriptor and mark in-use before calling the internal outcome-preserving reservation seam; no protected mutation occurs before this claim. |
| `ADMITTED -> EXPIRED` | Lease deadline is due, the request was never claimed `RESERVING`, and the bounded safety check permits removal. | Atomic reaper. | Release both held capacities and promote only through the same atomic operation. |
| `RESERVING -> COMPLETED` | The outcome-preserving seam returns `KNOWN_COMMIT`. | Reservation orchestrator. | Record the durable result, emit completion telemetry, and perform token-checked release. |
| `RESERVING -> REJECTED` | The outcome-preserving seam returns `KNOWN_ROLLBACK` or a governed rejection with no commit. | Reservation orchestrator. | Preserve current outward error semantics, emit rejection telemetry, and perform token-checked release. |
| `RESERVING -> UNKNOWN_DB_OUTCOME` | A final commit/rollback answer cannot be established. | Reservation orchestrator or reaper. | Retain both capacities, create/retain recovery fence, enqueue one recovery job if possible. |
| `UNKNOWN_DB_OUTCOME -> RECOVERING` | Safety window has elapsed and a recovery worker atomically owns the fence. | Recovery worker. | Query PostgreSQL by `reservation_key`; no second durable attempt. |
| `RECOVERING -> COMPLETED` | A consistent PostgreSQL lookup matches the operation's expected POST facts. | Recovery worker plus atomic resolver. | Reconstruct the durable result and release fenced capacity. Row presence alone is not sufficient for an adjustment. |
| `RECOVERING -> REJECTED` | A consistent PostgreSQL lookup matches the operation's proven PRE facts, or an insert operation has no row and its PRE inventory facts still match after the safety window. | Recovery worker plus atomic resolver. | Resolve as `ROLLED_BACK`/governed rejection and release capacity. |
| `RECOVERING -> UNRESOLVED` | Durable state matches neither valid PRE nor POST, lookup evidence is unavailable at the bounded deadline, or the descriptor was lost. | Recovery worker plus operations owner. | Retain/quarantine the fence and capacity. No automatic retry, release, or promotion. |

`COMPLETED`, `REJECTED`, `EXPIRED`, `ABANDONED`, and `UNRESOLVED` are terminal admission
states. `UNKNOWN_DB_OUTCOME` and `RECOVERING` are not terminal and cannot be treated as
rollback, timeout success, or permission for an unrestricted retry. `KNOWN_COMMIT`,
`KNOWN_ROLLBACK`, `COMMITTED`, and `ROLLED_BACK` are outcome labels carried by the
state transition, not additional queue owners.

### Durable reservation relationship

The only successful settlement relationship for a positive reservation operation is:

```text
InventoryAdmission.RESERVING
  -> existing Store.Orders.InventoryReservations outcome-preserving seam
  -> committed InventoryReservation.active
  -> InventoryReservation durable identity returned
```

Admission `COMPLETED` carries the durable reservation ID and `reservation_key`.
Admission `REJECTED`, `EXPIRED`, and `ABANDONED` do not call a durable reservation
transition. Existing `active -> consumed`, `active -> expired`, and
`active -> cancelled` operations remain unchanged and are not moved into admission.
The existing zero-quantity no-op behavior remains a durable no-op; it never makes
admission success mean stock ownership. A later authorized quantity adjustment uses a
new operation identity against the same durable row.

### Same-reservation mutation fence

The following invariant is normative for the no-migration recovery proof:

```text
at most one live protected mutation for a reservation_key
```

No new operation may begin while the prior operation is `QUEUED`, `ADMITTED`,
`RESERVING`, `UNKNOWN_DB_OUTCOME`, `RECOVERING`, or `UNRESOLVED`. The complete writer
policy, including the fixed treatment of consume, release, expiry, checkout, direct
resource actions, maintenance, tests, and system callers, is `INV-PLAN-SER-001` in
Section 6. A future implementation must satisfy that matrix before using the
no-migration decision. PostgreSQL row locks still protect atomic durable writes, but a
writer outside the matrix would invalidate PRE/POST attribution.

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

`B_total` is held for the entire admitted inventory operation window, including the
bounded durable PRE/POST preflight, Store.Repo checkout, the inventory reservation
transaction, and definitive outcome handling. It therefore bounds active reservation
DB work, not just the instant after a transaction callback starts. Other `Store.Repo`
traffic remains protected by the pool and the existing generic performance observer.
The budget is not a license to consume all connections.

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
  paths; this mode does not claim to solve the herd. It is valid only when no
  protected admission operation is live.
- `ENFORCED`: the protected `Store.Orders.reserve_inventory/3` single-variant path
  must pass through `InventoryAdmission`; Redis errors fail closed. The existing
  `reserve_inventory_for_checkout/3` CTE and direct resource/maintenance mutation
  actions return governed `INVENTORY_ADMISSION_UNSUPPORTED` before durable mutation.
  Consume, release, and expiry use the shared reservation fence from Section 6.

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
| `reservation:<reservation_digest>:mutation_fence` | HASH with one server-owned mutation owner, operation ID/epoch, owner token, mutation kind, descriptor reference, and deadline. | Shared exclusion for the admission operation and `SHARED_RESERVATION_FENCE` lifecycle writers. It is not a permit counter and contains no inventory state. | Held through the known durable result or the bounded recovery window. Fence expiry never authorizes a replacement by itself. | At most one owner per durable `reservation_key`; a bounded multi-key lifecycle operation acquires its complete target set atomically or none. |
| `global:active_expiry` | ZSET; member is the active admission member, score is active lease expiry. | Global active lease index and `B_total` occupancy. `ZCARD` is the active global permit count. | Member score is the active lease-expiry semantic. Do not independently expire the key while active members exist. | `ZCARD <= B_total`; bounded due-member pruning. |
| `request:<member>:meta` | HASH with state, durable-identity digest, variant, queue sequence, `operation_id`, `operation_epoch`, request fingerprint, mutation kind, trusted PRE/expected POST descriptor, deadlines, owner epoch/token, durable reservation ID when known, and terminal reason. | Request/lease status, idempotency, and ephemeral recovery evidence only. | `T_queue` while queued; `L_admission + T_recovery` while active/recovering; descriptor is retained until resolution; finite terminal retention after resolution. | Live metadata is bounded by `Q_global_max + B_total`; terminal retention is finite and memory-budgeted. No stock or availability fields. |
| `request:<member>:recovery_fence` | HASH/string with `operation_id`, operation epoch, recovery owner token, fence epoch, safety deadline, recovery deadline, descriptor reference/digest, and status. | Duplicate-attempt prevention and recovery ownership. | Finite recovery TTL covering the recovery budget plus cleanup grace. Fence expiry never itself releases capacity. | At most one fence per ambiguous operation; missing evidence causes quarantine, not release. |
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
| `enqueue_or_return_existing` | Durable-identity digest, variant, request fingerprint, `Q_variant_max`, `Q_global_max`, `B_total`, namespace epoch, and trusted adjustment authorization. | Prune bounded queued expiry; return an exact live/terminal/recovery operation; reject a mismatched live identity; or, only when terminal policy permits, server-generate a new `operation_id`/epoch under the same `reservation_key`. It forbids a new operation during any live or `UNRESOLVED` state. For a new operation, validate both queue bounds. If both capacities are available and the request is the eligible head, acquire both and create `ADMITTED`; otherwise insert exactly one member in all queue indexes and metadata. | `existing`, `queued`, `admitted`, `busy`, `mismatch`, `frozen`, or `unavailable`. It never partially increments a queue or grants one budget. |
| `promote_next` | Namespace epoch, optional releasing member, `B_total`, bounded candidate limit. | Prune due queued records, select an eligible global candidate whose per-variant member is the variant head, verify no active/recovery freeze, verify `ZCARD(global:active_expiry) < B_total`, then remove queue indexes and create the one active lease. | A complete lease, no eligible candidate, global-full, variant-frozen, or fail-closed error. Variant and global capacity change together. |
| `claim_reserving` | Member, variant, lease token, owner epoch, and complete server-owned operation PRE/POST descriptor. | Compare token/epoch/state, verify the operation identity, store the descriptor, and atomically change `ADMITTED` to `RESERVING`. No protected database mutation is allowed before this succeeds. | `claimed`, `already_reserving`, terminal/recovering, stale-owner, descriptor-invalid, or unavailable. Replays cannot claim a second owner. |
| `acquire_shared_mutation_fence` | One or more server-derived reservation digests, operation ID/epoch, mutation kind, owner token, and bounded deadline. | Used by consume, release, and expiry before their existing durable transaction. Acquire the complete bounded target set atomically or none of it; reject any key already owned by a live admission or lifecycle operation. It does not acquire `K_v` or `B_total` and does not enqueue. | `acquired`, `busy`, stale identity, frozen, or unavailable. A partial target-set acquisition is never returned. |
| `release_shared_mutation_fence_known_outcome` | Target set, owner token/epoch, and known commit or rollback result. | Verify ownership, record terminal operation metadata, and remove the fence set atomically. A repeated release is idempotent and cannot affect a newer owner. | `released`, `already_resolved`, stale-owner, frozen, or unavailable. A known durable result remains valid if Redis release fails. |
| `mark_shared_mutation_unknown` | Target set, owner token/epoch, operation descriptor, and recovery deadline. | Verify ownership, retain every target fence, and create one recovery record for the lifecycle operation. No target fence is released. | `fenced`, already fenced, stale-owner, or unavailable. An uncertain Redis result quarantines the target set rather than retrying the mutation. |
| `renew_lease` | Member, variant, token, owner epoch, server time. | Compare current ownership; renew only while `RESERVING`, before the hard `T_db` deadline, and within the configured lease window. Update active expiry index and metadata together. | `renewed`, `deadline_reached`, `stale_owner`, `frozen`, or unavailable. It cannot extend indefinitely. |
| `release_known_outcome` | Member, variant, token, owner epoch, `COMPLETED` or `REJECTED`, optional durable reservation ID. | Compare current ownership; mark terminal metadata; remove variant active and global active-expiry membership; promote the next eligible request in the same atomic operation. Repeated release is a no-op for the same terminal result and cannot affect a newer token. | `released` with optional next lease, `already_resolved`, stale-owner, frozen, or unavailable. A Redis error after known commit does not undo PostgreSQL. |
| `mark_unknown_and_fence` | Member, variant, token, owner epoch, operation identity, retained descriptor, and recovery deadline. | Compare current ownership; change `RESERVING` to `UNKNOWN_DB_OUTCOME`; create/retain one recovery fence and descriptor; retain both variant and global capacity. | `fenced`, already fenced, stale-owner, or unavailable. It never marks rollback or releases for an unrestricted retry. |
| `claim_recovery` | Member, fence token, worker owner, server time. | Verify the safety window, namespace, logical state, and fence ownership; atomically set `RECOVERING` and one recovery owner. Capacity remains held. | `claimed`, already recovering, not safe yet, terminal, or unavailable. Oban uniqueness is secondary to this fence. |
| `resolve_recovery` | Member, fence token, recovery owner, operation identity, and durable comparison result `:post_match`, `:pre_match`, or `:unresolved`. | The PostgreSQL comparison is produced outside Redis. `:post_match` marks `COMPLETED`; `:pre_match` marks `REJECTED`; `:unresolved` retains the fence/capacity or records `UNRESOLVED` at the bounded deadline. Release occurs only for a definitive PRE/POST result. | `resolved`, `retry_recovery`, `unresolved`, stale fence, terminal, or unavailable. Redis never determines whether PostgreSQL committed. |
| `abandon_queued` | Member, trusted owner context, identity digest. | Compare identity and state; remove only queued membership and mark `ABANDONED`. It cannot abandon `RESERVING`. | `abandoned`, already terminal, not queued, unauthorized, or unavailable. |
| `prune_due` | Namespace epoch, bounded count, server time. | Remove due queued members; for an unclaimed admitted lease, expire and release both permits; for `RESERVING`, create/retain unknown recovery and freeze promotion. | Counts of expired/fenced entries and any complete promotions; no unsafe release. |
| `quarantine_namespace` | Observed Redis generation/health event, server time, quarantine duration, and recovery-evidence status. | Advance namespace epoch and set `frozen_until`; reject all new admission and promotion until old operations are reconciled or explicitly escalated. Old tokens cannot mutate the new epoch. Missing operation evidence never permits a fresh empty namespace. | `frozen` or `healthy_after_quarantine` only after bounded reconciliation. It is coordination safety, not stock truth. |

Atomic invariants tested for every operation:

```text
active_variant_holders(variant) <= 1
active_global_holders <= B_total
queued_members(variant) <= Q_variant_max
queued_members(all_variants) <= Q_global_max
one logical identity => at most one queue member and one active lease
one reservation_key => at most one non-terminal operation_id/operation_epoch
one reservation fence => at most one live durable writer for that reservation_key
new operation => forbidden while prior operation is live or UNRESOLVED
stale token => no release, renew, promotion, or global decrement
```

## 11. Lease, deadline, and fencing semantics

### Admission-to-commit deadline

`T_db` starts when the request becomes `ADMITTED`, not when the transaction callback
begins. It covers the bounded operation descriptor preflight and:

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

The same owner-token rules apply to the `SHARED_RESERVATION_FENCE` policy. A consume,
release, or expiry writer obtains the reservation fence before its existing durable
transaction and holds it until a known commit or known rollback. It does not receive
an admission queue position, `K_v`, or `B_total`. For an order-wide lifecycle
transaction, the bounded target reservation-key set is acquired in one atomic Redis
operation, ordered by normalized binary UUID, or the transaction does not start. If a
lifecycle transaction loses its final database outcome, its server-generated
operation descriptor remains fenced and the bounded Oban recovery worker performs the
same PostgreSQL PRE/POST reconciliation. Existing durable lifecycle transitions are
unchanged. A fence TTL is only a recovery safety bound, never proof of rollback.

### Redis restart and partition quarantine

If Redis restarts, loses its namespace, or returns uncertain command results, the
adapter enters a namespace quarantine. No new admission, promotion, or direct
PostgreSQL fallback is allowed. The namespace gets a new epoch and remains frozen
through the maximum configured old lease/DB/recovery safety window and until old
operation evidence is reconciled or explicitly escalated. Existing durable
reservations remain queryable from PostgreSQL. Queued admission state may be lost in
this failure; a status/retry call returns a governed unavailable result and never
claims a lost queued request completed. Missing keys are not available stock. A fresh
Redis namespace cannot be treated as empty while an old operation or its recovery
evidence is unknown. Reopening admission requires bounded reconciliation of old
operations or an explicit operational decision that preserves the affected
same-reservation fence.

This sacrifices liveness during Redis uncertainty to preserve capacity semantics. It
does not infer stock availability from missing Redis keys and does not claim Redis and
PostgreSQL form a distributed transaction.

## 12. Structured database outcome boundary and recovery

### Outcome-preserving reservation seam

The current public `reserve_inventory/3` path is not a safe admission outcome
boundary. It sends `Repo.transaction/1` through `unwrap_transaction_error/2`, which
preserves a `Store.Support.Errors.Error` but maps other failures to
`RESERVATION_CONFLICT`. The future implementation must add the smallest internal seam
in `lib/store/orders/inventory_reservations.ex`, named
`reserve_inventory_outcome/3` for this plan. It shares the existing transaction body
and does not become a generic transaction framework.

`InventoryAdmission` calls this internal seam in `ENFORCED` mode. The existing public
`reserve_inventory/3` keeps its current outward compatibility mapping for callers that
remain outside the enforced gate, but that mapping must never run before admission has
classified an outcome. Post-commit cache invalidation is outside the database outcome:
once the transaction returns known commit, invalidation failure cannot turn durable
success into a database ambiguity.

The seam returns one structured result before any generic public error mapping:

```text
{:known_commit, durable_result}
{:known_rollback, governed_error}
{:ambiguous, %{phase: phase, reason_class: reason_class}}
```

The seam records enough phase information to distinguish these cases:

| Category | Evidence | Required behavior |
|---|---|---|
| `KNOWN_COMMIT` | `Repo.transaction/1` returns `{:ok, result}`. Ecto defines this return as a successful commit, and the durable result is available. | Mark `COMPLETED`, return/reconstruct the durable result, and release Redis idempotently. |
| `KNOWN_ROLLBACK` / governed rejection | Validation or unsupported input prevented DB entry; a checkout failure is definitively known to occur before the transaction callback/DB request; or the transaction body explicitly calls `Repo.rollback/1` with `OUT_OF_STOCK` or another governed `Error`, and the rollback result is returned. | Mark `REJECTED`, preserve the governed error, and release the lease. No durable retry is implied. |
| `AMBIGUOUS_DB_OUTCOME` | A `DBConnection.ConnectionError`, Postgrex/connection failure, timeout, process crash, or lost final result occurs after the callback may have run, after a transaction request may have been sent, or while commit/rollback confirmation is unavailable. | Do not assume rollback. Mark `UNKNOWN_DB_OUTCOME`, retain capacity, create/retain the recovery fence, and recover from PostgreSQL durable state. |

An arbitrary error tuple is not itself a rollback proof. The seam uses the operation
phase and an allowlisted, explicit rollback signal. It does not classify every
exception as ambiguous: pre-normalization/validation errors and a proven pre-checkout
failure are known non-entry outcomes, while an unclassified failure after DB entry is
ambiguous because it may have crossed the commit boundary. A raw `RESERVATION_CONFLICT`
from the legacy mapper is never sufficient evidence for the admission path.

### Operation descriptor

The admitted owner prepares the following transient `Operation` value before it calls
the outcome seam:

| Field | Meaning |
|---|---|
| `reservation_key` | Existing durable order/variant reservation identity. It is the PostgreSQL lookup/uniqueness key. |
| `operation_id` | Server-generated UUIDv7/opaque identity for one mutation attempt. Never client supplied. |
| `operation_epoch` | Server-issued monotonic attempt number for the same `reservation_key`. A later authorized adjustment receives a new epoch. |
| `request_fingerprint` | Deterministic digest of trusted normalized mutation content, including desired quantity and controlled expiry policy. It excludes client clocks and Redis ownership values. |
| `mutation` | Normalized desired quantity, operation kind, server-selected `expires_at`, and any controlled `now` value needed to reproduce the existing branch. |
| `pre` | The exact trusted durable reservation and inventory facts observed before the protected mutation. |
| `post` | The exact durable reservation and inventory facts expected if this operation commits. |
| `deadline` | The bounded DB operation deadline and admission lease/recovery references. |

The descriptor is written to the Redis request metadata by the atomic
`ADMITTED -> RESERVING` claim before the PostgreSQL mutation begins. The preflight read
that creates `pre` and computes `post` occurs only after admission, while both permits
are held, and is included in `T_db`. It is not performed for queued requests. If the
owner fails before the atomic claim, no database mutation has started and the lease
can expire normally. If it fails after the claim, the descriptor is available to
recovery.

The same descriptor shape is used by a `SHARED_RESERVATION_FENCE` lifecycle writer,
with its mutation kind and complete bounded target set recorded before the existing
transaction. A lifecycle operation does not acquire admission capacity, but it keeps
its fence and descriptor through a known result or the same recovery window. A
multi-reservation consume or release operation is one grouped operation with one
server owner and one PRE/POST fact set per target key. Expiry uses the same rule for
each fenced candidate in its bounded pass.

For a reservation row, `pre.reservation` is either `:absent` or the current row's
`id`, `quantity`, `state`, `expires_at`, lifecycle timestamps relevant to the branch,
and `version`. For the inventory row, `pre.inventory` contains `variant_id`,
`stock_on_hand`, `reserved_count`, `allow_oversell`, and `version`. The descriptor does
not store timestamps that the current `update_all` path generates nondeterministically,
such as `updated_at`, and it does not store unrelated product data.

`post` contains the fields the existing transaction is expected to change. For an
insert, it expects one row with the same `reservation_key`, order, variant, quantity,
active state, and operation expiry, with reservation `version = 1`; the generated row
UUID is not needed for the predicate. The inventory expects the PRE counters plus the
requested quantity and `version + 1`. For an active adjustment, the reservation expects
the same row ID, desired quantity/state/expiry, and `version + 1`. The inventory
expects `reserved_count + delta`, unchanged `stock_on_hand`, and `version + 1` when
`delta != 0`; a refresh with `delta == 0` leaves the inventory version/counters
unchanged. Cancellation includes its expected state, quantity, cancellation timestamp,
and counter delta. A zero-quantity new-row request remains the current no-op and uses
equal PRE/POST durable facts.

### Durable PRE/POST reconciliation

`Store.Orders.InventoryAdmission.Recovery` calls an internal read-only
`InventoryReservations.recovery_snapshot/1` boundary. It reads the reservation by
the unique `reservation_key` and the inventory row by the unique `variant_id` in one
consistent, bounded PostgreSQL read. Redis state selects the recovery owner; it never
answers whether PostgreSQL committed.

Recovery compares the complete durable snapshot with the operation descriptor:

| Operation | Proven PRE state | Expected POST state | Recovery proof |
|---|---|---|---|
| New reservation insert | No `InventoryReservation` for `reservation_key` plus the recorded inventory PRE facts. | Matching reservation identity/quantity/state/expiry/version and matching inventory counter/version delta. | POST match means `COMMITTED`; PRE match means `ROLLED_BACK`; neither means `UNRESOLVED`. Row presence alone is not enough when the fields do not match. |
| Existing active adjustment | Existing row ID, active state, prior quantity/expiry/version plus the recorded inventory PRE facts. | Same row ID with the intended quantity/state/expiry/version and the intended inventory counter/version delta. | POST match means `COMMITTED`; PRE match means `ROLLED_BACK`; neither means `UNRESOLVED`. Existing row presence never proves that the adjustment committed. |
| Known no-op/governed rejection | The recorded unchanged or pre-rejection facts. | No durable mutation, or the exact governed rejection returned by the seam. | The seam resolves it as `KNOWN_ROLLBACK`; recovery does not invent a reservation. |

For example, if the durable row has quantity `2`, the operation requests `3`, and
the inventory `reserved_count` is `c`, then the descriptor records reservation
quantity/version `(2, v)` and inventory `(c, w)` as PRE. Its POST requires reservation
quantity/version `(3, v + 1)` and inventory `reserved_count/version` `(c + 1, w + 1)`.
The exact POST snapshot resolves commit. The exact PRE snapshot resolves rollback. A
row with quantity `2` proves rollback only when the rest of the PRE facts also match;
a row with quantity `3` proves commit only when the inventory and version facts match
too.

This proof is valid because the existing transaction locks the unique inventory row
and the order/variant reservation row, updates both durable resources atomically, and
increments the existing `version` fields on each mutation. It also depends on the
normative writer matrix and `INV-PLAN-SER-001` in Section 6. The matrix disables the
checkout CTE and direct unversioned maintenance/resource-action paths while admission
is enforced. The lifecycle writers use the shared reservation fence, and their
operation descriptors enter the same recovery path if their database result is
ambiguous. An unguarded writer would make a matching POST attributable to the wrong
mutation and invalidate this no-migration proof.

### Recovery transitions and owner

Recovery behavior is:

1. Mark/retain `UNKNOWN_DB_OUTCOME` and the recovery fence before any retry or permit
   reuse. The synchronous caller only performs the bounded fence operation and attempts
   one recovery-job enqueue.
2. A bounded Oban
   `Store.Workers.InventoryAdmissionRecoveryWorker` claims the fence after the database
   safety window. Oban is the fixed MVP owner, not an implementation-time choice
   between inline and asynchronous recovery. The final reservation transaction never
   moves into Oban.
3. Query the durable recovery snapshot by `reservation_key` and compare it with the
   operation-specific PRE/POST predicate.
4. A POST match resolves `COMMITTED -> COMPLETED` and releases both capacities through
   the fenced atomic resolver. A PRE match resolves `ROLLED_BACK -> REJECTED` and
   releases both capacities through the same resolver.
5. A lookup that is uncertain, or a snapshot matching neither PRE nor POST, remains
   fenced. At the finite recovery deadline it becomes `UNRESOLVED`, retains or
   quarantines affected capacity, and requires governed operational resolution. It does
   not start an unrestricted second attempt.

For a grouped consume or release operation, every target reservation and affected
inventory snapshot must match the same operation's PRE or POST set. If any target
matches neither, the whole group remains fenced and becomes `UNRESOLVED`; recovery
never releases some target fences and retries the rest. Expiry applies the same rule to
the bounded candidate set it actually fenced.

The worker job is unique by the server-owned operation/recovery identity and has a
bounded retry budget. A later caller retry may use the same `reservation_key` only
after the fence is resolved and the operation is terminal. It gets a new operation
identity for a new authorized adjustment. PostgreSQL remains the authority for the
durable result.

### Schema sufficiency and Redis metadata loss

The existing schema is sufficient for the supported MVP mutations under the stated
serialization policy. The proof uses only the existing unique
`reservation_key`/`order_id + variant_id` identities, unique `inventory_items.variant_id`,
`quantity`, lifecycle state/timestamps, `stock_on_hand`, `reserved_count`, and the
existing reservation/inventory `version` fields. No durable mutation identity, table,
column, or migration is required.

This is not a claim that `reservation_key` alone identifies a mutation. The transient
operation descriptor supplies the mutation identity and expected PRE/POST facts. If a
deployment cannot retain that descriptor, or cannot enforce same-reservation
serialization, it must stop admission for the affected namespace/identity rather than
infer a result from row existence or version alone.

If Redis loses request metadata or recovery-fence state, the system cannot reconstruct
an ambiguous adjustment from PostgreSQL row presence alone. It therefore quarantines
the namespace, rejects new admission, retains affected capacity, and marks the
operation `UNRESOLVED` for bounded operational reconciliation. It does not create a
fresh empty namespace and silently promote a later operation. Durable PostgreSQL
reservations remain queryable and valid, but missing ephemeral evidence never becomes a
false commit or rollback result.

### Recovery worker and cleanup owner

Use the existing bounded Oban `:inventory` queue for
`Store.Workers.InventoryAdmissionRecoveryWorker`, with `Store.DirectRepo` for Oban job
storage and `Store.Repo` for the bounded durable snapshot. The Redis fence remains the
correctness authority for one active recovery owner. Redis enqueue uncertainty is
retried by bounded maintenance; it never produces a direct reservation fallback.

`Store.Workers.InventoryAdmissionReaperWorker` owns known queued/active expiry indexes,
bounded stale-fence maintenance, and recovery re-enqueue. It uses bounded
`ZRANGEBYSCORE`/member operations and never `KEYS`, a full key scan, or an unbounded
loop. Fence expiry alone never releases capacity.

## 13. Integration boundary

The dependency direction is:

```text
Store.Orders public facade
  -> InventoryAdmission
    -> InventoryAdmission.Redis
    -> InventoryReservations.reserve_inventory_outcome/3
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
4. Only then does the service call the internal
   `InventoryReservations.reserve_inventory_outcome/3` seam with one item, the
   operation descriptor, and the remaining `T_db` budget. The seam shares the existing
   transaction body and preserves the structured outcome before the legacy mapper.
5. The service classifies the result and releases or recovers as Section 12 states.

The existing `reserve_inventory_for_checkout/3` multi-variant CTE remains unchanged
and out of the tracer bullet, but it is not an allowed concurrent writer. In
`ENFORCED` mode, `Store.Orders.reserve_inventory_for_checkout/3` returns
`INVENTORY_ADMISSION_UNSUPPORTED` before the CTE for every item count, including the
single-variant subscription-renewal caller. The checkout and subscription callers
must handle that governed result; they must not invoke the CTE through a separate
path. `DISABLED` mode preserves the legacy CTE only while no protected operation is
live, and changing modes requires a deployment drain. Future multi-variant admission
must use deterministic binary UUID ordering or an atomic multi-key design before it
can be enabled.

The durable primitive is not a public web API. Because Elixir does not provide a
caller-based module visibility boundary, the integration phase must add a focused
call-site/boundary test. Direct resource and fixture writes run only before
`ENFORCED`; there is no runtime bypass flag. The only non-admission callers permitted
while enforced are the enumerated `SHARED_RESERVATION_FENCE` lifecycle callers. Raw
Ash actions and maintenance writes are `ENFORCED_UNAVAILABLE`. This is a fixed
boundary, not a caller choice.

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
| PostgreSQL error after transaction may have begun | `UNKNOWN_DB_OUTCOME` then `RECOVERING`. | Do not translate to `OUT_OF_STOCK`, ordinary `RESERVATION_CONFLICT`, or immediately retry. Query `reservation_key` and compare operation PRE/POST facts. |
| PostgreSQL definitively rolls back/rejects | `REJECTED`, existing governed error. | Release the current fenced lease and permit; no reservation mutation is created. |
| Lifecycle writer cannot acquire the shared reservation fence | `INVENTORY_ADMISSION_BUSY` with bounded retry for the caller or worker. | Do not enter the existing consume, release, or expiry transaction. A pending-provider cleanup rolls back its order cancellation; an expiry worker retries a later bounded pass. |
| Redis is unavailable or uncertain for a lifecycle fence | `INVENTORY_ADMISSION_UNAVAILABLE`; no durable lifecycle mutation is claimed. | Fail closed for the lifecycle writer. Do not use the generic waiting-room fail-open behavior and do not bypass the fence with a system actor. |
| Direct resource or maintenance mutation is requested in `ENFORCED` mode | `INVENTORY_ADMISSION_UNSUPPORTED`. | The direct Ash action does not run. Test/setup writes occur before enforcement; a future maintenance writer needs a separately reviewed variant fence. |
| PostgreSQL commits, Redis release succeeds | `COMPLETED` with durable row. | Release and promote atomically; replay returns the durable row for the same operation. |
| PostgreSQL commits, process or Redis release fails | Durable success is returned/retained; release remains pending for reaper. | PostgreSQL truth remains valid. Stale release cannot touch a newer lease or later operation. |
| Holder crashes before `RESERVING` | `ADMITTED` reaches safe expiry and becomes `EXPIRED`. | No DB call is assumed; capacity is released only by token/epoch-checked pruning. |
| Holder crashes after `RESERVING` | Reaper moves to unknown/recovery after the bounded safety window. | Capacity remains fenced until durable resolution/escalation. |
| Lease renewal lost inside transaction | Continue only within the already bounded operation; classify final result or ambiguity. | Freeze same-variant promotion; Redis cannot cancel the running transaction. |
| Queued client disconnects | Entry remains queued until explicit trusted abandonment or queue expiry. | No long-lived process cleanup is assumed. |
| Admitted client disconnects | The operation continues under its deadline or enters recovery. | Disconnect is not proof of rollback and cannot release a live permit by guess. |
| Recovery worker crashes | Fence and `RECOVERING` metadata remain until finite TTL/deadline. | Another worker may resume; fence expiry alone never releases capacity. |
| Recovery snapshot matches neither PRE nor POST, or required Redis descriptor is lost | `UNRESOLVED` and fail-closed operational escalation. | Retain/quarantine the fence and capacity. No automatic second durable attempt or promotion based on uncertainty. |

No Redis/PostgreSQL distributed transaction is simulated. The design relies on
PostgreSQL durable identity for truth and token-checked, retryable Redis coordination
for capacity.

## 16. PubSub, Redis Stream, and cache boundaries

Phoenix PubSub has no admission-correctness authority. It may broadcast a status
projection after a Redis/PostgreSQL transition or help a LiveView refresh. PubSub loss
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
- generate `operation_id` and `operation_epoch` on the server; clients cannot choose or
  replay a different live mutation identity;
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

The existing schema is sufficient for the supported Option A MVP mutations, subject to
deployment verification of the same migration set and the normative
same-`reservation_key` writer policy in Sections 6, 7, and 12. The proof is not
based on `reservation_key` being a mutation ID:

- `inventory_items.variant_id` unique index supports the durable inventory lookup;
- `inventory_reservations.reservation_key` unique index supports ambiguous-outcome
  reconciliation of the one durable row;
- `inventory_reservations(order_id, variant_id)` unique index preserves the existing
  order/variant identity and quantity-adjustment path;
- `inventory_reservations.version` and `inventory_items.version` advance on the
  existing update paths, allowing the recovery descriptor to distinguish the trusted
  PRE snapshot from the expected POST snapshot;
- The direct `InventoryReservation` Ash actions and direct `InventoryItem` update
  actions are not versioned operation paths and are therefore unavailable in
  `ENFORCED` mode. The only non-reservation inventory writer admitted by this plan is
  `InventoryItem.create` for a newly created variant, which cannot overlap a
  reservation.
- `quantity`, reservation state/expiry fields, `stock_on_hand`, and `reserved_count`
  provide the remaining operation-specific PRE/POST predicate fields;
- existing `(order_id, state)`, `(variant_id, state)`, `(state, expires_at)`, and
  active-expiry indexes support the unchanged reservation lifecycle and worker.

For an insert, the proof is `reservation_key` absent plus the recorded inventory PRE
state versus the exact reservation POST and inventory delta/version. For an existing
active adjustment, the proof is the existing row ID, quantity, state, expiry, version,
and inventory counter/version PRE state versus the exact POST state. PostgreSQL's
transaction atomicity means recovery observes all PRE facts or all POST facts when the
serialization invariant holds. A matching row without the expected adjustment fields
is not a commit proof.

The implementation plan requires no PostgreSQL migration solely for admission and no
admission state table. It also does not add a durable mutation ID. If a deployed schema
lacks any listed unique/index/version guarantee, or if an unguarded writer can violate
same-reservation serialization, the implementation gate stops for a separate schema
or concurrency review. This plan does not create or authorize a migration.

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
`test/store/governance/inventory_reservations_test.exs` suite:

- existing row lock and final availability check remain active;
- one winner and governed losers preserve zero oversell;
- known commit releases and replays the durable `InventoryReservation`;
- known rollback releases with no row/counter side effect;
- an ambiguous new-row result with a committed durable POST resolves `COMMITTED`;
- an ambiguous new-row result with no durable row and matching inventory PRE resolves
  `ROLLED_BACK`;
- an existing quantity `2 -> 3` adjustment with durable quantity `3` and matching
  inventory POST resolves `COMMITTED`;
- an existing quantity `2 -> 3` adjustment with durable quantity `2` and matching PRE
  resolves `ROLLED_BACK`;
- durable state matching neither valid PRE nor POST resolves `UNRESOLVED` and remains
  fail closed;
- existing row presence alone never proves an adjustment committed;
- ambiguous timeout does not become `OUT_OF_STOCK`, ordinary `RESERVATION_CONFLICT`,
  or an unrestricted retry;
- the outcome-preserving seam keeps known explicit rollback separate from ambiguity;
- current non-admission/public `InventoryReservations` outward behavior remains
  backwards compatible;
- lookup uncertainty retains the fence and retries within a bounded deadline;
- no row after the safety window resolves according to the documented PRE/POST policy;
- process crash before DB versus after DB entry has distinct cleanup behavior;
- commit followed by Redis release failure leaves durable success valid.

The same file also proves operation identity rules:

- an exact replay while an operation is live returns the same `operation_id` and epoch;
- a later authorized adjustment after terminal resolution receives a new operation
  identity under the same `reservation_key`;
- a recovery fence prevents a second mutation for the same reservation key;
- operation metadata loss does not guess a result and instead produces the documented
  quarantine/`UNRESOLVED` behavior.

### Capable-writer serialization tests

Target [`test/store/orders/inventory_admission_test.exs`](../../test/store/orders/inventory_admission_test.exs),
[`test/store/orders/inventory_admission_redis_test.exs`](../../test/store/orders/inventory_admission_redis_test.exs),
[`test/store/orders/inventory_admission_recovery_test.exs`](../../test/store/orders/inventory_admission_recovery_test.exs),
and [`test/store/governance/inventory_reservations_test.exs`](../../test/store/governance/inventory_reservations_test.exs):

- a live protected quantity adjustment rejects a second reserve mutation for the same
  `reservation_key`;
- a live protected adjustment and release, consume, or expiry for the same key use the
  shared fence and cannot enter durable mutation concurrently;
- lifecycle target discovery is materialized before fencing, so a reservation inserted
  after that snapshot is deferred rather than mutated through an unfenced re-scan;
- the checkout CTE targeting the same order/variant returns
  `INVENTORY_ADMISSION_UNSUPPORTED` in `ENFORCED` mode before its transaction;
- maintenance, direct Ash, system, and test mutation attempts cannot silently bypass
  the invariant while `ENFORCED`;
- Redis unavailable during a lifecycle fence returns
  `INVENTORY_ADMISSION_UNAVAILABLE` and performs no durable lifecycle mutation;
- a different `reservation_key` lifecycle mutation on the same variant changes the
  inventory evidence and therefore resolves the protected operation as
  `UNRESOLVED`, never as a false commit or rollback;
- after terminal resolution, a later authorized mutation may acquire a new operation
  identity under the same reservation key;
- the pending-provider cleanup path rolls back order cancellation when its release
  fence is busy or unavailable, and the bounded worker can retry it;
- direct `InventoryItem` maintenance writes are only fixture/setup operations before
  enforcement. The product-creation `InventoryItem.create` path remains the only
  non-overlapping inventory-only writer.

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
  -> derive existing reservation_key and server-generated operation identity
  -> fingerprint the normalized intended mutation
  -> request/deduplicate bounded Redis admission
  -> atomically acquire K_v = 1 and B_total
  -> capture durable PRE/POST facts while both permits are held
  -> claim ADMITTED -> RESERVING with the operation descriptor
  -> run the existing transaction through the outcome-preserving seam
  -> classify known commit / known rejection / ambiguous DB outcome
  -> complete and fenced-release, or fence and recover by reservation_key + PRE/POST
  -> return durable result or bounded status
```

It includes only the contract/types, Redis atomic primitive, internal service, one
single-variant facade integration, bounded lease/reaper machinery, recovery worker,
telemetry, and deterministic tests needed to prove the primitive. It does not include
a durable mutation table, a Redis inventory ledger, or any of the horizontal
expansions below.

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
- `lib/store/orders/inventory_admission/operation.ex`
- `lib/store/orders/inventory_admission/lease.ex`
- `lib/store/support/errors/error_codes.ex` only for registry-backed admission codes
- `config/config.exs`, `config/runtime.exs`, and `config/test.exs` only in the future
  implementation task
- `test/store/orders/inventory_admission_state_test.exs`

**Tasks:**

- [ ] Define the typed request, operation, and lease values, including server-generated
      `operation_id`, `operation_epoch`, `request_fingerprint`, and PRE/POST fact shapes.
- [ ] Define the live-operation rule: one non-terminal operation per `reservation_key`,
      with no new mutation during `UNKNOWN_DB_OUTCOME`, `RECOVERING`, or `UNRESOLVED`.
- [ ] Freeze `K_v = 1` outside runtime configuration.
- [ ] Add validated `B_total`, queue, deadline, recovery, namespace, and feature-gate
      settings without selecting an arbitrary production `B_total`.
- [ ] Define domain result/error codes and the `reserve/status/abandon` contract.
- [ ] Add pure state/deadline/idempotency tests.

**Completion gate:** State ownership, terminal behavior, mutation identity/PRE/POST
descriptor, config relationships, error meanings, serialization rule, and
no-migration boundary are reviewable and tested; the code still performs no Redis or
PostgreSQL admission.

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
- [ ] Prepare the operation descriptor only after admission and before the atomic
      `ADMITTED -> RESERVING` claim; queued requests perform no PostgreSQL preflight.
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
- `lib/store/orders/inventory_admission/redis.ex`
- `lib/store/orders/inventory_reservations.ex` for the internal outcome-preserving
      seam and read-only recovery snapshot
- `lib/store/checkout/domain.ex`
- `lib/store/payments/interlocks.ex`
- `lib/store/subscriptions/facade.ex`
- `lib/store/workers/expire_inventory_reservations_worker.ex`
- `lib/store/workers/expire_pending_provider_setup_orders_worker.ex`
- `test/store/orders/inventory_admission_test.exs`
- `test/store/orders/inventory_admission_redis_test.exs`
- `test/store/orders/inventory_admission_recovery_test.exs`
- `test/store/governance/inventory_reservations_test.exs`

The reviewed resource definitions [`lib/store/orders/inventory_reservation.ex`](../../lib/store/orders/inventory_reservation.ex:95)
and [`lib/store/catalog/inventory_item.ex`](../../lib/store/catalog/inventory_item.ex:83)
remain unchanged by this phase. Their direct mutation actions are not `ENFORCED`
entry points. The implementation must enforce that boundary at the application
call-site set, and a direct action call during `ENFORCED` is a test failure, not a
fallback.

**Tasks:**

- [ ] Route the enforced one-variant `Store.Orders.reserve_inventory/3` path through
      admission.
- [ ] Pass exactly one item to the unchanged existing reservation transaction after
      `ADMITTED -> RESERVING`.
- [ ] Add the narrow `reserve_inventory_outcome/3` internal seam before the legacy
      `RESERVATION_CONFLICT` mapper; preserve current public behavior for non-admission
      callers.
- [ ] Capture and persist the operation PRE/POST descriptor before the transaction and
      enforce `INV-PLAN-SER-001` with the exact writer matrix in Section 6.
- [ ] Make `Store.Orders.reserve_inventory_for_checkout/3` return
      `INVENTORY_ADMISSION_UNSUPPORTED` before its CTE in `ENFORCED` mode, including
      the call from `lib/store/checkout/domain.ex` and the single-item call from
      `lib/store/subscriptions/facade.ex`; never route either caller around admission.
- [ ] Wrap `consume_reservations_for_order/2`, `release_reservations_for_order/2`, and
      `expire_reservations/2` with the shared reservation fence before their existing
      durable mutations. These lifecycle operations do not join the admission queue or
      claim `B_total`; a busy or unavailable fence prevents the transaction.
- [ ] Update the exact payment, subscription, pending-provider cleanup, and expiry
      worker callers to preserve their existing lifecycle semantics when the governed
      fence-busy/unavailable result is returned. Pending cleanup must roll back order
      cancellation; the expiry worker must retry a bounded pass.
- [ ] Close direct `InventoryReservation` and unversioned `InventoryItem` maintenance
      Ash-action paths during `ENFORCED`; fixture/setup writes are allowed only before
      enforcement. Keep the product-creation `InventoryItem.create` path unchanged
      under its new-variant invariant.
- [ ] Preserve existing durable quantity adjustment, lifecycle, notification, and
      invalidation behavior.
- [ ] Keep `DISABLED`/test/system behavior explicit: no mode change is allowed while a
      protected operation is live, and no client-controlled or raw boolean bypass may
      run while `ENFORCED`.
- [ ] Do not alter multi-variant admission, checkout/payment design, durable resource
      fields, or migrations. `InventoryAdmissionRecoveryWorker` is the only recovery
      owner and may reconcile state but may not become another durable writer.

**Completion gate:** `test/store/orders/inventory_admission_test.exs`,
`test/store/orders/inventory_admission_redis_test.exs`,
`test/store/orders/inventory_admission_recovery_test.exs`, and
`test/store/governance/inventory_reservations_test.exs` prove the final row lock,
availability guard, durable identity, structured outcome boundary, PRE/POST recovery,
all entries in the capable-writer matrix, and zero-oversell behavior remain intact.
No schema change is needed.

### PHASE IA-05: ambiguous-outcome recovery

**Files:**

- `lib/store/orders/inventory_admission/recovery.ex`
- `lib/store/orders/inventory_admission/operation.ex`
- `lib/store/orders/inventory_reservations.ex`
- `lib/store/workers/inventory_admission_recovery_worker.ex`
- `test/store/orders/inventory_admission_recovery_test.exs`
- `test/store/workers/inventory_admission_recovery_worker_test.exs`

**Tasks:**

- [ ] Classify definitive commit, definitive rollback/rejection, pre-DB failure, and
      ambiguous database outcomes at the operation boundary.
- [ ] Add the read-only `recovery_snapshot/1` reconciliation boundary using existing
      PostgreSQL uniqueness/index/version support.
- [ ] Compare operation-specific durable PRE/POST facts for inserts and existing-row
      adjustments; never use row existence alone as adjustment commit proof.
- [ ] Reconcile a fenced consume, release, or expiry operation with the same
      operation-specific PRE/POST contract. A grouped lifecycle operation resolves all
      target keys together; one neither-match result keeps the complete target set
      fenced as `UNRESOLVED`.
- [ ] Mark unknown/fence before recovery and retain both capacities until resolution.
- [ ] Use one unique, bounded Oban recovery job per identity; keep the final reservation
      transaction synchronous and outside Oban.
- [ ] Resolve found-row and definitive-no-row outcomes atomically; retain uncertain
      lookup outcomes through bounded retry/escalation.

**Completion gate:**
`test/store/orders/inventory_admission_recovery_test.exs` and
`test/store/workers/inventory_admission_recovery_worker_test.exs` prove fault-injected
commit loss, rollback, process crash, worker crash, Redis-release loss, PRE/POST
adjustment recovery, and no unsafe permit reuse.

### PHASE IA-06: lease expiry, reaper, and Redis failure recovery

**Files:**

- `lib/store/workers/inventory_admission_reaper_worker.ex`
- `lib/store/orders/inventory_admission/redis.ex`
- `test/store/orders/inventory_admission_redis_test.exs`
- `test/store/orders/inventory_admission_recovery_test.exs`
- `test/store/workers/inventory_admission_reaper_worker_test.exs`
- `config/config.exs` and Oban schedule only in the future implementation task

**Tasks:**

- [ ] Prune queued expiry with bounded expiry-index operations.
- [ ] Freeze `RESERVING` holders on lease loss/expiry and enqueue recovery rather than
      returning permits by timestamp alone.
- [ ] Recover unclaimed `ADMITTED` leases only after the safe check.
- [ ] Quarantine Redis restart/namespace loss and prevent promotion during the old
      operation safety window.
- [ ] Re-enqueue missing recovery work without full Redis scans or unbounded loops.
- [ ] Quarantine lost operation descriptors as `UNRESOLVED`; do not treat an empty
      namespace as evidence that an ambiguous adjustment rolled back.
- [ ] Apply the same bounded cleanup to shared lifecycle fences. A lifecycle fence is
      released only after known outcome or recovery; Redis TTL alone never promotes a
      same-reservation writer.

**Completion gate:** Crash, disconnect, lease-loss, Redis timeout, restart, and stale
token tests prove bounded capacity safety and fail-closed behavior.

### PHASE IA-07: deterministic concurrency, security, and multi-node hardening

**Files:**

- `test/store/governance/inventory_admission_concurrency_test.exs`
- `test/support/inventory_admission_multi_node.ex`
- `test/store/orders/inventory_admission_test.exs`
- `test/store/orders/inventory_admission_redis_test.exs`
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

- `priv/repo/performance_smoke_test.exs`
- `test/support/performance_smoke_observer_contract.ex`
- `docs/hardening/s0_inventory_reservation_admission_performance_certification.md`
  only after the separate certification task is authorized

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

Task: Define the typed single-variant admission request, operation descriptor, lease
value, closed states, and transition contract.

Objective: Give the service one source of truth for durable identity versus mutation
identity, `K_v = 1`, deadlines, terminal states, PRE/POST facts, and replay behavior
before Redis or PostgreSQL integration.

Output: `lib/store/orders/inventory_admission.ex`,
`lib/store/orders/inventory_admission/request.ex`,
`lib/store/orders/inventory_admission/operation.ex`,
`lib/store/orders/inventory_admission/lease.ex`, and
`test/store/orders/inventory_admission_state_test.exs`.

Note: DATA LAYER: HOT transient Elixir values only; durable truth stays PostgreSQL.
INDEXES: preserve the existing `reservation_key` and inventory indexes; no migration.
CACHE: none. REDIS STRUCTURE: values mirror the versioned ZSET/HASH model. TTL: use
finite configured queue, lease, and recovery windows; do not make `K_v` configurable.
INVALIDATION/CLEANUP: transition contract must leave cleanup to atomic Redis/reaper
operations. PUBSUB: none. STORE.REPO EFFECT: no DB entry before an admitted claim.
100K SAFETY: status values must support bounded queue interactions, not blocked
processes; no certification claim. STOP CONDITIONS: do not use `reservation_key` as a
mutation ID, accept client operation IDs, add a PostgreSQL admission resource, or make
`K_v` configurable above one.

#### TOON CC-02

Task: Define and validate the admission configuration, error codes, and server-side
`DISABLED | ENFORCED` rollout gate.

Objective: Make `B_total`, queue bounds, deadlines, Redis quarantine, and governed
busy/unavailable/unsupported outcomes explicit without selecting arbitrary production
capacity constants.

Output: `config/config.exs`, `config/runtime.exs`, `config/test.exs`,
`lib/store/support/errors/error_codes.ex`, and
`test/store/orders/inventory_admission_state_test.exs`.

Note: DATA LAYER: configuration controls HOT Redis coordination and durable PostgreSQL
entry budgets. INDEXES: existing reservation/inventory indexes only; no migration.
CACHE: none. REDIS STRUCTURE: shared environment-prefixed admission namespace.
TTL: validate finite `T_db`, `L_admission`, queue, recovery, terminal, and quarantine
relationships. INVALIDATION/CLEANUP: invalid config keeps ENFORCED closed. PUBSUB: no
gate authority. STORE.REPO EFFECT: enforce `B_total < aggregate pool minus headroom`.
100K SAFETY: queue bounds and fail-closed Redis are required; no measured claim. STOP
CONDITIONS: do not choose a full-pool `B_total`, add a user-controlled gate, weaken
fail-closed Redis behavior, or change `K_v = 1`.

### Redis Primitive

#### TOON RP-01

Task: Define the internal Redis key namespace and record encoding for admission.

Objective: Give every future atomic operation one non-ambiguous key and semantic owner,
including the global/variant same-slot requirement.

Output: `lib/store/orders/inventory_admission/redis.ex` and
`test/store/orders/inventory_admission_redis_test.exs`.

Note: DATA LAYER: Redis is HOT/WARM ephemeral coordination, never inventory truth.
INDEXES: PostgreSQL lookup/indexes remain unchanged. CACHE: no stock cache. REDIS
STRUCTURE: per-variant queue ZSET, global dispatch ZSET, global queued-expiry ZSET,
variant active HASH, global active-expiry ZSET, metadata HASH, recovery fence, and
namespace epoch. TTL: semantic score deadlines are separate from container retention.
INVALIDATION/CLEANUP: bounded expiry-index cleanup only; no KEYS. PUBSUB: none.
STORE.REPO EFFECT: queued entries must not checkout connections. 100K SAFETY: bounded
queue/status state only; no certification claim. STOP CONDITIONS: do not encode stock,
availability, or mutation outcome in Redis; do not overload a score with order and
expiry semantics; do not use `KEYS`.

#### TOON RP-02

Task: Implement the atomic enqueue/deduplicate and dual-budget promotion contract.

Objective: Prove one Redis decision grants both `K_v = 1` and `B_total`, or grants
neither, across nodes.

Output: `lib/store/orders/inventory_admission/redis.ex` and
`test/store/orders/inventory_admission_redis_test.exs`.

Note: DATA LAYER: Redis coordinates only; PostgreSQL still decides stock. INDEXES:
reuse existing durable identity, no migration. CACHE: none. REDIS STRUCTURE: queue
order/dispatch/expiry ZSETs plus variant active and global active-expiry records.
TTL: queue deadlines and active lease deadlines are separate finite scores.
INVALIDATION/CLEANUP: prune bounded expired queue members before admission. PUBSUB:
not involved. STORE.REPO EFFECT: at most one same-variant DB entrant and at most
`B_total` globally. 100K SAFETY: excess requests return governed busy/retry; no DB
herd and no process-per-waiter claim. STOP CONDITIONS: do not acquire variant and
global permits in separate client operations, allow partial grants, bypass admission
on Redis error, or make `K_v > 1` available in the MVP.

#### TOON RP-03

Task: Implement token-checked lease claim, renewal, release, stale-owner rejection,
and promotion-after-release.

Objective: Preserve capacity correctness when owners replay, crash, or release after a
newer lease exists.

Output: `lib/store/orders/inventory_admission/redis.ex` and
`test/store/orders/inventory_admission_redis_test.exs`.

Note: DATA LAYER: transient Redis lease over durable PostgreSQL transaction. INDEXES:
existing `reservation_key` uniqueness remains the durable duplicate guard. CACHE: none.
REDIS STRUCTURE: variant active HASH and global active-expiry ZSET, with metadata HASH.
TTL: `L_admission` covers `T_db` plus margin; renewal cannot extend indefinitely.
INVALIDATION/CLEANUP: release and next promotion are one atomic transition; active
RESERVING expiry freezes instead of releasing. PUBSUB: none. STORE.REPO EFFECT: no
replacement enters while the prior DB operation may run. 100K SAFETY: stale holders
cannot multiply DB entrants; not certified. STOP CONDITIONS: do not release or
promote from an expired `RESERVING` lease without a known outcome/recovery decision,
and do not accept stale owner tokens.

#### TOON RP-04

Task: Implement unknown-outcome fencing, recovery ownership, and Redis namespace
quarantine transitions.

Objective: Make Redis uncertainty fail closed without allowing a stale holder or
restart to grant unsafe capacity.

Output: `lib/store/orders/inventory_admission/redis.ex` and
`test/store/orders/inventory_admission_redis_test.exs`.

Note: DATA LAYER: Redis fence is duplicate-prevention state, not durable outcome.
INDEXES: durable recovery uses existing `reservation_key` unique index; no migration.
CACHE: none. REDIS STRUCTURE: recovery fence HASH and namespace epoch HASH alongside
active lease records. TTL: recovery and quarantine TTLs are finite and safety-window
validated. INVALIDATION/CLEANUP: fence expiry never releases capacity by itself;
reaper resumes or escalates bounded recovery. PUBSUB: no correctness role.
STORE.REPO EFFECT: uncertainty freezes variant/global promotion. 100K SAFETY: Redis
outage rejects new admission instead of bypassing to PostgreSQL; no certification. STOP
CONDITIONS: do not treat missing Redis metadata as rollback, open an empty namespace,
or release an unresolved fence.

### Domain Logic

#### TOON DL-01

Task: Build the internal `InventoryAdmission.reserve/status/abandon` orchestration.

Objective: Separate short caller interactions from queue lifetime and keep lifecycle
decisions out of the Redis adapter.

Output: `lib/store/orders/inventory_admission.ex` and
`test/store/orders/inventory_admission_test.exs`.

Note: DATA LAYER: HOT admission coordination precedes COLD/DURABLE PostgreSQL.
INDEXES: use existing durable identities; no migration. CACHE: none in correctness
path. REDIS STRUCTURE: call only typed atomic operations, never ad hoc commands.
TTL: pass bounded queue/lease/deadline values. INVALIDATION/CLEANUP: emit transition
events and leave cleanup to atomic/reaper owners. PUBSUB: optional status projection
only. STORE.REPO EFFECT: queued calls return before checkout. 100K SAFETY: status/retry
contract avoids one blocked BEAM process per queue member. STOP CONDITIONS: do not let
queued callers perform PostgreSQL preflight, expose a raw Redis/lease API, or call the
durable reservation primitive when Redis admission is unavailable.

#### TOON DL-02

Task: Add admission telemetry and server-side ownership/rate-limit enforcement at the
domain boundary.

Objective: Make operational evidence and abuse controls part of the capability without
making UI or PubSub authoritative.

Output: `lib/store/orders/inventory_admission.ex` and
`test/store/orders/inventory_admission_test.exs`.

Note: DATA LAYER: HOT Redis coordination with COLD PostgreSQL outcomes. INDEXES:
existing identity/index guarantees only. CACHE: derived projections only. REDIS
STRUCTURE: request metadata HASH and opaque HMAC member. TTL: finite terminal and lease
retention. INVALIDATION/CLEANUP: bounded identity/queue cleanup and no raw key logs.
PUBSUB: status broadcast after transition only. STORE.REPO EFFECT: abuse controls must
not add DB work for queued requests. 100K SAFETY: bounded labels and queue limits, no
unbounded per-variant metric dimensions. STOP CONDITIONS: do not log raw Redis keys or
tokens, make PubSub authoritative, or allow client-selected operation identities or
unbounded queue/slot ownership.

### Integration

#### TOON IN-01

Task: Route the enforced single-variant `Store.Orders.reserve_inventory/3` facade
through `InventoryAdmission`.

Objective: Put the gate before the existing transaction while making multi-variant
accidental bypass explicit, preserving disabled-mode rollout, and leaving the
capable-writer policy to the exact matrix in Section 6.

Output: `lib/store/orders/domain.ex`, `lib/store/orders/inventory_admission.ex`, and
`test/store/orders/inventory_admission_test.exs`.

Note: DATA LAYER: HOT admission then existing COLD/DURABLE `InventoryReservation`.
INDEXES: existing `inventory_items.variant_id` and reservation identities; no
migration. CACHE: no admission decision from cache. REDIS STRUCTURE: atomic K_v/B_total
lease before transaction. TTL: pass remaining `T_db` and `L_admission`.
INVALIDATION/CLEANUP: preserve existing inventory invalidation after durable outcome.
PUBSUB: no correctness dependency. STORE.REPO EFFECT: no queued checkout; direct
herd is removed only in ENFORCED mode. 100K SAFETY: multi-variant is unsupported,
not partially admitted; no certification claim. STOP CONDITIONS: do not route a
multi-variant request around admission, expose a user-controlled bypass, or move
checkout/payment behavior into InventoryAdmission.

#### TOON IN-02

Task: Add the internal outcome-preserving reservation seam before the legacy error
mapper.

Objective: Preserve known commit, known rollback/rejection, and ambiguous database
outcomes for InventoryAdmission without rewriting the existing transaction or creating
a generic transaction framework.

Output: `lib/store/orders/inventory_reservations.ex` and
`test/store/orders/inventory_admission_recovery_test.exs`.

Note: DATA LAYER: COLD/DURABLE PostgreSQL transaction outcome. INDEXES: existing
reservation/inventory indexes only; no migration. CACHE: none. REDIS STRUCTURE: the
operation descriptor remains in request metadata/fence state, not stock. TTL: preserve
the bounded `T_db` and recovery windows. INVALIDATION/CLEANUP: classify before
post-commit cache invalidation and do not map ambiguity to `RESERVATION_CONFLICT`.
PUBSUB: none. STORE.REPO EFFECT: the seam covers checkout, transaction, and definitive
outcome for the enforced single-variant reservation path without adding a second
reservation transaction; it does not authorize the checkout CTE. 100K SAFETY: ambiguous
requests enter one fenced recovery path; no unrestricted retry. STOP CONDITIONS: do
not collapse raw transaction failures into the legacy error before classification, move
the transaction into Oban, or create a generic transaction framework.

#### TOON IN-03

Task: Add the read-only durable recovery snapshot for operation-specific PRE/POST
comparison.

Objective: Let recovery reconcile inserts and existing-row quantity adjustments from
PostgreSQL truth without treating row presence as proof of an adjustment commit.

Output: `lib/store/orders/inventory_reservations.ex` and
`test/store/orders/inventory_admission_recovery_test.exs`.

Note: DATA LAYER: COLD/DURABLE PostgreSQL snapshot. INDEXES: require existing unique
`inventory_reservations.reservation_key`, `(order_id, variant_id)`, and
`inventory_items.variant_id`; no migration. CACHE: none for recovery truth. REDIS
STRUCTURE: Redis owns the recovery fence and retains the operation PRE/POST descriptor.
TTL: bounded recovery retries and deadline. INVALIDATION/CLEANUP: read only; unresolved
PRE/POST comparison retains the fence and never releases capacity. PUBSUB: none.
STORE.REPO EFFECT: one bounded recovery read under the held global budget, never an
unrestricted retry. 100K SAFETY: recovery cannot multiply DB entrants; no certification
claim. STOP CONDITIONS: do not use row existence alone, add a mutation column/table,
read cached state, or release on a neither-match result.

#### TOON IN-04

Task: Enforce the exact capable-writer matrix and `INV-PLAN-SER-001` shared reservation
fence.

Objective: Prevent checkout, lifecycle, maintenance, test, and system paths from
invalidating operation-specific PRE/POST recovery attribution while keeping lifecycle
transitions outside the admission queue.

Output: `lib/store/orders/inventory_admission.ex`,
`lib/store/orders/inventory_admission/redis.ex`,
`lib/store/orders/inventory_reservations.ex`,
`lib/store/orders/domain.ex`,
`lib/store/checkout/domain.ex`,
`lib/store/payments/interlocks.ex`,
`lib/store/subscriptions/facade.ex`,
`lib/store/workers/expire_inventory_reservations_worker.ex`,
`lib/store/workers/expire_pending_provider_setup_orders_worker.ex`,
`test/store/orders/inventory_admission_test.exs`,
`test/store/orders/inventory_admission_redis_test.exs`,
`test/store/orders/inventory_admission_recovery_test.exs`, and
`test/store/governance/inventory_reservations_test.exs`.

Note: DATA LAYER: Redis is HOT/WARM exclusion coordination and PostgreSQL remains
COLD/DURABLE `InventoryReservation`/`InventoryItem` truth. INDEXES: use the existing
`reservation_key`, `(order_id, variant_id)`, and `inventory_items.variant_id` indexes;
no migration. CACHE: none in the writer guard or recovery decision. REDIS STRUCTURE:
use the per-reservation mutation-fence HASH, active lease, request descriptor, and
namespace quarantine; materialize a bounded lifecycle target set before acquiring it
atomically or none, then do not re-scan for new targets inside the transaction.
TTL: hold the fence through known durable outcome or bounded recovery, never release by
TTL alone. INVALIDATION/CLEANUP: known lifecycle results release idempotently; busy
or unavailable lifecycle writes perform no DB mutation; ambiguous results retain the
fence for Oban recovery. PUBSUB: status projection only, never a writer guard.
STORE.REPO EFFECT: queued reserve requests do not checkout; lifecycle callers do not
join the admission queue, and checkout CTE/direct unversioned writers are rejected in
`ENFORCED` mode. 100K SAFETY: this preserves bounded admission and does not certify
100k. STOP CONDITIONS: do not choose a different writer policy, let
`reserve_inventory_for_checkout/3` or a raw Ash/system/test action bypass the guard,
run a lifecycle transaction after Redis failure, allow a same-reservation second
writer, add a migration, or change the frozen PostgreSQL guard.

### Recovery

#### TOON RC-01

Task: Implement durable ambiguous-outcome reconciliation by operation-specific
`reservation_key` PRE/POST facts.

Objective: Resolve insert and existing-row adjustment commit versus rollback without
assuming rollback, treating row existence as proof, or starting a second durable
attempt automatically.

Output: `lib/store/orders/inventory_admission/recovery.ex` and
`test/store/orders/inventory_admission_recovery_test.exs`.

Note: DATA LAYER: PostgreSQL is final durable authority; Redis is the recovery fence.
INDEXES: use existing unique `reservation_key`, `(order_id, variant_id)`, and
`inventory_items.variant_id`; no migration. CACHE: none. REDIS STRUCTURE: recovery
fence HASH, active lease records, and operation PRE/POST descriptor. TTL: bounded
safety window, retry budget, and absolute recovery deadline. INVALIDATION/CLEANUP: only
a definitive PRE/POST result releases capacity; neither-match and missing metadata stay
fenced. PUBSUB: no correctness role. STORE.REPO EFFECT: one bounded recovery snapshot,
not an unrestricted reservation retry. 100K SAFETY: ambiguous workload cannot multiply
DB attempts; no measured claim. STOP CONDITIONS: do not resolve from row existence,
retry before reconciliation, add durable mutation schema, or release `UNRESOLVED`.

#### TOON RC-02

Task: Add the unique Oban recovery worker for bounded recovery execution.

Objective: Survive caller/worker crashes while keeping recovery ownership bounded and
separate from the synchronous final reservation transaction.

Output: `lib/store/workers/inventory_admission_recovery_worker.ex` and
`test/store/workers/inventory_admission_recovery_worker_test.exs`.

Note: DATA LAYER: Oban is operational retry; PostgreSQL reservation remains durable
truth. INDEXES: recovery worker relies on existing `reservation_key`; no migration.
CACHE: none. REDIS STRUCTURE: recovery fence, active lease, and operation PRE/POST
descriptor. TTL: finite Oban/recovery attempts and Redis safety TTLs. INVALIDATION/CLEANUP:
a worker resolves only a definitive PRE/POST result; it never uses a fence
expiry as release. PUBSUB: optional status projection only. STORE.REPO EFFECT: one
bounded recovery snapshot, never the final reservation transaction in Oban. 100K
SAFETY: bounded jobs and queue state, no blocked BEAM process per waiter; not
certified. STOP CONDITIONS: do not enqueue duplicate recovery jobs, bypass the Redis
fence, move reservation execution into Oban, or treat Redis metadata as inventory
truth.

#### TOON RC-03

Task: Add the bounded Oban reaper for queued expiry, lease expiry, and stale-fence
maintenance.

Objective: Clean coordination state without full scans or releasing an active or
ambiguous database operation by timestamp alone.

Output: `lib/store/workers/inventory_admission_reaper_worker.ex` and
`test/store/workers/inventory_admission_reaper_worker_test.exs`.

Note: DATA LAYER: HOT/WARM Redis coordination with COLD PostgreSQL recovery truth.
INDEXES: use Redis expiry indexes and existing PostgreSQL indexes; no migration. CACHE:
none. REDIS STRUCTURE: queued-expiry ZSET, active-expiry ZSET, recovery fence, and
namespace quarantine. TTL: finite queue, lease, recovery, and cleanup grace windows.
INVALIDATION/CLEANUP: bounded `ZRANGEBYSCORE`/member operations, no `KEYS`, no full
scan, and no unbounded loop. PUBSUB: optional status projection only. STORE.REPO
EFFECT: no transaction per queued request; `RESERVING` expiry creates recovery rather
than releasing capacity. 100K SAFETY: cleanup remains bounded; no certification claim.
STOP CONDITIONS: do not promote after lease loss while the DB window may run, expire
an ambiguous fence into a fresh permit, or use Redis absence as rollback proof.

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
SAFETY: assert bounded queue/status semantics, not load capacity. STOP CONDITIONS: do
not make `K_v` runtime-tunable above one, treat `ADMITTED` as durable success, or
allow a second live operation for one `reservation_key`.

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
100k certification. STOP CONDITIONS: do not use client-side check-then-set, bypass
admission on Redis failure, or make PubSub or a Redis Stream part of correctness.

#### TOON TS-03

Task: Add PostgreSQL integration tests for known outcomes, ambiguous recovery, replay,
and existing reservation lifecycle preservation.

Objective: Prove Redis admission never replaces the final PostgreSQL guard or creates a
duplicate durable reservation.

Output: `test/store/orders/inventory_admission_recovery_test.exs` and
`test/store/governance/inventory_reservations_test.exs`.

Note: DATA LAYER: COLD/DURABLE PostgreSQL reservation truth behind HOT admission.
INDEXES: verify existing unique `reservation_key`, `(order_id, variant_id)`, and
`inventory_items.variant_id`; no migration. CACHE: none. REDIS STRUCTURE: fence/lease
state only. TTL: recovery safety and retry windows are bounded. INVALIDATION/CLEANUP:
preserve existing stock projection invalidation after durable outcomes. PUBSUB: no
correctness role. STORE.REPO EFFECT: only admitted work checks out; ambiguous outcomes
do not retry unrestricted. 100K SAFETY: no claim beyond bounded entrant behavior. STOP
CONDITIONS: do not call row existence an adjustment commit, collapse ambiguity into
`RESERVATION_CONFLICT`, add a migration, or weaken the existing PostgreSQL availability
guard.

#### TOON TS-04

Task: Add the focused separate-node concurrency and security harness.

Objective: Prove `K_v` and `B_total` are global across nodes and that untrusted callers
cannot manipulate coordination state.

Output: `test/store/governance/inventory_admission_concurrency_test.exs` and
`test/support/inventory_admission_multi_node.ex`.

Note: DATA LAYER: shared PostgreSQL durable rows plus shared Redis coordination.
INDEXES: existing inventory/reservation indexes only. CACHE: no authority. REDIS
STRUCTURE: one cluster-global variant/global budget namespace. TTL: crash/restart
tests use bounded lease/recovery windows. INVALIDATION/CLEANUP: prove capacity returns
only through fenced atomic cleanup. PUBSUB: loss must not change outcomes.
STORE.REPO EFFECT: assert per-variant one entrant, global `B_total`, and retained
headroom. 100K SAFETY: harness proves architecture shape at focused scale; it does
not certify 100k. STOP CONDITIONS: do not substitute one-node tasks for separate
application nodes, weaken `B_total`/headroom assertions, or grant permits from local
state.

### Performance

#### TOON PF-01

Task: Extend observability for admission and DB-capacity evidence.

Objective: Make later certification able to distinguish queue pressure, Redis pressure,
DB entrant pressure, and durable reservation outcomes without high-cardinality labels.

Output: `priv/repo/performance_smoke_test.exs` and
`test/support/performance_smoke_observer_contract.ex`.

Note: DATA LAYER: HOT Redis/Elixir admission, durable PostgreSQL reservation, WARM
metrics. INDEXES: no migration; report existing lookup/index assumptions. CACHE: no
correctness cache. REDIS STRUCTURE: queue/lease depth and latency measurements.
TTL: report configured queue/lease/recovery windows. INVALIDATION/CLEANUP: include
expiry/abandon/recovery cleanup counts. PUBSUB: status-only metrics if used.
STORE.REPO EFFECT: report utilization, checkout queue, entrants, and lock waits.
100K SAFETY: metrics must support bounded-backpressure evidence, not a certification
claim. STOP CONDITIONS: do not change pool sizes, thresholds, or workloads, claim
100k certification, or expand InventoryAdmission into generic checkout admission.

#### TOON PF-02

Task: Run the separate performance/capacity certification sequence for enforced
admission.

Objective: Verify the architecture under approved workloads without weakening existing
correctness, pool, provider-fault, or chaos gates.

Output: `docs/hardening/s0_inventory_reservation_admission_performance_certification.md`,
`priv/repo/performance_smoke_test.exs`, and
`test/support/performance_smoke_observer_contract.ex`.

Note: DATA LAYER: HOT admission, HOT row contention, COLD durable reservation result.
INDEXES: use existing inventory/reservation indexes and record plans if required; no
unreviewed migration. CACHE: projections only. REDIS STRUCTURE: measure queue/lease
depth, dual-budget occupancy, expiry, and latency. TTL: test configured deadlines and
recovery behavior. INVALIDATION/CLEANUP: verify queues and leases drain. PUBSUB: must
remain non-authoritative. STORE.REPO EFFECT: retain the existing `0.95` whole-window
gate and prove no 40/40 same-variant herd. 100K SAFETY: 100k remains unmeasured until
its own evidence is accepted. STOP CONDITIONS: do not weaken the `0.95` pool
threshold, provider/lock/oversell gates, or call an unmeasured 100k run certified.

## 26. Plan self-review

Before handing this plan to an implementation-planning reviewer, confirm:

- [ ] The tracer bullet has exactly one variant and one durable reservation call.
- [ ] `K_v = 1` is normative and cannot be configured higher in the MVP.
- [ ] `B_total` is global, separately bounded, and never defaults to the full pool.
- [ ] Variant and global capacity are one Redis atomic decision.
- [ ] Queue bounds and request-process lifetime are independently finite.
- [ ] Queue order, queued expiry, and active expiry have separate semantics.
- [ ] Admission success never implies stock ownership or durable reservation.
- [ ] `reservation_key`, `operation_id`/epoch, and `request_fingerprint` have separate
      meanings, and only one live operation may use a reservation key.
- [ ] Every current durable writer is listed in the Section 6 matrix with one fixed
      policy: admission-required, shared-fence, enforced-unavailable,
      provably-non-overlapping create, or recovery-only.
- [ ] The checkout CTE and direct unversioned resource/maintenance actions cannot run
      in `ENFORCED`; consume, release, expiry, and pending-provider cleanup use the
      shared fence without joining the admission queue.
- [ ] Known commit, known rollback/rejection, and ambiguous DB outcomes are distinct
      before the legacy public error mapper.
- [ ] Recovery queries PostgreSQL by the existing unique `reservation_key` and compares
      operation-specific durable PRE/POST facts for inserts and adjustments.
- [ ] Existing version/counter/state fields prove PRE versus POST under the normative
      same-reservation fence; missing evidence produces `UNRESOLVED`.
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
