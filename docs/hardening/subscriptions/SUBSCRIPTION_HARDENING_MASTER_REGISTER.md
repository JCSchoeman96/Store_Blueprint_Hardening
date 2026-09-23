# Store Blueprint Hardening — Subscription Hardening Master Register

**Version:** v0.1.22
**Status:** SUBS READY / SERIAL EXPLICIT HARDENING / JC-219 + JC-220 + JC-221 + JC-222 + JC-223 CONTRACT_FROZEN / CANONICAL
**Verified:** 2026-09-23
**Repository:** `JCSchoeman96/Store_Blueprint_Hardening`  
**Workstream:** Subscription Backbone Hardening (`SUBS`)  
**Persistent worktree:** `/home/jcschoeman96/projects/current/Store_Blueprint_Hardening-subscriptions`  
**Persistent workstream branch:** `hardening/subscriptions`

> **Canonical SUBS governance artifact:**
> `docs/hardening/subscriptions/SUBSCRIPTION_HARDENING_MASTER_REGISTER.md`
>
> This document records the owner-approved JC-219 architecture, the Stage B JC-220/JC-221/JC-222 governance freeze, the JC-223 dependency graph and hardening matrix, and the historical controller evidence retained for provenance. The canonical Subscription domain/lifecycle/race map lives in `docs/hardening/01_domain_map.md`; scheduling terms are reconciled in `docs/governance/subscription_scheduling_terms.md`. This register does not override `docs/agent_rules/active_workstreams.md`, authorize migrations or shared-domain changes beyond an explicitly recorded task-specific grant, or manufacture READY work.

## Current authority boundary — v0.1.22

Canonical `main` governance at `ac1fd264de35522c010bdcc552b0ba22183cbca4`
supersedes the autonomous SUBS execution model. SUBS lifecycle remains
`READY`; its separate execution policy is **`SERIAL / EXPLICIT HARDENING`**:

```text
human selects one canonical READY issue
    ↓
verify current origin/main governance and origin/hardening/subscriptions authority
    ↓
materialize one bounded task contract and exact task_base_sha
    ↓
one task branch → TDD / minimal implementation → focused verification
    ↓
fresh independent review → required repository gates / exact-head CI
    ↓
human merge decision → refresh canonical SUBS authority
    ↓
only then select the next issue
```

At most one SUBS implementation issue may be active through this workflow.
`SUB-ACT-04`, Batch 001, `ACTIVE_PARALLEL`, frozen multi-task batch bases,
batch identifiers, successful-PR counters, persistent controller task claims,
autonomous runtime, and controller CI-cycle accounting are historical
provenance only. None is a prerequisite for a serial task, and no runtime
reconciliation is required merely to execute one.

Serial admission still requires the selected issue to be canonical `READY`,
frozen relevant Product/Architecture/Domain law, deterministic acceptance
criteria, explicit human selection, current authority inspection, required
dependencies and shared authority, and explicit allowed/forbidden scope.
`loop_eligible` may remain register metadata, but it is not the serial
execution-admission switch.

SUBS retains ownership of `Subscription`, `SubscriptionPlan`,
`SubscriptionItem`, `RenewalAttempt`, renewal scheduling, dunning,
cancellation, plan/variant changes, Subscription commercial-contract law, and
Subscription-specific reconciliation and certification. It does not own
`InventoryAdmission`, generic dependency/platform work, the auth platform,
migrations unless separately authorized, Payments core, Orders core, or
generic Entitlements infrastructure. Cross-domain mutations still require the
owning workstream/domain authority.

JC-219, JC-220, JC-221, JC-222, JC-223, and the existing frozen Subscription
lifecycle and scheduling law remain canonical. Simplifying execution does not
reopen or supersede them.

## Current v0.1.22 closure: SBH-10-02

Reconciliation base:

```text
09eb02b4a836a9db7156bdd5cc5e9fc722128d54
```

Implementation PR:

```text
#64
```

Certified implementation head:

```text
f20051c1a52c7e4bbad84ac6d8d26cdaa4f209d7
```

Implementation merge:

```text
09eb02b4a836a9db7156bdd5cc5e9fc722128d54
```

Exact-head CI run `35847542507` passed all five required jobs. The merge tree
matches the certified implementation-head tree, and the independent
implementation review verdict was `PASS`.

This is a governance-only closure reconciliation. It changes no production
code, tests, migrations, Ash snapshots, dependency files, Product Law,
Architecture Law, Domain Law, lifecycle law, scheduling law, or frozen JC-223
dependency edge.

`SBH-10-02` transitions:

```text
READY / No
→
CLOSED / No
```

Its task-specific shared authority remains recorded only as completed
provenance:

```text
AUTHORITY_ASSIGNED (completed provenance only)
```

That authority was consumed only for `SBH-10-02`. It grants no reusable
Checkout, Orders, Subscription, migration, or Ash-snapshot authority to any
other row and grants no further execution authority after closure.

The current canonical implementation/proof row count is:

```text
canonical READY implementation/proof rows = 0
```

No downstream row is promoted, no other row is moved to `READY`, no next
implementation task is selected, and no new shared authority is assigned.
`SBH-20-01`, `SBH-10-06`, and `SBH-50-06` remain
`BLOCKED_SHARED_AUTHORITY / No`.

`SBH-10-03` remains `BLOCKED_DEPENDENCY / No`. Its frozen prerequisites remain
`SBH-10-02` + `SBH-20-01` + `SBH-10-06`. Closing `SBH-10-02` satisfies only
that prerequisite; `SBH-20-01` and `SBH-10-06` remain unsatisfied. The frozen
JC-223 dependency graph is unchanged.

## Historical v0.1.21 admission: SBH-10-02

This section records the admission state at the time. The v0.1.22 closure above
supersedes its current-state effects; the admission itself remains historical
provenance.

Governance amendment base:

```text
27c3a774bc711b13aa238606ebcd2c6327d5fd1d
```

Current canonical `main` governance inspected for this admission:

```text
ac1fd264de35522c010bdcc552b0ba22183cbca4
```

The human owner approved the task-specific shared-authority grant for
`SBH-10-02 — Existing Subscription Contract Binding` on `2026-09-22`.

This is a governance-only admission amendment. It changes no production code,
migration, Ash snapshot, dependency file, Product Law, Architecture Law,
Domain Law, frozen JC-223 dependency edge, or scheduling law.

The approved authority resolved the recorded shared-authority blocker for the
minimum complete purchase-to-Subscription contract-binding boundary.

`SBH-10-02` transitions:

```text
BLOCKED_SHARED_AUTHORITY / No
→
READY / No
```

Its task-specific shared-authority status becomes:

```text
AUTHORITY_ASSIGNED
```

At the v0.1.21 admission point, exactly one canonical implementation/proof row
was `READY`:

```text
SBH-10-02
```

The frozen JC-223 dependency edge remains unchanged:

```text
SBH-10-02 depends on SBH-10-01
```

Closed `SBH-60-01` remains a satisfied selector-capability prerequisite. It is
not added as a new frozen dependency edge.

This amendment did not select `SBH-10-02` for implementation, create an
implementation branch, assign an implementation `task_base_sha`, or promote
any downstream row.

At that time, the exact implementation `task_base_sha` could be recorded only
after this governance amendment was merged, the canonical
`hardening/subscriptions` tip was refreshed, and the human separately selected
`SBH-10-02` for implementation.

## Historical v0.1.20 closure: SBH-60-01

Reconciliation base:

```text
3ee071cfd0daa927d0d3563771d2711bb0abb974
```

This is governance-only closure reconciliation. It changes no production code,
migration, Ash snapshot, dependency file, Domain Law, or scheduling law.

The human owner merge of successful PR `#53` at
`3ee071cfd0daa927d0d3563771d2711bb0abb974` closes `SBH-60-01 — Canonical
New-Sale / Change Eligibility`. `SBH-60-01` transitions from `READY` to
`CLOSED` with `loop_eligible: No` unchanged.

Zero canonical `READY` implementation/proof rows remain. No downstream row is
promoted by this reconciliation. `SBH-10-02` and `SBH-10-06` remain
`BLOCKED_SHARED_AUTHORITY / No`. The frozen JC-223 dependency edges are
unchanged.

Task-specific PlanRevision migration/Ash-snapshot authority assigned for
`SBH-60-01` is completed provenance only. It creates no reusable migration or
snapshot authority for any other row.

## Historical v0.1.19 admission: SBH-60-01

Historical admission provenance superseded by the v0.1.20 closure above.

The human owner approved this admission and decomposition on `2026-09-22`.
The approval covers:

```text
owner decision = APPROVED
approval date = 2026-09-22

SBH-60-01 selector-foundation decomposition
task-specific PlanRevision migration/Ash-snapshot authority assignment
```

It does not select SBH-60-01 for implementation.
This is a governance-only reconciliation; it changes no production code,
migration, or Ash snapshot.

### Post-v0.1.18 admission finding

Implementation inspection found that the existing SBH-60-01 wording crosses
three distinct seams:

```text
A. canonical EFFECTIVE-revision selector foundation
B. forward purchase integration
C. newly queued ContractChange integration
```

These seams do not share one bounded implementation authority. SBH-60-01 is
therefore not authorization to change all three.

### Selector-foundation ownership

The current executable SBH-60-01 scope is:

> Establish the reusable Subscription-owned canonical EFFECTIVE PlanRevision
> selector and its durable one-EFFECTIVE-per-SubscriptionPlan PostgreSQL
> invariant.

It owns:

```text
PlanRevision publication uniqueness
exact EFFECTIVE revision lookup
zero-EFFECTIVE fail closed
database race safety
no incidental-order selector
```

For one `SubscriptionPlan`, the selector contract is:

```text
zero EFFECTIVE PlanRevisions
→ selector reports unavailable / fails closed

exactly one EFFECTIVE PlanRevision
→ selector returns that exact immutable revision

more than one EFFECTIVE PlanRevision
→ prohibited by PostgreSQL durable authority
```

The selector must never substitute a `DRAFT`, `RETIRED`, newest row, highest
UUID, latest `inserted_at`, latest `updated_at`, last returned row, or mutable
`SubscriptionPlan` commercial values.

The later implementation must enforce simultaneous-EFFECTIVE exclusion with
PostgreSQL durable authority. Application-only `read → no EFFECTIVE found →
publish` logic is insufficient. Two competing DRAFT publications for one Plan
must not both commit `EFFECTIVE`.

The expected simplest mechanism is a PostgreSQL uniqueness constraint or index
covering `subscription_plan_id` where `status = 'effective'`. This governance
record does not freeze an index name, migration filename, Ash identity, exact
SQL, transaction API, or error shape. Those belong to the implementation
contract.

### Existing-data safety

If the migration target already contains more than one `EFFECTIVE`
`PlanRevision` for one `SubscriptionPlan`, the migration must stop. It must not
pick a winner. The following repair heuristics are forbidden:

```text
newest
oldest
latest inserted_at
latest updated_at
highest UUID
lowest UUID
arbitrary row
```

No authoritative customer-database assessment has proven duplicate absence, so
migration correctness must not assume it.

### Boundaries that remain downstream

Closing the bounded SBH-60-01 task later will not by itself prove that every
current caller consumes the selector. The following remain downstream/shared-
authority work:

```text
Cart caller
Checkout caller
Order snapshot
Subscription creation path
queued plan change
queued variant change
```

The current purchase flow freezes mutable Plan evidence but not exact
PlanRevision identity. Forward purchase-to-Subscription exact revision binding
therefore remains downstream work owned across `Checkout`, immutable `Orders`
purchase evidence, and `Subscription` binding. v0.1.19 assigns no authority to
those surfaces.

Current queued Subscription changes persist plan, variant, and pricing state but
not an exact target PlanRevision identity. Durable future-target authority belongs
to `SBH-10-06: Durable ContractChange / Future-Target Foundation`. SBH-60-01
must not create a temporary competing future-target authority.

The implementation decomposition is:

```text
SBH-60-01
    ↓ establishes reusable EFFECTIVE selector

SBH-10-02
    ↓ later uses selector for forward Subscription binding

SBH-10-06
    ↓ later uses selector for durable future ContractChange target
```

This clarifies implementation boundaries. It does not modify the frozen JC-223
dependency edges:

```text
SBH-10-02 depends on SBH-10-01
SBH-10-06 depends on SBH-10-02
SBH-60-01 depends on SBH-10-01
SBH-60-02 depends on SBH-10-02 + SBH-60-01 + SBH-10-05
```

### Bounded later implementation scope

The expected production scope for a later, explicitly selected implementation is:

```text
lib/store/subscriptions/plan_revision.ex
```

and, only if required for the smallest reusable selector interface:

```text
lib/store/subscriptions/facade.ex
```

It may also include focused Subscription tests, one PlanRevision
EFFECTIVE-uniqueness migration, and the corresponding `plan_revisions` Ash
snapshot. Exact filenames remain implementation outputs.

SBH-60-01 authority excludes:

```text
Cart
Checkout
Orders
OrderLineItem
Payments
Catalog core
Entitlements core
Subscription schema/binding
pending Subscription future-target fields
ContractChange
RenewalAttempt
provider contracts
rollout flags
```

If implementation requires any excluded surface, it must stop for an authority
assessment. It must not widen this task.

No dependency expansion is expected for this bounded selector foundation. This
reconciliation does not modify `mix.exs` or `mix.lock`. If the locked stack
cannot express the required durable constraint, implementation must stop rather
than add or upgrade a dependency silently.

### PlanRevision evidence and authority lifetime

`SBH-10-01` remains `CLOSED`. Its lawful historical revision tests already
support:

```text
EFFECTIVE
→ RETIRED
→ later revision EFFECTIVE
```

SBH-60-01 adds the missing simultaneous-EFFECTIVE exclusion and reusable
selector capability. It does not reopen SBH-10-01 or rewrite its proof history.

Task-specific shared authority is assigned only for:

```text
PlanRevision migration: per-SubscriptionPlan EFFECTIVE uniqueness only
Ash snapshot: corresponding plan_revisions snapshot only
```

This authority belongs only to SBH-60-01. It grants no migration or snapshot
authority to `SBH-10-02`, `SBH-10-06`, `SBH-20-01`, `SBH-50-06`, or any future
row. After SBH-60-01 closes, the grant is completed provenance and grants no
future modification authority. The task-specific execution consequence is:

```text
Task-specific authority assigned for SBH-60-01 selector foundation only.
No reusable or downstream migration authority is created.
```


# 1. Programme Objective

Systematically prove, harden, and close every material correctness, lifecycle, concurrency, commercial-contract, authorization, recovery, observability, and performance risk in the existing Subscription subsystem without redesigning already-correct mechanisms or crossing workstream authority boundaries.

The programme seeks to guarantee:

> **The contract charged, the contract activated, the Subscription lifecycle state, the payment evidence, and the customer's effective access cannot silently diverge under concurrency, retries, delayed provider events, administrative configuration changes, or partial downstream failure.**

This is a hardening programme, not a subscription rewrite.

---

# 2. Historical Independent Verification Pass — 2026-09-16

The material in §§2.1–2.6 is retained v0.1.4 provenance from the earlier Stage B
preflight. Its recorded hashes, observations, and statements about the next task
describe that earlier fixed point. They are not claims about the JC-223 fixed point
recorded in §2.7.

## 2.1 Verified authority state — refreshed before Stage B freeze

| Authority | Verified state |
|---|---|
| canonical `main` governance authority observed at preflight | `f0d0994e6d4d6c4c3f5966c5d00c9fa6739c475f` |
| `hardening/s0-baseline` current tip observed at preflight | `9b0b26a68399149abdde7c96529fbc1951e22cac` |
| `hardening/platform-security` current tip observed at preflight | `cc605040bfc8ddd6868a62de20f52c905f999835` |
| `hardening/subscriptions` current authority tip observed at preflight | `b2f46896e72bd907c800df5e0e4718177741b176` |
| PR #8 | **MERGED** |
| canonical topology | MAIN governance/integration authority + independent S0/PLATFORM/SUBS lanes |
| accepted SUBS development base | `575ffa1848ac69abe855bd018c7ae8eaf05d61e4` (SUB-ACT-01) |
| SUBS lifecycle | `READY` — governance/review only |
| Subscription implementation authority | **NONE; Batch 001 and SUB-ACT-04 remain outstanding** |
| Stage B law | **JC-220 + JC-221 + JC-222 CONTRACT_FROZEN / CANONICAL in this governance change** |

Canonical governance now explicitly separates:

```text
GOVERNANCE AUTHORITY
DEVELOPMENT BASE
INTEGRATION BASE
```

SUBS no longer waits for S0 merely because S0 moved. Cross-workstream changes block only the exact tasks that depend on them. Final convergence with canonical `main` remains mandatory before `READY_FOR_INTEGRATION`.

## 2.2 Verified branch topology and development-base interpretation

`hardening/subscriptions` current authority tip at preflight was:

```text
b2f46896e72bd907c800df5e0e4718177741b176
```

The accepted `development_base_sha` is separately pinned by `SUB-ACT-01`:

```text
575ffa1848ac69abe855bd018c7ae8eaf05d61e4
```

The current branch tip is the recorded governance authority; it is not a frozen Batch 001 base. Its age relative to another lane is not itself a blocker.

The activation decision asks:

```text
Is this exact SUBS tip a safe, provenanced development base
for independent Subscription hardening?
```

not:

```text
Has S0 or main been continuously merged into SUBS?
```

Any external capability absent from this base is evaluated per task. Shared boundaries still require explicit authority.

## 2.3 Verified documentation defect and Stage B result

Before this task, `docs/hardening/01_domain_map.md` was zero bytes.

This governance change populates it as the canonical Subscription domain,
lifecycle, and race map. It is the only Stage B lifecycle/race authority. The
scheduling document remains the policy-specific authority and is reconciled to the
same law.

## 2.4 Verified technical findings

The following high-impact findings were independently confirmed at the current SUBS/S0 source baseline:

- `SubscriptionPlan.update` can mutate recurring commercial-policy fields after plan creation, including cadence, currency/amount, trial, anchor, billing timezone, term, access, grace, retry, and entitlement configuration.
- `Subscription` does not presently expose an aggregate version attribute and its important `TransitionState` changes use `lock_attribute: nil`.
- renewal calculation can resolve the effective contract from current/pending Subscription fields.
- paid renewal reconciliation can promote then-current pending plan/variant/price fields rather than immutable evidence captured when the payment was initiated.
- `Scheduler.next_retry_at/3` applies `max(24)` to the configured retry offset, preventing an explicit `0`-hour retry from remaining zero.
- timezone conversion in the scheduler currently falls back to the original datetime when `DateTime.shift_zone/2` fails.
- initial entitlement issuance can degrade to `:skipped` after an entitlement failure.
- cancellation/expiry entitlement revocation results can be discarded.
- the nominal domain map is empty.
- duplicate-renewal protection itself remains materially strong and should not be rewritten merely because other concurrency gaps exist.

## 2.5 Corrections applied during this review

Two corrections were made to the earlier draft:

1. An earlier draft used an undeclared review-stop state. Review-only tasks now terminate only in explicit `STOPPED`, `PASS`, or `INCONCLUSIVE` outcomes.
2. The owner-approved hybrid `PlanRevision` + `Subscription` binding + exact `RenewalAttempt` charged-contract evidence is the canonical JC-219 architecture below. This is governance authority only; production implementation remains separately gated.

---

## 2.6 Local authority bootstrap rule

This subsection records the former pre-activation bootstrap protocol as
historical evidence. It is not a current serial admission requirement.

Before SUBS activation, the approved hardening documents may exist as **intentional untracked local authority bootstrap files** in the persistent SUBS worktree.

This exception is narrow:

