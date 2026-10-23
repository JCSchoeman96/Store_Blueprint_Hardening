# F0.5 — AccessEffect Target-Order Coverage

Status: **DESIGN APPROVED / SPEC APPROVED / IMPLEMENTATION PLAN APPROVED**  
Implementation: **AUTHORIZED on branch from canonical base**

Implementation plan: `docs/superpowers/plans/2026-10-23-access-effect-f0-5-target-order-coverage-implementation-plan.md`

Plan SHA256: `f57d09299b0637d090027b0ea32f839e9afa2863fd451af4fadb3d34d1c151d2`

Date: 2026-10-23  
Repository: `JCSchoeman96/Store_Blueprint_Hardening`  
Canonical base: `41a7fc998ad2d1bbb073f86c341df13a834dd6fa`

## 1. Purpose

Make AccessEffect ordering trustworthy so JC-245 (EFFECTIVE) and JC-246 (NON_EFFECTIVE) executors can later apply the latest unresolved AccessEffect without an older target surviving a newer Subscription target-changing transition.

F0.5 does **not** execute AccessEffects, converge grants, mark effects APPLIED, or cut over legacy EntitlementGrant writers (JC-300).

## 2. Architecture slice

```text
Subscription commercial transition
        ↓
immutable AccessEffect target order (F0.5)
        ↓
F0 currentness / source fence (existing)
        ↓
JC-245 / JC-246 executor (future)
        ↓
F0 exact-source Entitlements convergence (existing)
        ↓
JC-300 legacy-writer cutover (future)
```

F0.5 deliverables:

- Producer A: every successfully **applied** charged renewal establishes EFFECTIVE target (not only suspended recovery).
- Producer B: immediate cancellation (`effective_mode == :now`) establishes NON_EFFECTIVE inside the cancellation transaction.
- Bounded dual-stream reconciliation over unresolved EFFECTIVE and NON_EFFECTIVE AccessEffect risk sets.
- Dedicated Oban worker for resumable sweeps.
- Six-lane coverage proof.

No generic source system, no new outbox, no Entitlements mutation, no Redis/Cachex/PubSub correctness.

## 3. Domain authority

| Resource | F0.5 role |
|---|---|
| Subscription | Source mutex (`FOR UPDATE`); current commercial status and provenance |
| RenewalAttempt | Immutable charged-renewal entitlement pair and period boundaries |
| PlanRevision | Prove current entitlement pair during reconciliation only |
| AccessEffect | Immutable desired target; establishment/supersession unchanged |
| EntitlementGrant | Legacy writers unchanged until JC-300 |

## 4. Target-order reconciliation state machine

Per candidate (not a DB resource):

```text
SELECTED → SOURCE_LOCKED → LATEST_CHECKED
  ├─ NEWER_EFFECT_PRESENT → success (:noop)
  ├─ TARGET_MATCHES → success (:already_covered)
  ├─ TARGET_PROVABLE → ESTABLISH_NEW_EFFECT → success (:repaired)
  └─ TARGET_UNPROVABLE → BLOCKED (fail closed; fail page)
```

## 5. Current target derivation

Supported Subscription statuses only:

| Status | Disposition | Target |
|---|---|---|
| `active`, `past_due` | EFFECTIVE | PlanRevision pair + period boundaries; nil/nil uses `valid_from_at = nil`, `valid_until_at = current_period_end_at` |
| `suspended`, `canceled` | NON_EFFECTIVE | nil/nil pair and nil interval |
| `pending`, `expired`, unclassified | — | **BLOCKED** — no guess |

## 6. Target equivalence (ordering coverage)

Compare exact evidence **excluding** `source_version`:

- disposition, entitlement kind/scope, `valid_from_at`, `valid_until_at`
- `source_order_line_item_id`, `contract_change_id`, `plan_revision_id`

Matching evidence means the latest effect remains safe even when `effect.source_version < subscription.aggregate_version`.

## 7. Producers

### 7.1 Charged renewal (Producer A)

After period/revision update, ContractChange application, and late scheduled-cancellation resolution; only when final outcome is `:applied`:

- `source_version` = renewed `aggregate_version`
- entitlement pair from immutable `RenewalAttempt` charged snapshot
- `valid_from_at` = `attempt.period_start_at` for a pair; **nil** for nil/nil (no fabricated start)
- `valid_until_at` = `attempt.period_end_at`
- provenance from renewed subscription + `attempt.plan_revision_id`

If late boundary processing yields scheduled cancellation, **no** EFFECTIVE effect (scheduled-boundary NON_EFFECTIVE lane owns target).

Effect insertion failure rolls back the commercial renewal transaction.

### 7.2 Immediate cancellation (Producer B)

Inside `cancel_subscription_in_transaction/4`, after authoritative Subscription update, before commit, when **`effective_mode == :now`**:

- NON_EFFECTIVE nil/nil target at canceled `aggregate_version` and current provenance.

Period-end intent remains target-neutral. Legacy post-commit revoke unchanged.

## 8. Historical reconciliation

Candidate set: `status IN (required, pending, failed_retryable)` for both dispositions, via existing `access_effects_effective_recovery_index` and `access_effects_non_effective_recovery_index`.

Independent keyset cursors per disposition; one frozen `as_of` / `through_updated_at` per sweep.

Per candidate: one transaction, Subscription `FOR UPDATE`, re-read latest effect, derive/compare target, establish only on mismatch. Never Entitlements, never mark APPLIED, never PubSub/Cachex.

Unprovable target fails the **page** with effect id and subscription id.

## 9. Six-lane matrix

| Lane | F0.5 |
|---|---|
| Initial paid-order creation | Lifecycle-disjoint (no prior target) |
| Ordinary charged renewal | Producer A |
| Suspended charged recovery | Producer A (generalized) |
| Failed-payment suspension | Existing NON_EFFECTIVE preserved |
| Immediate cancellation | Producer B |
| Scheduled boundary cancellation | Existing NON_EFFECTIVE preserved |

## 10. Concurrency

1. Subscription `FOR UPDATE` is the source mutex.
2. Producers and reconciliation establish under that lock before commit.
3. AccessEffect rows are not the mutex.
4. Newer producer vs reconciliation races serialize safely via source lock.

## 11. Performance & scaling

- Cold PostgreSQL authority only; no new cache/TTL/Redis/PubSub.
- Reuse existing partial recovery indexes; no new index without EXPLAIN proof.
- Reconciliation off hot path; page size 1..500; one source transaction per candidate.

## 12. Success criteria

```text
ORDINARY_RENEWAL_ORDERING=COMPLETE
IMMEDIATE_CANCELLATION_ORDERING=COMPLETE
SUSPENDED_RECOVERY_ORDERING=PRESERVED
FAILED_PAYMENT_ORDERING=PRESERVED
SCHEDULED_CANCELLATION_ORDERING=PRESERVED
INITIAL_SOURCE_CLASSIFICATION=PRESERVED
RECONCILIATION=BOUNDED_RESUMABLE
RECONCILIATION_BLOCKERS=0
BROAD_SCAN=NO
ACCESS_TARGET_ORDER_COVERAGE=COMPLETE
```
