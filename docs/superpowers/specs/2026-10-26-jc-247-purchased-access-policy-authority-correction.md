# JC-247 — Purchased Access Policy Authority Correction

Status: **Proposed additive authority; human review required; implementation not authorized**

Repository: `JCSchoeman96/Store_Blueprint_Hardening`
Accepted main SHA: `4da56a3fdbafc80a60bbb965b4fa9996f4b17734`
Accepted main tree: `315686a6cb7cf5b97f66b5333dd5515866436606`
Date: 2026-10-26

## 1. Authority chain and scope

JC-247 derives purchased access policy at the owning Subscription source
transition and persists the resulting immutable AccessEffect target. F0.5
reconciliation independently derives that same target from durable source
evidence. It must not treat the latest AccessEffect as proof of its own
currentness.

The accepted F0.5 design remains unchanged and canonical until this amendment
is accepted. **Upon acceptance**, the policy-aware derivation in section 4
supersedes F0.5 §5's status-only current-target mapping only for the
policy-governed Subscription states and transitions defined here. The rest of
F0.5 remains in force, including its bounded candidate page, Subscription-first
mutex, exact candidate validation, currentness fence, repair behavior, and
executor transaction boundary.

`Store.Entitlements` remains an exact-target executor. It does not load a
Plan/PlanRevision to derive policy, interpret either purchased policy value,
choose EFFECTIVE versus NON_EFFECTIVE, determine AccessEffect currentness, or
derive policy from Subscription status. F1/F2 execute the immutable target
under the existing PostgreSQL source lock and currentness contract.

## 2. Purchased policy values

The durable policy values already present on immutable `PlanRevision` evidence
and in the bound attempt snapshot are:

```text
access_on_past_due:
  :keep_during_grace
  :remove_immediately

access_on_cancel:
  :keep_until_period_end
  :remove_immediately
```

Pair targets always use one exact `(entitlement_kind, entitlement_scope_key)`
pair. A funded PlanRevision with nil/nil composition remains nil/nil; no pair is
invented.

## 3. Full source-transition policy model

All interval boundaries below are exact persisted UTC timestamps. “Funded
revision” means the immutable PlanRevision referenced by
`Subscription.current_plan_revision_id`, which owns the last paid commercial
period. Policy selection and entitlement composition are separate evidence
questions for dunning, as specified in section 6.

