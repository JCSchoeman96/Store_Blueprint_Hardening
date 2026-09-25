# Subscription domain and lifecycle map

**Status:** Stage B governance freeze, JC-219 v0.1.18 effective-revision
selection amendment, JC-220 / JC-221 / JC-222
**Scope:** Subscription domain law and architecture only
**Implementation authority:** None
**Canonical navigation:** `docs/hardening/subscriptions/SUBSCRIPTION_HARDENING_MASTER_REGISTER.md`

This document is the canonical Subscription domain, lifecycle, and race map. It
freezes the owner-approved Stage B law without authorizing source code, schema,
migration, provider, Payments, Orders, Entitlements, infrastructure, rollout, or
Batch 001 work.

## 1. Domain purpose

The Subscription domain owns recurring commercial authority and the durable
evidence needed to reconcile a renewal. It decides which contract a customer is
bound to, whether recurring authority continues, how a renewal occurrence is
bound, and which source-specific access effect must eventually converge.

The domain must keep four facts separate:

```text
commercial authority
≠ provider execution
≠ provider observation
≠ access-effect execution
```

The correctness rule is durable and order-independent. Queue order, worker start
order, callback arrival order, and local observation order do not decide a race.

## 2. Durable authorities

### Subscription aggregate

`Subscription` is the durable aggregate and lifecycle authority for:

```text
status
period boundaries
current effective PlanRevision identity for authoritative bound contracts;
pre-PlanRevision legacy rows may temporarily have an explicitly unresolved
binding only under the approved legacy compatibility law
current variant and quantity where applicable
stored payment-method binding
cancellation intent
dunning and retry episode
current future-target version
aggregate version
```

Every material mutation uses optimistic versioning, compare-and-swap, or an
equivalent PostgreSQL authority mechanism. A stale writer fails, reloads the
current aggregate, and re-evaluates its original intent.

### Plan and PlanRevision

`SubscriptionPlan` is a mutable reusable offer and sellability surface. It is not
historical contract truth.

`PlanRevision` is the commercial-contract resource. An `EFFECTIVE` or `RETIRED`
revision is immutable. Its lifecycle is:

```text
DRAFT → EFFECTIVE → RETIRED
```

`DRAFT` is editable. `EFFECTIVE` is immutable. `RETIRED` is immutable and
terminal, and `RETIRED → EFFECTIVE` is forbidden. An effective or retired
revision remains truthful evidence even when it is no longer available for new
sale or future change selection.

For one `SubscriptionPlan`, at most one `PlanRevision` may be `EFFECTIVE` at a
time. This is a required governance invariant and durable PostgreSQL business
authority; implementation remains unauthorized. Competing publications must not
both commit `EFFECTIVE`; a read-before-write check alone is insufficient.

`EFFECTIVE` means the immutable `PlanRevision` currently eligible to participate
in new-sale or newly queued contract-change selection for its
`SubscriptionPlan`. It does not, by itself, make an offer sellable. Selection
also requires an active `SubscriptionPlan`, a valid active
`VariantSubscriptionPlan` attachment, and applicable Catalog/product/variant
availability authority.

A Plan may have zero `EFFECTIVE` revisions. That state means no authoritative
commercial revision is available for new-sale or change selection, so selection
fails closed. Selection must not fall back to a `RETIRED` or `DRAFT` revision,
newest or timestamp-ordered data, a UUID ordering, a last returned row, or
mutable `SubscriptionPlan` values. A `RETIRED` revision remains historical
commercial evidence and may remain renewable for an already-bound Subscription
where grandfathering law permits.

The approved commercial authority chain is:

```text
SubscriptionPlan
    ↓ publishes over time
PlanRevision
    ↓ binds
Subscription.current_plan_revision_id
    ↓ freezes one occurrence
RenewalAttempt charged-contract evidence
```

For new-sale and newly queued change selection, the relevant part of that chain
is:

```text
SubscriptionPlan
    ↓ publishes over time
0..1 EFFECTIVE PlanRevision per Plan
    ↓ exact current new-sale/change candidate
Subscription or future ContractChange binds that exact revision
```

#### Legacy contract-binding compatibility

