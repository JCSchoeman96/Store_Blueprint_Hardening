# Store Blueprint Hardening — Subscription Hardening Master Register

**Version:** v0.1.4
**Status:** WORKING / APPROVED DESIGN — SUBS READY / JC-219 + JC-220 + JC-221 + JC-222 CONTRACT_FROZEN
**Verified:** 2026-09-16
**Repository:** `JCSchoeman96/Store_Blueprint_Hardening`  
**Workstream:** Subscription Backbone Hardening (`SUBS`)  
**Persistent worktree:** `/home/jcschoeman96/projects/current/Store_Blueprint_Hardening-subscriptions`  
**Persistent workstream branch:** `hardening/subscriptions`

> **Canonical SUBS governance artifact:**
> `docs/hardening/subscriptions/SUBSCRIPTION_HARDENING_MASTER_REGISTER.md`
>
> This document records the independently verified SUBS activation, the owner-approved JC-219 architecture, and the Stage B JC-220/JC-221/JC-222 governance freeze. The canonical Subscription domain/lifecycle/race map lives in `docs/hardening/01_domain_map.md`; scheduling terms are reconciled in `docs/governance/subscription_scheduling_terms.md`. This register does **not** authorize migrations, shared-domain changes, Batch 001, or production implementation.

---

# 1. Programme Objective

Systematically prove, harden, and close every material correctness, lifecycle, concurrency, commercial-contract, authorization, recovery, observability, and performance risk in the existing Subscription subsystem without redesigning already-correct mechanisms or crossing workstream authority boundaries.

The programme seeks to guarantee:

> **The contract charged, the contract activated, the Subscription lifecycle state, the payment evidence, and the customer's effective access cannot silently diverge under concurrency, retries, delayed provider events, administrative configuration changes, or partial downstream failure.**

This is a hardening programme, not a subscription rewrite.

---

# 2. Independent Verification Pass — 2026-09-16

This register was checked against the current repository during the Stage B preflight.

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

---

# 3. Current Programme Verdict

```text
SUBS_STAGE_B_GOVERNANCE_FROZEN
```

Canonical governance is no longer the blocker.

Current remaining lane-local work is:

```text
1. merge this bounded Stage B governance change to hardening/subscriptions and verify the exact merged target;
2. perform the separately bounded main-governance registry refresh;
3. freeze the first executable dependency graph and hardening matrix through JC-223 / SBH-00-05;
4. only after those gates, freeze batch_base_sha and perform SUB-ACT-04 admission recertification.
```

No production `SBH-*` implementation task is authorized merely by this register, by SUBS `READY`, or by PR #8.

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
current effective PlanRevision identity
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

`PlanRevision` is the Subscription-owned immutable effective commercial contract.

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

### JC-219 boundary and concurrency consequences

SUBS owns `PlanRevision` commercial semantics, `Subscription` commercial/lifecycle
semantics, `RenewalAttempt` charged-contract semantics, and `ContractChange`
Subscription-owned identity/semantics. Migrations, Ash snapshots, Orders core,
Payments core, Entitlements core, provider contracts, and shared platform
configuration remain shared/external authority. `OrderLineItem` is supporting
immutable order/payment evidence; it is not Subscription contract authority. No shared
domain resource is modified by JC-219.

PostgreSQL remains durable commercial-contract, Subscription-lifecycle, and
charged-occurrence authority. Redis is not contract authority, and a GenServer is not
global Subscription serialization authority. Renewal processing resolves and binds
the authoritative contract once per occurrence and carries immutable evidence through
retries and reconciliation. No cache is required for correctness.

Conceptual lookup/index surfaces for later implementation are:

```text
PlanRevision plan/revision identity
Subscription.current_plan_revision_id
ContractChange subscription/state/effective boundary
RenewalAttempt.plan_revision_id
RenewalAttempt.contract_change_id
existing unique(subscription_id, renewal_key)
```

These are design guidance only; JC-219 creates no schema, migration, or index.

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