| Transition | Guard and authority | AccessEffect target | Execution, replay, and lifecycle |
|---|---|---|---|
| Verified bound payment failure or authentication-required bound dunning transition: `active -> past_due`, `keep_during_grace` | Both producer forms run under the Subscription lock and identify the exact bound RenewalAttempt for this subscription and funded period. The attempt must have a valid frozen charged-contract snapshot. Set its ID and the dunning timestamps in the same authoritative source transaction. Policy is the attempt snapshot. | EFFECTIVE. Pair: funded pair, `valid_from_at = current_period_start_at`, `valid_until_at = failed_payment_boundary_at`. Nil/nil: nil kind/scope/start and the exact same grace boundary. Do not alter `current_period_*`. | F1. Replaying the same attempt and unchanged episode is a no-op. A different attempt cannot take ownership of the live episode. `past_due` is nonterminal. Exact paid recovery or boundary suspension can supersede this target. |
| Verified bound payment failure or authentication-required bound dunning transition: `active -> past_due`, `remove_immediately` | Same two producer forms, source lock, exact-attempt, owner, period, snapshot, and source-transaction guards. | NON_EFFECTIVE, nil kind/scope/start/end. | JC247-B uses F2 after the narrow past_due source-admission/revocation-metadata extension. `past_due` remains nonterminal. Duplicate settlement creates no second target. Exact paid recovery establishes a newer EFFECTIVE target. |
| Retry progress or exhaustion: `past_due -> past_due` | Retry belongs to the exact `current_dunning_renewal_attempt_id`; retain that ID and the episode boundary. Exhaustion suppresses retries but does not end grace. | No new target while disposition, pair, and validity remain identical. Retry bookkeeping may advance `aggregate_version`. | F0.5 may consider the previous effect covered only after independently deriving the same target. It must not use `aggregate_version` alone. A new target-changing source transition supersedes it. |
| Grace boundary: `past_due -> suspended` | Exact stored `failed_payment_boundary_at` is due; payment state is rechecked under the source lock. Retain the current dunning attempt ID for exact same-renewal recovery. | NON_EFFECTIVE, nil target and validity fields. | Existing F2 suspension semantics. `suspended` is nonterminal and distinct from `past_due`, canceled, and expired. Exact paid recovery can supersede the suspension target. |
| Exact paid recovery: `past_due/suspended -> active` | Verified paid reconciliation identifies the exact RenewalAttempt and it must equal the current dunning ID. Payment success for a different attempt cannot clear the episode. | EFFECTIVE from the newly funded attempt's exact charged target. Pair starts at the attempt's `period_start_at` and ends at its `period_end_at`; nil/nil retains nil kind/scope/start and the exact end. | Existing F1. Promote the paid attempt's PlanRevision and clear the dunning ID and episode fields in the same locked source transaction that establishes the paid target. Duplicate success is a no-op. Canceled/expired subscriptions do not recover. |
| Schedule cancellation at period end: status unchanged, `cancel_at_period_end = true` | Scheduling is intent (“do not renew”), not a Subscription state transition. Record the exact current-period or bound-attempt boundary using existing cancellation authority. | Target-neutral. Keep the target already current for the source state. No effect is created solely because cancellation was scheduled, regardless of `access_on_cancel`. | No executor. Replaying the same scheduling intent is a no-op. An active Subscription remains active; a past_due Subscription remains past_due. |
| Rescind scheduled cancellation: status unchanged | Require the exact current cancellation instruction and the existing rescission guard. | Target-neutral. No restoration target is needed because scheduling did not remove access. | No executor. Replaying rescission is a no-op. Stale rescission cannot alter a newer cancellation instruction. |
| Scheduled boundary reached: currently `active -> canceled` | Due worker rechecks the exact current boundary and payment authority under the Subscription lock. `cancel_at_period_end` intent is consumed at the boundary. | NON_EFFECTIVE; nil target and validity fields. Both `access_on_cancel` values converge here because the funded period has reached its boundary. | Existing F2 canceled-period-end path. Clear current dunning identity if present. Canceled is terminal. |
| Cancel now with `access_on_cancel = :remove_immediately`: `active/past_due/suspended -> canceled` | Customer/admin cancel-now transition after the existing payment-precedence guard. Read policy and composition authority from the exact funded current PlanRevision; never from mutable current Plan data. | NON_EFFECTIVE; nil target and validity fields. | Existing canceled-state F2 admission. Clear current dunning identity. Canceled is terminal. The existing post-commit direct revoke is a legacy writer that JC247-C must remove or gate so it cannot race the target executor. |
| Cancel now with `access_on_cancel = :keep_until_period_end`: `active/past_due/suspended -> canceled` | Same actual cancel-now transition and funded PlanRevision authority. The funded interval remains only when `current_period_start_at <= canceled_at < current_period_end_at`. | If that interval remains, EFFECTIVE using the funded pair, `valid_from_at = current_period_start_at`, and `valid_until_at = current_period_end_at`; nil/nil composition uses nil kind/scope/start and the same end. Otherwise NON_EFFECTIVE with nil target and bounds. Never extend `current_period_*`. | F1 for the retained funded target; existing F2 for an empty target. Clear current dunning identity. Commerce status is terminal `canceled`, even while a retained entitlement remains valid through its funded boundary. JC247-C must gate the legacy direct revoke. |
| Other actual cancellation reasons | The current customer/admin cancel-now facade writes `canceled_reason = "user_request"`; scheduled boundary writes `"canceled_period_end"`. Any other actual cancellation reason must be explicitly classified before JC247-C admits it. Do not infer cancel-now semantics from `status == canceled` alone. | Derive only from the exact classified transition and purchased authority. Unknown/ambiguous reasons fail closed. | No new reason strings are introduced by this proposal. Existing paths and reason values must be mapped during JC247-C review. |
| Term expiry: `active/past_due -> expired` where exposed | This is the separate fixed-term end, not cancellation or dunning suspension. No production expiry caller was established in the preflight. | NON_EFFECTIVE at the separately governed term boundary. | Outside JC-247. Clear current dunning identity when terminalizing. `expired` remains distinct and terminal. |