A `Subscription` created before authoritative `PlanRevision` binding existed may
temporarily lack `current_plan_revision_id` when its complete historical
commercial contract cannot be proven from durable evidence. This is a legacy
contract-binding compatibility condition, not a `Subscription` lifecycle state.
It does not make `SubscriptionPlan` historical contract authority and does not
permit missing fields to be reconstructed from current mutable Plan state,
defaults, an arbitrary `EFFECTIVE` revision, provider state, or present
`Subscription` status.

An unresolved legacy binding must fail closed whenever an operation requires
commercial truth that has not been independently proven. At minimum, it cannot
start a new automatic renewal with a provider, create a new RenewalAttempt
charged-contract binding, queue a contract change, perform commercial-policy-
dependent rescheduling, or derive commercial/access policy from today's
mutable `SubscriptionPlan`. No provider payment may start with fabricated
contract values.

Missing evidence alone does not mean `CANCELED`, `EXPIRED`, `SUSPENDED`, revoked
access, forfeited funded coverage, or that today's Plan became the historical
contract. An arbitrary PlanRevision is not a valid substitute.

Once authoritative PlanRevision binding is available, every newly created
`Subscription` must resolve and commit an authoritative `EFFECTIVE`
PlanRevision at its governed creation boundary. If that binding cannot be
established, creation fails closed; the compatibility path must not create new
unresolved rows.

An unresolved legacy row becomes normally contract-authoritative only after
authoritative evidence establishes its complete commercial contract. Reconciliation
must record its provenance and may not guess, apply defaults, choose the newest
or any `EFFECTIVE` revision, or infer policy from provider state or status. If
the contract remains ambiguous, the row stays unresolved until a separate owner
or governance decision approves a disposition such as manual reconciliation,
an explicit legacy compatibility contract, an accepted approximation, or another
lawful outcome. This amendment approves none of those dispositions.

The compatibility condition is transitional, not silent programme completion.
Before final Subscription-hardening certification, every extant renewable
Subscription must have an authoritative `PlanRevision` binding or an explicit,
separately governed legacy disposition. This law freezes no schema mechanism,
lifecycle value, sentinel revision, or new resource; later implementation must
choose the simplest representation that enforces these invariants.

### ContractChange and the future target

`ContractChange` is the stable identity for a queued future commercial change. The
current future target is versioned. A change may be queued, superseded, canceled,
bound to a renewal, or applied after successful reconciliation.

Once bound at checkpoint B, the change and its charged occurrence are immutable.
A later change has a new identity and applies only to a later eligible boundary.

### RenewalAttempt

`RenewalAttempt` is one logical renewal occurrence. Its charged-contract binding is
durable evidence, not a cache of whatever Plan state happens to be current when a
worker retries.

At checkpoint B it records, at minimum:

```text
PlanRevision
variant
quantity
amount in integer minor units
currency
period
ContractChange, if any
commercial and access policy required for the occurrence
```

Retries reuse this bound occurrence. They do not resolve mutable Plan state,
consume a newer ContractChange, or create a replacement RenewalAttempt.

### StoredPaymentMethod

Stored payment-method state is durable, versioned authority for whether a method
may be used for a future provider start. It is separate from the commercial
contract bound to a RenewalAttempt.

### Provider and payment evidence

Provider observations become business truth only after the domain establishes the
stable logical occurrence and authoritative financial evidence. The following
timestamps remain distinct:

```text
provider occurred_at
local observed_at
webhook received_at
Commerce applied_at
```

`received_at` is never a financial precedence rule.

### AccessEffect

Access execution is a derived, source-specific obligation. It must converge from
the current authoritative Subscription target and may not mutate Subscription truth
to make a delayed or stale effect easier to apply.

## 3. Ownership and boundaries

SUBS owns the governance meaning of:

```text
Subscription lifecycle and recurring authority
PlanRevision and ContractChange commercial semantics
RenewalAttempt charged-contract semantics
renewal scheduling and dunning
cancellation and scheduled cancellation
StoredPaymentMethod lifecycle meaning
source-specific access-effect targets
grandfathering dimensions
subscription-specific reconciliation law
```

The following remain shared or external authority and are not changed by this
freeze:

