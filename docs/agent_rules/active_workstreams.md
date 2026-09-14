# Active Workstream Registry

Dynamic authority registry for parallel hardening programmes.

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
- Make independent parallel activation of S0, PLATFORM, and SUBS legally possible after this governance is accepted

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
- frozen for the relevant activation/batch

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

```text
SELECT READY TASK
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
       │ consider another independent READY task
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
| `S0` | `/home/jcschoeman96/projects/current/Store_Blueprint_Hardening` | `hardening/s0-baseline` | Own accepted SHA (activation gate) | `origin/main` | `BOOTSTRAPPED` (parallel activation gate required) | Topology only until activated |
| `PLATFORM` | `/home/jcschoeman96/projects/current/Store_Blueprint_Hardening-platform` | `hardening/platform-security` | Own accepted SHA (activation gate) | `origin/main` | `BOOTSTRAPPED` (parallel activation gate required) | Topology only until activated |
| `SUBS` | `/home/jcschoeman96/projects/current/Store_Blueprint_Hardening-subscriptions` | `hardening/subscriptions` | `575ffa1848ac69abe855bd018c7ae8eaf05d61e4` (SUB-ACT-01 accepted) | `origin/main` | `READY` | Governance/review only; production implementation not authorized |

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

**Activation:** this registry does **not** authorize IA-03 or other S0 implementation. State remains `BOOTSTRAPPED` until an independent S0 activation gate accepts a development base and transitions the lane.

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

Explicit exclusion until separately authorized:

- `InventoryAdmission`
- generic dependency graph
- auth platform
- migrations
- Payments core
- Orders core
- generic Entitlements infrastructure

SUBS may progress without S0 finishing, unless an exact task declares a validated external dependency.
SUBS does **not** continuously consume S0 as parent authority.

**Activation:** SUB-ACT-03 records the separately completed SUBS activation gate. The canonical lifecycle is now `READY`, but this does not authorize Subscription production implementation. `SBH-00-01` and `SBH-00-02` are available as governance/review work only, with `loop_eligible = No`.

`PR #8` itself did not activate SUBS. SUBS subsequently completed its independent activation gates. The current SUBS authority tip is `54871ef3bdda42f067ed5dbd398305151610c060`; it is not the development base. The accepted development base remains `575ffa1848ac69abe855bd018c7ae8eaf05d61e4`.

Production Subscription implementation remains blocked until all of the following are complete:

- `SBH-00` governance/contract freeze
- `SBH-00-05` executable dependency graph
- `SUB-ACT-04`
- `batch_base_sha` frozen
- implementation-admission recertification passed
- an executable `READY` task exists

`ACTIVE_PARALLEL` is not granted. Batch 001 has not started, and `batch_base_sha` is not frozen.

### SUBS activation record: SUB-ACT-03

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

The transition side effects are limited to recording the accepted development base and making `SBH-00-01` and `SBH-00-02` available as governance/review work. Both remain `loop_eligible = No`.

SUB-ACT-02 produced `ACTIVATION_FEASIBILITY_PASS` as a read-only activation-feasibility verdict and did not mutate runtime state.

SUB-ACT-02P subsequently reconciled and accepted the persisted `activation_feasibility = ACTIVATION_FEASIBILITY_PASS` runtime value through deterministic reconstruction. Its provenance result is `SUB_ACT_02_RUNTIME_PROVENANCE_RECONCILED`.

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
| `BASELINE_PINNED → READY` | `ACTIVATION_FEASIBILITY_PASS` with reconciled provenance | `SBH-00-01` and `SBH-00-02` become available as governance/review work | No |

Invalid transitions for this record include:

```text
BOOTSTRAPPED → READY without BASELINE_PINNED evidence
READY → ACTIVE_PARALLEL in ACT-03
BOOTSTRAPPED → ACTIVE_PARALLEL
READY → Batch 001 started
```

Any invalid activation transition is `INVALID_ACTIVATION_TRANSITION → STOP`.

`SUB-ACT-03` does not set `ACTIVE_PARALLEL`, freeze `batch_base_sha`, start Batch 001, or authorize production Subscription implementation. `ACTIVE_PARALLEL` remains an ACT-04-controlled outcome.

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

Persistent hardening programmes use:

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

Exceptional states:

```text
BLOCKED_EXTERNAL_DEPENDENCY
BLOCKED_SHARED_AUTHORITY
BASELINE_INVALIDATED
AUTHORITY_MOVED
```

Task-level blockers are normally **task** states.
Do not demote an entire workstream merely because one task is blocked.

`PR #8` itself did **not** transition S0, PLATFORM, or SUBS to `READY` or `ACTIVE_PARALLEL`. SUB-ACT-03 records only the separately evidenced SUBS transition to `READY`. S0 and PLATFORM remain independently `BOOTSTRAPPED`.

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
- SUBS activation is recorded separately by SUB-ACT-03.

No lane requires another lane to finish first unless its exact task declares a validated external dependency.

`PR #8` did not run those gates. This SUB-ACT-03 record records only the completed SUBS gate sequence; it does not run or alter the S0 or PLATFORM gates.

---

## Next authorized control-plane action

After this parallel-topology governance is accepted and verified:

- S0 may run its independent activation gate.
- PLATFORM may run its independent activation gate.
- SUBS activation is recorded by SUB-ACT-03.

No lane requires another lane to finish first unless its exact task declares a validated external dependency.

Until a lane's own activation gate succeeds, that lane remains `BOOTSTRAPPED` and must not begin programme implementation. SUBS is `READY` only as recorded by SUB-ACT-03; S0 and PLATFORM remain `BOOTSTRAPPED`.

This section does **not** authorize starting activation gates from an unrelated task, and does **not** authorize IA, Platform, Security, or SBH production implementation from this file alone. SUBS `SBH-00-01` and `SBH-00-02` are available only as governance/review work.

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
13. Freeze the exact batch/task base SHA
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
- do not self-activate S0 or PLATFORM from a registry-only change; record SUBS activation only through an explicit SUB-ACT task

### Current status / candidate development-base evidence (refresh when tips move)

Not implementation authority. Not frozen activation pins. Refresh from origin before any activation gate.

- `origin/main` = `56f06d028ec38896f5a927f54dc7adfcb20034a3` (PR #8 merge)
- `origin/hardening/s0-baseline` = `0fe372d1ef435b9826908ed41725457fdf78c034` (includes PR #6 merge)
- `origin/hardening/platform-security` = `7a89dc20aa4b2a261ed6bb96f1d3182254d0b7d3`
- `origin/hardening/subscriptions` = `54871ef3bdda42f067ed5dbd398305151610c060` (current authority tip; not the accepted development base)
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