The pre-binding fallback remains outside JC247-A. It may lack the exact bound
attempt, `failed_payment_boundary_at`, and a source-lock/target-establishment
contract. A null current dunning ID on that path means policy derivation fails
closed; the fallback is not repaired opportunistically.

## 4. Additive F0.5 target derivation

The accepted F0.5 §5 status-only mapping is insufficient after these purchased
policies become executable. Upon acceptance of this amendment, use the
following durable-source derivation for the affected states:

| Locked Subscription source | Independent current-target derivation |
|---|---|
| `active`, no target-changing cancellation transition | Existing funded PlanRevision and funded current period produce the existing EFFECTIVE target. Scheduled cancellation intent does not alter it. |
| `past_due` with `:keep_during_grace` | Exact current dunning attempt snapshot selects policy; funded current PlanRevision supplies composition; stored failed-payment boundary supplies `valid_until_at`. |
| `past_due` with `:remove_immediately` | Exact current dunning attempt snapshot selects NON_EFFECTIVE. |
| `suspended` | NON_EFFECTIVE. Keep the dunning ID on Subscription for exact paid recovery, but suspension itself determines the empty target. |
| `canceled` with `canceled_reason = "canceled_period_end"` | NON_EFFECTIVE because the funded interval reached its exact boundary. |
| `canceled` with a classified customer/admin cancel-now reason | Exact funded PlanRevision's `access_on_cancel` and the persisted cancellation time determine the target in section 3. |
| `expired` | NON_EFFECTIVE under the separate term-end rule. |
| Any policy-governed state with missing or inconsistent required evidence | Fail closed. Do not preserve the candidate merely because it is latest, and do not infer policy from Subscription status. |

For a `past_due` candidate, F0.5 must:

1. Lock the Subscription row using the existing source mutex.
2. Require non-null `current_dunning_renewal_attempt_id`; fetch exactly that
   RenewalAttempt by primary key.
3. Prove `attempt.subscription_id == subscription.id` and that
   `attempt.period_start_at == subscription.current_period_end_at` for this
   funded renewal boundary.
4. Validate the bound attempt's frozen charged-contract snapshot and episode
   fields, including `past_due_since_at` and
   `failed_payment_boundary_at`. Do not recompute the boundary from mutable
   Plan/PlanRevision data.
5. Read `access_on_past_due` only from that exact attempt snapshot. Read
   entitlement composition only from the exact funded
   `current_plan_revision_id`.
6. Compare the independently derived complete target against the latest
   AccessEffect under the existing F0.5 evidence rules. Ignore
   `source_version` only where the accepted F0.5 contract already says to.
   Repair from locked source evidence when target fields differ; never choose
   by queue order or preserve a stale target by recency.

Retry bookkeeping can advance `aggregate_version` without creating an effect.
The existing policy target remains covered if the linked episode still
re-derives the same disposition, pair, and validity. Aggregate version alone is
not target identity.

### Exact dunning episode identity

The current schema does not persist the RenewalAttempt that owns a live
dunning episode. The existing query by `subscription_id` and period start with
`LIMIT 2` bounds returned rows but does not establish a durable identity. The
`RenewalAttempt` uniqueness key is `(subscription_id, renewal_key)`, and the
renewal key depends on the attempt's period end. A queued contract change can
make the attempted revision and boundary differ from the currently funded
revision; binding then consumes the pending change. A timestamp or attempt
ordering guess is not an identity proof.

The smallest durable representation is:

```text
Subscription.current_dunning_renewal_attempt_id: nullable UUID FK -> RenewalAttempt.id
```