```text
Payments core
Orders core
Entitlements core
provider contracts and provider-specific point-of-no-return evidence
migrations and Ash snapshots
generic Oban/runtime infrastructure
generic cache or Redis infrastructure
```

This document records architecture law only. It does not select schemas, actions,
provider APIs, migrations, or implementation branches.

## 4. Subscription lifecycle

### Canonical states

```text
PENDING
ACTIVE
PAST_DUE
SUSPENDED
CANCELED
EXPIRED
```

State meanings:

| State | Meaning |
| --- | --- |
| `PENDING` | Durable Subscription exists but authoritative activation/payment evidence has not established `ACTIVE`. |
| `ACTIVE` | Recurring commercial relationship and its current paid period are active. |
| `PAST_DUE` | A renewal recovery episode is underway. The relationship is extant and not terminal. |
| `SUSPENDED` | The governed failed-payment suspension boundary was reached. The relationship remains extant, but ongoing automatic recurring capability and the affected recurring-source access effect are suspended. |
| `CANCELED` | Recurring authority ended by cancellation. This state is terminal. |
| `EXPIRED` | A governed term or paid-period completion ended recurring authority. This state is terminal. |

### Legal transition graph

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

The following transitions are forbidden:

```text
CANCELED → ACTIVE
EXPIRED → ACTIVE
CANCELED → PENDING
EXPIRED → PENDING
```

Grandfathering, late payment, a browser return, a webhook, or access-effect
execution cannot resurrect a terminal Subscription.

### Transition guards and effects

| Transition | Guard | Required effect |
| --- | --- | --- |
| `PENDING → ACTIVE` | Authoritative activation or payment evidence establishes active truth. A return URL alone is not proof. | Establish the first paid/current period and clear pre-activation termination intent. |
| `PENDING → CANCELED` | No authoritative activation/payment evidence has already established `ACTIVE` truth. | End recurring authority, forbid provider starts, begin no dunning episode, and supersede unbound future changes. |
| `ACTIVE → ACTIVE` | The same eligible renewal occurrence has authoritative successful payment evidence and its B-bound contract. | Apply the exact bound contract once, advance the paid period, and create current access-effect obligations. |
| `ACTIVE → PAST_DUE` | The first retryable renewal failure wins before an authorized recovery or terminal decision. | Fix `past_due_since_at` for the episode, record the failure, and schedule governed retries. |
| `ACTIVE → CANCELED` | Immediate cancellation commits, or a scheduled `DO_NOT_RENEW` instruction reaches the actual paid-period boundary. | End recurring authority, forbid future provider starts, and create the cancellation access-effect target. |
| `ACTIVE → EXPIRED` | A governed fixed term or paid-period completion is authoritative. Dunning retry exhaustion alone is not this guard. | End recurring authority, forbid future provider starts, and create the expiry access-effect target. |
| `PAST_DUE → ACTIVE` | Successful evidence belongs to the same still-authorized RenewalAttempt and current paid occurrence. | Recover that episode, apply the exact B-bound contract once, and clear dunning markers as governed. |
| `PAST_DUE → SUSPENDED` | The failed-payment boundary is reached before successful recovery or another terminal decision. | Stop automatic retries, keep the relationship extant, and make the affected recurring-source access effect non-effective. |
| `PAST_DUE → CANCELED` | Immediate cancellation commits. Do not wait for an artificial future paid boundary. | End recurring authority and create the cancellation access-effect target. |
| `PAST_DUE → EXPIRED` | A separately governed term or paid-period completion is authoritative. | End recurring authority and create the expiry access-effect target. |
| `SUSPENDED → ACTIVE` | Success belongs to the same still-authorized renewal, with the same Subscription, bound contract, and relevant paid period. | Recover that occurrence only. This is not generic reactivation. |
| `SUSPENDED → CANCELED` | Valid cancellation commits. | End recurring authority and create the cancellation access-effect target. |
| `SUSPENDED → EXPIRED` | A separately governed term or paid-period completion is authoritative. | End recurring authority and create the expiry access-effect target. |

## 5. Cancellation lifecycle

### Immediate cancellation

Immediate cancellation means:

```text
recurring authority ends immediately
→ CANCELED
```