## 9.2 Current SUBS activation items

| ID | Task | Current disposition | Loop eligible | Dependency | Expected output |
|---|---|---|---:|---|---|
| `SUB-ACT-00` | Upgrade local loop/register authority from v1.2 to v1.3 parallel semantics | `COMPLETED` | No | PR #8 merged | v1.3 authority upgrade, promotion, and reclassification completed |
| `SUB-ACT-01` | Independently verify and pin SUBS development base | `DEVELOPMENT_BASE_ACCEPTED` | No | ACT-00 | `development_base_sha = 575ffa1848ac69abe855bd018c7ae8eaf05d61e4` accepted |
| `SUB-ACT-02` | Verify activation feasibility, task-level dependencies, and shared-authority usability | `ACTIVATION_FEASIBILITY_PASS` | No | ACT-01 + separately authorized and verified v1.4 runtime compatibility | feasibility pass recorded |
| `SUB-ACT-03` | Record accepted SUBS development base and canonical activation state | `CANONICAL_READY_RECORDED` | No | ACT-01 + ACT-02 PASS + v1.4 runtime compatibility | ordered `BOOTSTRAPPED → BASELINE_PINNED → READY` transitions recorded |
| `SUB-ACT-04` | Freeze Batch 001 base and run v1.3/v1.4 admission recertification | `BLOCKED_DEPENDENCY` | No | ACT-03 + SBH-00-05 | `batch_base_sha` + 0A-P/0A-B/0A-N PASS |

**Hard gate:** production implementation requires canonical SUBS `READY` or `ACTIVE_PARALLEL`, an accepted `development_base_sha`, successful v1.3/v1.4 admission recertification, a frozen `batch_base_sha`, a completed SBH-00 executable dependency graph, and at least one task that passes task-level admission.

`SUB-ACT-02` is a feasibility gate, not implementation admission. It is not executable merely because `SUB-ACT-01` passed. Before it runs, the tracked authority must be v0.1.4 and the external controller state must be compatible with that authority: schema `1.4`, `activation_phase`, and `activation_feasibility` must be present, and any schema migration or runtime reclassification must have been separately authorized and verified. If v0.1.4 authority is tracked while the external runtime remains schema `1.3`, the deterministic result is `LOCAL_AUTHORITY_UPGRADE_REQUIRED → STOP`; `SUB-ACT-02` must not mutate runtime state.

After that compatibility gate, `SUB-ACT-02` must prove that the accepted base, authority package, SUBS ownership, task-specific external-dependency model, shared-authority model, and at least one authorized next governance/review task are usable, with no programme-wide blocker. It must not require `state == READY`, `loop_eligible == true`, or a frozen `batch_base_sha`.

`SUB-ACT-03` recorded two ordered, validated canonical lifecycle transitions. The initial canonical state was `BOOTSTRAPPED`. The accepted `SUB-ACT-01` development base guarded `BOOTSTRAPPED → BASELINE_PINNED`; the `ACTIVATION_FEASIBILITY_PASS` from `SUB-ACT-02` guarded `BASELINE_PINNED → READY`. The resulting canonical lane state is `READY`, and its side effects are recording the accepted `development_base_sha` and making `SBH-00-01` through `SBH-00-04` available as governance/review work in the frozen order. `SUB-ACT-03` did not set `ACTIVE_PARALLEL`, freeze `batch_base_sha`, start Batch 001, or authorize production Subscription implementation.

A sibling lane moving is not itself a blocker.

---

# 10. SBH-00 — Discovery, Contract, and Lifecycle Freeze

These are governance/review tasks. They establish law before production code changes.

The Stage B freeze records JC-219, JC-220, JC-221, and JC-222 as canonical
governance. All four items remain `loop_eligible = No`; canonical does not mean
implementation-authorized. `SBH-00-05` / JC-223 is the next governance step after
this Stage B change is merged and independently verified. It freezes the first
executable dependency graph and hardening matrix before `SUB-ACT-04` can consider
Batch 001.

