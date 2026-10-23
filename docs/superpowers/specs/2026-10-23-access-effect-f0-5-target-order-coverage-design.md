# F0.5 — AccessEffect Target-Order Coverage

Status: **Implementation correction for PR #181, 2026-10-23**

This document records technical behavior. Approval and merge state are tracked on PR #181.

Implementation plan: `docs/superpowers/plans/2026-10-23-access-effect-f0-5-target-order-coverage-implementation-plan.md`

Plan SHA256: `aadaff1e126107261ec2207846b99706e1d702ae251732a92503c87979ac8d78`

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
- One bounded reconciliation stream over all unresolved AccessEffects, ordered by immutable `inserted_at, id`.
- Dedicated Oban worker for resumable sweeps.
- Evidence-backed six-lane source audit with focused lifecycle tests.

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

Candidate set: `status IN (required, pending, failed_retryable)` across both dispositions. F0.5 uses the dedicated `read_target_order_candidates_for_system` selector and does not reuse the mutable `updated_at` recovery selectors.

Freeze one `as_of` watermark and use one keyset cursor:

```text
through_inserted_at, after_inserted_at, after_id, limit
```

The selector filters `inserted_at <= through_inserted_at`, sorts by `(inserted_at, id)`, uses no OFFSET, and never scans Subscriptions. The cursor key does not change when an AccessEffect moves through `required`, `pending`, and `failed_retryable`.

The matching partial PostgreSQL index is:

```sql
CREATE INDEX access_effects_target_order_reconciliation_index
ON access_effects (inserted_at, id)
WHERE status IN ('required', 'pending', 'failed_retryable');
```

Per candidate, use one transaction in this order: read the exact AccessEffect only to learn `subscription_id`; lock the Subscription `FOR UPDATE`; lock the exact AccessEffect `FOR UPDATE`; use that locked row; read the latest effect; derive the current target; classify terminal candidates and newer current effects as no-ops; return already covered when evidence matches; otherwise establish the target. Never execute effects, mutate Entitlements, or mark an effect APPLIED.

Each worker call selects and processes at most its requested limit, bounded to 1..500 candidates. It resumes from one immutable cursor. Never Entitlements, never mark APPLIED, never PubSub/Cachex.

Unprovable target fails the **page** with effect id and subscription id.

## 9. Six-lane matrix

| Lane | Production path | Evidence |
|---|---|---|
| Initial paid-order creation | New source creation has no prior AccessEffect target to order | `test/store/workers/subscriptions_ensure_for_paid_order_worker_test.exs` |
| Ordinary charged renewal | `maybe_establish_charged_renewal_access_effect/4` | `test/store/subscriptions/sbh_10_05_charged_contract_reconciliation_test.exs` |
| Suspended charged recovery | Same applied-renewal producer after recovery | `test/store/subscriptions/sbh_10_05_charged_contract_reconciliation_test.exs` |
| Failed-payment suspension | Existing suspension transition and NON_EFFECTIVE producer | `test/store/subscriptions/sbh_30_04_failed_payment_suspension_boundary_test.exs` |
| Immediate cancellation | `maybe_establish_immediate_cancellation_access_effect/2` under the cancellation transaction | `test/store/subscriptions/sbh_20_02_renewal_immediate_cancellation_test.exs` |
| Scheduled boundary cancellation | Existing `commit_scheduled_boundary_cancellation/1` producer | `test/store/subscriptions/sbh_40_02_durable_period_boundary_terminalization_test.exs` |

The source audit found four lifecycle producer paths in `Store.Subscriptions.Facade`: applied charged renewal, cancel-now, failed-payment suspension, and scheduled-boundary cancellation. Target-order reconciliation adds a repair writer. Initial paid-order creation remains lifecycle-disjoint. At review, rerun `rg -n 'establish_access_effect_for_system\\(|:extend_period|:scheduled_boundary_cancellation_transition|:mark_suspended_transition|create_subscription' lib/store/subscriptions/facade.ex lib/store/subscriptions/subscription.ex`, trace each target-changing write to its caller and transaction, and classify any new writer before accepting coverage. The current writer search finds no additional production callers; the table and focused tests are evidence, while a lane count alone is not a completeness proof.

## 10. Concurrency

1. Subscription `FOR UPDATE` is the source mutex.
2. Producers and reconciliation establish under that lock before commit.
3. AccessEffect rows are not the mutex.
4. Producer-first and reconciliation-first real-connection tests prove that both lock-arrival orders serialize.
5. After waiting, reconciliation uses the locked candidate row. It treats a candidate that became terminal as a no-op.

## 11. Performance & scaling

- Cold PostgreSQL authority only; no new cache/TTL/Redis/PubSub.
- Reconciliation runs off the customer hot path.
- One status-filtered keyset SELECT per page uses `access_effects_target_order_reconciliation_index` on `(inserted_at, id)`.
- One worker invocation processes no more than `limit` candidates, with `limit` clamped to 1..500; each candidate gets one source transaction and up to five source/effect reads before an optional insert.
- The page has at most 500 AccessEffect rows in memory. No cache stampede or invalidation path applies.
- Oban uses unique args per cursor page, so a continuation has an idempotent job key.

## 12. Runtime resource safety review

- Memory: page list is capped at 500 rows and the reducer processes rows sequentially.
- GC: no process retains candidate rows after a worker call; repeated-load measurements remain unmeasured.
- Mailbox: the worker does not spawn producers or send per-candidate messages; it enqueues at most one continuation.
- Resource cleanup: each candidate transaction commits or rolls back before the next begins; no new external handles are opened.
- Post-load convergence and capacity: unmeasured. This review makes no convergence or capacity claim.

## 13. Success criteria

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
