# Active Workstream Registry

Dynamic authority registry for parallel hardening programmes.

`AGENTS.md` is permanent law. This file records the **current** workstream topology, ownership, lifecycle state, and ownership-relevant pending PRs.

Before beginning any work, agents MUST read this file. If this registry conflicts with actual Git state, STOP.

Do not treat transient SHAs below as permanent law; they are commissioning/status evidence only and must be refreshed when authority moves.

---

## Purpose

- Name the persistent programme worktrees and their branches
- Declare parent authority, owned domains, exclusions, and shared boundaries
- Record lifecycle state so agents do not start unauthorized implementation
- Point to pending PRs that affect ownership or baseline sync

---

## Persistent workstreams

| ID | Path | Branch | Parent authority | Lifecycle state | Writable by long-lived agent? |
| --- | --- | --- | --- | --- | --- |
| `MAIN` | `/home/jcschoeman96/projects/current/Store_Blueprint_Hardening-main` | `main` | `origin/main` | `CANONICAL` | Normally no (observe / post-merge verify) |
| `S0` | `/home/jcschoeman96/projects/current/Store_Blueprint_Hardening` | `hardening/s0-baseline` | Existing S0 authority (`origin/hardening/s0-baseline`) | `BASELINE_STALE` / `SYNC_REQUIRED` | Yes (topology / sync only until re-verified; **no IA-03**) |
| `SUBS` | `/home/jcschoeman96/projects/current/Store_Blueprint_Hardening-subscriptions` | `hardening/subscriptions` | S0 authority (`origin/hardening/s0-baseline` at branch creation) | `BOOTSTRAPPED` / `WAITING_FOR_BASELINE_SYNC` | Yes (topology only until activated) |
| `PLATFORM` | `/home/jcschoeman96/projects/current/Store_Blueprint_Hardening-platform` | `hardening/platform-security` | `origin/main` | `BOOTSTRAPPED` / `WAITING_FOR_BASELINE_SYNC` | Yes (topology only until activated) |

Temporary worktrees (governance / integration / review / task) may exist under names such as `Store_Blueprint_Hardening-governance-*`, `Store_Blueprint_Hardening-integration-*`, or `Store_Blueprint_Hardening-review-*`. They are disposable. Do **not** create a permanent integration worktree.

---

## Ownership

### MAIN

Owns:

- canonical history
- repository-wide governance (via reviewed PRs to `main`)
- accepted shared dependency/security baseline
- release / integration authority

Implementation in the permanent main worktree: **NONE**.

### S0

Primary authority:

- `InventoryAdmission`
- inventory reservation / admission architecture
- inventory contention / concurrency
- IA lifecycle / recovery
- S0 closure

Explicit exclusion:

- subscription commercial lifecycle
- dependency / platform modernization except explicit shared task

**Synchronization gate:** S0 advanced by merging PR #6 (S0-IA-AUTH-03R1) into `hardening/s0-baseline`. Latest canonical `main` has **not** yet been integrated into that S0 authority. Lifecycle is therefore `BASELINE_STALE` / `SYNC_REQUIRED`. This registry correction does **not** authorize IA-03 implementation.

### SUBS (Subscription Backbone)

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

**Activation gate:** do not begin Subscription Backbone Hardening (SBH) implementation merely because the worktree exists. Current state is `BOOTSTRAPPED` / `WAITING_FOR_BASELINE_SYNC` because:

- S0 has advanced to the PR #6 merge authority;
- latest canonical `main` has not yet been integrated into latest S0;
- the subscription branch must later be synchronized from the **accepted converged S0 authority** before SBH work starts.

Do **not** start or authorize SBH-00 from this registry alone.

### PLATFORM

Primary authority:

- `mix.exs` / `mix.lock`
- npm dependency graph
- Hex / npm advisories
- authentication framework / platform
- OAuth / security infrastructure
- HTTP / Req / Finch infrastructure
- generic Redis infrastructure
- CI / static analysis
- Dialyzer / Sobelow methodology
- memory / GC / runtime methodology
- cross-cutting runtime tooling

Explicit exclusion:

- `InventoryAdmission.Redis` business semantics (requires S0 authority)
- S0 architecture
- subscription commercial rules

Exception note: generic Redis infrastructure ≠ InventoryAdmission Redis business semantics.

**Activation gate:** `hardening/platform-security` currently has no independent commits ahead of `origin/main` and is behind latest canonical `main`. State is `BOOTSTRAPPED` / `WAITING_FOR_BASELINE_SYNC`. Platform activation must occur only after the control-plane convergence checkpoint. Do **not** fast-forward the platform branch from registry updates alone.

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

---

## Workstream state machine

Persistent programme workstreams use:

```text
BOOTSTRAPPED
    → BASELINE_VERIFIED
    → READY
    → ACTIVE
    → VALIDATED
    → READY_FOR_INTEGRATION
    → INTEGRATING
    → POST_INTEGRATION_REVIEW
    → COMPLETE
```

`MAIN` uses `CANONICAL` instead of the implementation ladder.

Exceptional:

```text
ACTIVE → BLOCKED_SHARED_AUTHORITY → STOP
ACTIVE → BASELINE_STALE → SYNC_REQUIRED → STOP / SYNC DECISION
BASELINE_STALE → BASELINE_VERIFIED → READY / ACTIVE
  (only after an accepted controlled integration)
```