```text
docs/hardening/subscriptions/SUBSCRIPTION_HARDENING_MASTER_REGISTER.md
docs/hardening/subscriptions/SUBSCRIPTION_HARDENING_LOOP_SPEC.md
docs/hardening/subscriptions/SUBSCRIPTION_TASK_CONTRACT_TEMPLATE.md
docs/hardening/subscriptions/SUBSCRIPTION_HARDENING_CODEX_LOOP_PROMPT.md
.agent-loop/subscriptions/state.example.json
```

Rules:

- valid only in `PRE_ACTIVATION_VALIDATION`;
- no staged or unstaged tracked modification is allowed;
- no additional untracked path is allowed;
- the installer/upgrade package verifies source checksums before copying;
- Run 0A fingerprints these five files into external controller state;
- later pre-activation runs STOP on fingerprint drift;
- before `ACTIVE_IMPLEMENTATION_BATCH`, these files must either become tracked through an explicitly authorized SUBS/governance documentation task or be removed from the worktree and supplied as external read-only authority.

Active implementation must never begin from a worktree containing untracked bootstrap authority files.

## 2.7 Historical JC-223 fixed-point verification — 2026-09-16

This was the verification boundary for v0.1.5. It records the fixed authority
supplied at that authorization and does not rewrite the historical preflight
evidence above or establish current execution authority.

| Authority | Current fixed point | Meaning for this register |
|---|---|---|
| `origin/main` | `95f0a51e6e14e494b30ff589da64ad0d8d15fca8` | canonical main authority at authorization |
| `origin/hardening/subscriptions` | `4af7f3889d03eea1a9719600202449b5a8e488b8` | SUBS target authority at authorization |
| accepted SUBS development base | `575ffa1848ac69abe855bd018c7ae8eaf05d61e4` | unchanged; accepted by `SUB-ACT-01` |
| `batch_base_sha` | `null` | not frozen; Batch 001 has not started |
| SUBS lifecycle | `READY` | governance/review only; not `ACTIVE_PARALLEL` |
| current verdict | `SUBS_JC_223_DEPENDENCY_GRAPH_FROZEN` | JC-223 / SBH-00-05 is canonically frozen |

The JC-223 content change is bounded to this register and its PR targets
`hardening/subscriptions`. It grants no production implementation authority, no
migration/schema/Ash-snapshot authority, no Payments, Orders, Entitlements,
provider, or shared-infrastructure authority, no Batch 001, no `batch_base_sha`
freeze, no `ACTIVE_PARALLEL`, and does not start `SUB-ACT-04`.

The next control-plane sequence is:

```text
merge this content PR to hardening/subscriptions
    ↓
verify the exact merged target against the fixed authority
    ↓
merge the separate main-governance registry refresh
    ↓
independently verify the merged main-governance registry refresh
    ↓
only then start SUB-ACT-04 Batch 001 base freeze and admission recertification
```

No other persistent SUBS lifecycle state is introduced.

## 2.8 Historical post-SUB-ACT-04 reconciliation fixed point — 2026-09-17

This section preserves the v0.1.6 reconciliation-base observation recorded after
the first SUB-ACT-04 admission attempt. It does not assert a permanently current
canonical main or SUBS authority, and it does not rewrite the historical JC-223
fixed point in §2.7. The literal SHAs in this section remain historical
provenance for that reconciliation base.

| Authority | Reconciliation fixed point | Meaning for this register |
|---|---|---|
| `origin/main` | `baeac140f68db80643b76626e99387089821f790` | v0.1.6 reconciliation-base canonical main authority; historical observation |
| `origin/hardening/subscriptions` | `81d203df8cd0c63f87e7fa7bf5bc02aea9e730ae` | reconciliation base / post-PR #26 SUBS authority; not canonical post-PR #27 authority |
| accepted `development_base_sha` | `575ffa1848ac69abe855bd018c7ae8eaf05d61e4` | unchanged; accepted by `SUB-ACT-01` |
| `batch_base_sha` | `null` | not frozen; Batch 001 has not started |
| `integration_base_sha` | `null` | not set during normal hardening |
| SUBS lifecycle | `READY` | governance/review only |
| `ACTIVE_PARALLEL` | not granted | requires a passing fresh `SUB-ACT-04` admission |
| Batch 001 | not started | requires a passing fresh `SUB-ACT-04` admission |

Provenance chain: JC-219 through JC-223 are canonical; the separate
main-governance registry refresh was merged and independently verified; the
first SUB-ACT-04 was attempted and returned `BLOCKED / STOP`; PR #26 is the
immutable failed-gate findings evidence; this v0.1.6 tracked-authority
reconciliation resolves the stale tracked metadata; separate external
runtime-state reconciliation is required; then SUB-ACT-04 must run again as a
fresh admission attempt.

PR #26 is failed-gate evidence, not Batch 001 authority. This reconciliation
does not freeze `batch_base_sha`, set `ACTIVE_PARALLEL`, start Batch 001, or
start implementation. The external controller runtime remains a separate
authority record and must be reconciled independently.

The SHA above is the reconciliation base and post-PR #26 SUBS authority. The
canonical v0.1.6 SUBS authority SHA was established only by exact post-merge
verification of PR #27. This document does not embed a permanently current
post-merge SHA.

At that historical fixed point, the v0.1.8 dynamic governance and transition
rule was recorded as applying before external runtime reconciliation and fresh
`SUB-ACT-04` admission. It is not a current serial-task requirement:

1. Run `git fetch origin`.
2. Resolve `governance_authority_sha` as the exact SHA returned by
   `git rev-parse origin/main`.
3. Read `AGENTS.md` and `docs/agent_rules/active_workstreams.md` from that
   exact SHA, then verify the current SUBS authority and lifecycle against Git.
4. Persist the resolved SHA as `governance_authority_sha` in the external
   runtime or run evidence for that execution.

If `origin/main` moves after resolution and before the protected transition,
the run must return `AUTHORITY_MOVED` and stop without substituting another
SHA. A later movement invalidates the current-authority assumption for future
runs but does not rewrite historical run evidence.

## 2.9 Historical v0.1.8 successful SUB-ACT-04 runtime transition contract — 2026-09-19

This section is retained as historical controller provenance. It is superseded
by the current serial policy in the authority boundary above and grants no
current implementation authority.

The v0.1.8 amendment completes the machine-state contract for a successful
fresh `SUB-ACT-04`. The Subscription Hardening Loop remains v1.4 and the
external runtime schema remains 1.4. This amendment changes no production
Subscription semantics and does not mutate the external runtime.

Immediately before the protected transition, the admitted runtime state is:

```text
mode = PRE_ACTIVATION_VALIDATION
activation_phase = PRE_ACTIVATION_FEASIBILITY
lifecycle_state = READY
batch_base_sha = null
batch_id = null
```

A passing `SUB-ACT-04` must atomically write this complete transition:

```text
mode = ACTIVE_IMPLEMENTATION_BATCH
activation_phase = ACTIVE_IMPLEMENTATION_BATCH
lifecycle_state = ACTIVE_PARALLEL
batch_base_sha = exact frozen current origin/hardening/subscriptions SHA admitted by SUB-ACT-04
batch_id = SUBS-BATCH-001
```

`SUBS-BATCH-001` is the exact identifier for the first admitted implementation
batch. Later batch identifiers require an explicit governance decision; the
controller must not infer them by arithmetic alone.

The controller must persist the five successful-transition fields as one
atomic state update. These combinations are invalid and must never be
persisted:

```text
ACTIVE_PARALLEL + batch_base_sha = null
ACTIVE_IMPLEMENTATION_BATCH + batch_id = null
batch_base_sha != null + lifecycle_state = READY
activation_phase = PRE_ACTIVATION_FEASIBILITY + mode = ACTIVE_IMPLEMENTATION_BATCH
```

Immediately before the write, the controller must re-resolve `origin/main` and
`origin/hardening/subscriptions`. If either authority differs from the values
admitted by the current run, it must return `AUTHORITY_MOVED`, persist no
activation transition, and stop. If the atomic write fails, it must return
`ACTIVATION_STATE_COMMIT_FAILED`, persist no partial success, and stop.

Before this successful transition, candidate Task Contracts are inert admission
evidence. They become executable only after the runtime proves the complete
active tuple above. An executable Batch 001 contract must carry
`batch_id = SUBS-BATCH-001`, the exact frozen `batch_base_sha`, the accepted
development base, and the current governance authority SHA.
The `SUB-ACT-04` invocation itself creates no task branch and performs no
implementation.

---

# 3. Current Programme Verdict

```text
SUBS READY / SERIAL EXPLICIT HARDENING
```

The JC-219, JC-220, JC-221, JC-222, and JC-223 governance contracts are frozen
and canonical. The Subscription lifecycle remains `READY`; no new persistent
`ACTIVE_SERIAL` lifecycle value is introduced.

Current execution is explicitly serial:

```text
human selects one canonical READY issue
    ↓
inspect current origin/main governance and origin/hardening/subscriptions
    ↓
confirm dependencies, shared authority, deterministic acceptance, and bounded scope
    ↓
branch from the exact current explicitly accepted SUBS tip (`task_base_sha`)
    ↓
TDD / minimal implementation / focused verification
    ↓
fresh independent review / required repository gates / exact-head PR CI
    ↓
human merge decision
    ↓
refresh canonical SUBS authority before selecting another issue
```

At most one SUBS implementation issue may be active in this workflow. `READY`
is necessary but not sufficient: the human must explicitly select the issue,
and all serial admission checks must pass. `loop_eligible` is historical
register metadata only. The retired autonomous controller, Batch 001,
`SUB-ACT-04`, `ACTIVE_PARALLEL`, frozen batch bases, batch identifiers,
controller claims/counters, and controller CI-cycle accounting cannot admit or
resume current work.

The register preserves historical controller observations in §§2.7–2.9 and
elsewhere for provenance; those observations do not compete with this current
serial authority.

---

# 4. Existing Strengths — Preserve These

The hardening programme must not rewrite already-sound mechanisms without evidence.

| Surface | Verdict |
|---|---|
| Deterministic renewal key | KEEP |
| `(subscription_id, renewal_key)` DB uniqueness | KEEP |
| Oban renewal uniqueness | KEEP |
| Initial RenewalAttempt SQL/CAS claim | KEEP |
| Source-order-line Subscription idempotency | KEEP |
| Minor-unit money representation | KEEP |
| Currency snapshots | KEEP |
| SubscriptionItem purchase evidence | KEEP |
| PostgreSQL as lifecycle truth | KEEP |
| Asynchronous worker boundary | KEEP |
| No Redis authoritative Subscription state | KEEP |
| Existing meaningful replay/concurrency tests | EXTEND, DO NOT REPLACE |

The weak point is not duplicate-renewal protection.

The primary weak point is **commercial-contract authority across time and asynchronous execution**.

---

# 5. Central Hardening Law

The programme's primary release-blocking invariant is:

> **Once a customer Subscription contract becomes effective, subsequent mutation of a reusable commercial offer must not silently alter that Subscription's authoritative recurring contract. Every renewal payment must be permanently bound to the exact contract it was created to purchase, and reconciliation may apply only that exact contract evidence.**

Optimistic locking is one mechanism underneath this law, not the law itself.

Conceptually:

```text
commercial contract authority
        ↓
immutable effective contract
        ↓
renewal binds exact contract
        ↓
external payment uses bound contract
        ↓
reconciliation applies bound contract
        ↓
Subscription optimistic concurrency rejects stale aggregate mutation
```

---

# 6. Hardening Item State Machine

Every hardening item follows:

```text
CANDIDATE
    ↓ evidence confirmed
VALIDATED
    ↓ product / architecture semantics frozen
CONTRACT_FROZEN
    ↓ dependencies + authority satisfied
READY
    ↓ loop claims the item
IMPLEMENTING
    ↓ deterministic verification passes
VERIFIED
    ↓ draft PR opened
PR_OPEN
    ↓ independent review
APPROVED
    ↓ separately authorized merge
MERGED
    ↓ exact post-merge verification
CLOSED
```

Exceptional / blocked states:

```text
NEEDS_PRODUCT_DECISION
BLOCKED_EXTERNAL_DEPENDENCY
BLOCKED_SHARED_AUTHORITY
BLOCKED_DEPENDENCY
BASELINE_INVALIDATED
AUTHORITY_MOVED
BLOCKED_SCOPE
FAILED_RETRY_BUDGET
EXTERNALIZED
NOT_APPLICABLE
SUPERSEDED
ACCEPTED_RISK
```

Review-only task outcomes:

```text
PASS
STOPPED
INCONCLUSIVE
```

Rules:

- `ACCEPTED_RISK` requires explicit human-owner authorization.
- the implementation loop may not promote a finding from `CANDIDATE` to `READY`.
- the implementation loop may report a new candidate, but may not implement it.
- a `STOPPED` review does not self-authorize the next remediation task.

---

# 7. Canonical Domain and Lifecycle Register

## 7.1 Subscription

The canonical Stage B states are:

```text
PENDING → ACTIVE
PENDING → CANCELED                    pre-activation termination only

ACTIVE → ACTIVE                       successful renewal
ACTIVE → PAST_DUE                     retryable renewal failure
ACTIVE → CANCELED                     immediate or scheduled cancellation
ACTIVE → EXPIRED                      governed term completion

PAST_DUE → ACTIVE                     same authorized renewal succeeds
PAST_DUE → SUSPENDED                  failed-payment boundary
PAST_DUE → CANCELED                   cancellation
PAST_DUE → EXPIRED                    governed term completion

SUSPENDED → ACTIVE                    same still-authorized renewal succeeds
SUSPENDED → CANCELED                  cancellation
SUSPENDED → EXPIRED                   governed term completion

CANCELED = terminal
EXPIRED  = terminal
SUSPENDED = nonterminal / extant
```

`PENDING → CANCELED` is permitted only when no authoritative activation or payment
evidence has established `ACTIVE` truth. It ends recurring authority, forbids
provider starts, begins no dunning lifecycle, and supersedes unbound future
changes.

`PAST_DUE` is an extant renewal-recovery episode. `SUSPENDED` is the nonterminal
failed-payment boundary. Retry exhaustion alone does not end the relationship.

`CANCELED` and `EXPIRED` are terminal. The following transitions are forbidden:

```text
CANCELED → ACTIVE
EXPIRED → ACTIVE
CANCELED → PENDING
EXPIRED → PENDING
```

### Transition model

| Transition | Guard | Major side effects | Terminal |
|---|---|---|---|
| `PENDING → ACTIVE` | authoritative activation or payment evidence; a return URL is not proof | initialize the first paid/current period and clear pre-activation termination | No |
| `PENDING → CANCELED` | no authoritative activation/payment evidence has established `ACTIVE` | end recurring authority; forbid provider starts; begin no dunning; supersede unbound changes | Yes |
| `ACTIVE → ACTIVE` | successful evidence for the same eligible B-bound renewal | apply the exact bound contract once and advance the paid period | No |
| `ACTIVE → PAST_DUE` | first retryable renewal failure wins | fix `past_due_since_at`, record evidence, and schedule governed retries | No |
| `ACTIVE → CANCELED` | immediate cancellation or actual scheduled-cancellation boundary | end recurring authority and create the cancellation access-effect target | Yes |
| `ACTIVE → EXPIRED` | governed term or paid-period completion; not retry exhaustion alone | end recurring authority and create the expiry access-effect target | Yes |
| `PAST_DUE → ACTIVE` | same still-authorized renewal succeeds | recover that episode and apply its exact bound contract once | No |
| `PAST_DUE → SUSPENDED` | failed-payment boundary before success or another terminal decision | stop automatic retries and make the affected recurring-source access effect non-effective | No |
| `PAST_DUE → CANCELED` | valid cancellation | end recurring authority without waiting for an artificial paid boundary | Yes |
| `PAST_DUE → EXPIRED` | separately governed term or paid-period completion | end recurring authority and create the expiry access-effect target | Yes |
| `SUSPENDED → ACTIVE` | same still-authorized renewal succeeds | recover that occurrence only; this is not generic reactivation | No |
| `SUSPENDED → CANCELED` | valid cancellation | end recurring authority and create the cancellation access-effect target | Yes |
| `SUSPENDED → EXPIRED` | separately governed term or paid-period completion | end recurring authority and create the expiry access-effect target | Yes |

Required hardening:

- exact effective-contract authority;
- immutable renewal contract binding;
- aggregate optimistic concurrency;
- cancellation/payment precedence;
- expiry/payment precedence;
- dunning success/failure ordering;
- durable access-effect convergence.

### JC-219 commercial authority

For the approved commercial-contract architecture, `Subscription` is the aggregate and
lifecycle authority for:

```text
status
period boundaries
current effective PlanRevision identity for authoritative bound contracts;
pre-PlanRevision legacy rows may temporarily have an explicitly unresolved
binding only under the approved legacy compatibility law
current variant/quantity where applicable
stored payment-method identity/reference
cancellation intent
dunning/retry state
pending ContractChange identity
aggregate version
```

The canonical commercial meaning of a Subscription is:

```text
bound immutable PlanRevision
        +
explicitly Subscription-owned aggregate state
```

For a pre-PlanRevision legacy row whose complete contract is not provable, the
binding portion is explicitly unresolved under the approved compatibility law;
the row does not possess a fabricated revision or a current-Plan fallback.

Compatibility snapshots may exist for migration, reads, or performance, but they are
not competing commercial authorities. JC-219 does not add schema or change the
persisted lifecycle law.

---

## 7.2 Scheduled Cancellation

Scheduled cancellation is a current versioned instruction, not a terminal state:

```text
DO_NOT_RENEW
```

The current funded paid term may continue. At the actual paid-period boundary, the
Subscription transitions to `CANCELED`. Do not manufacture another period after the
last paid period has ended.

The governing rules are:

- `DO_NOT_RENEW` before checkpoint B blocks that renewal boundary;
- checkpoint B first freezes the occurrence and a later schedule targets the next
  eligible uncommitted boundary;
- cancellation in `PAST_DUE` or `SUSPENDED` becomes `CANCELED` without waiting for
  an artificial future paid boundary;
- before terminalization, authenticated current-version rescission creates
  `RENEW_UNCHANGED(current live contract)`;
- after `CANCELED`, rescission requires a new Subscription, not resurrection.

A boolean or equivalent field may represent the instruction. The instruction itself
does not replace the terminal `CANCELED` state.

---

## 7.3 RenewalAttempt

```text
pending → processing → succeeded
              ↓
            failed
              ↓ reclaim/retry
           processing
```

Required invariant:

```text
succeeded → no non-terminal state
```

`succeeded` is terminal.

`failed` remains retryable where the retry law permits.

Preserve:

- deterministic renewal key;
- unique Subscription/renewal identity;
- initial CAS claim;
- Oban uniqueness.

### JC-219 charged-contract authority

`RenewalAttempt` is one renewal occurrence plus immutable, exact charged-contract
evidence. At the first winning renewal claim, the attempt must bind enough evidence to
answer permanently:

```text
which contract revision was purchased
which variant and quantity were charged
which amount and currency were charged
which period was purchased
which ContractChange, if any, was consumed
which commercial/access policy governed the occurrence
```

Minimum conceptual evidence is:

```text
plan_revision_id
variant_id
quantity
amount_minor
currency
period_start_at
period_end_at
contract_change_id (nullable)
immutable commercial-policy snapshot or equivalent canonical serialized/versioned evidence
```

A `PlanRevision` foreign key alone is not sufficient where occurrence-specific truth
exists outside the revision. The occurrence must remain independently auditable.

The bind point is:

```text
load authoritative Subscription
↓
resolve the bound revision and eligible queued ContractChange
↓
atomically bind the exact charged contract to RenewalAttempt
↓ COMMIT
provider/payment work may begin
```

Retries reuse that bound contract and may not re-resolve mutable Plan, pending fields,
or a newer queued change.