No attempt scan or candidate-owned AccessEffect provenance can replace this
source pointer: F0.5 must learn which episode is current from the locked source.
With the field present, target derivation is an exact one-row PK lookup, then
an explicit owner and episode-consistency check. This resolves the prior
`POLICY_TARGET_REDERIVATION_UNPROVABLE` finding for newly established episodes,
subject to the migration and rollout gate in section 5.

## 5. P0 schema and data-integrity design

JC247-P0 is a schema/lifecycle foundation only. It does not interpret policy,
create an AccessEffect, or change access behavior.

### Field and relationship

- Add nullable `subscriptions.current_dunning_renewal_attempt_id` referencing
  `renewal_attempts.id` with `ON DELETE RESTRICT` so an attempt that owns a live
  dunning episode cannot be deleted out from under it.
- Add the corresponding private Ash attribute and `belongs_to` relationship.
  The field is not public API data.
- Add this one-way DB check:

  ```sql
  CHECK (
    current_dunning_renewal_attempt_id IS NULL
    OR status IN ('past_due', 'suspended')
  )
  ```

  Do not require a non-null ID for past_due/suspended. The accepted
  pre-binding fallback and legacy rows can have no exact identity.
- The ordinary FK proves that the attempt exists. Under the Subscription
  source lock, application transition guards must also prove its
  `subscription_id` matches the Subscription and its period start is the
  funded period end. A simple FK cannot enforce that cross-row owner pair.
- No reverse index is needed merely to follow the Subscription pointer to the
  RenewalAttempt primary key. Do not add an index without a real reverse query
  path.

### Field lifecycle and guards

| Source state/transition | Required field value and guard |
|---|---|
| Active or pending, outside dunning | ID is nil. |
| Verified payment failure settled against the bound RenewalAttempt, `active -> past_due` | Set ID to that exact attempt in the same locked transaction as `status`, `past_due_since_at`, and `failed_payment_boundary_at`. Verify attempt owner, funded period boundary, valid immutable snapshot, and that payment was not already applied. |
| Authentication-required bound dunning transition, `active -> past_due` | Set ID to the exact bound attempt in the same locked transaction as `status`, `past_due_since_at`, and `failed_payment_boundary_at`. Verify attempt owner, funded period boundary, valid immutable snapshot, and that no paid success has already won. |
| Replay of either first-episode producer | Same attempt and same episode is idempotent. A conflicting non-null ID or mismatched episode fails closed; it cannot overwrite the owner. |
| Retry while `past_due` | Retain exactly the same ID. The retry/collection evidence must belong to that ID. A different attempt fails closed. Legacy null-ID rows remain on the pre-P0 compatibility path and are never backfilled by guessing. |
| `past_due -> suspended` at grace boundary | Retain the ID. Retry authority is cleared as today, but same-renewal paid recovery remains possible. |
| Exact paid recovery, `past_due/suspended -> active` | Require the paid RenewalAttempt ID to equal the current field. Promote its funded contract and clear the ID plus dunning episode fields in the same source transaction that establishes the normal paid target. |
| Cancel-now or scheduled boundary terminalization to `canceled` | Clear the ID in the terminalizing source transaction. The RenewalAttempt row remains as audit history. |
| Term expiry to `expired` | Clear the ID in the terminalizing source transaction. |
| Pre-binding fallback | ID remains nil. JC-247 policy derivation fails closed for this source path. |

The P0 identity state machine is:

```text
nil
  └─ verified bound payment failure OR authentication-required bound dunning transition
       guard: exact RenewalAttempt belongs to this Subscription
       -> CURRENT_DUNNING(attempt_id)

CURRENT_DUNNING(attempt_id)
  ├─ retry progress or retry exhaustion
  │    guard: exact same attempt
  │    -> CURRENT_DUNNING(same attempt_id)
  ├─ past_due -> suspended at the stored grace boundary
  │    -> CURRENT_DUNNING(same attempt_id)
  ├─ exact paid recovery
  │    guard: recovered RenewalAttempt.id == current_dunning_renewal_attempt_id
  │    -> nil
  ├─ cancel
  │    -> nil
  └─ expire
       -> nil

active, canceled, expired, and other non-dunning final states:
  pointer = nil
```