Do not silently continue implementation through either exceptional state.
Do not transition S0 from `BASELINE_STALE` / `SYNC_REQUIRED` to `READY` / `ACTIVE` without that accepted integration.

---

## Pending ownership-relevant PRs

| PR | Title / subject | Belongs to | Status | Bootstrap note |
| --- | --- | --- | --- | --- |
| #2 | Memory / GC / runtime methodology | Platform | OPEN against `main` from older `main` | Requires later Platform reconciliation against current `main`; do not review/rebase/retarget/merge from this registry task |

### Recently resolved ownership gates

| PR | Title / subject | Belongs to | Status | Resulting authority |
| --- | --- | --- | --- | --- |
| #6 | S0-IA-AUTH-03R1 governance correction (IA-03 Redis status/abandon boundary) | S0 | **MERGED** / **RESOLVED** into `hardening/s0-baseline` | `origin/hardening/s0-baseline` = `0fe372d1ef435b9826908ed41725457fdf78c034` |

PR #6 authorized a governance/docs correction only. It did **not** implement IA-03.

---

## Next authorized control-plane action

After this registry reconciliation is merged and verified, the next authorized action is a **dedicated controlled main-to-S0 integration** workstream:

```text
latest canonical main
    +
latest hardening/s0-baseline
    →
dedicated controlled main-to-S0 integration workstream
    →
validation
    →
exact-head CI
    →
independent post-integration review
```

Until that completes:

| Workstream | Forbidden |
| --- | --- |
| S0 | no IA-03 implementation |
| SUBS | no SBH implementation |
| PLATFORM | no Platform implementation |

This section is a synchronization gate only. It does **not** authorize starting that integration from an unrelated task.

---

## Intended activation order after convergence

Sequencing information only — **not** current implementation authority:

```text
S0        → IA-03
PLATFORM  → PLAT-01 / PR #2 reconciliation
SUBS      → SBH-00 discovery/freeze
```

Do not mark any of the above active until convergence and synchronization succeed and a later governance update authorizes them.

---

## Agent start checklist

Every agent opened in a persistent worktree MUST:

1. Confirm `pwd` matches the intended worktree path in this registry
2. Confirm `git branch --show-current` matches the registry branch
3. Run `git status -sb` and require a clean tree unless dirt is already intentionally owned
4. Record `HEAD` and `@{upstream}` (when present)
5. `git fetch origin`
6. Read this registry entry for the workstream
7. Explicitly state before any modification:

```text
WORKSTREAM:
PATH:
BRANCH:
HEAD:
UPSTREAM:
OWNED AREA:
EXCLUDED AREA:
LIFECYCLE STATE:
```

8. STOP if any value conflicts with this registry

---

## STOP conditions

STOP immediately if:

- path / branch / upstream disagree with this registry
- expected parent authority moved and the workstream has not been re-authorized
- the worktree is dirty in an unowned way
- a shared boundary would be modified without `AUTHORITY_ASSIGNED`
- lifecycle state is `WAITING_FOR_BASELINE_SYNC`, `BLOCKED_SHARED_AUTHORITY`, `BASELINE_STALE`, or `SYNC_REQUIRED` and the task is implementation
- a force push or history rewrite would be required without explicit authorization
- work would require implementing directly on `main` in the permanent main worktree

On STOP: make no speculative correction. Report evidence and wait for authority.

---

## Update rule

Update this file only via an explicit governance or ownership-authority task (dedicated branch/worktree or authorized workstream PR).

When updating:

- keep `AGENTS.md` as permanent law
- refresh lifecycle states, pending PRs, and ownership assignments here
- record SHAs as status evidence only, never as frozen forever-law
- do not claim a PR merged unless GitHub shows it merged

### Status evidence (post PR #6 reconciliation; refresh when authority moves)

- `origin/main` = `486a1c74f5b738d488fdd54118002e90ec67bd49`
- `origin/hardening/s0-baseline` = `0fe372d1ef435b9826908ed41725457fdf78c034` (PR #6 merge)
- S0 persistent worktree verified at that authority (fast-forwarded; do not modify from this task)
- `origin/hardening/subscriptions` tip observed at `77a272c3887a7ab46e84a7fed02163d964e37b9b` (still waiting for converged S0 sync)
- `origin/hardening/platform-security` tip observed at `7a89dc20aa4b2a261ed6bb96f1d3182254d0b7d3` (ancestor of current `main`; no independent commits; behind `main`)
- PR #6 = MERGED into `hardening/s0-baseline`
- PR #2 = OPEN against `main` (Platform; later reconciliation)

Earlier topology-bootstrap commissioning evidence (historical):

- bootstrap `origin/main` was `7a89dc20aa4b2a261ed6bb96f1d3182254d0b7d3`
- bootstrap `origin/hardening/s0-baseline` was `77a272c3887a7ab46e84a7fed02163d964e37b9b`
- PR #6 head was `602d85d12a3d1c990a14b934f53582b84665fffa`
- PR #2 head was `cfd9be7491230edf4c1bde3281b78db3e4ca12a8`