It forbids future provider starts, automatic retries, and unbound future changes.
Already-started external collection is not erased. Its payment truth follows the
checkpoint and reconciliation laws below.

### Scheduled cancellation

Scheduled cancellation is the current instruction:

```text
DO_NOT_RENEW
```

The current paid term may continue. At the actual funded paid-period boundary, the
Subscription becomes `CANCELED`. No extra period is invented after the last paid
period ends.

`DO_NOT_RENEW` before checkpoint B blocks that renewal boundary. A B-bound
occurrence remains immutable if scheduling occurs later.

### Rescission

Before terminalization, an authenticated current-version rescission creates a new
current target:

```text
DO_NOT_RENEW
→ RENEW_UNCHANGED(current live contract)
```

It does not resurrect a hidden or superseded target. After `CANCELED`, the customer
must start a new Subscription rather than resurrecting the old one.

## 6. Dunning and retry lifecycle

### Attempt numbering

```text
initial collection = attempt 1
retries = attempts 2+
```

The retry budget counts retries after the initial collection attempt. The existing
field name `max_retry_attempts` does not authorize changing that meaning or a schema
rename in this freeze.

### Retry timing and episode clock

Retry offsets are measured from the first retryable failure. Offset `0` is valid.
The final configured offset is used once; it is not repeated indefinitely.

The first retryable failure performs:

```text
ACTIVE → PAST_DUE
past_due_since_at = first retryable failure time
```

Later retries never reset `past_due_since_at`.

### Retry exhaustion and suspension

Retry exhaustion before the failed-payment boundary means:

```text
remain PAST_DUE
stop automatic retries
```

At the separately governed failed-payment boundary:

```text
PAST_DUE → SUSPENDED
```

unless successful recovery or a separate terminal event wins first. Retry
exhaustion is not relationship termination and is not a substitute for `EXPIRED`.

Missing payment method, provider failure, and other retryable blockers do not start
provider collection when no authorized method exists. They enter the governed
`PAST_DUE` episode and follow the same suspension/terminal rules.

## 7. StoredPaymentMethod lifecycle

The frozen state graph is:

```text
ACTIVE ↔ INACTIVE

ACTIVE   → REVOKED
INACTIVE → REVOKED

REVOKED = terminal
```

Forbidden transitions:

```text
REVOKED → ACTIVE
REVOKED → INACTIVE
```

Replacement changes the Subscription's durable payment-method binding under
versioned authority. Replacement does not create a new RenewalAttempt and does not
automatically revoke the old method globally.

## 8. ContractChange and future-target lifecycle

```text
NONE
  ↓ queue
QUEUED
  ├── supersede → SUPERSEDED
  ├── cancel → CANCELED
  └── renewal binds → BOUND_TO_RENEWAL
                         ↓ successful reconciliation
                      APPLIED
```

The current future-target version is part of the Subscription's authoritative
aggregate decision. A later change cannot rewrite a B-bound occurrence. A
cancellation supersedes or voids unbound changes. A rescission creates a new
current target from the live contract.

## 9. RenewalAttempt authority

### Checkpoint B

Before external collection can pass its provider-specific point of no return, one
RenewalAttempt must durably bind the exact occurrence it intends to purchase:

```text
PlanRevision
variant
quantity
amount in integer minor units
currency
period
ContractChange, if any
commercial/access policy for the occurrence
```

After B:

```text
the occurrence may not re-resolve mutable Plan state
the occurrence may not consume a newer ContractChange
retries reuse the same bound occurrence
successful reconciliation applies that exact occurrence
```

The bind is durable historical evidence even if cancellation later prevents
provider execution.

### RenewalAttempt monotonicity

One successful RenewalAttempt is terminal as a successful occurrence. A later
ordinary failure notification for the same occurrence cannot produce:

```text
succeeded → failed
ACTIVE → PAST_DUE
period rollback
access rollback
```

A refund, reversal, or chargeback is separate financial evidence and follows its
own governed lifecycle.

## 10. Access-effect relationship

Access is source-specific and derived from the authoritative commercial decision.
It is not a second Subscription lifecycle.

### Durable effect obligation