The existing `activate_now` and `extend_period` transitions already clear
dunning fields on return to active. P0 must clear the new pointer in those same
source updates. Cancellation and expiry must clear it in their terminal
updates. The database check rejects a forgotten non-null pointer on active,
canceled, or expired rows.

When the ID is non-null, every retry, recovery, suspension, or terminalization
must run under the existing Subscription lock and check the exact ID before
mutating it. A duplicate worker or webhook for the same attempt replays
idempotently; an older or different attempt cannot seize or clear the current
episode. The F1/F2 currentness fence and executor transaction remain the final
protection against an older AccessEffect worker.

### Migration, backfill, rollback, and snapshots

The eventual migration is one nullable UUID column, one FK to the existing
RenewalAttempt primary key, and the safe one-way status check described above.
It creates no new resource and changes no AccessEffect or Entitlements schema.

There is no safe automatic historical backfill established by current
evidence. Existing past_due/suspended rows may have multiple attempts matching
a subscription and period boundary; the current `LIMIT 2` helper is not proof
of uniqueness. Do not select the newest row, use timestamps/queue order, or
promote a bounded query result as identity evidence. The migration leaves
existing rows null.

JC247-A has an explicit inventory and admission gate:

1. Before enabling policy-aware target derivation, inventory all
   `past_due` and `suspended` Subscriptions with a null
   `current_dunning_renewal_attempt_id`.
2. From those rows, identify every unresolved AccessEffect target-order
   candidate. This candidate count must be zero before the JC247-A
   target-order worker is enabled, unless the exact historical owner has been
   proven and repaired under separately reviewed, bounded authority.
3. P0 may ship while legacy rows remain null because P0 changes no access
   behavior. Those rows remain on the pre-JC247 compatibility path and do not
   gain policy interpretation from the migration.

Admission rules:

| Pointer state | JC247-A rule |
|---|---|
| Pointer present | Policy-aware derivation is admissible only after the exact PK lookup, attempt owner check, and episode-consistency guards pass. |
| Pointer null, no unresolved target-order candidate | Keep the row classified as legacy. Do not derive or create a JC247 policy target for it. |
| Pointer null, exact historical owner independently proven | Repair only under separately reviewed bounded authority, then use the pointer path. |
| Pointer null, exact owner ambiguous | Never infer an attempt from newest row, timestamps, period ordering, queue order, mutable Plan state, or worker memory. Do not admit JC247 policy derivation for the affected row. |

The accepted F0.5 worker fails a page when it cannot prove a current target.
JC247-A must therefore not silently skip or mark covered an unresolved
null-pointer candidate. If inventory finds one, hold JC247-A target-order
activation until the candidate resolves through an already-authorized exact
paid recovery/terminal transition or receives separately reviewed,
evidence-backed remediation. If ambiguity remains, report
`STOP=HISTORICAL_BACKFILL_UNSAFE` for that rollout cohort. Do not add a
migration-time “best candidate” update or a process-memory exclusion list.

The future Ash snapshot must describe the same nullable field, relationship,
FK, and check as the migration. Generate it only with the separately
authorized P0 implementation; no snapshot is generated by this design task.
The migration must be ordered after the existing RenewalAttempt table and must
match the resource's UUID type and reference behavior.

A down migration is safe only before runtime code has written non-null IDs.
After use, dropping the column loses live episode ownership. Rollback then
requires first stopping pointer writers and proving there are no live non-null
references, or using a forward corrective migration; blindly dropping the
column is not an acceptable rollback.

## 6. Dunning evidence and pending contract changes

The authoritative evidence rule is hybrid:

```text
dunning policy       = exact current dunning RenewalAttempt.charged_contract_snapshot
funded composition   = PlanRevision at Subscription.current_plan_revision_id
valid_from_at        = funded current_period_start_at for a pair; nil for nil/nil
valid_until_at       = exact Subscription.failed_payment_boundary_at
```