| ID | Task | Priority | State | Loop eligible | Dependency |
|---|---|---:|---|---:|---|
| `SBH-00-01` | Freeze commercial-contract architecture | P1 | `CONTRACT_FROZEN / CANONICAL` — governance/review only | No | ACT-03 |
| `SBH-00-02` | Populate canonical Subscription domain/lifecycle map | P1 | `CONTRACT_FROZEN / CANONICAL` — governance/review only | No | ACT-03 |
| `SBH-00-03` | Freeze concurrency/race precedence matrix | P1 | `CONTRACT_FROZEN / CANONICAL` — governance/review only | No | 00-01..02 |
| `SBH-00-04` | Freeze cancellation, dunning, access, revocation, and grandfathering laws | P1 | `CONTRACT_FROZEN / CANONICAL` — governance/review only | No | 00-01..03 |
| `SBH-00-05` | Freeze first executable dependency graph and hardening matrix | P1 | `NEXT / AVAILABLE_GOVERNANCE_REVIEW` | No | 00-01..04 verified |

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
provider contracts, or shared platform configuration. Stage B now freezes JC-220,
JC-221, and JC-222 as governance law in the canonical domain map, this register, and
the reconciled scheduling document. JC-223 / SBH-00-05 remains downstream and is not
started by this PR. JC-224, Batch 001, and production implementation remain blocked.

---

# 11. SBH-10 — Immutable Commercial-Contract Authority

Legacy source finding: `SUB-HARD-00`.

## SBH-10-01 — Plan Revision / Approved Contract Foundation

**Priority:** P1 / release blocker  
**Loop eligible:** Yes only after contract freeze and shared migration authority.

Objective:

Implement the exact immutable commercial-contract model approved by `SBH-00-01`.

Proposed branch after activation:

```text
subs-task/sbh-10-01-plan-revision-foundation
```

If the chosen architecture does not use PlanRevision, rename this task before it becomes READY.

Shared authority:

```text
priv/repo/migrations/**
Ash snapshots where applicable
```

must be explicitly assigned.

Performance/scaling:

- PostgreSQL remains durable contract truth.
- immutable revision reads may be cached only if profiling justifies it.
- no Redis authority.
- add FK/lookup indexes required by the chosen model.
- immutable revision caches require no mutation invalidation; sellability/listing caches invalidate on publish/retire metadata changes.

---

## SBH-10-02 — Existing Subscription Contract Binding

Bind each existing Subscription to its exact authoritative commercial contract.

Proposed branch:

```text
subs-task/sbh-10-02-subscription-contract-binding
```

Required:

- deterministic historical backfill;
- no invented contract history;
- STOP where historical meaning cannot be proven;
- explicit compatibility strategy;
- required FK/query indexes;
- no unrelated cross-domain change.

---

## SBH-10-03 — Immutable RenewalAttempt Charged-Contract Snapshot

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

Proposed branch:

```text
subs-task/sbh-10-04-bound-renewal-initiation
```

Invariant:

> Once a RenewalAttempt contract is frozen, provider-payment construction must use that evidence rather than re-resolving mutable current/pending Subscription/Plan state.

---

## SBH-10-05 — Reconciliation Applies Charged Contract Only

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

Proposed branch:

```text
subs-task/sbh-20-02-renewal-cancellation-race
```

Invariant:

> Cancellation and an in-flight provider payment must resolve according to the frozen precedence law; optimistic-lock failure after provider acceptance is not sufficient by itself.

Compensation/reconciliation must be explicit where necessary.

---

## SBH-20-03 — Renewal vs Contract / Variant Change

Proposed branch:

```text
subs-task/sbh-20-03-renewal-contract-change-race
```

Invariant:

> A renewal already bound to Contract X cannot be mutated into Contract Y by a later queued change.

---

## SBH-20-04 — Paid Reconciliation vs Expiry

Proposed branch:

```text
subs-task/sbh-20-04-reconciliation-expiry-race
```