Successful reconciliation applies only the successful attempt's immutable charged-
contract evidence together with the frozen race precedence. If change A was bound to
the attempt and change B was queued later, reconciliation applies A and preserves B.

Checkpoint B is not a global winner over later commercial authority. It freezes one
charged occurrence. A later cancellation, payment-method revocation, or future
ContractChange still governs later provider starts and later boundaries.

Checkpoint C is the provider-specific point at which an external financial
occurrence may happen even if local execution stops. This register does not invent a
Paystack or other provider operation as C. C does not prove payment success.

Checkpoint D is authoritative provider/payment occurrence evidence. D proves what
financially occurred, but it does not automatically reactivate `CANCELED` or
`EXPIRED`, undo a valid cancellation or expiry, restore stale future terms, or
restore a revoked payment-method binding. Ambiguous ordering fails closed and is
reconciled.

---

## 7.4 Dunning

Conceptual lifecycle:

```text
ACTIVE
  ↓ first retryable failure
PAST_DUE
  ├── same authorized renewal succeeds → ACTIVE
  ├── retry remains available → PAST_DUE
  ├── retries exhausted before boundary → PAST_DUE, no more automatic retries
  └── failed-payment boundary → SUSPENDED
```

Required law:

- initial collection is attempt 1 and retries are attempts 2+;
- the retry budget counts retries after the initial collection;
- retry offsets are measured from the first retryable failure and offset `0` is
  valid;
- the first retryable failure fixes `past_due_since_at`; retries do not reset it;
- retry exhaustion before the failed-payment boundary leaves the Subscription
  `PAST_DUE` and stops automatic retries;
- the governed failed-payment boundary performs `PAST_DUE → SUSPENDED` unless
  success or another terminal event wins first;
- `SUSPENDED` is nonterminal and extant;
- access during recovery follows the frozen source-specific policy;
- late success ordering is deterministic and cannot revive `CANCELED` or `EXPIRED`.

Retry exhaustion is not relationship termination. Generic failed-payment handling
must not use dunning cancellation as a substitute for `EXPIRED` term completion or
an explicit `CANCELED` decision.

---

## 7.5 Plan Revision — JC-219 Approved Commercial Contract Architecture

JC-219 freezes the approved hybrid model. It separates:

1. a mutable reusable offer/configuration and sellability surface; and
2. an immutable effective commercial contract, with exact immutable evidence for each
   charged renewal occurrence.

The authority chain is:

```text
SubscriptionPlan
    ↓ publishes
PlanRevision
    ↓ bound by
Subscription.current_plan_revision_id
    ↓ exact occurrence binding
RenewalAttempt.charged_contract_snapshot
    ↓ payment/provider evidence
PaymentIntent / Order evidence
    ↓ successful reconciliation
Subscription applies exactly charged attempt evidence
```

### SubscriptionPlan authority

`SubscriptionPlan` remains a mutable reusable offer, authoring, and sellability
surface. It may evolve for future sales according to governance. It is not historical
contract truth, and changing it must not silently alter an already-effective
Subscription contract. `SubscriptionPlan` is not redefined as immutable by this
decision.

### PlanRevision authority and lifecycle

`PlanRevision` is the Subscription-owned commercial-contract resource. An
`EFFECTIVE` revision is the immutable commercial contract.

```text
DRAFT
  ↓
EFFECTIVE
  ↓
RETIRED
```

The lifecycle rules are:

- `DRAFT` is editable before effectiveness.
- `EFFECTIVE` is immutable.
- `RETIRED` is immutable and terminal for that revision.
- `RETIRED → EFFECTIVE` is forbidden; publish a new revision instead.
- a Plan may publish multiple immutable revisions over time.
- retirement/sellability and grandfathered continuation are separate questions;
  JC-222 owns the full grandfathering law.

### Immutable commercial field ownership

The revision owns every commercial field whose later mutation could alter recurring
obligation or access meaning. At minimum this includes:

```text
plan identity/key
variant/offer compatibility identity where contract-relevant
amount_minor
currency
quantity semantics
interval_unit
interval_count
anchor_mode
anchor_day_of_month
billing_timezone
term_mode
term_cycles
term_end_at
trial_days
retry schedule
max retries
grace policy
access_on_past_due
access_on_cancel
entitlement_kind
entitlement_scope_key
membership/commercial classification where it changes access
billing-mode constraints where commercially relevant
```

Operational/provider references that do not define commercial policy remain outside
`PlanRevision`. This list does not invent additional Product Law.

### Historical backfill authority

Existing Subscriptions may not receive invented history. Evidence precedence is:

```text
1. immutable paid OrderLineItem / SubscriptionItem evidence
2. Subscription snapshots known to have been captured at purchase
3. provable historical governance or migration evidence
4. current mutable Plan only where it can be proven identical to the purchased contract
```

If material historical commercial meaning cannot be proven, the row or cohort must
stop for an explicit compatibility/product decision. Today's mutable Plan must never
be silently copied and presented as historical truth.

### Owner-approved legacy binding compatibility amendment — 2026-09-21

The owner-approved JC-219 amendment canonicalizes the compatibility boundary
exposed by the SBH-10-02 historical-evidence assessment. A Subscription created
before authoritative PlanRevision binding existed may temporarily lack
`current_plan_revision_id` when its complete historical commercial contract
cannot be proven from durable evidence. This is an explicitly unresolved legacy
contract-binding condition, not a Subscription lifecycle state.

The exception preserves the normal authority chain and does not make the mutable
`SubscriptionPlan` historical truth. Missing values may not be supplied from the
current Plan, defaults, an arbitrary or newest `EFFECTIVE` revision, provider
state, or present Subscription status. The unresolved row must fail closed for
any operation requiring unproven commercial truth, including new automatic
renewal provider start, new RenewalAttempt charged-contract binding, queued
contract change, commercial-policy-dependent rescheduling, and derivation of
commercial/access policy from today's Plan. Missing evidence alone does not
cancel, expire, suspend, revoke access, forfeit funded coverage, or authorize a
provider payment.

After authoritative PlanRevision binding capability is active, every newly
created Subscription must resolve and commit an authoritative `EFFECTIVE`
PlanRevision at its governed creation boundary. Binding failure fails closed and
must not create another unresolved row. Reconciliation of a legacy row requires
authoritative evidence for the complete contract and recorded provenance. An
ambiguous row remains unresolved until a separate owner/governance decision
approves a disposition; this amendment approves no particular disposition.

The exception is transitional. Before final Subscription-hardening certification,
every extant renewable Subscription must have an authoritative PlanRevision
binding or an explicit, separately governed legacy disposition. This amendment
freezes no schema mechanism, lifecycle value, sentinel revision, or new resource.

### Owner-approved canonical EFFECTIVE-revision selection amendment — 2026-09-21

The human owner approved this JC-219 amendment on `2026-09-21`. It is governance
authority only. It assigns no production, migration, or Ash-snapshot authority.

For one `SubscriptionPlan`, at most one `PlanRevision` may be `EFFECTIVE` at a
time. A Plan may publish multiple immutable revisions over its lifetime, but not
multiple simultaneously `EFFECTIVE` revisions. The lifecycle remains:

```text
DRAFT → EFFECTIVE → RETIRED
```

`DRAFT` is editable. `EFFECTIVE` is immutable. `RETIRED` is immutable and
terminal. `RETIRED → EFFECTIVE` is forbidden.

`EFFECTIVE` means the immutable PlanRevision currently eligible to participate in
new-sale or newly queued contract-change selection for its SubscriptionPlan. It
does not alone make an offer sellable. Subscription-side selection also requires
an `ACTIVE` SubscriptionPlan, a valid active `VariantSubscriptionPlan`
attachment, and applicable Catalog/product/variant availability authority.

A Plan may temporarily have zero `EFFECTIVE` revisions. That state means no
authoritative commercial revision is available for new-sale or change selection,
so selection fails closed. It must not fall back to a `RETIRED` or `DRAFT`
revision, newest or timestamp-ordered data, UUID ordering, the last returned row,
or mutable SubscriptionPlan values. A `RETIRED` revision remains historical
commercial evidence and may remain renewable for an already-bound Subscription
where grandfathering law permits. New-sale eligibility must not decide
grandfathered existing-renewal eligibility.

Revision replacement is governed rotation, conceptually:

```text
Revision A = EFFECTIVE
Revision B = DRAFT

        ↓ rotation

Revision A = RETIRED
Revision B = EFFECTIVE
```

The durable invariant is the authority. A temporary committed zero-`EFFECTIVE`
interval is allowed and fails closed. Two competing publications for one Plan
must not both commit `EFFECTIVE`; a preflight read such as "no effective revision
exists" is insufficient by itself. PostgreSQL must decide the race through a
later race-safe uniqueness/CAS implementation. Redis, ETS, a GenServer, or a
distributed lock is not introduced as business authority. This amendment does
not prescribe an index name, migration body, Ash identity, transaction shape, or
SQL syntax.

Once implemented, a purchase capable of creating a Subscription must resolve and
freeze the exact eligible `EFFECTIVE` PlanRevision before or at the authoritative
purchase-to-Subscription boundary. The Subscription must bind that same revision;
the creation path may not later re-resolve mutable Plan state. A newly queued
commercial change must likewise identify an exact eligible `EFFECTIVE`
PlanRevision. Its durable future-target representation remains governed by later
ContractChange work.

The current `EFFECTIVE` revision is not historical proof. The v0.1.17 legacy
binding compatibility amendment remains unchanged: an ambiguous historical
Subscription may not be filled with the current `EFFECTIVE` revision, and legacy
unresolved rows continue to follow their fail-closed compatibility law.

This amendment introduces no `current_plan_revision_id` on `SubscriptionPlan`,
`CurrentPlanRevision`, `SellableRevision`, `RevisionPointer`, or
`PlanPublication` authority. The existing `PlanRevision` lifecycle plus the
durable per-Plan uniqueness rule remains the default architecture.

### JC-219 boundary and concurrency consequences

SUBS owns `PlanRevision` commercial semantics, `Subscription` commercial/lifecycle
semantics, `RenewalAttempt` charged-contract semantics, and `ContractChange`
Subscription-owned identity/semantics. Migrations, Ash snapshots, Orders core,
Payments core, Entitlements core, provider contracts, and shared platform
configuration remain shared/external authority. `OrderLineItem` is supporting
immutable order/payment evidence; it is not Subscription contract authority. No shared
domain resource is modified by JC-219.

PostgreSQL remains durable commercial-contract, Subscription-lifecycle, and
charged-occurrence authority. The one-`EFFECTIVE`-per-Plan rule is a required
durable PostgreSQL invariant for later implementation. Redis is not contract
authority, and a GenServer is not global Subscription serialization authority.
Renewal processing resolves and binds the authoritative contract once per
occurrence and carries immutable evidence through retries and reconciliation. No
cache is required for correctness.

Conceptual lookup/index surfaces for later implementation are:

```text
PlanRevision plan/revision identity
Subscription.current_plan_revision_id
ContractChange subscription/state/effective boundary
RenewalAttempt.plan_revision_id
RenewalAttempt.contract_change_id
existing unique(subscription_id, renewal_key)
```

These are design guidance only. This amendment creates no schema, migration, or
index and assigns no shared migration or Ash-snapshot authority.

---

## 7.6 Contract Change — JC-219 Stable Identity Requirement

The approved architecture requires a stable queued commercial-change identity. The
exact storage shape may remain a downstream implementation decision: a dedicated Ash
resource or another Subscription-owned durable representation are both compatible
unless later approved architecture says otherwise.

Conceptual lifecycle:

```text
NONE
  ↓ queue
QUEUED
  ├── supersede → SUPERSEDED
  ├── cancel → CANCELED
  └── renewal binds exact queued contract → BOUND_TO_RENEWAL
                                             ↓ successful reconciliation
                                          APPLIED
```

Required invariant:

> Once a change is `BOUND_TO_RENEWAL`, later queue or supersession operations cannot mutate the already-started charged occurrence. A later queued change has a distinct identity and survives reconciliation of the older bound occurrence.

---

## 7.7 StoredPaymentMethod

The frozen conceptual states are:

```text
ACTIVE ↔ INACTIVE

ACTIVE   → REVOKED
INACTIVE → REVOKED

REVOKED = terminal
```

Forbidden transitions are:

```text
REVOKED → ACTIVE
REVOKED → INACTIVE
```

Replacement changes the Subscription's durable payment-method binding under
aggregate version/CAS control. It does not create a new RenewalAttempt and does
not automatically revoke the old method globally. Immediately before provider
checkpoint C, current payment-method authority must be revalidated.

---

## 7.8 Entitlement Effect

Required conceptual durable-obligation lifecycle:

```text
REQUIRED
   ↓ durable obligation written
PENDING
   ↓ execution succeeds
APPLIED
```

Retry:

```text
PENDING → FAILED_RETRYABLE → PENDING
```

Optional supersession where product law permits:

```text
PENDING → SUPERSEDED
```

Invariant:

> Every Subscription lifecycle transition that changes effective access must create a durable, idempotent access-effect obligation that can be retried and reconciled until access truth converges with Subscription truth.

The effect obligation is source-specific. A stale executor must read the latest
Commerce target, apply only that target, or supersede the stale obligation. It must
not restore rights from an older commercial version and must not mutate Subscription
truth to make execution easier.

---

# 8. Race Precedence Matrix — JC-221 frozen

The full canonical map is in `docs/hardening/01_domain_map.md`. This register
records the same deterministic outcomes for programme navigation and review.

| Race | Frozen result |
|---|---|
| renewal vs immediate cancellation | Cancellation before B prevents the bind. Cancellation after B but before C forbids provider start. After C, reconcile the in-flight occurrence. Late money never automatically resurrects a terminal Subscription. |
| renewal vs scheduled cancellation | Current `DO_NOT_RENEW` before B blocks that boundary. B first freezes the occurrence and later scheduling targets the next eligible uncommitted boundary. |
| renewal vs ContractChange | The target current at B is bound. Later changes cannot rewrite or be consumed by that occurrence. |
| renewal vs payment-method replacement/revocation | Current method authority is checked before C. Replacement does not create a new RenewalAttempt. No authorized method means no provider start. |
| reconciliation vs expiry | Successful D application first makes stale expiry fail its aggregate/version guard. Expiry first forbids new provider starts. In-flight outcomes reconcile without generic `EXPIRED → ACTIVE`. |
| reconciliation vs suspension | A success for the same still-authorized renewal may recover `SUSPENDED → ACTIVE`. This is not generic reactivation. |
| success vs late failure | A successful occurrence cannot regress because older failure evidence arrives. Refund, reversal, and chargeback are separate financial events. |
| two Subscription writers | Only one incompatible mutation may commit against a version. The stale writer reloads and re-evaluates its original intent. |
| dunning vs successful recovery | The same valid success beats a stale dunning write. Retry exhaustion means no more automatic retries, not terminal relationship end. |
| access effect vs commercial state | The effect converges from the latest source target. A stale access worker cannot restore obsolete rights. |
| duplicate provider callbacks | One logical occurrence applies once. Equivalent duplicates are no-ops; materially conflicting reuse of one identity fails closed and reconciles. |
| out-of-order provider callbacks | Use trustworthy provider identity, occurrence time, provider sequence/state authority, and reconciled payment state. Arrival time alone never regresses truth. |
| late success after cancellation | Preserve financial truth while `CANCELED` remains terminal. If cancellation won before the occurrence, use explicit refund, reversal, credit, or other remedy. Ambiguous ordering remains fail-closed. |
| queued retry after cancellation | Queue presence grants no authority. Re-read before C. A canceled Subscription creates no new occurrence and exits idempotently. |
| provider-event reordering across webhook, browser return, polling, and reconciliation | All paths converge on one stable logical occurrence. No channel independently extends a Subscription. |
| restart or crash recovery | Reconstruct from durable Subscription/version, future-target version, RenewalAttempt binding, payment evidence, and access effects. Never use worker history as authority. |

Checkpoint law:

```text
A = authoritative aggregate/version commit
B = exact RenewalAttempt charged-contract bind commit
C = provider-specific point of no return, not invented here
D = authoritative provider/payment occurrence evidence
```

These checkpoints are not a global "last checkpoint wins" hierarchy. D proves
payment truth but does not override valid terminal Commerce truth. Ambiguous
provider ordering fails closed and enters reconciliation.

## 8.1 JC-221 race-coverage matrix

This matrix maps each approved race to the hardening rows or existing evidence
that must cover it. Coverage is still open; no row below is `PROVEN_GOOD`.

| Race coverage | Required rows or evidence | Current proof status |
|---|---|---|
| renewal vs immediate cancellation | `SBH-20-02` + `SBH-40-03` | OPEN |
| renewal vs scheduled cancellation | `SBH-40-02` + `SBH-40-03` | OPEN |
| renewal vs ContractChange | `SBH-10-06` + `SBH-20-03` | OPEN |
| renewal vs payment-method replacement/revocation | `SBH-80-03` | OPEN |
| reconciliation vs expiry | `SBH-20-04` | OPEN |
| reconciliation vs suspension | `SBH-30-04` + `SBH-30-05` | OPEN |
| success vs late failure | `SBH-70-02` + `SBH-20-05` | OPEN |
| two Subscription writers | `SBH-20-01` + race suites | OPEN |
| dunning vs successful recovery | `SBH-30-04` + `SBH-30-05` | OPEN |
| access effect vs commercial state | `SBH-50-06` + `SBH-50-05` | OPEN |
| duplicate provider callbacks | `SBH-95-02` + existing replay/idempotency evidence | OPEN |
| out-of-order callbacks | `SBH-95-02` | OPEN |
| late success after cancellation | `SBH-20-02` + `SBH-40-03` + provider reconciliation proof | OPEN |
| queued retry after cancellation | `SBH-20-02` + `SBH-30-05` | OPEN |
| provider-event reordering across evidence paths | `SBH-95-02` | OPEN |
| restart/crash recovery | `SBH-95-04` | OPEN |

The matrix is a coverage obligation, not evidence that the pending work is
complete. Audits remain open and cannot promote a pending row to `PROVEN_GOOD`.

---

# 9. Activation / Historical Control-Plane Register

The former global main→S0→SUBS activation chain was superseded by canonical PR #8 parallel-governance law.

## 9.1 Historical control-plane items

| ID | Historical task | Current disposition | Loop eligible | Note |
|---|---|---|---:|---|
| `SUB-CP-01` | Review old PR #8 topology/CI | `SUPERSEDED_BY_PR8_MERGE` | No | PR #8 ultimately merged with parallel topology |
| `SUB-CP-02` | Diagnose old PR #8 chaos/performance attribution | `CLOSED_EXTERNAL_OWNER` | No | Subscription ownership = NO |
| `SUB-CP-03` | Resolve old external chaos gate | `EXTERNALIZED` | No | Platform/Main responsibility, not SUBS |
| `SUB-CP-04` | Mandatory main → S0 convergence before SUBS | `SUPERSEDED` | No | Global serial prerequisite removed |
| `SUB-CP-05` | Mandatory converged-S0 verification before SUBS | `SUPERSEDED` | No | Not a universal SUBS gate |
| `SUB-CP-06` | Mandatory SUBS synchronization from S0 before SBH | `SUPERSEDED` | No | Replaced by independent development-base pinning |

Historical entries remain for provenance only and may not block current task admission.

## 9.2 Historical SUBS activation items

The activation items and controller-gate text in this subsection are retained
as historical evidence. They do not describe current implementation admission;
the v0.1.9 serial rule follows the table.

