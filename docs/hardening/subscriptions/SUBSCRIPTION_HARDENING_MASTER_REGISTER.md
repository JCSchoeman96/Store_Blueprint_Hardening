# Store Blueprint Hardening — Subscription Hardening Master Register

**Version:** v0.1.4
**Status:** WORKING / APPROVED DESIGN — SUBS READY / JC-219 STAGE A IN REVIEW
**Verified:** 2026-09-14
**Repository:** `JCSchoeman96/Store_Blueprint_Hardening`  
**Workstream:** Subscription Backbone Hardening (`SUBS`)  
**Persistent worktree:** `/home/jcschoeman96/projects/current/Store_Blueprint_Hardening-subscriptions`  
**Persistent workstream branch:** `hardening/subscriptions`

> **Canonical SUBS governance artifact:**
> `docs/hardening/subscriptions/SUBSCRIPTION_HARDENING_MASTER_REGISTER.md`
>
> This document records the independently verified SUBS activation and the owner-approved JC-219 architecture. It does **not** authorize migrations, authorize shared-domain changes, freeze Batch 001, or authorize production implementation.

---

# 1. Programme Objective

Systematically prove, harden, and close every material correctness, lifecycle, concurrency, commercial-contract, authorization, recovery, observability, and performance risk in the existing Subscription subsystem without redesigning already-correct mechanisms or crossing workstream authority boundaries.

The programme seeks to guarantee:

> **The contract charged, the contract activated, the Subscription lifecycle state, the payment evidence, and the customer's effective access cannot silently diverge under concurrency, retries, delayed provider events, administrative configuration changes, or partial downstream failure.**

This is a hardening programme, not a subscription rewrite.

---

# 2. Independent Verification Pass — 2026-09-14

This register was checked against the current repository before being written.

## 2.1 Verified authority state — refreshed after canonical SUBS activation

| Authority | Verified state |
|---|---|
| canonical `main` governance authority | `67a310988ea5f31081175e934f1eb2a2bd6c8c3b` |
| `hardening/s0-baseline` current tip | `98dc7711d0aa80c8730e11b1f357491d799f404d` |
| `hardening/platform-security` candidate tip | `7a89dc20aa4b2a261ed6bb96f1d3182254d0b7d3` |
| `hardening/subscriptions` current authority tip | `54871ef3bdda42f067ed5dbd398305151610c060` |
| PR #8 | **MERGED** |
| canonical topology | MAIN governance/integration authority + independent S0/PLATFORM/SUBS lanes |
| accepted SUBS development base | `575ffa1848ac69abe855bd018c7ae8eaf05d61e4` (SUB-ACT-01) |
| SUBS lifecycle | `READY` — governance/review only |
| Subscription implementation authority | **NONE; Batch 001 and SUB-ACT-04 remain outstanding** |

Canonical governance now explicitly separates:

```text
GOVERNANCE AUTHORITY
DEVELOPMENT BASE
INTEGRATION BASE
```

SUBS no longer waits for S0 merely because S0 moved. Cross-workstream changes block only the exact tasks that depend on them. Final convergence with canonical `main` remains mandatory before `READY_FOR_INTEGRATION`.

## 2.2 Verified branch topology and development-base interpretation

`hardening/subscriptions` current authority tip is:

```text
54871ef3bdda42f067ed5dbd398305151610c060
```

The accepted `development_base_sha` is separately pinned by `SUB-ACT-01`:

```text
575ffa1848ac69abe855bd018c7ae8eaf05d61e4
```

The current branch tip is the governance authority being reviewed; it is not a frozen Batch 001 base. Its age relative to another lane is not itself a blocker.

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

## 2.3 Verified documentation defect

`docs/hardening/01_domain_map.md` is currently zero bytes.

Therefore completing the canonical Subscription domain map remains a valid SBH-00 task.

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
2. The owner-approved hybrid `PlanRevision` + `Subscription` binding + exact `RenewalAttempt` charged-contract evidence is canonicalized by JC-219 below. This is governance authority only; production implementation remains separately gated.

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
SUBS_READY_FOR_GOVERNANCE_REVIEW
```

Canonical governance is no longer the blocker.

Current remaining lane-local work is:

```text
1. independently review and merge the JC-219/SBH-00-01 governance canonicalization;
2. perform the separately scoped Stage B governance work for JC-220, JC-221, and JC-222;
3. freeze the first executable dependency graph and hardening matrix;
4. freeze the first batch_base_sha and perform SUB-ACT-04 admission recertification.
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

