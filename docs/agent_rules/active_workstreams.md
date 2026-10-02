# Active Workstream Registry

Dynamic authority registry for hardening programmes.

`AGENTS.md` is permanent law. This file records the **current** workstream topology, ownership, lifecycle state, and ownership-relevant pending PRs.

Before beginning any work, agents MUST read this file. If this registry conflicts with actual Git state, STOP.

Do not treat transient SHAs below as permanent law; they are commissioning/status evidence only and must be refreshed when authority moves.

---

## Purpose

- Name the four persistent programme worktrees and their branches
- Define **governance authority**, **development base**, and **integration base** as distinct concepts
- Declare owned domains, exclusions, and shared boundaries
- Record lifecycle state so agents do not start unauthorized implementation
- Point to pending PRs that affect ownership
- Make independent activation of S0, PLATFORM, and SUBS legally possible after this governance is accepted

This registry grants no implementation authority to unactivated lanes. The accepted S0 and PLATFORM activation and READY states are recorded below. SUBS remains READY under its serial execution policy.

---

## Topology (parallel hardening)

```text
                         MAIN
              governance + integration authority
                          │
             ┌────────────┼────────────┐
             │            │            │
             ▼            ▼            ▼
            S0         PLATFORM       SUBS
          parallel      parallel     parallel
          hardening     hardening    hardening
             │            │            │
             └────────────┼────────────┘
                          │
                 integration-time
                    convergence
                          │
                          ▼
                         MAIN
```

S0 is **not** the mandatory development parent of PLATFORM or SUBS.
PLATFORM and SUBS do **not** wait for S0 merely because S0 moved.
Cross-workstream dependencies are evaluated at the **task** level.
Convergence with canonical `main` remains mandatory before integration.

This topology remains parallel across independent workstreams. It does not authorize parallel SUBS issue execution. SUBS implementation follows the serial policy in the SUBS section below.

---

## Three authority concepts (MANDATORY)

### A. Governance authority

```text
GOVERNANCE AUTHORITY
=
latest accepted canonical governance on origin/main
```

All persistent workstreams MUST:

```bash
git fetch origin
```

and read canonical governance from `origin/main`.

A lane does **not** need to merge `main` merely to read current governance.

Approved read-only pattern:

```bash
git show origin/main:AGENTS.md
git show origin/main:docs/agent_rules/active_workstreams.md
```

This covers the case where an older development branch does not physically contain the newest registry.

### B. Development base

```text
DEVELOPMENT BASE
=
exact accepted code SHA against which one hardening lane independently works
```

Each of S0, PLATFORM, and SUBS owns its own development base.

Another lane moving does **not** automatically invalidate it.

A development base must be:

- explicit
- provenanced
- verified
- frozen for the relevant activation or task

Do not describe transient SHAs as permanent law.
Candidate tip SHAs in this file are status evidence only until an activation gate accepts them.

### C. Integration base

```text
INTEGRATION BASE
=
latest accepted canonical main authority against which a validated
hardening stream must reconcile before integration
```

The integration base is intentionally allowed to differ from the development base.
Ordinary independent hardening does **not** require continuous main synchronization.

---

## Development-base validity law

A development base remains valid until specific evidence invalidates it.

Valid reasons for `BASELINE_INVALIDATED`:

- task requires an external capability absent from the base
- critical shared architecture change makes that base unsafe
- canonical governance explicitly revokes the base
- the workstream's own branch authority moved unexpectedly
- correctness cannot be proven against that base

**Not** sufficient by itself:

- another workstream has newer commits
- main is ahead
- S0 is ahead of SUBS (or any other independent-lane tip comparison)

---

## Task-level dependency law

Replace global workstream serialization with task-level dependency admission.

This law classifies dependencies after a lane's execution policy explicitly selects a task. It does not authorize automatic task selection. SUBS uses the serial policy below.

```text
SELECT A READY TASK UNDER THE LANE'S CURRENT POLICY
       ↓
Does this exact task require an external change
not present in the lane's development base?
       │
       ├── YES
       │     ↓
       │ BLOCKED_EXTERNAL_DEPENDENCY
       │     ↓
       │ do not execute this task
       │     ↓
       │ consider another independent READY task where that lane's policy permits it
       │
       └── NO
             ↓
       continue admission
```

Then evaluate shared authority:

```text
Does this exact task modify a shared boundary?
       │
       ├── YES + authority not assigned
       │       ↓
       │ BLOCKED_SHARED_AUTHORITY
       │
       └── NO / authority assigned
               ↓
            executable
```

A blocked task must **not** globally block unrelated tasks.

Only when no executable READY work exists may the lane report:

```text
NO_EXECUTABLE_READY_WORK
→ STOP
```

---

## Persistent workstreams