The attempt snapshot is immutable evidence of the contract charged for the
dunning episode. The Subscription's current PlanRevision is immutable evidence
of the last funded entitlement composition. A failed attempt does not fund or
promote its attempted revision. This separates policy ownership (the bound
dunning episode) from composition ownership (the paid period) without treating
an unpaid contract as current access.

Example: funded revision A owns `[S,T)`. A pending contract change binds
revision B for `[T,U)`, and the exact RenewalAttempt stores B's frozen policy.
Payment fails. The Subscription remains funded by A. JC247-A reads
`access_on_past_due` from that exact attempt snapshot, but uses A's entitlement
pair, `S`, and the persisted grace boundary for the EFFECTIVE target. B is not
promoted. If that same attempt later succeeds, exact paid reconciliation
promotes B and establishes its ordinary F1 target for `[T,U)`. A focused
pending-contract-change failure/recovery proof is required before JC247-A.

For nil/nil funded composition, `keep_during_grace` is a valid EFFECTIVE
nil/nil AccessEffect: kind nil, scope nil, `valid_from_at` nil, and
`valid_until_at` equal to the exact grace boundary. Do not invent a pair.

## 7. Cancellation timing authority

This proposal freezes `access_on_cancel` at the actual Subscription
cancellation transition. Recording `cancel_at_period_end` is intent, not
cancellation and not a Subscription state. It does not apply the purchased
cancel policy. Rescission is target-neutral for the same reason.

At the scheduled boundary, the funded period has ended; the actual transition
to canceled therefore establishes NON_EFFECTIVE for either policy value.
For cancel-now, `:remove_immediately` establishes NON_EFFECTIVE. For
`:keep_until_period_end`, retain EFFECTIVE only through the exact currently
funded period boundary when `canceled_at` falls inside that funded interval;
otherwise establish NON_EFFECTIVE. Never extend `current_period_*`.

Current lifecycle inventory records the legacy cancel-now path as revoking all
Subscription grants after the source transaction. That is observed existing
behavior, not a purchased-policy rule. It conflicts with the proposed
cancel-now `keep_until_period_end` target and must be removed or gated in
JC247-C before that policy is enabled. This JC247-C work must be jointly
authorized with the affected remaining JC-300 cancellation writer coverage;
JC-300 final all-source cutover otherwise stays separate.

The cancellation-scheduling governance and lifecycle model do not directly
settle purchased policy timing. This proposed rule therefore needs human
acceptance as additive authority before cancellation code changes. No direct
authority contradiction was found that prevents proposing it.

## 8. F1/F2 boundary

F1 core semantics remain unchanged. F2 core semantics remain unchanged. Keep
the accepted transaction and execution contract:

- caller-owned PostgreSQL transaction;
- Subscription source mutex before currentness proof;
- exact AccessEffect identity, fingerprint, source-version, and latest-effect
  validation;
- exact-source grant convergence;
- marking that exact effect APPLIED in the same executor transaction; and
- existing post-commit projection repair behavior.

JC247-B needs only a future F2 source-admission/revocation-metadata extension
for a correctly persisted current NON_EFFECTIVE target while Subscription is
still `past_due`. The target itself remains decided by JC-247. No active-state
policy admission is needed under the frozen cancellation timing. Do not change
F0 currentness, the Subscription mutex, convergence, APPLIED semantics, or
Entitlements authority. Do not invent a new stable revocation reason here; if
runtime requires one, define it in accepted authority before code.

```text
F1_CORE_CHANGE_REQUIRED=NO
F2_CORE_CHANGE_REQUIRED=NO
F2_ACTIVE_POLICY_ADMISSION_REQUIRED=NO
F2_PAST_DUE_POLICY_ADMISSION_REQUIRED=YES_FOR_JC247_B
ENTITLEMENTS_CHANGE_REQUIRED=NO
ACCESS_EFFECT_SCHEMA_CHANGE_REQUIRED=NO
```

## 9. Implementation sequence after separate authorization