```text
REQUIRED
   ↓
PENDING
   ↓ successful execution
APPLIED

PENDING → FAILED_RETRYABLE → PENDING
PENDING → SUPERSEDED       where the current target replaces it
```

Every access-changing commercial decision creates a durable idempotent effect or
target obligation. A delayed worker must read the latest source target and either
apply that target or supersede the stale obligation.

### Policy meaning

For `PAST_DUE`, both policies remain valid:

```text
KEEP_DURING_GRACE
REMOVE_IMMEDIATELY
```

`KEEP_DURING_GRACE` may keep the affected access effective through the recovery
window. At `SUSPENDED`, the affected recurring-source effect becomes non-effective.
`REMOVE_IMMEDIATELY` makes that source effect non-effective when `ACTIVE → PAST_DUE`
commits. The Subscription remains `PAST_DUE`.

For `SUSPENDED`, the affected recurring-source effect is non-effective. No
Entitlements `SUSPENDED` business state is invented solely to mirror Commerce.
Other valid entitlement sources remain independently valid.

For cancellation, `KEEP_UNTIL_PERIOD_END` uses only the already-funded authoritative
paid period. It does not extend grace, invent a period, turn a failed renewal into
paid coverage, or extend past fixed-term expiry. `REMOVE_IMMEDIATELY` removes the
affected source effect after the cancellation decision.

## 11. Grandfathering and eligibility

Keep these dimensions separate:

```text
NEW-SALE ELIGIBILITY
CHANGE ELIGIBILITY
EXISTING-RENEWAL ELIGIBILITY
```

Plan archival or public unavailability does not automatically end an existing
renewal contract. Existing renewal evaluates:

```text
Subscription
+ bound immutable current contract
+ applicable grandfathering policy
+ renewal occurrence
```

An unresolved legacy `Subscription` does not satisfy the bound-immutable-current-
contract requirement merely because it is grandfathered. Grandfathering does not
reconstruct missing commercial history. A new renewal operation requiring that
contract must fail closed until authoritative reconciliation or another
separately governed legacy disposition exists.

New-sale eligibility controls new purchases. Change eligibility controls a queued
ContractChange. Existing-renewal eligibility controls continuation of an extant
contract. `PAST_DUE` and `SUSPENDED` may recover the same authorized occurrence;
that is not a new sale. Terminal states cannot be revived by grandfathering.

New-sale and newly queued change selection must resolve the exact currently
eligible `EFFECTIVE` revision. A Plan with no `EFFECTIVE` revision fails closed;
two `EFFECTIVE` revisions are a database-invariant violation and also fail
closed. A `RETIRED` revision may remain authoritative for an existing bound
Subscription, but it is not eligible for new selection.

## 12. Authority checkpoints and precedence

The checkpoints are evidence boundaries, not a global "last checkpoint wins"
hierarchy.

### A — authoritative aggregate/version commit

`A` is a durable, concurrency-protected Commerce/Subscription decision that has
committed. Examples include a lifecycle transition, future-target version change,
cancellation intent, ContractChange supersession, payment-method binding/revocation,
or aggregate version change.

### B — exact charged-contract bind commit

`B` is the durable RenewalAttempt bind described above. It freezes the commercial
occurrence before later provider work can rely on it.

### C — provider point of no return

`C` means a provider-side financial occurrence may now happen even if local
execution stops. It does not mean that payment succeeded.

The operation that constitutes C is provider-specific. This governance freeze does
not invent a Paystack or other provider operation as C. Provider evidence must
prove it later.

### D — authoritative payment occurrence evidence

`D` exists when authoritative evidence establishes what financially occurred.
Payment truth and Commerce truth are both preserved when they diverge. A D result
does not automatically reactivate `CANCELED` or `EXPIRED`, undo a valid
cancellation/expiry, restore stale contract terms, or restore a revoked binding.

If occurrence ordering cannot be proven, the system fails closed and reconciles.

## 13. Canonical race precedence matrix

Arrival order is never sufficient. The following matrix freezes the required result.