Canonical executable states currently include:

```text
pending → active ↔ past_due → canceled
                       ↘
                       expired
```

### Required transition model

| Transition | Guard | Major side effects | Terminal |
|---|---|---|---|
| `pending → active` | valid activation/payment authority | initialize period; clear dunning | No |
| `past_due → active` | proven successful recovery/payment | advance/recover period; clear dunning | No |
| `active → active` | proven successful renewal | advance period and apply exact bound contract | No |
| `active → past_due` | canonical renewal/payment failure | record dunning evidence/retry schedule | No |
| `pending/active/past_due → canceled` | valid cancellation law | end/suppress renewal; create access-effect obligations | Yes |
| `active/past_due → expired` | frozen terminal expiry law | end/suppress renewal; create access-effect obligations | Yes |

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

This is a meaningful lifecycle even if it remains represented by fields rather than a new Subscription enum.

```text
NONE
  ↓ schedule
SCHEDULED
  ├── rescind → NONE
  └── period boundary reached → TERMINATED
```

Required guards and side effects:

- authorized actor;
- allowed source Subscription states;
- whether rescind is permitted;
- exact period-boundary authority;
- interaction with already-claimed renewal;
- interaction with provider-accepted payment;
- access end timing;
- communications;
- canonical terminal state.

A boolean may remain sufficient.

The lifecycle may not end at `cancel_at_period_end = true`.

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

---

## 7.4 Dunning

Conceptual lifecycle:

```text
HEALTHY
  ↓ payment failure
PAST_DUE_RETRYABLE
  ├── payment success → RECOVERED → HEALTHY
  ├── retry available → PAST_DUE_RETRYABLE
  ├── retry budget exhausted but grace remains → DELINQUENT_NO_MORE_RETRIES
  └── canonical terminal boundary reached → TERMINAL
```

Required law:

- retry budget and grace duration are separate concepts;
- retry exhaustion must not automatically terminate the commercial contract unless explicitly frozen as product law;
- terminal state must be explicit;
- access during past-due/grace must match plan/revision law;
- late success ordering must be deterministic.

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

Current conceptual states:

```text
active ↔ inactive
active/inactive → revoked
```

Unresolved:

```text
revoked → active ?
```

Two legitimate meanings exist:

- permanent security revocation → `revoked` terminal;
- recoverable provider-state marker → recovery may be legal, but naming/documentation must reflect it.

Freeze semantics before implementation.

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

---

# 8. Race Precedence Matrix — Required Before Implementation

At minimum, the programme must freeze expected outcomes for:

| Race | Required law |
|---|---|
| renewal ↔ immediate cancellation | define provider point-of-no-return and compensation |
| renewal ↔ scheduled-cancellation boundary | define whether renewal was already irrevocably claimed |
| renewal ↔ plan change | exact contract snapshot must win |
| renewal ↔ variant change | exact charged variant must win |
| renewal ↔ payment-method revocation | define use-after-revocation boundary |
| paid reconciliation ↔ expiry | define authoritative evidence and terminality |
| payment success ↔ late failure | successful proof must not regress |
| two Subscription mutations | stale writer rejected |
| two queued contract changes | deterministic winner/supersession |
| cancellation ↔ queued contract change | terminating contract may not silently acquire future terms |

Every race entry must include:

```text
initial state
event ordering
winner / precedence law
irreversible external boundary
expected DB state
expected provider/payment state
expected entitlement/access state
compensation / reconciliation rule
```

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

`SUB-ACT-03` recorded two ordered, validated canonical lifecycle transitions. The initial canonical state was `BOOTSTRAPPED`. The accepted `SUB-ACT-01` development base guarded `BOOTSTRAPPED → BASELINE_PINNED`; the `ACTIVATION_FEASIBILITY_PASS` from `SUB-ACT-02` guarded `BASELINE_PINNED → READY`. The resulting canonical lane state is `READY`, and its side effects are recording the accepted `development_base_sha` and making `SBH-00-01` and `SBH-00-02` available as governance/review work. `SUB-ACT-03` did not set `ACTIVE_PARALLEL`, freeze `batch_base_sha`, start Batch 001, or authorize production Subscription implementation.