These slices are a proposed sequence, not authorization to implement:

1. **JC247-P0 — dunning identity foundation:** add the nullable exact attempt
   reference, lifecycle guards, and migration. No policy behavior or new
   AccessEffect producer. Prove same-attempt ownership and null legacy handling.
2. **JC247-A — keep during grace:** `past_due + keep_during_grace`,
   policy-aware F0.5 derivation through the exact P0 ID, and existing F1 only.
3. **JC247-B — remove immediately:** `past_due + remove_immediately`, with
   only the narrow F2 past_due admission/revocation-metadata extension.
4. **JC247-C — cancellation:** actual cancel-now keep/remove behavior;
   schedule intent and rescission remain target-neutral; boundary cancellation
   is NON_EFFECTIVE; remove or gate the conflicting legacy direct revoke under
   joint source-writer authorization.

Keep these separate from JC247-P0/A/B/C: pre-binding fallback repair, term-end
execution, and JC-300 remaining production writer/source coverage cutover.

### Required future P0 proofs

- First bound failure stores the exact bound attempt ID atomically with
  `past_due` and both episode timestamps.
- Same-attempt failure replay does not replace the ID or create duplicate
  episode state; a conflicting attempt fails closed.
- Retry retains the ID and rejects evidence for another attempt.
- Grace-boundary suspension retains the ID.
- Recovery requires the exact ID and clears it with the episode fields after
  paid promotion.
- Cancel and expiry clear the ID; the referenced attempt remains intact.
- The one-way check accepts legacy/null past_due rows, rejects a non-null ID on
  active/canceled/expired rows, and the FK rejects missing attempt IDs.
- Null legacy/pre-binding rows are not backfilled by newest timestamp, queue
  order, mutable Plan, or `LIMIT` result.

### Required future JC247-A proofs

- First bound failure with `keep_during_grace` creates exactly one EFFECTIVE
  target from the exact attempt's frozen policy.
- Mutable Plan/PlanRevision changes after binding cannot rewrite that policy.
- Pending contract-change failure uses the attempt's policy while retaining
  the last funded revision's composition; exact paid recovery promotes the
  attempted revision and establishes its exact F1 target.
- Pair and nil/nil targets both use the exact persisted grace boundary.
- Retry replay creates no new target; aggregate-version-only retries remain
  already-covered when the derived target is unchanged.
- Target-order reconciliation cannot rewrite the grace boundary to
  `current_period_end_at` and repairs only from independently derived source
  evidence.
- Exact paid recovery and grace-boundary suspension supersede the grace target.
- Both PostgreSQL lock-arrival orders are deterministic using barriers/messages;
  no sleep-based race tests.

## 10. Performance and scaling

P0 adds one nullable source reference, not a new lookup table. The source
transition already locks and loads Subscription and the bound RenewalAttempt;
it writes the ID in the same Subscription update. No extra resource scan is
introduced. The hot-path lookup is:

```text
locked Subscription
 -> current_dunning_renewal_attempt_id
 -> RenewalAttempt primary key
```

This is one bounded exact lookup, not a scan. Do not add a secondary index on
`current_dunning_renewal_attempt_id` solely for this forward lookup. Consider a
reverse index only if later deletion, audit, or query evidence demonstrates a
real need.

For F0.5 policy derivation, the added dunning evidence lookup is one
`RenewalAttempt WHERE id = current_dunning_renewal_attempt_id` primary-key
fetch, bounded to one row. The exact owner check is on that row. The current
funded PlanRevision is a direct Subscription FK/PK fetch if it is not already
loaded. Reuse both loaded records within the candidate transaction: no
subscription-wide/user-wide scan, no N+1 relationship loading, no attempt
timestamp sort, and no mutable Plan lookup. Existing page/candidate/latest
AccessEffect queries remain those defined by F0.5.

The RenewalAttempt primary key supplies the forward lookup index. No reverse
pointer index is proposed. PostgreSQL remains the sole correctness authority.
No Redis, Cachex, ETS, PubSub, Oban ordering, worker state, or process memory is
used to identify the current dunning episode or policy target. These are
expected query bounds, not measured runtime performance claims.