| ID | Task | Current disposition | Loop eligible | Dependency | Expected output |
|---|---|---|---:|---|---|
| `SUB-ACT-00` | Upgrade local loop/register authority from v1.2 to v1.3 parallel semantics | `COMPLETED` | No | PR #8 merged | v1.3 authority upgrade, promotion, and reclassification completed |
| `SUB-ACT-01` | Independently verify and pin SUBS development base | `DEVELOPMENT_BASE_ACCEPTED` | No | ACT-00 | `development_base_sha = 575ffa1848ac69abe855bd018c7ae8eaf05d61e4` accepted |
| `SUB-ACT-02` | Verify activation feasibility, task-level dependencies, and shared-authority usability | `ACTIVATION_FEASIBILITY_PASS` | No | ACT-01 + separately authorized and verified v1.4 runtime compatibility | feasibility pass recorded |
| `SUB-ACT-03` | Record accepted SUBS development base and canonical activation state | `CANONICAL_READY_RECORDED` | No | ACT-01 + ACT-02 PASS + v1.4 runtime compatibility | ordered `BOOTSTRAPPED → BASELINE_PINNED → READY` transitions recorded |
| `SUB-ACT-04` | Freeze Batch 001 base and run v1.3/v1.4 admission recertification | `BLOCKED_DEPENDENCY` | No | ACT-03 + SBH-00-05 + separately merged and independently verified main-governance registry refresh + v0.1.8 runtime transition contract | `batch_base_sha` + `batch_id` + 0A-P/0A-B/0A-N PASS + atomic transition PASS |

The former hard gate required canonical SUBS `READY` or `ACTIVE_PARALLEL`, an
accepted `development_base_sha`, v1.3/v1.4 admission recertification, a frozen
`batch_base_sha`, and controller state. That sentence is historical only and
is superseded by the serial admission rule below.

`SUB-ACT-02` is a feasibility gate, not implementation admission. It is not executable merely because `SUB-ACT-01` passed. Before it runs, the tracked authority must be v0.1.8 and the external controller state must be compatible with that authority: schema `1.4`, `activation_phase`, and `activation_feasibility` must be present, and any schema migration or runtime reclassification must have been separately authorized and verified. If v0.1.8 authority is tracked while the external runtime remains schema `1.3`, the deterministic result is `LOCAL_AUTHORITY_UPGRADE_REQUIRED → STOP`; `SUB-ACT-02` must not mutate runtime state.

After that compatibility gate, `SUB-ACT-02` must prove that the accepted base, authority package, SUBS ownership, task-specific external-dependency model, shared-authority model, and at least one authorized next governance/review task are usable, with no programme-wide blocker. It must not require `state == READY`, `loop_eligible == true`, or a frozen `batch_base_sha`.

`SUB-ACT-03` recorded two ordered, validated canonical lifecycle transitions. The initial canonical state was `BOOTSTRAPPED`. The accepted `SUB-ACT-01` development base guarded `BOOTSTRAPPED → BASELINE_PINNED`; the `ACTIVATION_FEASIBILITY_PASS` from `SUB-ACT-02` guarded `BASELINE_PINNED → READY`. The resulting canonical lane state is `READY`, and its side effects are recording the accepted `development_base_sha` and making `SBH-00-01` through `SBH-00-04` available as governance/review work in the frozen order. `SUB-ACT-03` did not set `ACTIVE_PARALLEL`, freeze `batch_base_sha`, start Batch 001, or authorize production Subscription implementation.

A sibling lane moving is not itself a blocker.

### Current serial admission rule

A SUBS issue may be implemented only when all of the following are true:

1. its register state is exactly `READY`;
2. relevant Product/Architecture/Domain law is frozen and canonical;
3. acceptance criteria are deterministic;
4. a human explicitly selects that canonical issue;
5. current `origin/main` governance and current `origin/hardening/subscriptions`
   authority are inspected;
6. required external dependencies are present and required shared authority is
   assigned;
7. the objective is bounded; and
8. allowed and forbidden write scope are explicit.

Only one SUBS implementation issue may be active through this workflow. The
human creates one task branch from the exact current explicitly accepted SUBS
tip, records that SHA as `task_base_sha`, and does not silently rebase during
the task. After merge, the canonical SUBS tip is refreshed before another
issue is selected. `loop_eligible` remains historical/register metadata and is
not an admission switch.

---

# 10. SBH-00 — Discovery, Contract, and Lifecycle Freeze

These are governance/review tasks. They establish law before production code changes.

The Stage B and JC-223 freeze records JC-219, JC-220, JC-221, JC-222, and JC-223
as canonical governance. All five items remain `loop_eligible = No`; canonical
does not mean implementation-authorized. `SBH-00-05` / JC-223 freezes the
dependency graph and hardening matrix. Earlier text described that freeze as a
precondition for Batch 001; Batch 001 and that autonomous gate are historical
only. Current implementation admission follows the serial rule in §9.2.

| ID | Task | Priority | State | Loop eligible | Dependency |
|---|---|---:|---|---:|---|
| `SBH-00-01` | Freeze commercial-contract architecture | P1 | `CONTRACT_FROZEN / CANONICAL` — governance/review only | No | ACT-03 |
| `SBH-00-02` | Populate canonical Subscription domain/lifecycle map | P1 | `CONTRACT_FROZEN / CANONICAL` — governance/review only | No | ACT-03 |
| `SBH-00-03` | Freeze concurrency/race precedence matrix | P1 | `CONTRACT_FROZEN / CANONICAL` — governance/review only | No | 00-01..02 |
| `SBH-00-04` | Freeze cancellation, dunning, access, revocation, and grandfathering laws | P1 | `CONTRACT_FROZEN / CANONICAL` — governance/review only | No | 00-01..03 |
| `SBH-00-05` | Freeze first executable dependency graph and hardening matrix | P1 | `CONTRACT_FROZEN / CANONICAL` — governance/review only | No | 00-01..04 verified |

## `SBH-00-01` architecture decision

JC-219 records the owner-approved decision; these are no longer unresolved alternatives.

### APPROVED — Hybrid: PlanRevision + Subscription binding + RenewalAttempt charged-contract snapshot

The selected model is:

```text
mutable SubscriptionPlan offer/configuration
        ↓ publishes
immutable PlanRevision commercial contract
        ↓ bound by
Subscription.current_plan_revision_id
        ↓ exact occurrence binding
RenewalAttempt.charged_contract_snapshot
```

It provides immutable reusable commercial semantics, exact per-renewal asynchronous
evidence, deterministic reconciliation, and independent auditability. The model
requires later schema/migration discipline, but that downstream work is not authorized
by this documentation PR.

### Rejected — mutable Plan + partial Subscription snapshots only

This does not provide durable immutable contractual provenance. Mutable plan changes
can drift away from existing customer obligations, while duplicated partial snapshots
can diverge from the exact terms actually charged.

### Rejected — PlanRevision reference alone

A revision reference does not preserve occurrence-specific truth where variant,
quantity, amount, period, consumed ContractChange, or commercial/access policy can be
bound at renewal time. A `PlanRevision` foreign key alone is therefore insufficient
for exact charged-occurrence auditability.

The owner-approved hybrid is canonical for JC-219. `SBH-10` and later implementation
tasks may implement it only after the separate activation, dependency, shared-authority,
and batch gates pass.

### Stage A boundary

This is a governance/documentation freeze only. It does not authorize production code,
schema, migrations, Ash snapshots, or changes to Orders, Payments, Entitlements,
provider contracts, or shared platform configuration. JC-220, JC-221, and JC-222
remain governance law in the canonical domain map, this register, and the reconciled
scheduling document. JC-223 / SBH-00-05 is frozen by this bounded register change,
but it does not start `SUB-ACT-04`, freeze `batch_base_sha`, start Batch 001, set
`ACTIVE_PARALLEL`, or authorize production implementation. The separate main
registry refresh must be merged and independently verified before `SUB-ACT-04`
may start.

---

# 11. SBH-10 — Immutable Commercial-Contract Authority

Legacy source finding: `SUB-HARD-00`.

## SBH-10-01 — Plan Revision / Approved Contract Foundation

**Priority:** —
**State:** `CLOSED`
**Loop eligible:** No.
**Shared authority:** `AUTHORITY_ASSIGNED` — completed task-specific
PlanRevision migration and applicable Ash snapshot authority. The authority was
used only for `SBH-10-01` and grants no further execution authority after
closure.

Completed implementation establishes the first JC-219 foundation:

```text
mutable SubscriptionPlan
        ↓
immutable PlanRevision
```

Completed durable lifecycle:

```text
DRAFT
  ↓ publish
EFFECTIVE
  ↓ retire
RETIRED
```

Completed invariants:

```text
- PlanRevision is owned by Store.Subscriptions.
- PlanRevision belongs to exactly one SubscriptionPlan.
- PostgreSQL is durable PlanRevision authority.
- DRAFT commercial policy is editable.
- EFFECTIVE commercial policy is immutable.
- RETIRED commercial policy is immutable and terminal.
- RETIRED → EFFECTIVE is forbidden.
- DRAFT → RETIRED is forbidden.
- caller-supplied create status cannot manufacture EFFECTIVE or RETIRED truth.
- stale DRAFT edits cannot modify an EFFECTIVE revision.
- stale publication cannot publish an unseen newer DRAFT version.
- competing stale DRAFT writers cannot both commit.
- mutable SubscriptionPlan updates do not mutate published revision evidence.
- one SubscriptionPlan can retain multiple distinct historical revisions.
- max_retry_attempts = 0 with an empty retry schedule is valid.
- optional entitlement kind/scope can be explicitly cleared together while DRAFT.
- no Subscription binding was introduced.
- no historical Subscription backfill was introduced.
```

Implemented durable commercial fields:

```text
amount_minor
currency
interval_unit
interval_count
trial_days
anchor_mode
anchor_day_of_month
billing_timezone
term_mode
term_cycles
term_end_at
access_on_past_due
access_on_cancel
grace_period_days
max_retry_attempts
retry_schedule_hours
entitlement_kind
entitlement_scope_key
```

Plus durable lifecycle/identity fields:

```text
id
subscription_plan_id
status
version
inserted_at
updated_at
```

The completed SBH-10-01 task did not implement or authorize a revision number,
current flag, single-`EFFECTIVE` uniqueness invariant, quantity-policy field, or
variant-compatibility snapshot. The v0.1.18 JC-219 amendment now records the
single-`EFFECTIVE` invariant as a required later capability; it does not reopen
the closed task or assign its migration/Ash-snapshot authority.

Scope boundary preserved — this row did **not** implement:

```text
Subscription.current_plan_revision_id
Subscription binding
historical Subscription backfill
RenewalAttempt charged-contract evidence
ContractChange
renewal-vs-change races
provider checkpoint-C behavior
Orders changes
Payments changes
Entitlements-core changes
```

Subscription binding remains downstream work (`SBH-10-02` and later rows).

Completed task branch:

```text
subs-task/sbh-10-01-plan-revision-foundation
```

Completion provenance:

```text
task: SBH-10-01
task base: 5bf0f7643d53b4747c95dd05e3c58fa58bf6b6d9
initial reviewed head: 74a80e14bbfb986fa32ee2e0f0e47e0c921811ac
final PR head: de62b108015ebed1290b960efb6bdfb2e5c82baf
PR: #46
merge commit: 945214761a736c66659b375c6005da470605828a
```

At initial reviewed head `74a80e14bbfb986fa32ee2e0f0e47e0c921811ac`,
independent review result was `PASS WITH NON-BLOCKING CORRECTIONS`. The reviewed
implementation already satisfied the core lifecycle, concurrency, migration, and
scope invariants. The review identified proof-quality/validation follow-up items
including tighter caller-supplied create-status rejection proof, stronger
Subscription non-binding proof, and entitlement clearing behavior on DRAFT edits.
`74a80e14...` is not the final certified merged head.

Final correction head `de62b108015ebed1290b960efb6bdfb2e5c82baf` changed only:

```text
lib/store/subscriptions/plan_revision.ex
test/store/subscriptions/plan_revision_test.exs
```

relative to `74a80e14...`. The correction required canonical `NoSuchInput`
rejection for caller-supplied create status; proved no draft is persisted by
those invalid create attempts; inspected the Subscription Ash resource schema
for accidental revision binding; fixed entitlement validation so explicit `nil`
changes are distinguished from unchanged values; and proved a DRAFT can clear
optional entitlement kind and scope together. No migration, snapshot, schema,
lifecycle, or downstream scope changed in this correction.

Exact final PR head `de62b108015ebed1290b960efb6bdfb2e5c82baf` CI run
`35621281204` — all five required jobs `PASS`:

```text
check_static: PASS (migration alignment PASS; mix check PASS; generated drift: none)
test_pr_strict: PASS
performance_smoke_required: PASS
performance_smoke_chaos_required: PASS
dialyzer_required: PASS
```

PR `#46` merge commit `945214761a736c66659b375c6005da470605828a` is
content-equivalent to final PR head `de62b108...` (zero file differences between
those SHAs). No separate post-merge code recovery cycle was required.

Post-merge independent review of the final corrected implementation: `PASS`.

Review-order deviation (historical provenance): the final corrected PR head
`de62b108...` was merged before the fresh independent review of that corrected
head was completed. The prior independent certification applied to
`74a80e14...`, not automatically to `de62b108...`. This was a review-order
deviation, not a CI failure, production correctness failure, migration failure,
or content divergence at merge. The final corrected head had all five required CI
jobs green before merge and was subsequently independently reviewed as `PASS`.

Assigned shared-authority surfaces (completed):

```text
priv/repo/migrations/20260921152624_sbh_10_01_plan_revision_foundation.exs
priv/resource_snapshots/repo/plan_revisions/20260921152625.json
```

Human owner approval dated 2026-09-21 assigned this authority to `SBH-10-01`
only. It does not assign migration/Ash-snapshot authority to `SBH-10-02`,
`SBH-20-01`, `SBH-10-06`, `SBH-50-06`, or any other row. This completed record
is no longer eligible for selection.

Performance/scaling (as implemented):

- PostgreSQL remains durable contract truth.
- no Redis/ETS/GenServer authority.
- FK index on `plan_revisions(subscription_plan_id)`.

---

## SBH-10-02 — Existing Subscription Contract Binding

**State:** `CLOSED`.
**Loop eligible:** No.
**Shared authority:** `AUTHORITY_ASSIGNED` — completed task-specific
Checkout/Orders/Subscriptions purchase-binding authority. The authority was
used only for `SBH-10-02` and grants no further execution authority after
closure.

The semantic dependency on `SBH-10-01` is satisfied.

Forward-created Subscription binding requires canonical `EFFECTIVE` PlanRevision
selection before forward-binding execution can run. That capability prerequisite
is satisfied by closed `SBH-60-01`, which implemented and proved
`PlanRevision.get_effective_for_plan/2` with zero-`EFFECTIVE` fail-closed
behavior, exact single-`EFFECTIVE` return, no `DRAFT`/`RETIRED`/incidental-order
fallback, PostgreSQL partial unique enforcement of at most one `EFFECTIVE`
revision per `SubscriptionPlan`, and competing-publication proof permitting only
one committed `EFFECTIVE`.

`SBH-60-01` supplies that selector capability only. The task-specific
shared-authority grant below was an independent v0.1.21 owner decision.

This remains a task-level capability requirement under the existing admission
law, not a new frozen dependency edge. The JC-223 edge remains `SBH-10-02`
depends on `SBH-10-01`.

### Historical v0.1.21 approved task-specific shared-authority grant

The human owner assigned Checkout authority only to:

- resolve the exact eligible `EFFECTIVE` PlanRevision at the authoritative
  subscription purchase-snapshot boundary;
- freeze and propagate that exact PlanRevision identity into immutable purchase
  evidence;
- fail closed when no eligible `EFFECTIVE` revision exists;
- fail closed when the selected revision does not belong to the snapshotted
  SubscriptionPlan; and
- avoid substituting a later/newer/current PlanRevision or mutable
  SubscriptionPlan commercial state after the purchase evidence is frozen.

The human owner assigned Orders authority only to:

- persist the exact selected PlanRevision identity in immutable
  `OrderLineItem` purchase evidence;
- propagate that identity through `Orders.SnapshotWriter`;
- add the task-specific `order_line_items` migration; and
- add the corresponding Ash snapshot required solely for that immutable
  purchase-evidence identity.

Existing historical `OrderLineItem` rows must not receive fabricated,
current/newest, or heuristic revision identity.

The human owner assigned Subscriptions authority only to:

- add the nullable legacy-compatible current PlanRevision binding;
- add the task-specific `subscriptions` migration;
- add the corresponding Subscription Ash snapshot;
- consume the exact PlanRevision identity frozen in purchase evidence during
  forward Subscription creation;
- bind that same exact revision without re-running current mutable PlanRevision
  selection at Subscription creation time; and
- make only the minimal Subscription-owned creation/scheduling adaptation
  required to derive revision-owned creation semantics from immutable
  PlanRevision evidence rather than mutable SubscriptionPlan commercial state.

The nullable binding exists only for the approved unresolved-legacy
compatibility law. Forward-created Subscriptions after binding capability is
active must not become unresolved.

Focused fixtures and tests are authorized only as needed to prove:

```text
Checkout selection → immutable OrderLineItem evidence → exact Subscription binding

zero EFFECTIVE → fail closed

plan/revision identity mismatch → fail closed

revision retirement or publication of a newer EFFECTIVE revision after purchase
→ Subscription still binds the originally purchased revision

mutable SubscriptionPlan changes after purchase
→ do not alter the frozen purchased contract

replay/idempotent Subscription creation
→ preserves the same binding

unprovable legacy history
→ remains unresolved without heuristic backfill
```

Explicitly excluded from this authority:

```text
Pricing core
Payments core
Entitlements core
provider business contracts
RenewalAttempt / SBH-10-03
ContractChange / SBH-10-06
Subscription aggregate version / SBH-20-01
dependency additions or upgrades
Redis / ETS / GenServer business authority
unrelated Checkout or Orders refactoring
broad historical data repair
```

If correct implementation requires an excluded surface or any additional shared
modification not listed above, `SBH-10-02` must stop and return to
shared-authority review rather than silently widening its scope.

At the v0.1.21 admission, this authority assignment made `SBH-10-02` `READY`
for explicit human selection under `SERIAL / EXPLICIT HARDENING`. It did not
select the row, create an implementation branch, or assign an implementation
`task_base_sha`.

### SBH-10-02 historical-evidence finding

Assessment base:

```text
25f5e0d20b7da2d4f476dcb47083348c416f2220
```

The completed assessment found durable immutable evidence for:

```text
plan identity/key
variant
quantity
amount
currency
interval unit
interval count
```

The reviewed repository does not prove historical values for all legacy rows for:

```text
trial
anchor mode/day
billing timezone
term policy
retry policy
grace policy
access policy
complete entitlement policy
```

No authoritative migration-target customer database was available during the
assessment, so `ZERO_EXISTING_SUBSCRIPTIONS` was not proven. Current mutable
`SubscriptionPlan` state remains unproven historical evidence.

### Compatibility-aware SBH-10-02 contract

The task must bind every Subscription whose exact complete authoritative
commercial contract is provable. A pre-PlanRevision Subscription whose complete
history is not provable may instead remain explicitly unresolved under the
approved JC-219 compatibility law. It must fail closed for operations requiring
unproven contract truth, including:

```text
new automatic renewal provider start
new RenewalAttempt charged-contract binding
new queued contract change
commercial-policy-dependent rescheduling
commercial/access-policy derivation from today's mutable SubscriptionPlan
```

The migration may not copy today's Plan, assume defaults, select an arbitrary or
newest PlanRevision, infer policy from provider state or Subscription status, or
silently bind an ambiguous row. Missing evidence alone does not cancel, expire,
suspend, revoke access, or forfeit funded coverage. Any reconciliation must use
authoritative evidence and record provenance. An unresolved row stays unresolved
until a separate owner/governance decision approves a legacy disposition.