| Race | Canonical result |
| --- | --- |
| Renewal vs immediate cancellation | Cancellation before B prevents the bind. Cancellation after B but before C forbids provider start. After C, the in-flight occurrence is reconciled. Late money never automatically resurrects a terminal Subscription. |
| Renewal vs scheduled cancellation | Current `DO_NOT_RENEW` before B blocks that boundary. B first freezes the occurrence; later scheduling targets the next eligible uncommitted boundary. |
| Renewal vs ContractChange | The target current at B is bound. A later change cannot rewrite or be consumed by that occurrence. |
| Renewal vs payment-method replacement/revocation | Current payment-method authority is checked before C. A replacement does not create a new RenewalAttempt. If no authorized method exists, no provider call starts. |
| Reconciliation vs expiry | Successful authoritative application first makes a stale expiry writer fail. Expiry first forbids provider starts. An in-flight external outcome is reconciled without generic `EXPIRED → ACTIVE`. |
| Reconciliation vs suspension | The same still-authorized success may recover `SUSPENDED → ACTIVE`. This is not generic reactivation and cannot be used by another occurrence. |
| Success vs late failure | A successful occurrence cannot regress because an older failure arrives. Refund, reversal, and chargeback are separate financial events. |
| Two Subscription writers | Only one incompatible mutation may commit against a version. A stale writer fails, reloads authority, and re-evaluates its original intent. |
| Dunning vs successful recovery | Valid success for the same authorized renewal beats a stale dunning write. Retry exhaustion means no more automatic retries, not terminal relationship end. |
| Access effect vs commercial state | The effect worker reads the latest source target and applies only that target. A stale effect cannot restore obsolete rights. |
| Duplicate provider callbacks | A logical provider/payment occurrence is deduplicated durably and applies commercial effects once. Conflicting reuse of one event identity fails closed and reconciles. |
| Out-of-order provider callbacks | Use trustworthy provider identity, occurrence time, sequence/state authority, and reconciled payment state. Stale evidence cannot regress established truth. Without trustworthy ordering, query/reconcile. |
| Late success after cancellation | Preserve financial truth. `CANCELED` remains terminal. If cancellation won before the occurrence, use explicit refund, reversal, credit, or other remedy. Ambiguous ordering remains fail-closed. |
| Queued retry after cancellation | Queue presence grants no authority. Re-read current authority before C. A canceled Subscription creates no new occurrence and exits idempotently. |
| Provider-event reordering across webhook, browser return, polling, and reconciliation | All paths converge on one stable logical occurrence. No channel independently extends the Subscription. Conflicting observations remain evidence until authoritative provider/payment truth is established. |
| Restart or crash recovery | Reconstruct from Subscription/version, future-target version, RenewalAttempt binding, provider/payment evidence, and durable access effects. Never use worker memory or queue history as authority. |

No row in this matrix permits a generic terminal-state resurrection.

## 14. Concurrency and idempotency

### Aggregate concurrency

All material Subscription mutations use durable optimistic concurrency. Redis locks,
node-local mutexes, global GenServers, and worker serialization are not authority.

### Renewal identity

One Subscription and billing boundary have one durable logical renewal identity.
Duplicate claims reuse the existing RenewalAttempt. Every collection attempt
under that occurrence reuses its B-bound commercial contract and Order, but a
sequential dunning collection after authoritative terminal non-success requires
its own durable collection-attempt identity, PaymentIntent identity, and
provider idempotency identity. An ambiguous transport/provider outcome replays
the same collection attempt and its keys. `requires_action` or unknown status
does not authorize a new attempt. The occurrence `renewal_key` is not the key
for every sequential provider collection.

The inspected runtime still reuses the occurrence-level PaymentIntent and
Stripe idempotency key, and its `requires_action` path releases the physical
reservation. Those behaviors are recorded in the lifecycle registry. The
v0.1.27 master-register amendment defines the blocked target and does not
authorize implementation; the JC-223 dependency graph and SBH-10-05
reconciliation semantics remain unchanged.

### Payment and callback apply-once

Provider-event/payment-occurrence identity and business application are both
durably deduplicated. Duplicate evidence is a no-op after successful application.
Materially conflicting evidence under one identity fails closed and enters
reconciliation.

### Notification and effect apply-once

Access effects and relevant notifications use durable idempotent obligations. A
database transaction that changes commercial truth collects post-commit work; it
does not pretend an external effect committed inside the same transaction.