Preserve proven payment evidence while obeying the frozen terminal-state law.

---

## SBH-20-05 — Success vs Late Failure / Dunning

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

Review-only.

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

Loop eligible: No.

---

## SBH-30-02 — Correct Retry Schedule Offset Semantics

Current implementation prevents configured zero-hour retry semantics by forcing offsets through a minimum of 24 hours.

Proposed branch:

```text
subs-task/sbh-30-02-retry-offset-semantics
```

TDD must cover:

```text
0-hour offset
24-hour offset
72-hour offset
schedule exhaustion / edge selection
normalized schedule behaviour
```

---

## SBH-30-03 — Separate Retry Exhaustion from Suspension Boundary

Proposed branch:

```text
subs-task/sbh-30-03-retry-grace-separation
```

Invariant:

> Retry-budget exhaustion leaves the Subscription `PAST_DUE` and stops automatic retries. It does not terminate the relationship or substitute for the governed `PAST_DUE → SUSPENDED` boundary.

---

## SBH-30-04 — Enforce Failed-Payment Suspension Boundary

Proposed branch:

```text
subs-task/sbh-30-04-dunning-suspension-boundary
```

Depends on `SBH-30-01` and `SBH-30-03`.

---

## SBH-30-05 — Dunning Adversarial Boundary Suite

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

Review-only.

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

Proposed branch:

```text
subs-task/sbh-40-02-period-end-cancellation
```

Current due selection suppresses scheduled rows, so a separate durable boundary-completion path must exist.

Use durable async execution where appropriate.

Do not poll from the UI.

---

## SBH-40-03 — Scheduled-Cancellation Race Suite

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

Review-only / shared-boundary task.

Recommended shape:

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

---

## SBH-50-02 — Durable Active-Entitlement Issuance Recovery

Proposed branch:

```text
subs-task/sbh-50-02-entitlement-issuance-recovery
```

Invariant:

> An active entitled Subscription cannot remain permanently under-granted because a transient entitlement operation failed.

---

## SBH-50-03 — Durable Terminal-Entitlement Revocation Recovery

Proposed branch:

```text
subs-task/sbh-50-03-entitlement-revocation-recovery
```

Security invariant:

> A canceled/expired Subscription cannot permanently retain subscription-derived access because revocation failed.

Shared Entitlements authority must be explicitly assigned where required.

---

## SBH-50-04 — Enforce `access_on_past_due` and `access_on_cancel`

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

Proposed branch:

```text
subs-task/sbh-60-01-plan-eligibility
```

Invariant:

> New purchases and newly queued contract changes may select only a currently sellable commercial contract/revision plus a valid active variant-plan attachment.

---

## SBH-60-02 — Grandfathered Retired-Contract Renewal

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

Proposed branch:

```text
subs-task/sbh-70-02-renewal-attempt-monotonicity
```

Use the smallest correct state/CAS/version mechanism.

Do not replace working initial CAS machinery simply for stylistic uniformity.

---

# 18. SBH-80 — StoredPaymentMethod Lifecycle

Legacy source finding: `SUB-HARD-07`.

## SBH-80-01 — Implement Frozen Revocation Semantics

The Stage B governance law is frozen. This later implementation task must enforce
the terminal meaning of `REVOKED` and may not reopen the product decision.

The frozen graph is:

```text
ACTIVE ↔ INACTIVE
ACTIVE/INACTIVE → REVOKED
REVOKED = terminal
```

---

## SBH-80-02 — Enforce Frozen Transition Graph

Proposed branch:

```text
subs-task/sbh-80-02-payment-method-state-guards
```

Do not add an AshStateMachine solely because an enum exists.

Use it only if it materially improves transition correctness and auditability.

---

# 19. SBH-90 — Billing Timezone Safety

Legacy source finding: `SUB-HARD-09`.

## SBH-90-01 — Validate Billing Timezone Before Contract Effectiveness

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

These audit tasks may end in `PROVEN_GOOD` or create new `CANDIDATE` findings.

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