Once binding capability is active, forward-created Subscriptions must resolve and
commit an authoritative `EFFECTIVE` PlanRevision at their governed creation
boundary or fail closed. The compatibility path cannot create new unresolved
rows. No new Subscription lifecycle state or schema mechanism is prescribed here.

Required:

- deterministic evidence classification;
- exact binding where the complete contract is provable;
- no invented contract history;
- explicit unresolved legacy compatibility where complete history is not provable;
- fail closed for operations requiring unresolved contract truth;
- mandatory forward binding after capability activation;
- explicit reconciliation provenance;
- required FK/query indexes;
- no unrelated cross-domain change;
- STOP where implementation requires authority outside this task.

The migration-sensitive and bounded cross-domain authority identified for this
task was assigned by the v0.1.21 owner decision above. At that admission point,
`SBH-10-02` was `READY` for explicit human selection. Readiness alone did not
start implementation. The row's current state is `CLOSED` under the v0.1.22
closure above.

## SBH-10-06 — Durable ContractChange / Future-Target Foundation

**State:** `BLOCKED_SHARED_AUTHORITY` until the required migration and Ash snapshot
authority is explicitly assigned.
**Loop eligible:** No.

Create durable stable `ContractChange` identity and a versioned current future
target. The conceptual lifecycle is:

```text
NONE → QUEUED → SUPERSEDED / CANCELED / BOUND_TO_RENEWAL → APPLIED
```

The contract must guarantee:

- a later change cannot mutate a B-bound occurrence;
- cancellation voids an unbound target;
- rescission creates `RENEW_UNCHANGED(current live contract)`;
- no stale predecessor restoration occurs.

Depends on `SBH-10-02` and is required before `SBH-10-03` and `SBH-20-03`.
Migrations and Ash snapshots are likely required, so this row remains
`BLOCKED_SHARED_AUTHORITY` until assigned. Do not implement the renewal-versus-
change race here; that belongs to `SBH-20-03`.

This row receives no ContractChange migration or Ash-snapshot authority from
the v0.1.20 closure reconciliation. SBH-60-01 must not write temporary
future-target revision state into `Subscription` to bypass this row.

---

## SBH-10-03 — Immutable RenewalAttempt Charged-Contract Snapshot

**State:** `BLOCKED_DEPENDENCY`.
**Loop eligible:** No.

Bind each renewal to the exact contract it attempts to purchase.

Minimum candidate evidence:

```text
subscription_id
expected Subscription aggregate/contract version
commercial contract / plan revision id
variant_id
quantity
amount_minor
currency
period_start_at
period_end_at
```

Final fields come from `SBH-00-01`.

Proposed branch:

```text
subs-task/sbh-10-03-renewal-contract-snapshot
```

Invariant:

> The RenewalAttempt contract becomes immutable before the external provider point-of-no-return.

---

## SBH-10-04 — Renewal Initiation Uses Bound Contract

**State:** `BLOCKED_DEPENDENCY`.
**Loop eligible:** No.

Proposed branch:

```text
subs-task/sbh-10-04-bound-renewal-initiation
```

Invariant:

> Once a RenewalAttempt contract is frozen, provider-payment construction must use that evidence rather than re-resolving mutable current/pending Subscription/Plan state.

---

## SBH-10-05 — Reconciliation Applies Charged Contract Only

**State:** `BLOCKED_DEPENDENCY`.
**Loop eligible:** No.

Proposed branch:

```text
subs-task/sbh-10-05-bound-renewal-reconciliation
```

Invariant:

> Paid reconciliation may apply only the exact contract evidence associated with the successful RenewalAttempt.

It may not promote arbitrary then-current pending fields if those fields were not part of the contract actually charged.

---

# 12. SBH-20 — Subscription Aggregate Concurrency

Legacy source finding: `SUB-HARD-01`.

## SBH-20-01 — Optimistic Aggregate-Version Foundation

**State:** `BLOCKED_SHARED_AUTHORITY` until migration and Ash snapshot authority is
explicitly assigned.
**Loop eligible:** No.

Proposed branch:

```text
subs-task/sbh-20-01-subscription-optimistic-version
```

Requirements:

- expected version/state checked on authoritative writes;
- stale updates rejected deterministically;
- no Redis/distributed lock;
- no global Subscription GenServer serialization;
- migration authority assigned;
- deterministic two-writer tests first.

---

## SBH-20-02 — Renewal vs Immediate Cancellation

**State:** `BLOCKED_DEPENDENCY`.
**Loop eligible:** No.

Proposed branch:

```text
subs-task/sbh-20-02-renewal-cancellation-race
```

Invariant:

> Cancellation and an in-flight provider payment must resolve according to the frozen precedence law; optimistic-lock failure after provider acceptance is not sufficient by itself.

Compensation/reconciliation must be explicit where necessary.

---

## SBH-20-03 — Renewal vs Contract / Variant Change

**State:** `BLOCKED_DEPENDENCY`.
**Loop eligible:** No.

Proposed branch:

```text
subs-task/sbh-20-03-renewal-contract-change-race
```

Invariant:

> A renewal already bound to Contract X cannot be mutated into Contract Y by a later queued change.

---

## SBH-20-04 — Paid Reconciliation vs Expiry

**State:** `BLOCKED_DEPENDENCY`.
**Loop eligible:** No.

Proposed branch:

```text
subs-task/sbh-20-04-reconciliation-expiry-race
```

Preserve proven payment evidence while obeying the frozen terminal-state law.

---

## SBH-20-05 — Success vs Late Failure / Dunning

**State:** `BLOCKED_DEPENDENCY`.
**Loop eligible:** No.

Proposed branch:

```text
subs-task/sbh-20-05-success-late-failure-race
```

Invariant:

> A proven successful renewal cannot regress because stale failure processing arrives later.

---

# 13. SBH-30 — Dunning Correctness

Legacy source finding: `SUB-HARD-08`.

## SBH-30-01 — Freeze Dunning Law

**State:** `CONTRACT_FROZEN / CANONICAL` from JC-222.
**Loop eligible:** No. This is satisfied canonical governance, not unfinished
architecture.

Review-only governance record.

Explicitly define:

```text
attempt numbering
offset-0 meaning
retry budget
recovery-window duration
access during recovery
retry suppression
recovery
failed-payment suspension boundary
terminal Subscription states
```

---

## SBH-30-02 — Correct Retry Schedule Offset Semantics

**State:** `CLOSED`.
**Loop eligible:** No.
**Shared-authority status:** `NONE`.
**Priority:** P1.

Priority rationale: zero-hour retry behavior and durable first-failure anchoring
are release-blocking dunning correctness risks. This P1 label was assigned
alongside the other implementation rows and did not rank them.

Completed implementation uses configured retry offsets exactly, normalizes
schedules deterministically, exhausts after the final configured offset, and
anchors each dunning episode to its first durable retryable-failure timestamp.

Completed task branch:

```text
subs-task/sbh-30-02-retry-offset-semantics-v2
```

Completion provenance: original selected task `SBH-30-02`; task base
`10e894902dc3af6ed9071bd74fc01b554f3c7d2a`; successful task HEAD
`b9ce01c3cdd5ee13f6d35d6d399d7c51697cd50e`; successful PR `#36`; merge SHA
`91c391cae894a61869c0bc2ad77b0d02eac5ed10`; exact-head required CI: PASS;
independent review: PASS; exact post-merge verification: PASS; post-sync
`mix check`: 590 tests, 3 properties, 0 failures.

PR `#33` remains historical superseded evidence: historical HEAD
`a03a4534d6373dd9a0ff99c32c95b30d62f918f8`; closed without merge; superseded
by PR `#36`.

TDD must cover:

```text
0-hour offset
24-hour offset
72-hour offset
schedule exhaustion / edge selection
normalized schedule behaviour
```

This was genuinely lane-local because the frozen contract targeted Subscription
scheduler offset normalization and selection. It did not require migration,
Payments, Orders, Entitlements, provider-business-contract, or generic
infrastructure changes. `READY` was the required register state for serial
selection; this completed record is no longer eligible for selection.

---

## SBH-30-03 — Separate Retry Exhaustion from Suspension Boundary

**State:** `BLOCKED_DEPENDENCY`.
**Loop eligible:** No.

Proposed branch:

```text
subs-task/sbh-30-03-retry-grace-separation
```

Invariant:

> Retry-budget exhaustion leaves the Subscription `PAST_DUE` and stops automatic retries. It does not terminate the relationship or substitute for the governed `PAST_DUE → SUSPENDED` boundary.

---

## SBH-30-04 — Enforce Failed-Payment Suspension Boundary

**State:** `BLOCKED_DEPENDENCY`.
**Loop eligible:** No.

Proposed branch:

```text
subs-task/sbh-30-04-dunning-suspension-boundary
```

Frozen dependencies: `SBH-20-01` + `SBH-10-05` + `SBH-30-03` + `SBH-50-06`.
The `SBH-30-01` JC-222 dunning governance is already satisfied and canonical;
it is not an executable dependency.

---

## SBH-30-05 — Dunning Adversarial Boundary Suite

**State:** `BLOCKED_DEPENDENCY`.
**Loop eligible:** No.

Proposed branch:

```text
subs-task/sbh-30-05-dunning-boundary-tests
```

Coverage:

- retry at exact configured offset;
- retry/recovery-window boundary at the same instant;
- successful final retry;
- success after retry exhaustion while still `PAST_DUE`, if permitted;
- `PAST_DUE → SUSPENDED` at the governed failed-payment boundary;
- late success after terminal boundary;
- duplicate failure;
- success/failure ordering.

---

# 14. SBH-40 — Scheduled Cancellation

Legacy source finding: `SUB-HARD-02`.

## SBH-40-01 — Freeze Scheduled-Cancellation Law

**State:** `CONTRACT_FROZEN / CANONICAL` from JC-222.
**Loop eligible:** No. This is satisfied canonical governance, not unfinished
architecture.

Review-only governance record.

Define:

```text
schedule
rescind
period boundary
immediate cancellation
provider already processing
provider success after cancellation
access end
communications
canonical terminal state
```

---

## SBH-40-02 — Durable Period-Boundary Terminalization

**State:** `BLOCKED_DEPENDENCY`.
**Loop eligible:** No.

Proposed branch:

```text
subs-task/sbh-40-02-period-end-cancellation
```

Current due selection suppresses scheduled rows, so a separate durable boundary-completion path must exist.

Use durable async execution where appropriate.

Do not poll from the UI.

---

## SBH-40-03 — Scheduled-Cancellation Race Suite

**State:** `BLOCKED_DEPENDENCY`.
**Loop eligible:** No.

Proposed branch:

```text
subs-task/sbh-40-03-cancellation-race-tests
```

Coverage:

```text
schedule vs renewal claim
rescind vs boundary worker
immediate cancellation vs in-flight provider charge
duplicate boundary execution
late boundary worker
```

---

# 15. SBH-50 — Entitlement Convergence and Access Law

Legacy source findings: `SUB-HARD-03` plus the P1 access-policy part of `SUB-HARD-04`.

## SBH-50-01 — Freeze Durable Access-Effect Architecture

**State:** `CONTRACT_FROZEN / CANONICAL` from JC-222.
**Loop eligible:** No. This is satisfied canonical governance, not unfinished
architecture.

Review-only governance record with a shared-boundary implementation consequence.

Frozen shape:

```text
Subscription truth transition
        ↓
durable access-effect obligation
        ↓
idempotent async execution
        ↓
Entitlements
        ↓
reconciliation
```

Do not jump to event sourcing.

Do not embed arbitrary Entitlements side effects directly inside unrelated Subscription resource changes.

## SBH-50-06 — Durable AccessEffect Obligation Foundation

**State:** `BLOCKED_SHARED_AUTHORITY` until required migration and Ash snapshot
authority is assigned.
**Loop eligible:** No.

Freeze durable, source-specific access-effect convergence:

```text
REQUIRED → PENDING → APPLIED
PENDING → FAILED_RETRYABLE → PENDING
PENDING → SUPERSEDED
```

The obligation must be idempotent, carry the latest target and version, and
prevent stale effects from restoring obsolete rights. It must leave Subscription
truth untouched, and independent sources must remain independent. It depends on
`SBH-10-02` and `SBH-20-01`, and is required before `SBH-50-02` through
`SBH-50-05`, `SBH-30-04`, and `SBH-40-02`.

Migrations and Ash snapshots are likely shared. Do not invent an Entitlements
`:suspended` state. If Entitlements core must change, this row remains
`BLOCKED_SHARED_AUTHORITY` until that authority is explicitly assigned. This task
does not change actual shared authorities.

---

## SBH-50-02 — Durable Active-Entitlement Issuance Recovery

**State:** `BLOCKED_DEPENDENCY`.
**Loop eligible:** No.

Proposed branch:

```text
subs-task/sbh-50-02-entitlement-issuance-recovery
```

Invariant:

> An active entitled Subscription cannot remain permanently under-granted because a transient entitlement operation failed.

---

## SBH-50-03 — Durable Terminal-Entitlement Revocation Recovery

**State:** `BLOCKED_DEPENDENCY`.
**Loop eligible:** No.

Proposed branch:

```text
subs-task/sbh-50-03-entitlement-revocation-recovery
```

Security invariant:

> A canceled/expired Subscription cannot permanently retain subscription-derived access because revocation failed.

Shared Entitlements authority must be explicitly assigned where required.

---

## SBH-50-04 — Enforce `access_on_past_due` and `access_on_cancel`

**State:** `BLOCKED_DEPENDENCY`.
**Loop eligible:** No.

Proposed branch:

```text
subs-task/sbh-50-04-access-policy-enforcement
```

Depends on:

- frozen access law;
- durable access-effect architecture.

These settings affect purchased authorization and are not merely dormant metadata.

---

## SBH-50-05 — Entitlement Reconciliation / Repair

**State:** `BLOCKED_DEPENDENCY`.
**Loop eligible:** No.

Proposed branch:

```text
subs-task/sbh-50-05-entitlement-reconciliation
```

Detect and repair:

```text
active Subscription but missing grant
terminal Subscription but active grant
wrong entitlement scope
wrong contract/revision-derived access
stale pending effect
```

Performance requirements:

- no peak-time full-table scans;
- indexed incremental reconciliation;
- Oban for repair work;
- cached/aggregated operator metrics where appropriate.

---

# 16. SBH-60 — Commercial Availability and Grandfathering

Legacy source finding: `SUB-HARD-05`.

## SBH-60-01 — Canonical New-Sale / Change Eligibility

**Priority:** —
**State:** `CLOSED`.
**Loop eligible:** No.

**Shared authority:** `AUTHORITY_ASSIGNED` — completed task-specific PlanRevision
migration and corresponding `plan_revisions` Ash snapshot authority. The
authority was used only for `SBH-60-01` and grants no further execution
authority after closure.

Completed capability:

```text
canonical PlanRevision.get_effective_for_plan/2 EFFECTIVE selector
zero EFFECTIVE → fail closed
exactly one EFFECTIVE → return that exact immutable revision
DRAFT / RETIRED / incidental ordering are never fallbacks
PostgreSQL partial unique index enforces at most one EFFECTIVE per SubscriptionPlan
competing publication proof permits only one committed EFFECTIVE
```

The selector foundation owns PlanRevision publication uniqueness, exact
EFFECTIVE revision lookup, zero-EFFECTIVE fail-closed behavior, database race
safety, and the absence of incidental-order selection. It does not certify that
Cart, Checkout, Orders, Subscription creation, or queued change callers already
consume the selector. Those integrations remain downstream/shared-authority
work.

Completed task branch:

```text
subs-task/sbh-60-01-plan-eligibility
```

Completion provenance:

```text
task: SBH-60-01
task base: b744069cc6135577882d7a134ddee14859b5ef31
successful final task head: 248f7e2d365e99a8072b4b7dec5ffb5f99bc3de8
successful PR: #53
merge SHA: 3ee071cfd0daa927d0d3563771d2711bb0abb974
```

Exact final task head `248f7e2d365e99a8072b4b7dec5ffb5f99bc3de8` CI run
`35704318935` — all five required jobs `PASS`:

```text
check_static: PASS
test_pr_strict: PASS
performance_smoke_required: PASS
performance_smoke_chaos_required: PASS
dialyzer_required: PASS
```

PR `#53` merge SHA `3ee071cfd0daa927d0d3563771d2711bb0abb974` is
content-equivalent to successful final task head
`248f7e2d365e99a8072b4b7dec5ffb5f99bc3de8` (zero file differences between
those SHAs).

Fresh independent final review of the successful final task head: `PASS`.

Post-sync `mix check`: `648` tests, `3` properties, `0` failures.
Post-sync `git diff --check`: `PASS`.

Assigned shared-authority surfaces (completed):

```text
priv/repo/migrations/20260922080609_sbh_60_01_plan_revision_effective_uniqueness.exs
priv/resource_snapshots/repo/plan_revisions/20260922080610.json
```

Task-specific PlanRevision migration/Ash-snapshot authority assigned for
`SBH-60-01` selector foundation only. It does not assign migration or snapshot
authority to `SBH-10-02`, `SBH-10-06`, `SBH-20-01`, `SBH-50-06`, or any other
row. This completed record is no longer eligible for selection.

At the v0.1.20 `SBH-60-01` closure point, the semantic dependency on
`SBH-10-01` was satisfied and the frozen JC-223 edges remained unchanged.
`SBH-10-02` and `SBH-10-06` retained their then-current
`BLOCKED_SHARED_AUTHORITY / No` states and received no authority from
`SBH-60-01`. The later v0.1.21 `SBH-10-02` authority grant is independent of
this completed row.

---

## SBH-60-02 — Grandfathered Retired-Contract Renewal

**State:** `BLOCKED_DEPENDENCY`.
**Loop eligible:** No.

Proposed branch:

```text
subs-task/sbh-60-02-grandfathered-renewals
```

Stage B permits grandfathered existing-renewal evaluation under the bound immutable
contract and applicable policy. Do not terminate or prevent renewal for an extant
subscriber solely because a commercial revision is no longer offered to new
customers. This task remains implementation work and is not authorized by this
governance PR.

---

# 17. SBH-70 — RenewalAttempt Monotonicity

Legacy source finding: `SUB-HARD-06`.

## SBH-70-01 — Prove Attempt Ordering

**State:** `CONTRACT_FROZEN / CANONICAL` from JC-221.
**Loop eligible:** No. This is a satisfied canonical review/test contract, not
unfinished architecture.

Review/test contract:

```text
processing → failed → processing
processing → succeeded
succeeded → late failure
succeeded → duplicate success
failed → retry claim
```

---

## SBH-70-02 — Enforce Successful Terminal Monotonicity

**State:** `CLOSED`.
**Loop eligible:** No.
**Shared-authority status:** `NONE`.
**Priority:** P1.

Priority rationale: a successful renewal must remain terminal when late failure
or retry evidence arrives. This P1 label was assigned alongside the other
implementation rows and did not rank them.

Completed invariant:

```text
RenewalAttempt.succeeded is terminal.
Late/stale mark_failed and mark_processing writes cannot regress it.
Valid processing→failed and failed→processing behavior remains.
Initial claim CAS remains unchanged.
A stale losing failure cannot push the Subscription into past-due dunning
after authoritative success wins.
```

Completed task branch:

```text
subs-task/sbh-70-02-renewal-attempt-monotonicity
```

Completion provenance: task `SBH-70-02`; task base
`60b66bba24277d2f874da5bb2e1e474849c750ea`; successful task HEAD
`f3688501801008bb8b7ecf89ed84ff484e002c99`; successful PR `#38`; merge SHA
`0ab0e6bf94590073fcb168a37e4ada5bb180f326`; fresh independent review: PASS;
exact-head required CI: all five required jobs PASS; post-sync `mix check`: PASS;
focused post-sync monotonicity suite: 7 tests, 0 failures; exact post-merge sync:
PASS.