## 15. Restart, crash recovery, and reconciliation

Recovery starts from durable truth:

```text
Subscription + aggregate version
current future-target version
RenewalAttempt + bound contract
provider/payment evidence
durable access-effect obligations
```

If B exists and C definitely did not occur, resume the same occurrence with the
same bound contract. If C may have occurred but the outcome is unknown, do not
issue a second non-idempotent collection. Reuse the idempotency identity for the
same durable collection attempt where guaranteed and/or query the provider
before deciding whether another request is safe. A pre-submission fence may
release a physical hold, but it does not create a new collection identity;
resume with the same attempt and keys. A new collection identity is permitted
only after final provider/payment non-success is durably verified and dunning
policy permits another attempt.

If D exists but local application crashed, replay local application idempotently.
If access execution crashed, re-derive the current source target and converge the
outstanding effect.

When payment evidence and Commerce authority diverge, preserve both truths and
perform explicit reconciliation or remedy. Possible remedies include refund,
reversal, credit, paid-period preservation where policy permits, or manual
investigation. Do not rewrite one truth to hide the other.

## 16. Manual-funded subscriptions

```text
manual payment occurrence
≠ fake recurring provider occurrence
```

The end of a manually funded period does not automatically create `PAST_DUE` or a
dunning episode. Manual access begins only after governed verification. No fake
provider call or automatic collection is invented.

## 17. Authority versus derived, cached, and observed truth

| Concern | Authority |
| --- | --- |
| Subscription lifecycle and commercial decision | Durable PostgreSQL Subscription aggregate and version |
| Exact renewal commercial occurrence | B-bound RenewalAttempt evidence |
| Provider execution | Provider adapter/provider contract, not Commerce status alone |
| Provider observation | Durable normalized evidence until authoritative payment truth is established |
| Payment truth | D-level authoritative provider/payment evidence |
| Access execution | Durable source-specific AccessEffect target and latest Commerce authority |
| Cache/projection | Derived only; never a business decision authority |
| Queue/worker state | Execution hint only; never billing authority |
| Browser return | Read-only observation; never payment proof |

## 18. Performance and scaling review

This governance freeze changes no production performance architecture.

| Area | Stage B law |
| --- | --- |
| Hot paths | Storefront reads, cart, checkout, renewal, webhook, access, and dunning decisions read durable authority without using cache as truth. |
| Warm paths | Cached plan/revision or projection data is derived, bounded by an explicit invalidation policy, and never used to decide payment or lifecycle precedence. |
| Cold paths | Reconciliation, audit, and repair work is durable, idempotent, batched, and safe to retry. |
| DB query count | Future implementation must avoid N+1 reads around renewal/effect application and must use indexes proven by the implementation task. |
| Caching | No cache, ETS, Redis, or GenServer is required for correctness. Stampede protection and TTLs are implementation concerns only if a later task introduces derived caching. |
| Oban | Renewal, reconciliation, notifications, and access-effect work remain durable and idempotent. Queue order never grants authority. |
| Telemetry | Later implementation must distinguish provider occurrence, local observation, webhook receipt, and Commerce application times. |

## 19. Implementation boundary

The following mechanisms are later implementation consequences, not authorization
from this document:

```text
optimistic Subscription version/CAS
stable future-target versions
unique RenewalAttempt identity
immutable charged-contract binding
provider idempotency
durable payment/event deduplication
apply-once reconciliation
durable source-specific access-effect convergence
```

The provider-specific definition of checkpoint C remains downstream evidence work.
If a provider cannot supply enough evidence to resolve a disputed occurrence safely:

```text
FAIL CLOSED
RECONCILE
```

The owner-approved JC-219 v0.1.18 effective-revision selection amendment and
JC-223 / SBH-00-05 are `CONTRACT_FROZEN / CANONICAL`. They are governance
authority and do not themselves grant production implementation, migration,
schema, provider, or shared-boundary authority. Current SUBS implementation
admission follows the canonical serial explicit-hardening policy in
`origin/main`. `SUB-ACT-04`, Batch 001, and `ACTIVE_PARALLEL` are historical
controller provenance and are not current implementation prerequisites.
Shared, schema, and provider changes remain separately gated by task-specific
authority.