## 11. Review disposition

```text
F0_5_HISTORICAL_DOC_RESTORED=YES
JC247_ADDITIVE_SUPERSESSION=PROPOSED; EFFECTIVE ONLY AFTER HUMAN ACCEPTANCE

DUNNING_IDENTITY_FIELD=Subscription.current_dunning_renewal_attempt_id
DUNNING_IDENTITY=EXACT_RENEWAL_ATTEMPT_FK; PK_LOOKUP_AFTER_SUBSCRIPTION_LOCK
DUNNING_POINTER_FK=RENEWAL_ATTEMPT.ID; ON DELETE RESTRICT
DUNNING_POINTER_STATUS_CHECK=NULL OR STATUS IN (PAST_DUE, SUSPENDED)
BOUND_FAILURE_PRODUCERS=VERIFIED_BOUND_PAYMENT_FAILURE, AUTHENTICATION_REQUIRED_BOUND_DUNNING
RECOVERY_POINTER_GUARD=RECOVERED_ATTEMPT_ID MUST EQUAL CURRENT_DUNNING_RENEWAL_ATTEMPT_ID
HISTORICAL_BACKFILL_POLICY=NO_AUTOMATIC_BACKFILL; NULL LEGACY ROWS FAIL CLOSED FOR JC247
LEGACY_NULL_INVENTORY_GATE=INVENTORY PAST_DUE/SUSPENDED NULL POINTERS AND THEIR UNRESOLVED ACCESS EFFECT CANDIDATES; REQUIRE ZERO AMBIGUOUS CANDIDATES BEFORE JC247-A
AUTOMATIC_BACKFILL=NO

MIGRATION_REQUIRED=YES
SCHEMA_CHANGE_REQUIRED=YES
ENTITLEMENTS_CHANGE_REQUIRED=NO
ACCESS_EFFECT_SCHEMA_CHANGE_REQUIRED=NO

CANCEL_POLICY_TIMING=ACTUAL_SUBSCRIPTION_CANCELLATION_TRANSITION
SCHEDULED_CANCEL_INTENT_TARGET=TARGET_NEUTRAL
CANCEL_NOW_KEEP_TARGET=EFFECTIVE_THROUGH_FUNDED_PERIOD_END_IF_STILL_FUNDED; ELSE NON_EFFECTIVE
CANCEL_NOW_REMOVE_TARGET=NON_EFFECTIVE

F1_CORE_CHANGE_REQUIRED=NO
F2_CORE_CHANGE_REQUIRED=NO
F2_ACTIVE_POLICY_ADMISSION_REQUIRED=NO
F2_PAST_DUE_POLICY_ADMISSION_REQUIRED=YES_FOR_JC247_B

F0_5_POLICY_DERIVATION=SOURCE_STATE_PLUS_DURABLE_POLICY_AND_FUNDED_COMPOSITION
DUNNING_POLICY_SOURCE=EXACT_CURRENT_DUNNING_ATTEMPT_CHARGED_CONTRACT_SNAPSHOT
DUNNING_COMPOSITION_SOURCE=SUBSCRIPTION.CURRENT_PLAN_REVISION_ID
PENDING_CONTRACT_CHANGE_RULE=UNPAID_REVISION_POLICY_WITH_LAST_FUNDED_COMPOSITION
NIL_NIL_RULE=EFFECTIVE_NIL_NIL_THROUGH_EXACT_GRACE_BOUNDARY

JC247_SLICE_SEQUENCE=P0, A, B, C; FALLBACK/TERM_END/JC300_CUTOVER_SEPARATE
MIGRATION_IMPLEMENTED=NO
RUNTIME_IMPLEMENTED=NO
TESTS_MODIFIED=NO
IMPLEMENTATION_AUTHORIZED=NO
```

No runtime code, tests, migration, Ash snapshot, Linear state, or PR is changed
or authorized by this document. Human review is required before any P0 schema
work begins.
