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

This registry grants **no** implementation authority by itself. Each hardening lane requires a separate post-merge activation gate.

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
| `S0` | `/home/jcschoeman96/projects/current/Store_Blueprint_Hardening` | `hardening/s0-baseline` | `e16767e92ac22ca7a108f13677052c63bb13c3f2` (explicitly human-accepted; exact-head review `PASS`; PR #51 merged provenance) | `origin/main` | `BOOTSTRAPPED` (parallel activation gate required) | Topology only until activated |
| `PLATFORM` | `/home/jcschoeman96/projects/current/Store_Blueprint_Hardening-platform` | `hardening/platform-security` | Own accepted SHA (activation gate) | `origin/main` | `BOOTSTRAPPED` (parallel activation gate required) | Topology only until activated |
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

**Activation:** this registry does **not** authorize IA-03 or other S0 implementation. The accepted development base is not implementation authority. S0 lifecycle remains `BOOTSTRAPPED`, and IA-03 remains **NOT AUTHORIZED**, pending a separate independent S0 activation/feasibility decision.

The explicitly human-accepted S0 development base is `e16767e92ac22ca7a108f13677052c63bb13c3f2`. Independent exact-head review result: `PASS` (CI run `35707962997`; `performance_smoke_required` `PASS`). PR #51 merged this accepted candidate into canonical `main` as `f0c6902d258e9e57528359f660c68e88f3aa7f62` and remains reconciliation/integration provenance. Integration into canonical `main` is not S0 activation or implementation authority.

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

**Activation:** do not begin Platform implementation from this registry alone. State remains `BOOTSTRAPPED` until an independent PLATFORM activation gate runs. Do **not** fast-forward the platform branch from registry updates alone.

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

`PR #8` itself did **not** transition S0, PLATFORM, or SUBS to `READY` or `ACTIVE_PARALLEL`. SUB-ACT-03 records only the separately evidenced SUBS transition to `READY`. S0 and PLATFORM remain independently `BOOTSTRAPPED`. The `ACTIVE_PARALLEL` reference is retained as historical state evidence and is not a current SUBS implementation prerequisite.

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

- S0 may run its independent activation gate.
- PLATFORM may run its independent activation gate.
- SUBS remains `READY` as recorded by SUB-ACT-03 and uses the serial execution policy above.

The SUBS gate in the topology diagram is the completed SUB-ACT-03 activation record, not a new autonomous implementation gate.

No lane requires another lane to finish first unless its exact task declares a validated external dependency.

`PR #8` did not run those gates. This SUB-ACT-03 record records only the completed SUBS gate sequence; it does not run or alter the S0 or PLATFORM gates.

---

## Next authorized control-plane action

After this parallel-topology governance is accepted and verified:

- S0 may run its independent activation gate.
- PLATFORM may run its independent activation gate.
- SUBS remains `READY` as recorded by SUB-ACT-03 and may begin a serial issue only after the admission rules above pass.

No lane requires another lane to finish first unless its exact task declares a validated external dependency.

Until a lane's own activation gate succeeds, that lane remains `BOOTSTRAPPED` and must not begin programme implementation. SUBS has completed the activation recorded by SUB-ACT-03 and remains `READY`; S0 and PLATFORM remain `BOOTSTRAPPED`.

This section does **not** authorize starting activation gates from an unrelated task, and does **not** authorize IA, Platform, Security, or SBH production implementation from this file alone. SUBS `SBH-00-01` through `SBH-00-04`, and `SBH-00-05 / JC-223`, are available only as governance/review work and are `CONTRACT_FROZEN / CANONICAL`.

---

## Pending ownership-relevant PRs

| PR | Title / subject | Belongs to | Status | Bootstrap note |
| --- | --- | --- | --- | --- |
| #2 | Memory / GC / runtime methodology | Platform | OPEN against `main` from older `main` | Requires later Platform reconciliation against current `main`; do not review/rebase/retarget/merge from this registry task |

### Recently resolved ownership gates

| PR | Title / subject | Belongs to | Status | Resulting authority |
| --- | --- | --- | --- | --- |
| #6 | S0-IA-AUTH-03R1 governance correction (IA-03 Redis status/abandon boundary) | S0 | **MERGED** / **RESOLVED** into `hardening/s0-baseline` | `origin/hardening/s0-baseline` tip observed below (candidate evidence only) |

PR #6 authorized a governance/docs correction only. It did **not** implement IA-03.

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
- do not self-activate S0 or PLATFORM from a registry-only change; keep SUBS at `READY` as recorded by SUB-ACT-03 and require serial admission for new implementation

### Current status / candidate development-base evidence (refresh when tips move)

Not implementation authority. Not frozen activation pins. Refresh from origin before any activation gate.

- `origin/main` = dynamic canonical governance ref; resolve with `git fetch origin && git rev-parse origin/main` before work. PR #23 base authority was `f0d0994e6d4d6c4c3f5966c5d00c9fa6739c475f`.
- `origin/hardening/s0-baseline` = `9b0b26a68399149abdde7c96529fbc1951e22cac` (current branch tip after governance cleanup propagation)
- `origin/hardening/platform-security` = `cc605040bfc8ddd6868a62de20f52c905f999835` (current branch tip after governance cleanup propagation)
- `origin/hardening/subscriptions` = `80d44613dc45a26ecb34a8eb6cbad8cce1e4f0c1` (verified PR #31 v0.1.8 runtime-transition merge; not the accepted development base)
- PR #6 = MERGED into `hardening/s0-baseline`
- PR #2 = OPEN against `main` (Platform; later reconciliation)

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
