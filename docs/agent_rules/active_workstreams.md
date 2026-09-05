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
| `S0` | `/home/jcschoeman96/projects/current/Store_Blueprint_Hardening` | `hardening/s0-baseline` | Existing S0 authority (`origin/hardening/s0-baseline`) | `ACTIVE` | Yes |
| `SUBS` | `/home/jcschoeman96/projects/current/Store_Blueprint_Hardening-subscriptions` | `hardening/subscriptions` | S0 authority (`origin/hardening/s0-baseline` at branch creation) | `BOOTSTRAPPED` / `WAITING_FOR_BASELINE_SYNC` | Yes (topology only until activated) |
| `PLATFORM` | `/home/jcschoeman96/projects/current/Store_Blueprint_Hardening-platform` | `hardening/platform-security` | `origin/main` | `BOOTSTRAPPED` | Yes (topology only until activated) |

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

**Activation gate:** do not begin Subscription Backbone Hardening (SBH) implementation merely because the worktree exists. Current state is `BOOTSTRAPPED` / `WAITING_FOR_BASELINE_SYNC` because `main` has advanced relative to the S0 parent and S0 PR #6 remains unresolved.

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
ACTIVE → BASELINE_STALE → STOP / SYNC DECISION
```

Do not silently continue implementation through either exceptional state.

---

## Pending ownership-relevant PRs

| PR | Title / subject | Belongs to | Status | Bootstrap note |
| --- | --- | --- | --- | --- |
| #6 | S0-IA-AUTH-03R1 governance correction (IA-03 Redis status/abandon boundary) | S0 | OPEN against `hardening/s0-baseline` | Not part of topology bootstrap; do not merge/retarget from bootstrap work |
| #2 | Memory / GC / runtime methodology | Platform | OPEN against `main` from older `main` | Requires later Platform reconciliation against current `main`; not part of bootstrap |

Neither PR is accepted or merged by virtue of this registry.

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
- lifecycle state is `WAITING_FOR_BASELINE_SYNC`, `BLOCKED_SHARED_AUTHORITY`, or `BASELINE_STALE` and the task is implementation
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

After topology bootstrap commissioning (status evidence only):

- `origin/main` was `7a89dc20aa4b2a261ed6bb96f1d3182254d0b7d3`
- `origin/hardening/s0-baseline` was `77a272c3887a7ab46e84a7fed02163d964e37b9b`
- PR #6 head was `602d85d12a3d1c990a14b934f53582b84665fffa`
- PR #2 head was `cfd9be7491230edf4c1bde3281b78db3e4ca12a8`