Any new problem discovered here becomes a new `CANDIDATE`.

It must pass:

```text
evidence
→ validation
→ contract freeze
→ authority
→ dependency review
→ READY
```

before implementation.

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

---

# 23. Dependency Spine

Primary dependency chain:

```text
CONTROL PLANE
      ↓
SBH-00-01 / JC-219 commercial-contract architecture — frozen
      ↓
SBH-00-02 / JC-220 domain and lifecycle map — frozen
      ↓
SBH-00-03 / JC-221 race precedence — frozen
      ↓
SBH-00-04 / JC-222 cancellation, dunning, access, payment-method, and grandfathering law — frozen
      ↓
SBH-00-05 / JC-223 dependency graph and hardening matrix — next
      ↓
SBH-10 commercial-contract foundation
      ↓
SBH-10 Subscription binding
      ↓
SBH-10 RenewalAttempt charged-contract snapshot
      ↓
SBH-10 bound renewal initiation
      ↓
SBH-10 bound reconciliation
      ↓
SBH-20 aggregate/race hardening
```

Major streams may gradually become parallel after their prerequisites close:

```text
              ┌→ SBH-30 Dunning
SBH-20 stable ├→ SBH-40 Cancellation
              ├→ SBH-50 Access / Entitlements
              ├→ SBH-60 Availability / Grandfathering
              ├→ SBH-70 RenewalAttempt monotonicity
              ├→ SBH-80 StoredPaymentMethod
              └→ SBH-90 Timezone
```

Actual READY ordering must be generated from the final dependency graph, not this illustration alone.

---

# 24. Shared-Authority Register

These surfaces are not implicitly owned by SUBS:

```text
priv/repo/migrations/**
Ash snapshots
Payments core
Orders core
generic Entitlements infrastructure
InventoryAdmission
auth platform
generic dependency/platform infrastructure
shared config
provider business contracts
AGENTS.md
docs/agent_rules/**
.github/workflows/**
```

Required transition:

```text
UNOWNED / SHARED
        ↓ explicit authority decision
AUTHORITY_ASSIGNED
        ↓
MODIFICATION
```

No authority decision = no modification.

If the correct Subscription fix requires a shared surface without authority:

```text
current item → BLOCKED_SHARED_AUTHORITY → STOP
```

Do not "helpfully" fix the neighbouring domain.

---

# 25. Proposed Branch Model After Activation

Persistent worktree:

```text
/home/jcschoeman96/projects/current/Store_Blueprint_Hardening-subscriptions
```

Persistent workstream branch:

```text
hardening/subscriptions
```

Proposed task-branch namespace:

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

**Important:** this task-branch namespace is proposed by this programme and must be confirmed when SUBS is activated. It is not current repository governance law merely because this document recommends it.

---

# 26. One-Task / One-Branch Rule

Each implementation item should normally map to:

```text
one bounded contract
one task branch
one TDD cycle
one draft PR
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

# 27. Loop Admission Rule

An item may enter the implementation loop only when all are true:

```text
state == READY
loop_eligible == true
SUBS lifecycle == READY or ACTIVE_PARALLEL
governance_authority_sha == current accepted canonical governance
development_base_sha == accepted SUBS development base
task batch_base_sha == frozen batch_base_sha
product / architecture law == frozen
acceptance criteria == deterministic
```

Then perform task-level admission:

```text
required external capability absent from development_base_sha
→ BLOCKED_EXTERNAL_DEPENDENCY for this item
→ consider another READY item

shared boundary required without AUTHORITY_ASSIGNED
→ BLOCKED_SHARED_AUTHORITY for this item
→ consider another READY item
```

Do not globally block SUBS merely because another workstream or `main` advanced.

If no executable READY item remains:

```text
NO_EXECUTABLE_READY_WORK
STOP
```

The coding agent cannot reinterpret this rule.

---

# 28. Batch Rule

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

# 29. Per-Item Execution Loop

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
continue current task if still safe
```

Forbidden:

```text
self-authorize new task
expand current branch
modify neighbouring domain
promote candidate directly to READY
```

New finding lifecycle:

```text
DISCOVERED
   ↓
CANDIDATE
   ↓ separate review
VALIDATED / NOT_APPLICABLE / EXTERNALIZED
```

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

# 32. Universal STOP Conditions

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

Every final matrix row must end in exactly one of:

```text
PROVEN_GOOD
RESOLVED
NOT_APPLICABLE
EXTERNALIZED
ACCEPTED_RISK
```

There must be zero unresolved:

```text
UNKNOWN
UNREVIEWED
ASSUMED
TODO
CANDIDATE
VALIDATED
CONTRACT_FROZEN
READY
IMPLEMENTING
BLOCKED
```

unless programme closure explicitly records a still-open external dependency and the owner accepts that the Subscription programme cannot yet close.

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

# 36. Immediate Next Authorized Candidate

No Subscription production implementation is authorized yet.

The immediate lane-local sequence is:

```text
SUB-ACT-00  completed v1.3 authority upgrade/promotion/reclassification
    ↓
SUB-ACT-01  accepted SUBS development base
    ↓
SUB-ACT-02  ACTIVATION_FEASIBILITY_PASS recorded
    ↓
SUB-ACT-03  canonical READY recorded after ordered BASELINE_PINNED then READY transitions
    ↓
JC-219 / SBH-00-01  CONTRACT_FROZEN / CANONICAL
    ↓
JC-220 / JC-221 / JC-222  CONTRACT_FROZEN / CANONICAL in this Stage B governance change
    ↓
exact merged-target verification + separate main registry refresh
    ↓
SBH-00-05 / JC-223  next: freeze first executable dependency graph and hardening matrix
    ↓
SUB-ACT-04  freeze Batch 001 base + v1.3/v1.4 admission recertification
```

Each step is bounded and must STOP after producing its evidence.

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

The coding loop executes Task Contracts against a frozen batch base derived from the accepted development base. It does not own programme/governance authority and may not manufacture READY work.

---

# 39. Recommended Operating Cadence

```text
REVIEW / GOVERNANCE
    ↓
validate findings
freeze laws
mark bounded items READY
    ↓
IMPLEMENTATION BATCH
    ↓
0–3 independent READY items
one branch + draft PR each
    ↓
MANDATORY STOP
    ↓
INDEPENDENT REVIEW
    ↓
exact diff
exact head
CI
authority
lifecycle invariants
cross-domain effects
    ↓
approved merge(s) into the SUBS workstream branch
    ↓
refresh persistent SUBS branch and freeze next batch base
    ↓
next batch
```

This is the intended long-term subscription-hardening loop discipline.

---

# 40. Final Current Verdict

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
PR #8 parallel topology merged at 56f06d028ec38896f5a927f54dc7adfcb20034a3.

CURRENT IMPLEMENTATION AUTHORITY:
NONE. SUBS READY authorizes governance/review only; Batch 001 and SUB-ACT-04 admission remain outstanding.

CURRENT WORKSTREAM STATE:
READY / GOVERNANCE-REVIEW ONLY / STAGE B FROZEN.

HISTORICAL v0.1.3 CANDIDATE:
77a272c3887a7ab46e84a7fed02163d964e37b9b.

ACCEPTED DEVELOPMENT BASE RECORD:
575ffa1848ac69abe855bd018c7ae8eaf05d61e4 (SUB-ACT-01 accepted development base).

NEXT AUTHORIZED GATE:
JC-223 / SBH-00-05 after exact Stage B target verification and the separate main registry refresh.

FINAL ACTION:
Merge and independently verify the coherent JC-220/JC-221/JC-222 Stage B governance
freeze. Refresh the main registry in a separate bounded governance change. Then
complete JC-223's executable dependency graph and hardening matrix, followed by
JC-224's Batch 001 base and implementation-admission recertification. Production
implementation remains unauthorized until those gates are separately certified.
```

---