Use the smallest correct state/CAS/version mechanism.

Do not replace working initial CAS machinery simply for stylistic uniformity.

This was genuinely lane-local because it hardened RenewalAttempt state
monotonicity within the existing Subscription renewal resource and test boundary.
It did not require migrations, Payments, Orders, Entitlements,
provider-business-contract, or generic infrastructure changes.

---

# 18. SBH-80 — StoredPaymentMethod Lifecycle

Legacy source finding: `SUB-HARD-07`.

## SBH-80-01 — Implement Frozen StoredPaymentMethod Revocation Semantics Across All Write Paths

**State:** `CLOSED`.
**Loop eligible:** No.
**Shared-authority status:** `NONE`.
**Priority:** P1.

Priority rationale: a revoked payment method must remain terminal across every
write path. This P1 label was assigned alongside the other implementation rows
and did not rank them.

Completed invariant:

```text
StoredPaymentMethod lifecycle:

ACTIVE ↔ INACTIVE
ACTIVE/INACTIVE → REVOKED
REVOKED is terminal.

mark_active cannot transition a durably REVOKED row.
mark_inactive cannot transition a durably REVOKED row.
mark_revoked remains a valid idempotent terminal write.
create_or_reuse / upsert cannot resurrect a REVOKED identity to ACTIVE or INACTIVE.
Nonterminal ACTIVE ↔ INACTIVE behavior remains valid.
Duplicate/replayed upserts retain the same durable identity.
Stale writers cannot resurrect a row after revocation has committed.
A skipped upsert returning a revoked row is not interpreted by the
payment-method-update facade as active payment authority.
INACTIVE, REVOKED, or absent StoredPaymentMethod authority causes the
payment-method-update success application to fail closed with the existing
PAYMENT_METHOD_REQUIRED vocabulary.
Rejected payment-method recovery does not clear Subscription recovery evidence
or enqueue a false immediate renewal retry.
Already-paid-order Subscription creation was intentionally not broadened into
SBH-80-03 race semantics.
```

This closure does not prove the later renewal-vs-revocation race. That remains
separate work under `SBH-80-03`.

Completed task branch:

```text
subs-task/sbh-80-01-stored-payment-method-revocation
```

Completion provenance: task `SBH-80-01`; task base
`2b638f15fbfbd4db265bec307bcc0237b0b4ea6c`; successful task HEAD
`09cc60d6579fe9ca2054056e814b8b7d0195ea5b`; successful PR `#40`; merge SHA
`562ccc40fd33a3e1530974e90087e70753d0a914`; fresh independent review: PASS
WITH NON-BLOCKING CORRECTIONS (final blocking corrections resolved before
certification/merge); exact-head required CI: all five required jobs PASS;
exact post-merge verification: PASS; post-sync focused revocation suite: 15
tests, 0 failures; post-sync neighbour suites: 29 tests, 0 failures; post-sync
`mix check`: PASS; post-sync `git diff --check`: PASS. The implementation went
through two material independent-review corrections before final certification.

This was genuinely lane-local because it hardened StoredPaymentMethod lifecycle
writes within the existing Subscription resource, focused facade payment-method
update fail-closed behavior, and related tests. It did not require migrations,
Payments core, Orders core, Entitlements, provider-business-contract, or generic
infrastructure changes.

---

## SBH-80-02 — StoredPaymentMethod Transition-Graph Adversarial Proof