| ID | Path | Branch | Development base | Integration target | Lifecycle state | Writable by long-lived agent? |
| --- | --- | --- | --- | --- | --- | --- |
| `MAIN` | `/home/jcschoeman96/projects/current/Store_Blueprint_Hardening-main` | `main` | n/a (canonical) | n/a | `CANONICAL` | Normally no (observe / post-merge verify) |
| `S0` | `/home/jcschoeman96/projects/current/Store_Blueprint_Hardening` | `hardening/s0-baseline` | `f2d3ed27476d1d8bfdda2a28dcdbfe6a1d02e2d9` (accepted tip after PR #117; PR #115 task base remains historical provenance) | `origin/main` | `READY` | Explicitly admitted S0 tasks may be implemented under the task-admission and integration laws below |
| `PLATFORM` | `/home/jcschoeman96/projects/current/Store_Blueprint_Hardening-platform` | `hardening/platform-security` | `cc605040bfc8ddd6868a62de20f52c905f999835` (accepted) | `origin/main` | `READY` | Explicitly admitted PLATFORM tasks may be implemented under the task-admission and integration laws below |
| `SUBS` | `/home/jcschoeman96/projects/current/Store_Blueprint_Hardening-subscriptions` | `hardening/subscriptions` | `575ffa1848ac69abe855bd018c7ae8eaf05d61e4` (SUB-ACT-01 accepted) | `origin/main` | `READY` | Stage B governance frozen; READY issues may be implemented only through the serial policy below |

Temporary worktrees (governance / integration / review / task / remediation) may exist under names such as `Store_Blueprint_Hardening-governance-*`, `Store_Blueprint_Hardening-integration-*`, `Store_Blueprint_Hardening-review-*`, `Store_Blueprint_Hardening-task-*`, or `Store_Blueprint_Hardening-remediation-*`. They are disposable. Do **not** create a permanent integration worktree. Do **not** create a fifth programme lane.

---

## Ownership

### MAIN

Role:

- canonical governance authority
- canonical integration / convergence authority
- release authority

Owns:

- canonical history
- repository-wide governance (via reviewed PRs to `main`)
- accepted shared dependency/security baseline
- release / integration authority

Implementation in the permanent main worktree: **NONE**.

Bounded governance/integration work should use temporary dedicated worktrees/branches.

### S0

Role: independent general/core hardening and InventoryAdmission programme.

Primary authority:

- `InventoryAdmission`
- inventory reservation / admission architecture
- inventory contention / concurrency
- IA lifecycle / recovery
- S0-specific closure

Explicit exclusion:

- subscription commercial lifecycle
- dependency / platform modernization except explicit shared task

S0 is **not** the mandatory development parent of PLATFORM or SUBS.

**Activation:** S0 is `READY` under the S0-specific activation record below. READY allows S0 to accept separately reviewed and explicitly authorized S0 tasks. READY itself does not automatically start implementation. Current implementation authority is recorded by the bounded task-admission records below (including IA-04 for GitHub #101 when accepted on `main`).

### S0 activation record

This record defines S0's activation guards and side effects. It does not import
SUB-ACT identifiers, SUBS runtime provenance, or SBH task side effects.

Prior state: `BOOTSTRAPPED`.

Accepted S0 development base: `e16767e92ac22ca7a108f13677052c63bb13c3f2`.

This records the original S0 activation baseline. It remains historical provenance;
it is not the current S0 development base after PR #71.

Baseline guard: `PASS`.

Activation-feasibility guard: `PASS`.

| Ordered transition | Guard | Side effect |
| --- | --- | --- |
| `BOOTSTRAPPED -> BASELINE_PINNED` | The exact S0 development base was explicitly accepted and canonically recorded. | Records the accepted S0 development base as the activation baseline. This transition alone grants no implementation authority. |
| `BASELINE_PINNED -> READY` | A completed independent S0 activation-feasibility review returns `PASS` for architecture, source compatibility, capable writers, concurrency/recovery, security/authority, performance/scaling feasibility, migration/data integrity, and shared-authority review. | S0 becomes eligible to accept separately reviewed and explicitly authorized implementation tasks. |

Both guards were independently satisfied and are recorded here in order. This
governance action does not skip `BASELINE_PINNED`. This reviewed S0-specific
activation record records the ordered transition sequence and establishes the
resulting current state as `READY`.

Baseline provenance:

- Human acceptance and independent exact-head review: `PASS`.
- Exact-head CI: run `35707962997`, `PASS`.
- PR #51 merged the accepted candidate `e16767e92ac22ca7a108f13677052c63bb13c3f2` into canonical `main` as `f0c6902d258e9e57528359f660c68e88f3aa7f62`.
- PR #56 canonicalized the accepted S0 development base.
- PR #62 corrected the accepted architecture documentation and merged as `9e6e9b627ec03c3e020fcf0b08710222ea62d1f3`.
- The completed independent S0 activation-feasibility review against canonical main `9e6e9b627ec03c3e020fcf0b08710222ea62d1f3` returned `PASS`, with no shared-authority blockers. No activation identifier is assigned to that review.

Resulting current state: `READY`.

At activation, the persistent S0 branch remained at its prior tip pending a separate
alignment task. PR #71 later advanced it to the replacement development base recorded
below. `READY` does not mean `ACTIVE_PARALLEL`, `VALIDATED`, or `READY_FOR_INTEGRATION`.
Convergence with current `main` remains a later integration obligation.

### Current accepted S0 development base

Current accepted S0 development base: `f2d3ed27476d1d8bfdda2a28dcdbfe6a1d02e2d9`.
The prior accepted S0 task base was `f122b24bcf78f48f2954d372cef38c06ebcc1e5e`; the prior reconciled S0 base was `f4127902c3f328b76674724faa6a473c629c01ef`.

Provenance:

- PR #71 candidate HEAD: `458d9592113bb99713c1ee41b510999fc3d4e469`; independent candidate certification: `PASS`.
- Exact-head CI run `35870593599`: `PASS`; all five required jobs passed.
- PR #71 merged into `hardening/s0-baseline` as `b40832ee8f955f294cec8c5193aa2c61a02e75b9`.
- Candidate and merge commit have identical tree `61b240c552358dbf7c09a633b89495f40f900af4`.
- Independent post-merge review: `PASS`.
- PR #83 reconciled canonical main `d78a916472a75c9ffebea33acf6b07f41ffe07f3` into prior S0 `b40832ee8f955f294cec8c5193aa2c61a02e75b9` as `f4127902c3f328b76674724faa6a473c629c01ef`.
- The PR #83 integration commit's parents are the prior S0 SHA and canonical main SHA, in that order.
- Exact-head CI run `36250010176`, attempt 1: `PASS`; all five required jobs passed.
- Independent post-integration review: `PASS`.
- PR #115 merged generic IA-03 into `hardening/s0-baseline` as
  `f122b24bcf78f48f2954d372cef38c06ebcc1e5e`.
- PR #115 certified implementation head: `35e85a05083d3be144c07c97c4e8b9ad8c38a02e`.
- PR #115 certified and merge tree: `b4e3bf388433d7f7b17931c777ad0e33fb318102`.
- PR #115 exact-head CI run `36885741940`: `PASS`, with 3 properties, 598 tests,
  and 0 failures; independent implementation verdict:
  `PASS WITH NON-BLOCKING CORRECTIONS`.
- PR #117 certified renewal-generation implementation head:
  `aaf33a1abf68d65c00b8cf10a43225350c5bbdc5`.
- PR #117 exact-head CI run `36968312583`: `PASS`; all five required jobs passed,
  with 3 properties, 625 tests, and 0 failures.
- PR #117 merged into `hardening/s0-baseline` as
  `f2d3ed27476d1d8bfdda2a28dcdbfe6a1d02e2d9`.
- GitHub comparison from the certified head to the merge commit is one commit ahead
  with zero changed files; independent post-merge verification: `PASS`.

### S0 main-to-branch reconciliation record

PR #80 added an accepted InventoryAdmission architecture amendment for
renewal-generation admission to canonical `main`. The required reconciliation is
complete. PR #83 merged the exact canonical main `d78a916472a75c9ffebea33acf6b07f41ffe07f3`
into prior S0 `b40832ee8f955f294cec8c5193aa2c61a02e75b9`, producing accepted S0
integration `f4127902c3f328b76674724faa6a473c629c01ef`. The merge was conflict-free.
Its tree `9959f6db68823ccbf99bf8c17c8ac419079d3ea0` matched canonical main at the
time of integration. The integration introduced no runtime or migration changes.
Exact-head CI run `36250010176`, attempt 1, and the independent post-integration
review both passed.

State at completion of the PR #83 reconciliation, before the fresh task-admission decision: S0 remained `READY`; IA-03 was `NOT AUTHORIZED`.

Task-admission status: the reconciliation prerequisite is satisfied. S0 remains
`READY`. The fresh bounded generic IA-03 task admission below authorized only the
recorded four-file implementation boundary. PR #115 completed that boundary and
generic IA-03 is now `COMPLETE / FROZEN`. It did not authorize SBH-10-04
implementation.

The narrow governance PR that records this completed PR #83 reconciliation changes
authority/status documentation only. It adds no runtime, dependency, schema, migration,
CI, shared-architecture, or implementation semantics. Its governance-only commit does
not invalidate the completed reconciliation or require another main-to-S0 integration
before the immediate fresh IA-03 task-admission review. This exception applies only to
this bounded reconciliation record. Future `main` changes must still be evaluated under
`AGENTS.md` main-to-long-lived-branch synchronization rules; this exception does not
waive reconciliation when a future change requires it.

### Fresh generic IA-03 task admission (2026-09-26)

Task base: `f4127902c3f328b76674724faa6a473c629c01ef`.

At admission time, S0 lifecycle remained `READY` and generic IA-03 was
`AUTHORIZED / NOT STARTED`. PR #115 later completed this bounded task, and generic
IA-03 is now `COMPLETE / FROZEN`. IA-04 and later remain `NOT AUTHORIZED`; completing
IA-03 did not authorize a later slice.

The exact coding boundary is:

```text
lib/store/orders/inventory_admission.ex
lib/store/orders/inventory_admission/redis.ex
test/store/orders/inventory_admission_test.exs
test/store/orders/inventory_admission_redis_test.exs
```

No fifth implementation file is authorized. The frozen read-only contracts are
`lib/store/orders/inventory_admission/request.ex`,
`lib/store/orders/inventory_admission/operation.ex`,
`lib/store/orders/inventory_admission/lease.ex`, and
`test/store/orders/inventory_admission_state_test.exs`. IA-03 must not modify
them. The admitted behavior and exclusions are recorded in section 20 of
`s0_inventory_reservation_admission_architecture.md`.

At that time PR #80's renewal-generation InventoryAdmission work remained separately
`NOT AUTHORIZED`. This governance update makes a distinct admission decision for its
typed identity contract and exact-key recovery below. Generic IA-03 uses only
`order:<order_id>:sku:<variant_id>`.

### Generic IA-03 closure and PR #80 renewal-generation admission (2026-10-01)

Generic IA-03 is `COMPLETE / FROZEN`. PR #115 merged the certified implementation
without a tree delta:

- Task base: `f4127902c3f328b76674724faa6a473c629c01ef`.
- Certified implementation head: `35e85a05083d3be144c07c97c4e8b9ad8c38a02e`.
- Certified implementation tree: `b4e3bf388433d7f7b17931c777ad0e33fb318102`.
- Merge commit: `f122b24bcf78f48f2954d372cef38c06ebcc1e5e`.
- Merge tree: `b4e3bf388433d7f7b17931c777ad0e33fb318102`.
- Exact-head CI run `36885741940`: `PASS`, with 3 properties, 598 tests, and 0
  failures.
- Independent implementation verdict: `PASS WITH NON-BLOCKING CORRECTIONS`.

The only correction was PR-description performance wording. No code changed after
certification. The completed behavior is limited to the generic four-part identity,
Redis-only reserve/status/queued-abandon orchestration, exact replay, governed
mismatch/busy/unavailable outcomes, caller-independent queue state, metadata/fence/
index coherence checks, fail-closed corruption handling, no raw lease or fencing
exposure through the facade, no abandon promotion, no PostgreSQL reservation
execution, no operational admitted-expiry or release, no recovery/reaper/workers,
unchanged `K_v = 1`, and unchanged global `B_total`.

Separately, at the 2026-10-01 admission point, the PR #80 renewal-generation
InventoryAdmission / exact-key reservation prerequisite was `AUTHORIZED / NOT STARTED`
against task base `f122b24bcf78f48f2954d372cef38c06ebcc1e5e`. That admission was
independent from the IA-03 closure. It was supported by the canonical PR #80
cross-domain authority and a fresh review of the S0 source at that exact tip.

The authorized implementation boundary is recorded in section 21 of
`s0_inventory_reservation_admission_architecture.md`. It includes only the listed
InventoryAdmission, Orders, one migration, one generated snapshot, and focused tests.
It authorizes the server-derived UUIDv7 generation key, exact-key identity
propagation and recovery, Orders' global `reservation_key` identity plus the active
partial unique index, exact reserve/read/recover/release/consume operations, generic
key disambiguation, and renewal cleanup exclusion. It does not authorize any
Subscription, Payments, provider, PR #78, IA-04+, recovery-worker, reaper, or Redis
authority work.

### PR #117 renewal-generation prerequisite closure (2026-10-02)

The admitted S0 prerequisite is now `COMPLETE / FROZEN`:

- Implementation task base: `f122b24bcf78f48f2954d372cef38c06ebcc1e5e`.
- Certified implementation head: `aaf33a1abf68d65c00b8cf10a43225350c5bbdc5`.
- Exact-head CI run `36968312583`: `PASS`; all five required jobs passed, with
  3 properties, 625 tests, and 0 failures.
- PR #117 merge commit: `f2d3ed27476d1d8bfdda2a28dcdbfe6a1d02e2d9`.
- Certified-head to merge comparison: one merge commit, zero changed files.
- Independent post-merge verification: `PASS`.

This closure exhausts only the bounded renewal-generation / exact-key prerequisite
implementation authority. Generic IA-03 remains frozen. IA-04+ remains unauthorized.
`S0-CLOSE-02` and overall S0 merge readiness remain blocked under their separate
programme gates.

The current accepted SUBS tip `bd0555c41bb014326b0754329f2ca5fbf0f8911b`
does not contain the exact-key runtime capability. Therefore this closure does not
make JC-229 / SBH-10-04 executable by itself. A bounded S0-to-SUBS integration must
first place the accepted runtime into the SUBS development base and pass its own
validation, exact-head CI, independent review, merge, and post-merge verification.
Only then may the separate SUBS re-admission required by the canonical cross-domain
authority decide JC-229 readiness and assign a new implementation `task_base_sha`.
PR #78 remains stale draft evidence and is not resumed by this closure.

Resulting state:

```text
S0 lifecycle = READY
generic IA-03 = COMPLETE / FROZEN
PR #80 renewal-generation InventoryAdmission / exact-key reservation prerequisite = COMPLETE / FROZEN
renewal implementation task base = f122b24bcf78f48f2954d372cef38c06ebcc1e5e (completed provenance)
accepted S0 tip = f2d3ed27476d1d8bfdda2a28dcdbfe6a1d02e2d9
IA-04+ = NOT AUTHORIZED
S0-CLOSE-02 = BLOCKED
S0 merge readiness = BLOCKED
JC-229 / SBH-10-04 implementation readiness = NOT GRANTED BY THIS CLOSURE
```

The S0-side runtime prerequisite is satisfied. SUBS is not thereby READY: its current
accepted development tip does not yet contain the capability, and the canonical
cross-domain authority requires a separate SUBS re-admission after accepted runtime
integration. This governance closure assigns no SUBS implementation branch or
`task_base_sha` and grants no Subscription, Payments, provider, or IA-04+ authority.
That closure state remains historical provenance. Current IA-04 authority is recorded
in the fresh full-scope task admission below and in section 22 of
`s0_inventory_reservation_admission_architecture.md`.

### Fresh full-scope IA-04 task admission (GitHub #101) (2026-10-02)

Issue: `#101` — S0 IA-04: integrate single-variant admission with the durable
reservation transaction.

Readiness review (post-PR-117, task base `f2d3ed27476d1d8bfdda2a28dcdbfe6a1d02e2d9`):
the historical IA-04 phase is `PARTIALLY_STALE` because PR #117 completed the
renewal-generation / exact-key prerequisites; the canonical IA-04 protection boundary
(writer matrix, lifecycle-fence introduction, ENFORCED rollout configuration, and
single-variant durable settlement) remains required. There is no IA-04A / IA-04B split.

Task base (implementation parent): `f2d3ed27476d1d8bfdda2a28dcdbfe6a1d02e2d9`.

Issue existence alone grants no implementation authority. This admission record is the
authority. Normative detail: section 22 of
`docs/hardening/s0_inventory_reservation_admission_architecture.md` and frozen
`S0-PLAN-01` PHASE IA-04 / capable-writer matrix (implementation plan is not modified
by this governance PR).

**PR #117 — COMPLETE / FROZEN (IA-04 must not reimplement):** renewal-generation
Request identity; reservation-key parser/classifier; exact key through Operation and
Lease validation paths; Redis exact-key metadata/fence compatibility; global
`reservation_key` uniqueness; partial active `(order_id, variant_id)` uniqueness;
historical terminal reservation generations; exact-generation reserve, recovery read,
release, and consume; generic/renewal key disambiguation; renewal exclusion from
generic order-wide release/consume/expiry; exact-generation
`:ambiguous_database_outcome` classification.

**Operation identity law (frozen):** one logical InventoryAdmission operation equals
Redis `operation_id` / `operation_epoch` equals Operation descriptor
`operation_id` / `operation_epoch`. Redis owns initial server generation; exact replay
retains the same pair. The IA-04 settlement path must not use `Operation.new/2` to
manufacture a second identity. Authorize a narrow trusted internal constructor in
`lib/store/orders/inventory_admission/operation.ex` only.

**Lifecycle authorized in IA-04:** `ADMITTED -> RESERVING`; `RESERVING -> COMPLETED |
REJECTED | UNKNOWN_DB_OUTCOME`. Not authorized: `UNKNOWN_DB_OUTCOME -> RECOVERING` or
recovery execution (IA-05 / GitHub #102).

**Redis IA-04 primitives (minimum):** `claim_reserving`; `release_known_outcome`;
`mark_unknown_and_fence` — per frozen plan §10 and section 22.

**Capable-writer / ENFORCED boundary:** full frozen matrix (single-variant
`reserve_inventory/3` through admission; checkout CTE blocked in ENFORCED; shared
exact reservation fences on consume/release/expiry; fenced pending-provider release
with rollback on failure; direct Ash/maintenance writers closed at governed call sites
without changing `inventory_reservation.ex` or `inventory_item.ex` resource definitions).

**Rollout configuration (Option B):** `config/config.exs`, `config/runtime.exs`,
`config/test.exs`, and new `lib/store/orders/inventory_admission/config.ex` (typed
loader/validator only). Production default `DISABLED` until reviewed ENFORCED settings.
`Store.Application` changes are not authorized unless a later implementation review
proves them strictly necessary.

**Required implementation files:**

```text
lib/store/orders/inventory_admission/config.ex
lib/store/orders/inventory_admission/operation.ex
lib/store/orders/inventory_admission/redis.ex
lib/store/orders/inventory_admission.ex
lib/store/orders/inventory_reservations.ex
lib/store/orders/domain.ex
config/config.exs
config/runtime.exs
config/test.exs
```

**Conditionally writable (only if focused tests prove propagation insufficient):**
`lib/store/checkout/domain.ex`, `lib/store/payments/interlocks.ex`,
`lib/store/subscriptions/facade.ex`,
`lib/store/workers/expire_inventory_reservations_worker.ex`,
`lib/store/workers/expire_pending_provider_setup_orders_worker.ex` — governed error
propagation only; no Checkout/Payments/SUBS commercial redesign.

**Frozen / read-only for IA-04 (STOP for independent review if implementation requires
change):** `request.ex`, `lease.ex`, `inventory_reservation.ex`, `inventory_item.ex`,
`product.ex`, `application.ex`.

**Shared authority:** Orders REQUIRED; Checkout/Payments/SUBS/workers conditional
propagation only as above.

**IA-04 exclusions:** multi-variant admission; IA-05 recovery service/worker;
`RECOVERING` / `UNRESOLVED` execution; IA-06 reaper; IA-07/IA-08 certification;
migrations/schema/dependency changes; Redis stock truth; SBH-10-04 subscription
orchestration; Checkout/Payment/provider redesign.

Resulting state after this governance record (implementation not started until a
separate coding task on `hardening/s0-baseline`):

```text
S0 lifecycle = READY
generic IA-03 = COMPLETE / FROZEN
renewal-generation / exact-key prerequisite = COMPLETE / FROZEN
accepted S0 tip = f2d3ed27476d1d8bfdda2a28dcdbfe6a1d02e2d9
IA-04 = AUTHORIZED / NOT STARTED
IA-05+ = NOT AUTHORIZED
```

### PLATFORM

Role: independent security / platform / runtime hardening programme.

Primary authority:

- `mix.exs` / `mix.lock`
- npm dependency graph
- Hex / npm advisories
- authentication framework / platform
- OAuth / security infrastructure
- HTTP / Req / Finch infrastructure
- generic Redis infrastructure
- CI / static analysis methodology
- Dialyzer / Sobelow methodology
- memory / GC / runtime methodology
- cross-cutting runtime tooling

Explicit exclusion:

- `InventoryAdmission.Redis` business semantics (requires S0 authority)
- S0 architecture
- subscription commercial rules

Exception note: generic Redis infrastructure ≠ InventoryAdmission Redis business semantics.

PLATFORM may progress without S0 finishing, unless an exact task declares a validated external dependency.

**Activation:** the accepted PLATFORM development base is `cc605040bfc8ddd6868a62de20f52c905f999835`. PLATFORM lifecycle is `READY`, and PLATFORM implementation is authorized through explicit task admission.

An advance of `origin/main` does not by itself invalidate the PLATFORM development base or stop an active PLATFORM task.

At task admission, inspect current canonical governance and evaluate only task-relevant changes.

A PLATFORM task stops for main movement only when the newer canonical state specifically changes or invalidates:

- PLATFORM ownership or exclusions;
- the task's required shared dependency;
- shared runtime/configuration used by the task;
- schema/migration authority;
- the task's affected files or contracts; or
- the accepted PLATFORM development base itself.

Ordinary unrelated main movement is not a stop condition.

Convergence with current canonical `main` is required before final integration. Do not fast-forward the platform branch merely to acquire unrelated registry updates.

### SUBS (Subscription Backbone)

Role: independent Subscription hardening programme.

Primary authority:

- `Subscription`
- `SubscriptionPlan`
- `SubscriptionItem`
- `RenewalAttempt`
- renewal scheduling
- dunning
- cancellation
- plan / variant changes
- subscription commercial contract law
- subscription-specific reconciliation and certification

Explicit exclusions unless separately authorized by the owning authority:

- `InventoryAdmission`
- generic dependency/platform work
- auth platform
- migrations
- Payments core
- Orders core
- generic Entitlements infrastructure

SUBS may progress without S0 finishing, unless an exact task declares a validated external dependency.
SUBS does **not** continuously consume S0 as parent authority.

Cross-domain mutations still require the owning workstream or domain authority.

The following law remains frozen and is not reopened by this execution-model change:

- JC-219
- JC-220
- JC-221
- JC-222
- JC-223
- existing frozen Subscription lifecycle and scheduling law

Stage B remains frozen and canonical. `SBH-00-01` through `SBH-00-04` are `CONTRACT_FROZEN / CANONICAL` governance/review records with `loop_eligible = No`. The subsequent JC-223 dependency-graph freeze records `SBH-00-05 / JC-223` as `CONTRACT_FROZEN / CANONICAL` governance/review work with `loop_eligible = No`.

`PR #8` itself did not activate SUBS. SUBS subsequently completed its independent activation gates. The current SUBS authority tip is `80d44613dc45a26ecb34a8eb6cbad8cce1e4f0c1`, the verified PR #31 v0.1.8 runtime-transition merge commit; it is not the development base. The prior `08f5db67f7bf524ecd7fcf77d54a1ab27ecfe6e3` PR #29 dynamic-governance-authority merge, the earlier `317d3c1e4304f671162b53f9d31a060682849e9e` PR #27 authority-reconciliation merge, and the earlier `8f93e0c9b6edc083093c74cc8e6243259683d50b` JC-223 dependency-graph / governance-freeze merge remain historical provenance. JC-219, JC-220, JC-221, JC-222, and JC-223 are repository-canonical. The accepted development base remains `575ffa1848ac69abe855bd018c7ae8eaf05d61e4`.

### SUBS execution policy: SERIAL / EXPLICIT HARDENING

`SUBS lifecycle = READY`.

Lifecycle is separate from execution policy. The current SUBS execution policy is:

```text
SERIAL / EXPLICIT HARDENING

human explicitly selects one canonical READY issue
    ↓
verify current governance + SUBS authority
    ↓
materialize bounded task scope
    ↓
one task branch
    ↓
TDD / minimal implementation
    ↓
focused verification
    ↓
fresh independent review
    ↓
required repository quality gates / CI
    ↓
human merge decision
    ↓
refresh canonical SUBS authority
    ↓
only then select the next issue
```

At most one SUBS implementation issue may be active through this serial workflow at a time. Future governance must explicitly change that rule before more than one issue may be active. Do not create a persistent `ACTIVE_SERIAL` lifecycle value.

READY issues may be implemented serially and explicitly only under the admission, scope, review, and CI rules below. `loop_eligible` may remain historical or register metadata, but it is not the execution-admission switch. Do not manufacture READY work.

#### Serial task admission

A SUBS issue may be implemented only when all of the following are true:

- its register state is `READY`
- relevant Product, Architecture, and Domain law is frozen
- acceptance criteria are deterministic
- the user or human explicitly selects that issue
- current `origin/main` governance is inspected
- current `origin/hardening/subscriptions` is inspected
- required external dependencies are present
- required shared authority is assigned
- the task has a bounded objective
- allowed and forbidden write scope are explicit

#### Per-task execution

Every selected issue requires:

- one bounded task
- explicit authority
- exact allowed and forbidden scope
- TDD where implementation changes are required
- a minimal change
- focused tests
- named neighbouring regressions where relevant
- performance and scaling consideration
- security and multi-tenant consideration
- fresh independent read-only review
- required repository quality gates
- required PR CI
- no automatic merge

If implementation reveals a new authority problem, scope expansion, shared-boundary dependency, migration requirement, or upstream contradiction, stop at the owning authority level.

#### Branch and base rule

Do not freeze a multi-task batch base. For each new serial issue:

1. fetch current refs
2. verify the current canonical `hardening/subscriptions` tip
3. create that issue's task branch from the current explicitly accepted SUBS tip
4. record that exact base in the task evidence
5. do not silently rebase during the task

After a task is merged, refresh the canonical SUBS tip before selecting another issue. Each issue therefore receives a fresh current base instead of sharing a frozen autonomous batch base.

#### Historical controller and batch provenance

The following references remain historical/controller provenance. They no longer form the implementation-admission mechanism for new serial SUBS tasks:

- autonomous SUBS implementation batches
- automatic READY task selection
- `SUB-ACT-04` as an implementation-admission gate
- `ACTIVE_PARALLEL` as a prerequisite for implementation
- `batch_base_sha` as a prerequisite for serial tasks
- `SUBS-BATCH-001` and future autonomous batch identifiers
- `successful_pr_count` batch ceilings
- multi-task same-batch independence admission
- persistent controller task claims
- autonomous 0–3 PR execution
- controller-specific CI wait-cycle accounting

External SUBS controller runtime and Batch 001 evidence remain historical evidence. Do not rewrite or delete that evidence. It does not grant implementation authority after this amendment becomes canonical, and runtime reconciliation is not required to execute future serial issues.

#### Existing PR #33 evidence

PR #33 remains bounded implementation evidence:

- Task: `SBH-30-02`
- PR: `#33`
- Current task HEAD: `a03a4534d6373dd9a0ff99c32c95b30d62f918f8`

The autonomous-loop retirement does not declare PR #33 successful and does not authorize merge while required CI is red. Its existing implementation and review evidence remains valid historical evidence unless its HEAD changes or new contradictory evidence appears.

Under the serial model, required CI must pass before merge. Unrelated CI or platform failures must not be repaired inside SBH-30-02 without authority. Controller-specific batch or resumption state no longer determines whether the task may be manually reviewed or revalidated. Any source change to PR #33 requires normal focused verification, fresh review, and exact-head CI again.

Do not rerun CI or alter PR #33 in a governance task.

### SUBS main-to-branch reconciliation record

The bounded reconciliation of accepted canonical `main` runtime/governance into
`hardening/subscriptions` is **complete**. PR #88 accepted the integration. This
record preserves historical provenance; it does not reopen SUBS lifecycle law,
serial execution policy, or SBH-10-04 shared-authority status.

Historical integration inputs (frozen provenance):

- Accepted runtime integration base on canonical `main`:
  `59a166c8cfba73bc1c239775cc326936a1f7b1ad` (PR #86 merge into `main`).
- SUBS source head at integration start:
  `fa26c01e4c4dbe312e5445915839f7f4a5eb8bef`.

Governance prerequisite on `main` before final SUBS merge:

- PR #89 merged into `main` as `a3a8e8b2c5b9a372fcff2a68a69e72f6418dd1b7`.
- PR #89 exact-head CI run `36535488158`: `PASS`.
- PR #89 exact-main CI run `36538649644`: `PASS`; all five required jobs passed.

Reconciliation path on temporary branch `integration/subscriptions-main-59a166c`
(preserved commit evidence only):

- `12bb5631959bbe485012d532a75960b18958973f`
- `d04587a40216ecc96c1f25f32a142f613ca42188` (reconciled accepted `main` /
  PR #89 perf DB safety governance into the integration line)
- Reviewed merge candidate `2849e9fe642c5ce76e132779128e3db9a4acc77c`

Accepted integration merge:

- PR #88 merged into `hardening/subscriptions` as
  `f621d2db355d3ef2c1531f73b0c698a323cc768e`.
- Merge parents: `fa26c01e4c4dbe312e5445915839f7f4a5eb8bef` and
  `2849e9fe642c5ce76e132779128e3db9a4acc77c`.
- Merge commit tree `99eb23e6561b7dafb504656acce0e115d9a4eed2` equals the
  reviewed candidate tree; the merge introduced no content drift.
- PR #88 candidate exact-head CI run `36542911205`: `PASS`; all five required
  jobs passed.

Resulting persistent SUBS tip after acceptance:
`origin/hardening/subscriptions` =
`f621d2db355d3ef2c1531f73b0c698a323cc768e`.

SUBS lifecycle remains `READY` under SUB-ACT-03 and the serial execution policy
above. `SBH-10-04` remains `BLOCKED_SHARED_AUTHORITY` until a separate governed
re-admission path succeeds; this integration does not authorize SBH-10-04
implementation.

The accepted SUB-ACT-01 development base
`575ffa1848ac69abe855bd018c7ae8eaf05d61e4` remains activation provenance; it
is not replaced by this reconciliation record.

The PLATFORM reconciliation is recorded separately below. This SUBS closure
does not alter PLATFORM lifecycle or authorize PLATFORM work.

The temporary integration workstream `integration/subscriptions-main-59a166c` is
`COMPLETE` / `VERIFIED_ON_TARGET` through PR #88 and is no longer active.

### PLATFORM main-to-branch reconciliation record

The bounded reconciliation of accepted canonical `main` into
`hardening/platform-security` is complete. PR #91 accepted the integration.
This record preserves PLATFORM's independent lifecycle and development-base
semantics above. It does not change either.

Canonical `main` source:

- PR #90 candidate `c9dae2080a6f05df18c277d66530883e813e66dd` merged into
  `main` as `7f5545117f1cc965b0529787705ec2a1969af32a`.
- PR #90 exact-main CI run `36555509169`: `PASS`; all five required jobs passed.

Historical integration inputs:

- Platform source before reconciliation:
  `435924ae2b9c819c8d4f820c5b316d154f3be2b0`.
- Accepted main reconciliation source:
  `7f5545117f1cc965b0529787705ec2a1969af32a`.

Reconciliation path on temporary branch `integration/platform-main-7f554511`:

- Reviewed integration candidate `d1d7ac3e278f6f07aaa14c752ceb25f3bac8d060`.
- Candidate parents: `435924ae2b9c819c8d4f820c5b316d154f3be2b0` and
  `7f5545117f1cc965b0529787705ec2a1969af32a`.

Accepted integration:

- PR #91 merged into `hardening/platform-security` as
  `8a113dac52d19bebf067018a1484055612e71ea6`.
- Merge parents: `435924ae2b9c819c8d4f820c5b316d154f3be2b0` and
  `d1d7ac3e278f6f07aaa14c752ceb25f3bac8d060`.
- PR #91 exact-head CI run `36562911494`: `PASS`; all five required jobs passed.
- Merge and candidate tree `9fa843480403ab15d0668c2ebe52a5e17c4824ad` are
  equal, so the merge introduced no content drift.

The temporary integration workstream `integration/platform-main-7f554511` is
`COMPLETE` / `VERIFIED_ON_TARGET` through PR #91 and is no longer active.

### SUBS activation record: SUB-ACT-03

This record is historical activation evidence. It establishes the current SUBS lifecycle as `READY`; it does not define the current serial task-admission policy.

Initial canonical state:

```text
BOOTSTRAPPED
```

Ordered transitions:

```text
BOOTSTRAPPED
    ↓ SUB-ACT-01 accepted development base
BASELINE_PINNED
    ↓ SUB-ACT-02 == ACTIVATION_FEASIBILITY_PASS
READY
```

Transition 1 guard:

```text
SUB-ACT-01 accepted development base
575ffa1848ac69abe855bd018c7ae8eaf05d61e4
```

Transition 2 guard:

```text
SUB-ACT-02 == ACTIVATION_FEASIBILITY_PASS
ACT-02 provenance: SUB_ACT_02_RUNTIME_PROVENANCE_RECONCILED
```

Resulting current state: `READY`.

The activation transition initially made `SBH-00-01` and `SBH-00-02` available as governance/review work. The subsequent Stage B freeze records `SBH-00-01` through `SBH-00-04` as `CONTRACT_FROZEN / CANONICAL`; the subsequent JC-223 dependency-graph freeze records `SBH-00-05 / JC-223` the same way. All remain governance/review work with `loop_eligible = No`.

SUB-ACT-02 produced `ACTIVATION_FEASIBILITY_PASS` as a read-only activation-feasibility verdict and did not mutate runtime state.

SUB-ACT-02P subsequently reconciled and accepted the persisted `activation_feasibility = ACTIVATION_FEASIBILITY_PASS` runtime value through deterministic reconstruction. Its provenance result is `SUB_ACT_02_RUNTIME_PROVENANCE_RECONCILED`.

The accepted persisted-state provenance is historical metadata. In particular, `batch_base_sha = null` is evidence from that record, not a current prerequisite for a serial task.

The accepted persisted-state provenance is:

```text
historical_writer = unknown
historical_provenance = inconclusive
current_state_acceptance = AUTHORIZED_BY_DETERMINISTIC_RECONSTRUCTION
schema_version = 1.4
activation_feasibility = ACTIVATION_FEASIBILITY_PASS
development_base_sha = 575ffa1848ac69abe855bd018c7ae8eaf05d61e4
batch_base_sha = null
integration_base_sha = null
terminal_outcome = null
```

| Transition | Guard | Side effect | Terminal |
| --- | --- | --- | --- |
| `BOOTSTRAPPED → BASELINE_PINNED` | accepted SUB-ACT-01 development base | canonical development base recorded | No |
| `BASELINE_PINNED → READY` | `ACTIVATION_FEASIBILITY_PASS` with reconciled provenance | `SBH-00-01` and `SBH-00-02` initially become available as governance/review work | No |

The following invalid-transition entries are retained as historical SUB-ACT-03 provenance:

```text
BOOTSTRAPPED → READY without BASELINE_PINNED evidence
READY → ACTIVE_PARALLEL in ACT-03
BOOTSTRAPPED → ACTIVE_PARALLEL
READY → Batch 001 started
```

Any invalid activation transition is `INVALID_ACTIVATION_TRANSITION → STOP` in the historical activation record.

Historically, `SUB-ACT-03` did not set `ACTIVE_PARALLEL`, freeze `batch_base_sha`, start Batch 001, or authorize production Subscription implementation. Those historical entries do not make `ACTIVE_PARALLEL`, `batch_base_sha`, Batch 001, or `SUB-ACT-04` prerequisites for the current serial process.

### Performance & Scaling Review

This governance record changes no production performance architecture.

| Area | Result |
| --- | --- |
| production PostgreSQL | unchanged |
| Redis | unchanged |
| ETS/Cachex | unchanged |
| Oban | unchanged |
| PubSub | unchanged |
| indexes | unchanged |
| TTL | unchanged |
| production DB calls | none |
| 100k concurrency | unchanged |
| latency | unchanged |

---

## Shared boundaries (no default owner)

These MUST never receive implicit ownership:

- Payments
- Orders
- Entitlements
- migrations
- Ash snapshots
- shared config
- provider business contracts
- `AGENTS.md`
- `docs/agent_rules/**` (except when a governance task explicitly owns a bounded edit)

For each task touching one of these:

`UNOWNED/SHARED` → `AUTHORITY_ASSIGNED` → `MODIFICATION`

No authority decision = no modification.

Do not weaken this protection to gain parallelism.

---

## Workstream state machine

Persistent hardening programmes that use the parallel execution model use:

```text
BOOTSTRAPPED
    ↓
BASELINE_PINNED
    ↓
READY
    ↓
ACTIVE_PARALLEL
    ↓
VALIDATED
    ↓
INTEGRATION_SYNC_REQUIRED
    ↓
INTEGRATION_VERIFIED
    ↓
READY_FOR_INTEGRATION
    ↓
INTEGRATED
```

`MAIN` uses `CANONICAL` instead of the implementation ladder.

SUBS does not use `ACTIVE_PARALLEL` or any downstream parallel state for issue execution. Its lifecycle remains `READY`, and its serial execution policy governs each explicitly selected issue. Do not add an `ACTIVE_SERIAL` lifecycle state.

Exceptional states:

```text
BLOCKED_EXTERNAL_DEPENDENCY
BLOCKED_SHARED_AUTHORITY
BASELINE_INVALIDATED
AUTHORITY_MOVED
```

Task-level blockers are normally **task** states.
Do not demote an entire workstream merely because one task is blocked.

`PR #8` itself did **not** transition S0, PLATFORM, or SUBS to `READY` or `ACTIVE_PARALLEL`. SUB-ACT-03 records only the separately evidenced SUBS transition to `READY`. S0's later activation is recorded under its S0-specific activation record above; the current PLATFORM activation and accepted development base are recorded above. The `ACTIVE_PARALLEL` reference is retained as historical state evidence and is not a current SUBS implementation prerequisite.

---

## Integration law (strict)

Parallel development must not weaken integration safety.

Before any hardening lane reaches `READY_FOR_INTEGRATION`:

```text
identify latest accepted canonical main
    ↓
enter INTEGRATION_SYNC_REQUIRED
    ↓
controlled reconciliation
    ↓
resolve conflicts
    ↓
complete relevant regression
    ↓
verify shared boundaries
    ↓
migration/snapshot verification if applicable
    ↓
exact-head CI
    ↓
independent review
    ↓
INTEGRATION_VERIFIED
    ↓
READY_FOR_INTEGRATION
```

Do **not** require continuous main synchronization during ordinary independent hardening.

---

## Independent activation after governance acceptance

There is **no** global serial activation sequence of the form:

```text
main → S0 convergence → PLATFORM activation → SUBS activation
```

and **no** global:

```text
S0 → PLATFORM → SUBS
```

activation order.

After this parallel-topology governance is accepted:

```text
                  GOVERNANCE ACCEPTED
                         │
              ┌──────────┼──────────┐
              │          │          │
              ▼          ▼          ▼
          S0 GATE   PLATFORM GATE  SUBS GATE
```

- S0 is `READY` under its S0-specific activation record and may accept explicitly admitted tasks.
- PLATFORM is `READY` under the accepted development base above and may accept explicitly bounded tasks.
- SUBS remains `READY` as recorded by SUB-ACT-03 and uses the serial execution policy above.

The SUBS gate in the topology diagram is the completed SUB-ACT-03 activation record, not a new autonomous implementation gate.

No lane requires another lane to finish first unless its exact task declares a validated external dependency.

`PR #8` did not run the S0 or PLATFORM gates. The S0 gate later completed under the S0-specific activation record above. This SUB-ACT-03 record records only the completed SUBS gate sequence; the current PLATFORM activation is recorded above.

---

## Next authorized control-plane action

After this parallel-topology governance is accepted and verified:

- S0 is `READY` under its S0-specific activation record and may accept explicitly admitted tasks.
- PLATFORM is `READY` under the accepted development base above and may begin explicitly admitted implementation tasks.
- SUBS remains `READY` as recorded by SUB-ACT-03 and may begin a serial issue only after the admission rules above pass.

No lane requires another lane to finish first unless its exact task declares a validated external dependency.

Until a lane's own activation gate succeeds, that lane remains `BOOTSTRAPPED` and must not begin programme implementation. SUBS has completed the activation recorded by SUB-ACT-03 and remains `READY`; S0 is `READY` under its S0-specific activation record; PLATFORM is `READY` under the activation record above.

S0 `READY` does not itself authorize production implementation. S0 tasks require separate explicit task admission. As of the IA-04 admission record below, GitHub #101 IA-04 is `AUTHORIZED / NOT STARTED` on accepted S0 tip `f2d3ed27476d1d8bfdda2a28dcdbfe6a1d02e2d9`; IA-05+ remains `NOT AUTHORIZED`. PLATFORM implementation is authorized only for explicitly admitted tasks under the READY law above. SUBS `SBH-00-01` through `SBH-00-04`, and `SBH-00-05 / JC-223`, are available only as governance/review work and are `CONTRACT_FROZEN / CANONICAL`.

---

## Pending ownership-relevant PRs

| PR | Title / subject | Belongs to | Status | Bootstrap note |
| --- | --- | --- | --- | --- |
| #2 | Memory / GC / runtime methodology | Platform | OPEN against `main` from older `main` | Requires later Platform reconciliation against current `main`; do not review/rebase/retarget/merge from this registry task |

### Recently resolved ownership gates and integrations

| PR | Title / subject | Belongs to | Status | Resulting authority |
| --- | --- | --- | --- | --- |
| #6 | S0-IA-AUTH-03R1 governance correction (IA-03 Redis status/abandon boundary) | S0 | **MERGED** / **RESOLVED** into `hardening/s0-baseline` | `origin/hardening/s0-baseline` tip observed below (candidate evidence only) |
| #9 | PLAT-PERF-01 RedisPool teardown ownership | Platform | **CLOSED** / **SUPERSEDED BY PR #86** | PR #9 must not be merged independently; its accepted integration is recorded under PR #86 |
| #86 | Workstation infrastructure and PR #9 lifecycle semantic integration | Platform | **MERGED** / **ACCEPTED** | Merge SHA `59a166c8cfba73bc1c239775cc326936a1f7b1ad`; exact-main CI run `36406423871` attempt 1 failed only `performance_smoke_required`, and attempt 2 passed all five required jobs |
| #89 | Performance smoke destructive DB safety guard | Platform / `main` | **MERGED** / **ACCEPTED** into `main` | Merge SHA `a3a8e8b2c5b9a372fcff2a68a69e72f6418dd1b7`; exact-head CI run `36535488158` `PASS`; exact-main CI run `36538649644` `PASS` (all five required jobs) |
| #88 | Reconcile accepted main runtime base into SUBS | SUBS | **MERGED** / **ACCEPTED** into `hardening/subscriptions` | Merge SHA `f621d2db355d3ef2c1531f73b0c698a323cc768e`; merge parents `fa26c01e4c4dbe312e5445915839f7f4a5eb8bef` and `2849e9fe642c5ce76e132779128e3db9a4acc77c`; candidate exact-head CI run `36542911205` `PASS` (all five required jobs); merge tree equals reviewed candidate tree `99eb23e6561b7dafb504656acce0e115d9a4eed2` |
| #90 | docs(governance): post-PR-88 SUBS reconciliation closure | SUBS / `main` | **MERGED** / **ACCEPTED** into `main` | Merge SHA `7f5545117f1cc965b0529787705ec2a1969af32a`; candidate `c9dae2080a6f05df18c277d66530883e813e66dd`; exact-main CI run `36555509169` `PASS` (all five required jobs) |
| #91 | Reconcile Platform hardening with canonical main | Platform | **MERGED** / **ACCEPTED** into `hardening/platform-security` | Merge SHA `8a113dac52d19bebf067018a1484055612e71ea6`; candidate `d1d7ac3e278f6f07aaa14c752ceb25f3bac8d060`; exact-head CI run `36562911494` `PASS` (all five required jobs); merge tree equals candidate tree `9fa843480403ab15d0668c2ebe52a5e17c4824ad` |

PR #6 authorized a governance/docs correction only. It did **not** implement IA-03.

The `workstation-infra-pr9-semantic-reconcile` temporary integration workstream is `COMPLETE` / `VERIFIED_ON_TARGET` through PR #86 and is no longer active.

The `integration/subscriptions-main-59a166c` temporary integration workstream is `COMPLETE` / `VERIFIED_ON_TARGET` through PR #88 and is no longer active.

---

## Agent start checklist

Every agent opened in a persistent worktree MUST:

1. Confirm `pwd` matches the intended persistent worktree path in this registry
2. Confirm the intended persistent worktree (MAIN / S0 / PLATFORM / SUBS)
3. Confirm `git branch --show-current` matches the registry branch
4. Confirm upstream tracking when present
5. Run `git status -sb` and require a clean tree unless dirt is already intentionally owned
6. `git fetch origin`
7. Read canonical `AGENTS.md` from accepted governance authority (`git show origin/main:AGENTS.md`)
8. Read canonical active-workstream registry from accepted governance authority (`git show origin/main:docs/agent_rules/active_workstreams.md`) — after this PR merges; until then use the accepted PR/governance head for this file
9. Verify this lane's accepted development base (do **not** merge main merely to obtain governance documents)
10. Load the exact task contract
11. Evaluate task-specific external dependencies against the development base
12. Evaluate shared-authority requirements
13. Record the exact task base SHA; do not freeze a multi-task batch base
14. STOP on a genuine mismatch

Before any modification, explicitly state:

```text
WORKSTREAM:
PATH:
BRANCH:
HEAD:
UPSTREAM:
DEVELOPMENT_BASE:
INTEGRATION_BASE:
OWNED AREA:
EXCLUDED AREA:
LIFECYCLE STATE:
TASK:
EXTERNAL_DEPENDENCY_CHECK:
SHARED_AUTHORITY_CHECK:
```

---

## STOP conditions

STOP immediately if:

- wrong worktree
- wrong branch
- unexpected / unowned dirt
- governance authority moved unexpectedly
- development base invalidated
- shared authority missing for a shared-boundary change
- task-specific external dependency unresolved
- task contract ambiguous
- integration required for this exact task
- a force push or history rewrite would be required without explicit authorization
- work would require implementing directly on `main` in the permanent main worktree

Do **not** globally STOP merely because another independent workstream advanced.

On STOP: make no speculative correction. Report evidence and wait for authority.

---

## Update rule

Update this file only via an explicit governance or ownership-authority task (dedicated branch/worktree or authorized workstream PR).

When updating:

- keep `AGENTS.md` as permanent law
- refresh lifecycle states, pending PRs, and ownership assignments here
- record SHAs as status / candidate evidence only, never as frozen forever-law
- do not claim a PR merged unless GitHub shows it merged
- do not set S0 to `READY` through a registry-only change unless a reviewed S0-specific activation record evidences both ordered guards; keep later S0 slices unauthorized absent a separate bounded task-admission decision; the current PLATFORM activation and accepted development base are recorded above; keep SUBS at `READY` as recorded by SUB-ACT-03 and require serial admission for new implementation

### Current status / candidate development-base evidence (refresh when tips move)

This section records dynamic status only. It does not override the accepted PLATFORM lifecycle or development base above. Refresh from origin before any S0 activation gate or new task admission.

- `origin/main` = `35bc644e91a07b262b471cfb718572e590f926f7` at this refresh (canonical main before this governance PR); resolve with `git fetch origin && git rev-parse origin/main` before work. PR #23 base authority was `f0d0994e6d4d6c4c3f5966c5d00c9fa6739c475f`.
- `origin/hardening/s0-baseline` = `f2d3ed27476d1d8bfdda2a28dcdbfe6a1d02e2d9` (current fetched persistent S0 tip after PR #117 renewal-generation prerequisite merge)
- `origin/hardening/platform-security` = `8a113dac52d19bebf067018a1484055612e71ea6` (current fetched persistent PLATFORM tip after PR #91 reconciliation)
- `origin/hardening/subscriptions` = `bd0555c41bb014326b0754329f2ca5fbf0f8911b` (current persistent SUBS tip after PR #99 / v0.1.33 authority consumption)
- PR #90 = MERGED / ACCEPTED into `main`
- PR #91 = MERGED / ACCEPTED into `hardening/platform-security`
- PR #6 = MERGED into `hardening/s0-baseline`
- PR #115 = MERGED / ACCEPTED into `hardening/s0-baseline`; exact merge tree equals
  the certified generic IA-03 tree `b4e3bf388433d7f7b17931c777ad0e33fb318102`
- PR #117 = MERGED / POST-MERGE VERIFIED into `hardening/s0-baseline` as
  `f2d3ed27476d1d8bfdda2a28dcdbfe6a1d02e2d9`; certified head
  `aaf33a1abf68d65c00b8cf10a43225350c5bbdc5`; exact-head CI `36968312583` PASS;
  certified-head to merge comparison has zero changed files
- PR #2 = OPEN against `main` (Platform; later reconciliation)
- PR #88 = MERGED / ACCEPTED into `hardening/subscriptions` (SUBS main reconciliation complete; see SUBS main-to-branch reconciliation record)
- PR #89 = MERGED / ACCEPTED into `main`

SUBS main-to-branch reconciliation is **complete** through PR #88. Historical integration provenance remains:
`main` runtime integration base `59a166c8cfba73bc1c239775cc326936a1f7b1ad`, SUBS source
`fa26c01e4c4dbe312e5445915839f7f4a5eb8bef`, and integration-branch commits
`12bb5631959bbe485012d532a75960b18958973f`, `d04587a40216ecc96c1f25f32a142f613ca42188`,
and `2849e9fe642c5ce76e132779128e3db9a4acc77c`. Ordinary independent PLATFORM
hardening does not require continuous `main` synchronization. The bounded
Platform reconciliation and its historical provenance are recorded above.

Earlier topology-bootstrap commissioning evidence (historical only):

- bootstrap `origin/main` was `7a89dc20aa4b2a261ed6bb96f1d3182254d0b7d3`
- bootstrap `origin/hardening/s0-baseline` was `77a272c3887a7ab46e84a7fed02163d964e37b9b`
- PR #6 head was `602d85d12a3d1c990a14b934f53582b84665fffa`
- PR #2 head was `cfd9be7491230edf4c1bde3281b78db3e4ca12a8`

### Historical serial model (superseded)

Prior registry versions encoded a serial control plane:

```text
latest main → converge into S0 → then activate PLATFORM/SUBS
```

and treated S0 tip movement as a blanket `WAITING_FOR_BASELINE_SYNC` stopper for SUBS/PLATFORM.

That global serial activation model is **superseded** by this document. Retain this note only as historical context.