A sibling lane moving is not itself a blocker.

---

# 10. SBH-00 — Discovery, Contract, and Lifecycle Freeze

These are governance/review tasks. They establish law before production code changes.

`SBH-00-01` and `SBH-00-02` remain `loop_eligible = No`. After `SUB-ACT-03` they are available as governance/review work; they do not enter implementation-loop READY admission. JC-219/SBH-00-01 is owner-approved and is currently being canonicalized for independent review. `SBH-00-05` freezes the first executable dependency graph and hardening matrix before `SUB-ACT-04` freezes Batch 001.

| ID | Task | Priority | State | Loop eligible | Dependency |
|---|---|---:|---|---:|---|
| `SBH-00-01` | Freeze commercial-contract architecture | P1 | `IN_REVIEW` — governance/review only | No | ACT-03 |
| `SBH-00-02` | Populate canonical Subscription domain/lifecycle map | P1 | `AVAILABLE_GOVERNANCE_REVIEW` | No | ACT-03 |
| `SBH-00-03` | Freeze concurrency/race precedence matrix | P1 | `BLOCKED_DEPENDENCY` | No | 00-01 |
| `SBH-00-04` | Freeze cancellation, dunning, access, revocation, and grandfathering laws | P1 | `BLOCKED_DEPENDENCY` | No | 00-01 |
| `SBH-00-05` | Freeze first executable dependency graph and hardening matrix | P1 | `BLOCKED_DEPENDENCY` | No | 00-02..04 |

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
provider contracts, or shared platform configuration. JC-220, JC-221, and JC-222 remain
the later Stage B lifecycle/product-law canonicalization work; existing lifecycle,
dunning, scheduling, access, and race-matrix material elsewhere in this register is
not newly approved by JC-219. JC-223 and JC-224 remain blocked.

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
grace duration
access during grace
retry suppression
recovery
terminal boundary
terminal Subscription state
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

## SBH-30-03 — Separate Retry Exhaustion from Grace Expiry

Proposed branch:

```text
subs-task/sbh-30-03-retry-grace-separation
```

Invariant:

> Retry-budget exhaustion must not silently define commercial termination unless the frozen dunning contract explicitly says so.

---

## SBH-30-04 — Enforce Terminal Dunning Outcome

Proposed branch:

```text
subs-task/sbh-30-04-dunning-terminal-law
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
- retry/grace same instant;
- successful final retry;
- success after retry exhaustion but before terminal boundary, if permitted;
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

Only implement if the frozen product law permits grandfathering.

Do not accidentally terminate or prevent renewal for existing subscribers solely because a commercial revision is no longer offered to new customers.

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

## SBH-80-01 — Freeze Revocation Semantics

Review/product/provider task.

Decide whether:

```text
revoked = permanent
```

or:

```text
revoked = recoverable provider state
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
SBH-00 contract/lifecycle freeze
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
JC-219 / SBH-00-01  owner-approved architecture canonicalization in review
    ↓
JC-220 / JC-221 / JC-222  later Stage B lifecycle/product-law canonicalization
    ↓
SBH-00-05 / JC-223  freeze first executable dependency graph and hardening matrix
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
READY / GOVERNANCE-REVIEW ONLY.

HISTORICAL v0.1.3 CANDIDATE:
77a272c3887a7ab46e84a7fed02163d964e37b9b.

ACCEPTED DEVELOPMENT BASE RECORD:
575ffa1848ac69abe855bd018c7ae8eaf05d61e4 (SUB-ACT-01 accepted development base).

NEXT AUTHORIZED GATE:
Independently review and, if certified, merge JC-219/SBH-00-01 into `hardening/subscriptions`; then perform only the separately scoped Stage B governance work.

FINAL ACTION:
After JC-219 is independently reviewed and merged, canonicalize JC-220, JC-221, and JC-222 coherently. Keep JC-223 and JC-224 blocked until the executable graph, hardening matrix, Batch 001 base, and all admission gates are separately certified.
```

---