**State:** `CLOSED`.
**Loop eligible:** No.
**Shared-authority status:** `NONE`.
**Priority:** —.
**Dependency:** `SBH-80-01` (satisfied by the canonical closure of `SBH-80-01` at
register v0.1.12 / PR #41 / merge `50f0549b1f84acd18fc5bc1b6aa3d3724a2d1f25`).

Completed proof:

```text
StoredPaymentMethod lifecycle remains:

ACTIVE ↔ INACTIVE
ACTIVE/INACTIVE → REVOKED
REVOKED is terminal.

The authorized status-write mechanisms at the task base were:
- create_or_reuse / upsert
- mark_active
- mark_inactive
- mark_revoked

No additional raw SQL / Repo writer on stored_payment_methods was identified
within the reviewed Subscription production surface.

Adversarial proof confirmed:

- upsert can legally transition ACTIVE → REVOKED;
- upsert can legally transition INACTIVE → REVOKED;
- repeated upsert REVOKED retains one durable identity;
- mark_revoked defeats a delayed stale mark_inactive writer;
- mark_revoked defeats delayed upsert INACTIVE;
- upsert-to-REVOKED defeats stale mark_active;
- upsert-to-REVOKED defeats stale mark_inactive;
- upsert-to-REVOKED defeats delayed upsert ACTIVE;
- upsert-to-REVOKED defeats delayed upsert INACTIVE.

Each adversarial race asserts durable PostgreSQL state after the ordered writes.

The existing SBH-80-01 lifecycle and facade proofs remain green.

No production source change was required.
```

This closure does not prove renewal-vs-payment-method replacement/revocation
ordering around provider checkpoint C. That remains `SBH-80-03`.

Completed task branch:

```text
subs-task/sbh-80-02-payment-method-transition-proof
```

Completion provenance: task `SBH-80-02`; task base
`b994e646d8a94c4f64198c95e43f42e0a782072c`; first fully green reviewed task
HEAD `20b53e72b9f8c54e34fd2cd57eaec54b702b4cae` (focused StoredPaymentMethod
revocation suite: 24 tests / 0 failures; neighbour StoredPaymentMethod suite:
1 test / 0 failures; `mix check`: PASS; `git diff --check`: PASS; required PR CI:
all five jobs PASS; fresh independent review: PASS WITH NON-BLOCKING
CORRECTIONS); final PR #43 head `55343ce7c657cc489c1bd923a6bc2dd6b5fe62d4`
(hardened concurrency test harness `wait_until/2` synchronization timeout to
fail explicitly; exact-head CI at this head: `check_static` FAIL — `mix check`
formatting compliance; `test_pr_strict`, `performance_smoke_required`,
`performance_smoke_chaos_required`, and `dialyzer_required` SKIPPED); PR #43
merged at `55343ce7c657cc489c1bd923a6bc2dd6b5fe62d4`; merge SHA
`d37615fcb2096c1e7a9c7a650e668e0d73dd85fd`; formatting-only post-merge repair
produced canonical SUBS tip `71eba2d321e75f266a5c4da52836de7f6cae4cf8` (delta
from merged task behavior: formatting-only around the `wait_until/2` guard
formatting; no automatic GitHub CI run on pushes to `hardening/subscriptions`);
post-merge recovery verification at `71eba2d321e75f266a5c4da52836de7f6cae4cf8`:
RECOVERED / VERIFIED (`git diff --check`: PASS; focused revocation suite: 24
tests / 0 failures; neighbour StoredPaymentMethod suite: 1 test / 0 failures;
`mix check`: PASS / 621 tests / 0 failures; strict test gate: PASS / 621 tests /
0 failures; `mix check.types`: PASS / exit 0 / existing baseline warnings only;
performance smoke: PASS / 12 tests / 0 failures; performance chaos smoke: PASS
/ 12 tests / 0 failures / mobile_realistic profile; `git diff --exit-code`: PASS
/ no generated or working-tree drift). Historical governance/process deviation:
PR #43 merged despite failed final-head `check_static` at `55343ce7...`; current
proof correctness is recovered/verified at `71eba2d...`; historical final-PR-head
gate compliance remains a deviation and is not retroactively converted to PASS.

This was genuinely lane-local because it proved the frozen StoredPaymentMethod
terminal-state graph through adversarial regression coverage without production
changes. It did not require migrations, Payments core, Orders core, Entitlements,
provider-business-contract, or generic infrastructure changes.

## SBH-80-03 — Renewal vs Payment-Method Replacement / Revocation Race

**State:** `BLOCKED_DEPENDENCY`.
**Loop eligible:** No.

This is separate from StoredPaymentMethod transition validity. It must prove:

- durable, versioned Subscription payment-method binding;
- replacement is not a new RenewalAttempt;
- replacing a method does not automatically revoke the old method globally;
- immediate revalidation before provider checkpoint C;
- replacement or revocation before C prevents a stale provider start;
- replacement after C cannot erase in-flight financial truth;
- checkpoint D governs financial evidence;
- a stale binding writer cannot win.

Depends on `SBH-20-01` + `SBH-80-01` + `SBH-10-03` + `SBH-10-04`.
Do not invent a provider-specific definition of checkpoint C.

---

# 19. SBH-90 — Billing Timezone Safety

Legacy source finding: `SUB-HARD-09`.

## SBH-90-01 — Validate Billing Timezone Before Contract Effectiveness

**State:** `BLOCKED_DEPENDENCY`.
**Loop eligible:** No.

Proposed branch:

```text
subs-task/sbh-90-01-billing-timezone-validation
```

Invariant:

> A timezone-sensitive commercial contract cannot become effective unless its billing timezone is valid and supported.

Do not silently fall back at renewal time.

Whether this is P1 or P2 depends on the commercial billing modes proven active during SBH-00.

---

# 20. SBH-95 — Remaining Structured Audits

These audit tasks remain open. They may later end in `PROVEN_GOOD` or create new
`CANDIDATE` findings. Pending proof is not `PROVEN_GOOD`.

They do not self-authorize implementation.

| ID | Audit | Initial priority |
|---|---|---:|
| `SBH-95-01` | Term / trial / provider-managed executable behaviour | P2 |
| `SBH-95-02` | Provider webhook ordering, replay, missing-event recovery | P1/P2 |
| `SBH-95-03` | Full Subscription authorization matrix | P1/P2 |
| `SBH-95-04` | Scheduler / Oban overlap and worker-crash boundaries | P1/P2 |
| `SBH-95-05` | Operator observability and recovery | P2 |
| `SBH-95-06` | Query/index/N+1/performance review | P2 |
| `SBH-95-07` | Facade responsibility / transaction-boundary audit | P2 |
| `SBH-95-08` | Comprehensive failure-injection/concurrency certification | P1 final gate |

Audit ordering is part of the executable review graph:

- `SBH-95-02` provider ordering, replay, and missing-event recovery comes after
  stable renewal binding and reconciliation, especially `SBH-10-03` through
  `SBH-10-05`.
- `SBH-95-04` scheduler/worker overlap and crash recovery comes after the
  relevant lifecycle and worker paths are implemented and reviewed.
- `SBH-95-08` final P1 failure-injection and concurrency certification comes only
  after all release-blocking streams close.

Audits do not authorize fixes. A new finding follows:

```text
CANDIDATE → VALIDATED → CONTRACT_FROZEN → dependency/authority review → READY
```

Any new problem discovered here becomes a new `CANDIDATE` and follows that
canonical lifecycle before implementation.

---

# 21. Facade Decomposition Policy

`Store.Subscriptions.Facade` is large and coordinates many domains.

That is a real architecture smell, but **not an automatic refactor mandate**.

Do not split it before contractual and lifecycle semantics are frozen.

After correctness hardening, audit natural seams such as:

```text
renewal orchestration
contract changes
lifecycle/access effects
initial activation
payment-method management
```

A facade audit may legitimately conclude:

```text
PROVEN_GOOD / NO REFACTOR REQUIRED
```

Large-file size alone is not sufficient authority.

---

# 22. Performance and Scaling Doctrine

Subscription hardening must preserve correct data ownership.

## 22.1 Data placement

| Data | Primary layer |
|---|---|
| Subscription authoritative lifecycle | PostgreSQL |
| Effective commercial contract/revision | PostgreSQL |
| RenewalAttempt / payment reconciliation evidence | PostgreSQL |
| Oban execution state | PostgreSQL / Oban |
| immutable plan/revision catalogue reads | PostgreSQL; optional Cachex/Redis derived cache if justified |
| realtime UI notification | Phoenix PubSub after authoritative commit |
| analytics/dashboard aggregates | materialized/cached aggregate / read replica |
| static marketing/plan content | CDN/browser cache where appropriate |

## 22.2 Explicitly prohibited

Do not introduce:

```text
Redis as Subscription lifecycle authority
Redis distributed locks as default Subscription concurrency solution
global Subscription GenServer serialization
polling for realtime lifecycle state
large peak-time reconciliation scans
cache-as-authority for payment/contract decisions
```

## 22.3 High-concurrency writes

Critical Subscription writes require:

```text
expected aggregate version/state
database constraints
idempotency
immutable charged-contract evidence
short transactional writes
```

External provider operations require durable reconciliation.

Do not pretend an external provider call participates in the same ACID transaction as PostgreSQL.

## 22.4 PubSub

Broadcast only after authoritative state commits.

PubSub is notification, never transaction authority.

## 22.5 Cache invalidation

If immutable commercial revisions are cached:

```text
publish revision → update/invalidate sellability/listing cache
retire revision  → update/invalidate sellability/listing cache
immutable revision content → no mutation invalidation required
```

Do not make Subscription transactional decisions from warm caches.

## 22.6 JC-223 Performance & Scaling Review

This is a governance-only change. It makes no production performance changes.
Later implementation PRs must retain this review boundary:

| Temperature | Review expectation |
|---|---|
| Hot | Storefront reads, cart, checkout, webhooks, renewal, access, and dunning paths must state DB query count and N+1 risk, required indexes, and the durable authority used for each decision. |
| Warm | Any ETS/Redis or other derived cache must record TTL, invalidation, and stampede protection. A cache must not decide contract, payment, lifecycle, or race precedence. |
| Cold | Reconciliation, audit, repair, and certification work must be bounded and retry-safe. Oban uniqueness and idempotency must be explicit, and telemetry/logging must distinguish provider occurrence, local observation, queue execution, and Commerce application. |

No row in the JC-223 matrix authorizes a cache, index, worker, telemetry, or
database change. The expectations are acceptance and review criteria for the
later task contracts.

---

# 23. Execution Classes and Dependency Spine

Task identifiers do not determine execution order. The executable dependency
graph determines execution order. Numbering and `P1` labels are navigation and
priority labels; neither creates an executable edge.

The graph distinguishes four classes:

1. the foundational commercial/concurrency spine: immutable contract authority,
   Subscription binding, aggregate/version control, future-target identity,
   RenewalAttempt binding, provider initiation, reconciliation, and their races;
2. independent lane-local hardening: the completed `SBH-30-02`, `SBH-70-02`, and
   `SBH-80-01` records;
3. shared-boundary hardening: durable access effects, lifecycle terminalization,
   provider/payment boundaries, migrations, snapshots, and any core owned outside
   SUBS;
4. audit and final certification: `SBH-95-*`, which may prove a contract or
   create a finding but cannot authorize its own fix.

## 23.1 Foundational commercial/concurrency spine

The executable foundation is:

```text
SBH-10-01  PlanRevision foundation
    ↓
SBH-10-02  existing Subscription contract binding
    ├──→ SBH-20-01  aggregate/version foundation ──┐
    └──→ SBH-10-06  ContractChange/future-target foundation ──┤
                                                               ↓
                          SBH-10-02 + SBH-20-01 + SBH-10-06
                                                               ↓
SBH-10-03  exact RenewalAttempt charged-contract bind
    ↓
SBH-10-04  bound provider work
    ↓
SBH-10-05  bound reconciliation
```

`SBH-20-01` therefore precedes `SBH-10-03`. The old illustrative `SBH-10` then
`SBH-20` sequence is not executable order. Later race rows consume the stable
foundation according to the frozen edges below.

## 23.2 Explicit executable lane graphs

Dunning:

```text
SBH-30-02 independently

SBH-20-01 → SBH-30-03 → SBH-30-04 → SBH-30-05
                         ↑             ↑
             SBH-10-05 + SBH-50-06   SBH-30-02 + SBH-70-02
```

Retry exhaustion != `SUSPENDED`/`CANCELED`/`EXPIRED`. `SBH-30-04` also needs the
bound reconciliation and durable access-effect foundations. `SBH-30-05` also
needs the independent retry-offset and RenewalAttempt monotonicity work.

Cancellation:

```text
SBH-20-01 + SBH-10-03 + SBH-10-04 + SBH-10-05 + SBH-50-06
    ↓
SBH-40-02
    ↓
SBH-40-03 + SBH-20-02 + SBH-70-02
```

The queue and worker order never becomes authority.

Access:

```text
SBH-10-02 + SBH-20-01
    ↓
SBH-50-06
    ├──→ SBH-50-02 ──┐
    ├──→ SBH-50-03 ──┼──→ SBH-50-05
    └──→ SBH-50-04 ──┘
          ↑
relevant implemented PAST_DUE/SUSPENDED/cancellation/expiry lifecycle capability
```

`SBH-50-02` and `SBH-50-03` are parallel children of `SBH-50-06`; neither is a
prerequisite for `SBH-50-04`. `SBH-50-04` independently depends on `SBH-50-06`
and the relevant implemented `PAST_DUE`, `SUSPENDED`, cancellation, and expiry
lifecycle capability. All three rows feed `SBH-50-05`.
Entitlements is not commercial authority.

Grandfathering:

```text
SBH-10-01 → SBH-60-01
SBH-10-02 + SBH-60-01 + SBH-10-05 → SBH-60-02
```

Preserve `NEW-SALE`, `CHANGE`, and `EXISTING-RENEWAL` as separate decisions.

Timezone:

```text
SBH-10-01 → SBH-90-01
```

There is no silent runtime timezone fallback.

Conditional lifecycle dependencies are capability requirements, not additional
hard-order edges. A task must stop if the required capability is absent or owned
by an unassigned shared authority. In particular, `SBH-50-04` needs the relevant
`PAST_DUE`, `SUSPENDED`, cancellation, and expiry paths implemented, and
`SBH-80-03` must use the provider contract's actual checkpoint-C evidence without
inventing a provider-specific C.

## 23.3 Frozen core dependency edges

| Row | Frozen dependency |
|---|---|
| `SBH-10-01` | JC-219..223 frozen; migration authority before execution |
| `SBH-10-02` | `SBH-10-01` |
| `SBH-20-01` | `SBH-10-02` |
| `SBH-10-06` | `SBH-10-02` |
| `SBH-10-03` | `SBH-10-02` + `SBH-20-01` + `SBH-10-06` |
| `SBH-10-04` | `SBH-10-03` |
| `SBH-10-05` | `SBH-10-03` + `SBH-10-04` |
| `SBH-20-02` | `SBH-20-01` + `SBH-10-03` + `SBH-10-04` + `SBH-10-05` |
| `SBH-20-03` | `SBH-20-01` + `SBH-10-06` + `SBH-10-03` + `SBH-10-04` |
| `SBH-20-04` | `SBH-20-01` + `SBH-10-05` |
| `SBH-20-05` | `SBH-20-01` + `SBH-10-05` + `SBH-70-02` |
| `SBH-30-02` | `JC-222` |
| `SBH-30-03` | `SBH-20-01` |
| `SBH-30-04` | `SBH-20-01` + `SBH-10-05` + `SBH-30-03` + `SBH-50-06` |
| `SBH-30-05` | `SBH-30-02` + `SBH-30-03` + `SBH-30-04` + `SBH-70-02` |
| `SBH-40-02` | `SBH-20-01` + `SBH-10-03` + `SBH-10-04` + `SBH-10-05` + `SBH-50-06` |
| `SBH-40-03` | `SBH-40-02` + `SBH-20-02` + `SBH-70-02` |
| `SBH-50-06` | `SBH-10-02` + `SBH-20-01` |
| `SBH-50-02` | `SBH-50-06` |
| `SBH-50-03` | `SBH-50-06` |
| `SBH-50-04` | `SBH-50-06` + implemented relevant PAST_DUE/SUSPENDED/cancellation/expiry lifecycle paths |
| `SBH-50-05` | `SBH-50-02` + `SBH-50-03` + `SBH-50-04` |
| `SBH-60-01` | `SBH-10-01` |
| `SBH-60-02` | `SBH-10-02` + `SBH-60-01` + `SBH-10-05` |
| `SBH-70-02` | `JC-221` |
| `SBH-80-01` | `JC-222` |
| `SBH-80-02` | `SBH-80-01` |
| `SBH-80-03` | `SBH-20-01` + `SBH-80-01` + `SBH-10-03` + `SBH-10-04` |
| `SBH-90-01` | `SBH-10-01` |

These edges are semantic prerequisites. Queue order, worker start order, task
number, and priority do not add authority or reorder a race.

---

# 24. Shared-Authority Register

These surfaces are not implicitly owned by SUBS:

```text
migrations
Ash snapshots
Payments core
Orders core
Entitlements core
provider business contracts
generic infrastructure
main governance
```

The implementation-row matrix uses only these shared-authority values:

```text
NONE
AUTHORITY_ASSIGNED
BLOCKED_SHARED_AUTHORITY
EXTERNALIZED
```

`NONE` means the current task contract identifies no shared modification.
`AUTHORITY_ASSIGNED` means an explicit authority is recorded for the named
shared surface. On a `CLOSED` row, it records completed task-specific
provenance only and grants no further execution authority.
`BLOCKED_SHARED_AUTHORITY` means the task cannot proceed until that authority is
assigned. `EXTERNALIZED` means the surface remains owned outside SUBS and the
task must not modify it. `SBH-10-01`, `SBH-60-01`, and `SBH-10-02` retain
`AUTHORITY_ASSIGNED` as completed task-specific provenance only. No authority
grant is reusable outside its named row and surfaces.

| Row | Shared surface or boundary | Shared-authority status | Execution consequence |
|---|---|---|---|
| `SBH-10-01` | PlanRevision migration and applicable Ash snapshot surfaces | `AUTHORITY_ASSIGNED` | Completed task-specific PlanRevision migration/snapshot authority. The authority was used only for `SBH-10-01` and grants no further execution authority after closure. |
| `SBH-10-02` | Checkout exact-revision purchase boundary; immutable Orders PlanRevision purchase evidence plus task-specific `order_line_items` migration/Ash snapshot; Subscription PlanRevision binding plus task-specific `subscriptions` migration/Ash snapshot | `AUTHORITY_ASSIGNED` | Completed task-specific Checkout/Orders/Subscriptions purchase-binding authority. The authority was used only for `SBH-10-02` and grants no further execution authority after closure. |
| `SBH-20-01` | migrations, Ash snapshots | `BLOCKED_SHARED_AUTHORITY` | Version foundation cannot run without assigned migration authority. |
| `SBH-10-06` | migrations, Ash snapshots | `BLOCKED_SHARED_AUTHORITY` | Future-target foundation remains blocked until assigned. |
| `SBH-10-03` | no shared modification identified in this contract | `NONE` | Semantic dependencies still block admission. |
| `SBH-10-04` | provider business contracts | `EXTERNALIZED` | Use the existing provider boundary; do not change provider business contracts. |
| `SBH-10-05` | Payments core | `EXTERNALIZED` | Use payment evidence authority; do not change Payments core. |
| `SBH-20-02` | no shared modification identified in this contract | `NONE` | Semantic dependencies still block admission. |
| `SBH-20-03` | no shared modification identified in this contract | `NONE` | Semantic dependencies still block admission. |
| `SBH-20-04` | no shared modification identified in this contract | `NONE` | Semantic dependencies still block admission. |
| `SBH-20-05` | no shared modification identified in this contract | `NONE` | Semantic dependencies still block admission. |
| `SBH-30-02` | no shared modification identified in this contract | `NONE` | Completed lane-local task; no further admission. |
| `SBH-30-03` | no shared modification identified in this contract | `NONE` | Semantic dependencies still block admission. |
| `SBH-30-04` | Entitlements core only if the implementation requires it | `EXTERNALIZED` | Stop and reclassify as blocked if Entitlements core must change. |
| `SBH-30-05` | no shared modification identified in this contract | `NONE` | Semantic dependencies still block admission. |
| `SBH-40-02` | no shared modification identified in this contract | `NONE` | Durable worker path remains dependency-blocked. |
| `SBH-40-03` | no shared modification identified in this contract | `NONE` | Semantic dependencies still block admission. |
| `SBH-50-06` | migrations, Ash snapshots, Entitlements core if required | `BLOCKED_SHARED_AUTHORITY` | Not executable until required authority is assigned. |
| `SBH-50-02` | Entitlements core only if the implementation requires it | `EXTERNALIZED` | Stop and reclassify as blocked if Entitlements core must change. |
| `SBH-50-03` | Entitlements core only if the implementation requires it | `EXTERNALIZED` | Stop and reclassify as blocked if Entitlements core must change. |
| `SBH-50-04` | Entitlements core only if the implementation requires it | `EXTERNALIZED` | Stop and reclassify as blocked if Entitlements core must change. |
| `SBH-50-05` | Entitlements core only if the implementation requires it | `EXTERNALIZED` | Stop and reclassify as blocked if Entitlements core must change. |
| `SBH-60-01` | PlanRevision migration: per-SubscriptionPlan `EFFECTIVE` uniqueness only; corresponding `plan_revisions` Ash snapshot only | `AUTHORITY_ASSIGNED` | Completed task-specific PlanRevision migration/snapshot authority. The authority was used only for `SBH-60-01` and grants no further execution authority after closure. |
| `SBH-60-02` | no shared modification identified in this contract | `NONE` | Semantic dependencies still block admission. |
| `SBH-70-02` | no shared modification identified in this contract | `NONE` | Completed lane-local task; no further admission. |
| `SBH-80-01` | no shared modification identified in this contract | `NONE` | Completed lane-local task; no further admission. |
| `SBH-80-02` | no shared modification identified in this contract | `NONE` | Completed lane-local adversarial proof; no further admission. |
| `SBH-80-03` | provider business contracts only if a provider contract must change | `EXTERNALIZED` | Use existing provider evidence; stop if a shared change is required. |
| `SBH-90-01` | no shared modification identified in this contract | `NONE` | Semantic dependencies still block admission. |

Migration-sensitive foundations must not become executable merely because semantic
dependencies are frozen. Shared blockers are task-specific, not programme-wide.
If the correct Subscription fix requires a shared surface without authority:

```text
current item → BLOCKED_SHARED_AUTHORITY → STOP
```

Do not "helpfully" fix the neighbouring domain.

## 24.1 Current hardening matrix

Every implementation row has a frozen scope. `State` below is its current
register state. `SBH-10-01`, `SBH-10-02`, `SBH-30-02`, `SBH-60-01`,
`SBH-70-02`, `SBH-80-01`, and `SBH-80-02` are `CLOSED`. The canonical
`READY` implementation/proof row count is zero. The recorded `loop_eligible`
values remain register metadata; human selection is still required under the
serial workflow before a `READY` row may enter implementation.

| ID | Class | Priority | State | Loop eligible |
|---|---|---:|---|---:|
| `SBH-10-01` | foundational spine | — | `CLOSED` | No |
| `SBH-10-02` | foundational spine | — | `CLOSED` | No |
| `SBH-20-01` | foundational spine | — | `BLOCKED_SHARED_AUTHORITY` | No |
| `SBH-10-06` | foundational spine | — | `BLOCKED_SHARED_AUTHORITY` | No |
| `SBH-10-03` | foundational spine | — | `BLOCKED_DEPENDENCY` | No |
| `SBH-10-04` | foundational spine | — | `BLOCKED_DEPENDENCY` | No |
| `SBH-10-05` | foundational spine | — | `BLOCKED_DEPENDENCY` | No |
| `SBH-20-02` | foundational/concurrency | — | `BLOCKED_DEPENDENCY` | No |
| `SBH-20-03` | foundational/concurrency | — | `BLOCKED_DEPENDENCY` | No |
| `SBH-20-04` | foundational/concurrency | — | `BLOCKED_DEPENDENCY` | No |
| `SBH-20-05` | foundational/concurrency | — | `BLOCKED_DEPENDENCY` | No |
| `SBH-30-02` | independent lane-local | P1 | `CLOSED` | No |
| `SBH-30-03` | dunning boundary | — | `BLOCKED_DEPENDENCY` | No |
| `SBH-30-04` | shared-boundary hardening | — | `BLOCKED_DEPENDENCY` | No |
| `SBH-30-05` | dunning boundary | — | `BLOCKED_DEPENDENCY` | No |
| `SBH-40-02` | shared-boundary hardening | — | `BLOCKED_DEPENDENCY` | No |
| `SBH-40-03` | cancellation proof | — | `BLOCKED_DEPENDENCY` | No |
| `SBH-50-06` | shared-boundary hardening | — | `BLOCKED_SHARED_AUTHORITY` | No |
| `SBH-50-02` | shared-boundary hardening | — | `BLOCKED_DEPENDENCY` | No |
| `SBH-50-03` | shared-boundary hardening | — | `BLOCKED_DEPENDENCY` | No |
| `SBH-50-04` | shared-boundary hardening | — | `BLOCKED_DEPENDENCY` | No |
| `SBH-50-05` | shared-boundary hardening | — | `BLOCKED_DEPENDENCY` | No |
| `SBH-60-01` | commercial availability | — | `CLOSED` | No |
| `SBH-60-02` | commercial availability | — | `BLOCKED_DEPENDENCY` | No |
| `SBH-70-02` | independent lane-local | P1 | `CLOSED` | No |
| `SBH-80-01` | independent lane-local | P1 | `CLOSED` | No |
| `SBH-80-02` | payment-method proof | — | `CLOSED` | No |
| `SBH-80-03` | shared-boundary race proof | — | `BLOCKED_DEPENDENCY` | No |
| `SBH-90-01` | billing safety | — | `BLOCKED_DEPENDENCY` | No |

An em dash in the Priority column means this reconciliation assigns no priority
to that row. No other priority is inferred.

`READY` means the row has satisfied its frozen semantic prerequisites and any
required external dependency/shared-authority conditions identified by its
current contract.

A `READY` row may have no shared modification, or it may have an explicitly
`AUTHORITY_ASSIGNED` shared surface.

`READY` makes the row eligible for explicit human selection only; it does not
authorize automatic execution. Before implementation, the selected row must
pass the current serial admission checks, receive a bounded exact-base task
contract, and branch from the current explicitly accepted SUBS tip.

`READY` does not mean selected, implementation started, or automatic execution.
It means only that all current admission blockers for this bounded task have
been resolved sufficiently for explicit human selection under
`SERIAL / EXPLICIT HARDENING`.

If task-level inspection discovers an additional required shared modification
that is not covered by the row's existing authority assignment, STOP and
reclassify the task as `BLOCKED_SHARED_AUTHORITY` rather than expanding authority
silently. Authority remains task-specific; this register grants no authority to
make a shared change beyond what is explicitly assigned to that row.

The recorded human-owner priority decision was:

```text
SBH-30-02 = P1
SBH-70-02 = P1
SBH-80-01 = P1
```

`SBH-10-01`, `SBH-10-02`, `SBH-30-02`, `SBH-60-01`, `SBH-70-02`,
`SBH-80-01`, and `SBH-80-02` remain `CLOSED`. There are zero canonical
`READY` implementation/proof rows. No downstream row is promoted by the
v0.1.22 closure. `SBH-20-01`, `SBH-10-06`, and `SBH-50-06` remain
`BLOCKED_SHARED_AUTHORITY / No`. `SBH-10-03` remains
`BLOCKED_DEPENDENCY / No` because its frozen prerequisites are
`SBH-10-02` + `SBH-20-01` + `SBH-10-06`; closure of `SBH-10-02` satisfies only
its own edge. The `SBH-10-02` authority is completed provenance for the named
Checkout/Orders/Subscriptions purchase-binding surfaces and does not alter the
frozen dependency edges. The P1 labels provide no severity ordering.

---

# 25. Current Serial Branch Rule

Persistent worktree:

```text
/home/jcschoeman96/projects/current/Store_Blueprint_Hardening-subscriptions
```

Persistent workstream branch:

```text
hardening/subscriptions
```

Task-branch namespace:

```text
subs-task/<canonical-id>-<short-description>
```

Examples:

```text
subs-task/sbh-10-01-plan-revision-foundation
subs-task/sbh-20-02-renewal-cancellation-race
subs-task/sbh-30-02-retry-offset-semantics
```

Do not use:

```text
hardening/subscriptions/<child>
```

because `hardening/subscriptions` is already an existing Git ref.

For each selected issue, fetch current refs, verify the current canonical
`hardening/subscriptions` tip, and create the task branch from that exact
explicitly accepted tip. Record the exact tip as `task_base_sha` in the task
evidence and do not silently rebase during the task. This rule is subordinate
to canonical `main` governance and does not create a second lifecycle value.

---

# 26. One-Task / One-Branch Rule

Each selected implementation item maps to:

```text
one bounded contract
one task branch
one TDD cycle
one PR
one independent review
```

A task is branch-sized only if a reviewer could meaningfully approve or reject it independently of neighbouring tasks.

Do not combine:

```text
commercial-contract architecture
+ optimistic locking
+ cancellation
+ entitlement repair
```

into one PR.

---

# 27. Current Serial Task Admission

An item may enter the current serial workflow only when all are true:

The register state is exactly `READY`; relevant Product/Architecture/Domain law
is frozen; acceptance criteria are deterministic; a human explicitly selected
this issue; current `origin/main` governance and current
`origin/hardening/subscriptions` are inspected; required dependencies and shared
authority are present; the objective is bounded; and allowed/forbidden write
scope is explicit. `loop_eligible` remains historical/register metadata only.

```text
state == READY
human_selected == true
SUBS lifecycle == READY
governance_authority_sha == current accepted canonical governance
task_base_sha == exact current explicitly accepted SUBS tip
product / architecture law == frozen
acceptance criteria == deterministic
```

Then perform task-level admission:

```text
required external capability absent from the accepted task base
→ BLOCKED_EXTERNAL_DEPENDENCY for this item
→ STOP this item and return to human selection

shared boundary required without AUTHORITY_ASSIGNED
→ BLOCKED_SHARED_AUTHORITY for this item
→ STOP this item and return to the owning authority
```

Do not globally block SUBS merely because another workstream or `main` advanced.

At most one SUBS implementation issue may be active through this workflow. If no
human-selected READY item is available:

```text
NO_HUMAN_SELECTED_READY_TASK
STOP
```

If implementation reveals a new authority problem, scope expansion,
shared-boundary dependency, migration requirement, or upstream contradiction,
stop at the owning authority level. The coding agent cannot reinterpret this
rule or manufacture READY work.

---

# 28. Historical Autonomous Batch Rule (superseded)

The remainder of this section records the former controller's batch ceiling and
independence rule as historical provenance only. It is not current execution
authority; no autonomous batch, batch identifier, or controller resumption is
required or permitted for serial SUBS work.

A single autonomous implementation-loop invocation may complete:

```text
0..3
```

successful independent items.

Never "exactly three."

Each candidate in the same batch must have no unresolved dependency on another candidate in that batch.

If:

```text
SBH-B requires SBH-A to be merged first
```

then they cannot be processed in the same autonomous batch.

Early contract/concurrency work is expected to produce many one-item batches.

---

# 29. Current Serial Per-Task Execution

Every selected issue follows one bounded task sequence:

```text
VERIFY CURRENT GOVERNANCE AND SUBS AUTHORITY
    ↓
MATERIALIZE ONE BOUNDED READY TASK
    ↓
CREATE ONE TASK BRANCH FROM EXACT task_base_sha
    ↓
TDD / MINIMAL IMPLEMENTATION
    ↓
FOCUSED VERIFICATION
    ↓
FRESH INDEPENDENT REVIEW
    ↓
REQUIRED REPOSITORY GATES / EXACT-HEAD PR CI
    ↓
HUMAN MERGE DECISION
    ↓
REFRESH CANONICAL SUBS AUTHORITY
    ↓
SELECT THE NEXT ISSUE ONLY THEN
```

The task contract must include the performance/scaling review,
security/multi-tenant review, named neighbouring regressions where relevant,
and explicit STOP conditions. The agent never merges automatically.

The former controller sequence below is retained as historical provenance and
must not be executed.

Once implementation authority exists:

```text
VERIFY AUTHORITY
    ↓
SELECT ONE READY ITEM
    ↓
CREATE TASK BRANCH
    ↓
LOAD EXACT CONTRACT + RELEVANT SOURCE + TESTS
    ↓
WRITE DETERMINISTIC FAILING TEST
    ↓
PROVE RED
    ↓
MINIMAL IMPLEMENTATION
    ↓
PROVE GREEN
    ↓
RUN FOCUSED QUALITY GATES
    ↓
RUN REQUIRED FULL / RELEVANT QUALITY GATES
    ↓
SELF-REVIEW EXACT DIFF
    ↓
COMMIT
    ↓
PUSH
    ↓
OPEN DRAFT PR
    ↓
RECORD RESULT
    ↓
RETURN TO SELECTOR
```

After three successful PRs:

```text
MANDATORY STOP
```

The coding agent never merges.

---

# 30. New-Finding Rule

During implementation an agent may discover something outside the current task.

Allowed:

```text
record candidate finding
capture evidence
identify affected boundary
continue the current task if still safe
```

Forbidden:

```text
self-authorize new task
expand current branch
modify neighbouring domain
promote candidate directly to READY
```

New finding lifecycle:

Once recorded as `CANDIDATE`, a new finding follows the canonical hardening-item
lifecycle defined in §6 and may not skip a stage. It is not automatically
selected for a later serial task.

`NOT_APPLICABLE` and `EXTERNALIZED` remain explicit review outcomes after
validation when appropriate. A finding may not move directly to implementation.

---

# 31. Agent Skills and Minimum Tools

## 31.1 Diagnosis tasks

Primary skill:

```text
$diagnosing-bugs
```

Supporting instruction where available in the coding environment:

```text
@unslop
```

Minimum tools:

```text
git
gh
shell
filesystem/search
relevant existing diagnostic/test command
```

No implementation skill unless a later task explicitly authorizes a fix.

## 31.2 Implementation tasks

Primary skill:

```text
$tdd
```

Supporting instruction where available:

```text
@unslop
```

Minimum tools:

```text
git
gh
shell
filesystem/search
mix
existing repository quality commands
test PostgreSQL where required
```

Additional tools are forbidden unless the exact task proves them necessary.

---

# 32. Historical Autonomous STOP Conditions (superseded)

The autonomous batch/controller STOP taxonomy below is retained as historical
evidence only. Current serial work stops the selected task at the owning
authority level whenever its scope, dependency, migration, law, review, or CI
assumptions fail; it never widens the task or starts another issue.

## 32.1 STOP the entire batch when

1. Three successful draft PRs exist.
2. Authorized base SHA moves.
3. `hardening/subscriptions` moves unexpectedly.
4. SUBS loses `READY/ACTIVE_PARALLEL` authority or its accepted development base is invalidated.
5. Governance/ownership authority changes materially.
6. Required baseline CI becomes red before the next task.
7. No executable READY loop-eligible item remains after task-level dependency/shared-authority admission.
8. The worktree path/branch/upstream disagrees with the active registry.

## 32.2 STOP the current item when

9. Required shared migration authority is absent.
10. Correct remediation requires unauthorized Payments, Orders, Entitlements, Inventory, Platform, Auth, CI, or governance modification.
11. A business/product rule remains ambiguous.
12. A new lifecycle state/resource becomes necessary but has not been authorized.
13. Two proper correction attempts fail.
14. Two iterations produce no meaningful progress.
15. Deterministic acceptance criteria cannot be satisfied.
16. A shared migration materially changes another domain's ownership.
17. Production access, credentials, deployment, or destructive operations would be required.
18. Dependency assumptions become stale.
19. Provider or shared-domain behaviour contradicts the frozen task contract.
20. A task begins to require architectural redesign beyond its approved boundary.

## 32.3 Never

21. Merge a PR.
22. Deploy.
23. Change production.
24. Accept risk on behalf of the owner.
25. Implement newly discovered candidate findings.
26. Begin a fourth item.
27. Use Redis as authoritative Subscription truth.
28. Add broad distributed locking without explicit architecture authority.
29. Fix unrelated failing infrastructure merely to obtain a green badge.
30. Rewrite strong renewal-idempotency mechanisms without evidence.

---

# 33. Hardening Matrix Closure States

The current matrix is an admission register, not the programme closure record.
Its implementation rows may remain `CONTRACT_FROZEN`, `READY`,
`BLOCKED_DEPENDENCY`, or `BLOCKED_SHARED_AUTHORITY` while the required work is
outstanding. Audit rows remain open and pending proof is not `PROVEN_GOOD`.

At final programme closure, every completed matrix row must end in exactly one of:

```text
PROVEN_GOOD
RESOLVED
NOT_APPLICABLE
EXTERNALIZED
ACCEPTED_RISK
```

Before final closure, these are valid current register states:

```text
CONTRACT_FROZEN
READY
BLOCKED_DEPENDENCY
BLOCKED_SHARED_AUTHORITY
```

`CANDIDATE` and `VALIDATED` remain valid states in the new-finding lifecycle.
They are not evidence of closure and cannot be promoted directly to
implementation. Audit work remains open outside this closure-state list. No new
persistent SUBS lifecycle state is introduced.

---

# 34. Final Exhaustion / Certification Gate

Subscription Backbone Hardening is complete only when all of the following are true:

- every meaningful Subscription concept has explicit states, transitions, guards, side effects, recovery rules, and terminal states;
- effective commercial contracts cannot drift underneath existing subscriptions;
- every external renewal payment is bound to immutable charged-contract evidence;
- paid reconciliation applies the exact charged contract;
- stale Subscription mutations are rejected;
- renewal/cancel/change/expiry races have deterministic tests;
- payment success cannot regress to stale failure;
- dunning retry, grace, suppression, recovery, and terminal semantics match the frozen contract;
- scheduled cancellation reaches a deterministic terminal lifecycle outcome;
- access-effect obligations are durable and idempotent;
- Subscription and Entitlement truth can be reconciled;
- `access_on_past_due` and `access_on_cancel` have executable semantics or are explicitly unsupported;
- new-sale/change eligibility is distinct from grandfathered existing-contract renewal;
- RenewalAttempt success is monotonic;
- StoredPaymentMethod revocation semantics are explicit;
- timezone-sensitive contracts fail closed;
- term/trial/provider-managed configuration is either executed correctly or explicitly unsupported;
- provider webhook replay/order/missing-event behaviour is proven;
- Subscription authorization matrix is proven;
- worker crash/retry boundaries are proven;
- critical query paths are indexed;
- no unnecessary authoritative Redis lifecycle state exists;
- no peak-time analytics/reconciliation design requires large base-table scans;
- exact-head CI is green;
- final adversarial concurrency/failure-injection suite is green;
- independent final review returns PASS.

---

# 35. Success Criteria for the Programme

The programme succeeds when the Subscription subsystem can answer, deterministically and from durable evidence:

```text
What exact contract is this customer on?
Which contract revision was this renewal charging?
What exact price/currency/variant/period did the provider payment purchase?
What happened if cancellation raced the payment?
Why is the Subscription in its current state?
Why is it past due?
Which retry is next?
When does grace actually end?
Why did access remain or disappear?
Can the operation be safely retried?
Can a late event regress proven success?
Can an archived/retired offer still renew an existing grandfathered contract?
```

The answer must not depend on reconstructing mutable historical plan state from today's configuration.

---

# 36. Historical v0.1.5 Immediate Next Authorized Candidate

No Subscription production implementation is authorized yet.

This section is historical v0.1.5 control-plane narration retained for
provenance only. It is not the current next action. The current v0.1.7 path
requires separate external runtime-state reconciliation before a fresh
`SUB-ACT-04` admission attempt.

JC-223 completion boundary and the next gate are:

```text
JC-219 / JC-220 / JC-221 / JC-222 / JC-223
    CONTRACT_FROZEN / CANONICAL; SBH-00-01..05 loop_eligible = No
    ↓
merge this bounded content PR to hardening/subscriptions
    ↓
verify the exact merged target against the fixed authority
    ↓
merge the separate main-governance registry refresh
    ↓
independently verify the merged main-governance registry refresh
    ↓
only then start SUB-ACT-04  freeze Batch 001 base + v1.3/v1.4 admission recertification
```

Do not start `SUB-ACT-04` in this PR. `batch_base_sha` remains null and unfrozen,
and this register does not set `ACTIVE_PARALLEL` or authorize production work.

No step requires continuous S0 synchronization merely because S0 moved.

# 37. Historical SUB-CP-02 Record

`SUB-CP-02` is retained only as provenance for an old PR #8 CI-attribution investigation. Its Subscription-side conclusion was that the relevant failure belonged outside SUBS. It is no longer the next candidate and must not be used to reintroduce a global control-plane blocker.

Do not run the historical diagnostic again unless new exact evidence explicitly reopens it.

---

# 38. Recommended Governance Relationship

The system maintains five distinct authority layers:

```text
CANONICAL GOVERNANCE AUTHORITY
    latest accepted governance on origin/main

PROGRAMME AUTHORITY
    defines SUBS scope, exclusions, lifecycle/product law

DEVELOPMENT BASE
    accepted exact SUBS code SHA for independent hardening

HARDENING REGISTER
    defines validated findings, dependencies, task eligibility

TASK CONTRACT
    defines exactly one branch-sized executable unit
```

A sixth SHA role appears only at integration time:

```text
INTEGRATION BASE
    latest accepted canonical main used for convergence before integration
```

The coding agent executes one Task Contract against the exact `task_base_sha`
recorded for that issue. It does not own programme/governance authority, may
not manufacture READY work, and may not silently rebase during the task.

---

# 39. Current Serial Operating Cadence

```text
REVIEW / GOVERNANCE
    ↓
validate findings and freeze laws
    ↓
human selects one canonical READY issue
    ↓
inspect current main and SUBS authorities
    ↓
record exact task_base_sha and bounded scope
    ↓
one task branch / TDD / focused verification
    ↓
fresh independent review / repository gates / exact-head CI
    ↓
human merge decision
    ↓
refresh canonical SUBS tip
    ↓
human selects the next issue
```

This is the current subscription-hardening discipline. No automatic task
selection, batch ceiling, controller claim, or runtime reconciliation is part of
it.

---

# 40. Historical v0.1.8 Final Verdict (superseded)

The following verdict is retained as dated historical evidence. Its controller,
Batch 001, `ACTIVE_PARALLEL`, and runtime-gate conclusions no longer describe
current authority.

```text
SUBSCRIPTION ENGINE:
Strong foundation.
Not production-hardened yet.

PRIMARY RELEASE BLOCKER:
Immutable commercial-contract authority across asynchronous renewal execution.

REQUIRED SUPPORTING HARDENING:
Subscription optimistic concurrency.
Dunning correctness.
Scheduled cancellation completion.
Durable entitlement/access convergence.
Availability/grandfathering law.
RenewalAttempt monotonicity.
Payment-method semantics.
Billing-timezone safety.
Provider/event/recovery certification.

CANONICAL GOVERNANCE:
Historical v0.1.6 reconciliation-base observation: `origin/main` =
baeac140f68db80643b76626e99387089821f790 and
`origin/hardening/subscriptions` =
81d203df8cd0c63f87e7fa7bf5bc02aea9e730ae, the reconciliation base and
post-PR #26 SUBS authority. The canonical v0.1.6 SUBS authority SHA is
established only by exact post-merge verification of PR #27 and is not embedded
in this document. The JC-223 authorization hashes remain historical provenance
in §2.7.

CURRENT IMPLEMENTATION AUTHORITY:
NONE. SUBS READY authorizes governance/review only; Batch 001 and SUB-ACT-04 admission remain outstanding. `batch_base_sha` is null and unfrozen.

CURRENT WORKSTREAM STATE:
READY / GOVERNANCE-REVIEW ONLY / JC-223 DEPENDENCY GRAPH FROZEN.

CURRENT VERDICT:
SUBS_JC_223_DEPENDENCY_GRAPH_FROZEN / SUB-ACT-04_RUNTIME_TRANSITION_CONTRACT_COMPLETE.

HISTORICAL v0.1.3 CANDIDATE:
77a272c3887a7ab46e84a7fed02163d964e37b9b.

ACCEPTED DEVELOPMENT BASE RECORD:
575ffa1848ac69abe855bd018c7ae8eaf05d61e4 (SUB-ACT-01 accepted development base).

NEXT AUTHORIZED GATE:
After the v0.1.8 authority is independently verified, read the actual current
`origin/hardening/subscriptions`. Reconcile the external runtime state
separately, then rerun `SUB-ACT-04` against that verified current authority.
Only a passing fresh admission may atomically freeze `batch_base_sha`, set
`batch_id = SUBS-BATCH-001`, grant `ACTIVE_PARALLEL`, and start Batch 001.

FINAL ACTION:
After the v0.1.8 authority is independently verified, read the actual current
`origin/hardening/subscriptions` and complete the separate external runtime-
state reconciliation against it. Independently verify that reconciliation, then
rerun `SUB-ACT-04` as a fresh Batch 001 base and implementation-admission
recertification. Production implementation remains unauthorized until that gate
passes.
```

---

# 41. Historical v0.1.21 Serial Verdict

This section preserves the v0.1.21 serial verdict as a point-in-time record.
The current v0.1.22 verdict below supersedes its state and READY-count claims.

```text
SUBS lifecycle = READY
SUBS execution policy = SERIAL / EXPLICIT HARDENING
current authority = canonical main governance ac1fd264de35522c010bdcc552b0ba22183cbca4
canonical READY implementation/proof rows = 1
canonical READY row = SBH-10-02
```

```text
SBH-60-01 = CLOSED / No
SBH-60-01 shared authority = AUTHORITY_ASSIGNED (completed provenance only)
SBH-10-02 = READY / No
SBH-10-02 shared authority = AUTHORITY_ASSIGNED (current task-specific grant)
SBH-10-06 = BLOCKED_SHARED_AUTHORITY / No
SBH-20-01 = BLOCKED_SHARED_AUTHORITY / No
SBH-50-06 = BLOCKED_SHARED_AUTHORITY / No
```

This v0.1.21 governance-only admission amendment records the human
owner-approved task-specific shared-authority grant for `SBH-10-02` and moves
that row from `BLOCKED_SHARED_AUTHORITY / No` to `READY / No`. It changes no
frozen JC-223 dependency edge and promotes no downstream row.

The prior v0.1.20 closure of `SBH-60-01` at merge
`3ee071cfd0daa927d0d3563771d2711bb0abb974` (PR `#53`) remains historical
provenance.

This v0.1.21 amendment does not start `SBH-10-02` implementation. No
implementation branch or implementation `task_base_sha` is assigned here. The
exact implementation base may be recorded only after this governance amendment
is merged, canonical SUBS authority is refreshed, and the human separately
selects `SBH-10-02` for implementation.

The v0.1.18 JC-219 Domain Law is unchanged. For one SubscriptionPlan, at most
one PlanRevision may be `EFFECTIVE`; `DRAFT → EFFECTIVE → RETIRED` remains
unchanged. Zero `EFFECTIVE` is valid but unavailable for selection, one is the
exact canonical candidate, and more than one is a prohibited durable invariant
violation.

```text
for one SubscriptionPlan:
count(EFFECTIVE PlanRevision) <= 1

0 EFFECTIVE → valid / selection unavailable
1 EFFECTIVE → exact canonical candidate
>1 EFFECTIVE → prohibited durable invariant violation
```

The owner-approved JC-219 legacy binding compatibility amendment and canonical
EFFECTIVE-revision selection amendment are canonical, both with approval dated
`2026-09-21`. For one SubscriptionPlan, at most one PlanRevision may be
`EFFECTIVE`. `EFFECTIVE` is the current immutable new-sale/change candidate,
subject to independent Plan, attachment, and Catalog eligibility. Zero
`EFFECTIVE` revisions is allowed and fails closed; multiple `EFFECTIVE`
revisions are a database-invariant violation and fail closed. `RETIRED`
revisions remain immutable historical evidence and may remain valid for
grandfathered existing bindings.

The legacy law still forbids using the current mutable `SubscriptionPlan` or
current `EFFECTIVE` revision as historical fallback. A pre-PlanRevision
Subscription whose complete historical contract cannot be proven may remain
explicitly unresolved and must fail closed for operations requiring unproven
contract truth. This compatibility condition is not a Subscription lifecycle
state. Forward-created Subscriptions must bind the exact selected `EFFECTIVE`
PlanRevision once the selection capability is active.

At the v0.1.21 admission point, `SBH-10-02` was `READY / No` after the human
owner assigned the bounded task-specific Checkout, immutable Orders
purchase-evidence,
`order_line_items` migration/Ash snapshot, Subscription binding,
`subscriptions` migration/Ash snapshot, and focused proof authority recorded
above. Its semantic dependency on `SBH-10-01` is satisfied, and its
EFFECTIVE-selector capability prerequisite is satisfied by closed
`SBH-60-01`.

The frozen JC-223 edge remains `SBH-10-02` depends on `SBH-10-01`;
`SBH-60-01` is not added as a dependency edge.

`SBH-10-06` remains `BLOCKED_SHARED_AUTHORITY / No` and receives no
ContractChange or future-target authority. `SBH-20-01` and `SBH-50-06` also
retain their own shared-authority blockers. No downstream row is promoted by
the `SBH-10-02` admission.

`SBH-60-01` is `CLOSED / No` after implementation of the canonical
`PlanRevision.get_effective_for_plan/2` EFFECTIVE selector, PostgreSQL partial
unique enforcement, competing-publication proof, exact-head required CI, fresh
independent final review, content-equivalent merge verification, and post-sync
`mix check` / `git diff --check`. Successful final task head
`248f7e2d365e99a8072b4b7dec5ffb5f99bc3de8`; PR `#53` merged as
`3ee071cfd0daa927d0d3563771d2711bb0abb974` (CI run `35704318935`). Task-specific
PlanRevision migration/Ash-snapshot authority is completed provenance only and
grants no further execution authority. At the v0.1.20 `SBH-60-01` closure
point, zero canonical `READY` implementation/proof rows remained. The later
v0.1.21 owner decision independently admits `SBH-10-02` and does not derive
authority from the completed `SBH-60-01` grant.

`SBH-10-01` is `CLOSED` after implementation of the JC-219 PlanRevision
foundation, exact-head required CI, human merge, content-equivalent merge
verification, and post-merge independent final review. The final corrected PR
head was `de62b108015ebed1290b960efb6bdfb2e5c82baf`; PR `#46` merged as
`945214761a736c66659b375c6005da470605828a`. All five required CI jobs passed on
`de62b108...` before merge (CI run `35621281204`). The fresh independent review
of the corrected final head occurred after merge; that review-order deviation
remains historical provenance. The v0.1.21 admission then left exactly one
canonical `READY` implementation/proof row, `SBH-10-02`. No implementation task
was selected by that governance amendment.

`SBH-80-02` is `CLOSED` after adversarial proof, merge, and post-merge recovery
verification. Its proof correctness is recovered/verified at current canonical
tip `71eba2d321e75f266a5c4da52836de7f6cae4cf8`. The final PR-head gate deviation
at `55343ce7c657cc489c1bd923a6bc2dd6b5fe62d4` remains historical provenance and
is not retroactively converted to PASS.

`SBH-80-01` is `CLOSED` after successful implementation, exact-head
verification, human merge, and exact post-merge verification. Successful PR #40
merged at `562ccc40fd33a3e1530974e90087e70753d0a914`; exact-head required CI,
fresh independent final review after corrections, exact post-merge verification,
post-sync focused revocation suite (15/15), post-sync neighbouring suites
(29/29), post-sync `mix check`, and post-sync `git diff --check` are recorded
in the `SBH-80-01` completion provenance above.

`SBH-70-02` is `CLOSED` after exact post-merge verification. Successful PR #38
merged at `0ab0e6bf94590073fcb168a37e4ada5bb180f326`; exact-head required CI,
fresh independent review, exact post-merge verification, post-sync `mix check`,
and focused post-sync monotonicity suite are recorded in the `SBH-70-02`
completion provenance above.

`SBH-30-02` is `CLOSED` after exact post-merge verification. Successful PR #36
merged at `91c391cae894a61869c0bc2ad77b0d02eac5ed10`; exact-head required CI,
independent review, exact post-merge verification, and post-sync `mix check`
are recorded above. PR #33 remains closed historical evidence at HEAD
`a03a4534d6373dd9a0ff99c32c95b30d62f918f8` and was superseded by PR #36.

`SBH-80-03` remains `BLOCKED_DEPENDENCY`. Only the `SBH-80-01` dependency within
its frozen edge set is satisfied; `SBH-20-01`, `SBH-10-03`, and `SBH-10-04`
remain unresolved. Closing `SBH-80-02` does not satisfy any missing `SBH-80-03`
dependency. No other downstream row is promoted by this reconciliation.

One bounded issue may be active at a time when a row is admitted as `READY`.
Each selected issue must use a current governance check, an exact `task_base_sha`
from the current explicitly accepted SUBS tip, TDD/minimal implementation where
required, focused verification, fresh independent review, repository gates,
exact-head PR CI, and a human merge decision. The SUBS tip is refreshed before
another issue is selected.

`SUB-ACT-04`, Batch 001, `ACTIVE_PARALLEL`, frozen batch bases, batch IDs,
controller claims/counters, autonomous runtime, and controller CI-cycle
accounting remain historical provenance only. They do not grant serial
implementation authority or require runtime reconciliation for future issues.

# 42. Current v0.1.22 Serial Verdict

```text
SUBS lifecycle = READY
SUBS execution policy = SERIAL / EXPLICIT HARDENING
current authority = canonical hardening/subscriptions 09eb02b4a836a9db7156bdd5cc5e9fc722128d54
canonical READY implementation/proof rows = 0
```

```text
SBH-10-02 = CLOSED / No
SBH-10-02 shared authority = AUTHORITY_ASSIGNED (completed provenance only)
SBH-20-01 = BLOCKED_SHARED_AUTHORITY / No
SBH-10-06 = BLOCKED_SHARED_AUTHORITY / No
SBH-50-06 = BLOCKED_SHARED_AUTHORITY / No
SBH-10-03 = BLOCKED_DEPENDENCY / No
```

SBH-10-02 closed after successful PR `#64`, certified implementation head
`f20051c1a52c7e4bbad84ac6d8d26cdaa4f209d7`, exact-head CI run `35847542507`
with all five required jobs passing, independent implementation review verdict
`PASS`, and a merge tree identical to the certified head. The merge SHA and
reconciliation base are both
`09eb02b4a836a9db7156bdd5cc5e9fc722128d54`.

Its Checkout/Orders/Subscriptions purchase-binding authority was consumed only
for SBH-10-02. It grants no reusable authority or further execution authority
after closure. No downstream row was promoted, no other row is READY, no next
implementation task was selected, and no new shared authority was assigned.

The frozen JC-223 dependency graph is unchanged. SBH-10-02 closure satisfies
only its own prerequisite edge for SBH-10-03; SBH-20-01 and SBH-10-06 remain
unsatisfied, so SBH-10-03 remains dependency-blocked.
