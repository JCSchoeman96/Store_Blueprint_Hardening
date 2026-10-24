# JC-245 / F1 EFFECTIVE AccessEffect executor implementation plan

> Review plan only. Implementation is not authorized by this document.

**Goal:** Execute current EFFECTIVE AccessEffects by converging their exact Subscription-source grant set and marking the effect APPLIED atomically.

**Architecture:** `Store.Subscriptions` owns lifecycle, Subscription serialization, currentness, fingerprint and target checks, and the APPLIED transition. It calls the accepted `Store.Entitlements` exact-source convergence helper inside the same PostgreSQL transaction. Projection delivery remains post-commit and repairable.

**Base:** `39c67a5973fe5a679abd09fe380a9cfd6d7fb12f`

**Tree:** `4e588ce3d6092ab2966e496e47344c53b1e2c9f3`

## Scope and accepted authority

F0 and F0.5 are accepted at this base, and AccessEffect target-order coverage is complete. JC-245 implements only EFFECTIVE execution. JC-246 NON_EFFECTIVE execution remains separate. The ordinary charged-renewal legacy grant writer remains until JC-300.

The accepted F0 `AccessEffectCurrentnessFence.prove/1` is the only currentness proof for this executor and its failure recorder. Call it unchanged from a caller-owned `Repo.transaction/1`. Do not duplicate its reads, locks, validations, or ordering.

The source order in the accepted fence is:

1. Bounded exact candidate lookup by `access_effect_id`, projecting `subscription_id`.
2. Lock that exact Subscription row with PostgreSQL `FOR UPDATE`.
3. Lock the candidate AccessEffect row.
4. Validate source identity.
5. Validate `source_version <= aggregate_version`.
6. Validate persisted fingerprint integrity, recomputing v2 first and allowing only the accepted exact v1 fallback when persisted `valid_from_at` is nil.
7. Validate target executability.
8. Read the latest AccessEffect for that Subscription, ordered by descending `source_version`, limit one.
9. Classify the candidate as current or stale.

Fingerprint integrity and executability therefore precede latest-effect classification. Disposition admission follows a successful shared proof and precedes any lifecycle mutation, including stale supersession. Do not change the fence to support F1.

## Ownership and transaction design

Add `Store.Subscriptions.execute_effective_access_effect_for_system/1` as the EFFECTIVE executor. Freeze its public result contract:

- `{:ok, :applied}` — correctness transaction committed and projection delivery completed.
- `{:ok, :applied_projection_pending}` — correctness transaction committed, AccessEffect is APPLIED, grant convergence is durable, projection delivery failed after commit, and `projection_delivered_at` remains nil for the existing repair path.
- `{:ok, :superseded}` — a valid stale EFFECTIVE obligation was superseded and the newer target remains authoritative.
- `{:ok, :noop}` — terminal or idempotent no-op.
- `{:error, reason}` — correctness execution failed before successful commit, or currentness/validation proof failed. Only a qualifying rolled-back correctness execution failure may invoke the post-rollback failure recorder.

Post-commit projection failure returns `{:ok, :applied_projection_pending}`. It must never return an ordinary correctness-execution error, invoke the failure recorder, change APPLIED to FAILED_RETRYABLE, roll back or repeat grant convergence, or make an already-paid suspended renewal fail. Its repair belongs to the existing projection evidence and recovery selector.

The outer transaction owns all correctness writes:

1. Begin the outer Repo transaction.
2. Call `AccessEffectCurrentnessFence.prove/1` unchanged.
3. Admit EFFECTIVE disposition only after the proof succeeds. A wrong-disposition candidate fails closed before lifecycle mutation or stale supersession.
4. Treat APPLIED and SUPERSEDED as terminal. For a valid current candidate, transition REQUIRED or FAILED_RETRYABLE to PENDING as needed; PENDING stays PENDING.
5. Build the typed `SubscriptionSourceConvergenceInput` exclusively from the locked Subscription identity and persisted AccessEffect target. A complete pair uses the exact persisted kind, scope, `valid_from_at`, and `valid_until_at`. EFFECTIVE nil/nil is a valid empty target. A half-pair or incomplete interval fails closed.
6. Call `Store.Entitlements.Facade.converge_subscription_source_grants_for_system/1` inside this transaction. The Subscription lock remains held through convergence, APPLIED, and commit. Entitlements does not select effects, read Subscription policy, derive a commercial target, open a transaction, or transition AccessEffect state.
7. Persist projection user IDs and transition PENDING to APPLIED in the same transaction as grant convergence. Return notifications/projection evidence for post-commit delivery.
8. After commit, notify through the existing post-commit wrapper and deliver the projection. If projection delivery fails, return `{:ok, :applied_projection_pending}` and leave `projection_delivered_at` nil. Do not invoke the failure recorder or rewrite the APPLIED effect or converged grant truth. The pending projection remains repairable through its existing evidence and selector.

For a valid stale EFFECTIVE candidate, use the accepted stale transitions: REQUIRED/FAILED_RETRYABLE -> PENDING -> SUPERSEDED and PENDING -> SUPERSEDED. APPLIED and SUPERSEDED remain terminal. Do not supersede a candidate until the shared fence has passed fingerprint and executability checks and the executor has admitted EFFECTIVE disposition.

### Failure recording

If convergence or the APPLIED write fails before commit, roll back the entire execution transaction before recording retry state. In a new Repo transaction, the failure recorder calls the same `AccessEffectCurrentnessFence.prove/1` and repeats EFFECTIVE disposition admission. It must not use the old suspension executor's aggregate-version-equality helper. Invoke it only for qualifying rolled-back correctness execution failures, never for validation/proof failures or post-commit projection delivery failures.

- CURRENT, executable EFFECTIVE: REQUIRED -> PENDING -> FAILED_RETRYABLE; PENDING -> FAILED_RETRYABLE; FAILED_RETRYABLE is a no-op.
- STALE: apply the accepted stale supersession transitions.
- Malformed, fingerprint-invalid, execution-incomplete, or wrong-disposition evidence: fail closed without guessing, changing lifecycle state, or rewriting evidence.

The recorder must not convert a failed proof into a retryable transition. If failure recording itself fails, return/report both the original execution failure and recording failure through the established error boundary.

## Replay-safe charged-renewal handoff

F0.5 establishes EFFECTIVE AccessEffects for ordinary charged renewals and suspended charged-renewal recovery. The Subscription status and dunning fields are mutable, and `extend_period` clears the suspension evidence, so they cannot identify the original lane on replay.

RENEWAL EFFECT IDENTITY and F0 CURRENTNESS are separate concerns. The charged-renewal reconciliation identifies which exact AccessEffect belongs to that immutable renewal occurrence. `AccessEffectCurrentnessFence.prove/1` remains the only authority that decides whether the identified effect is CURRENT or STALE when F1 executes it. The renewal handoff must not require its effect to remain latest/current before passing its ID to F1.

On first commercial reconciliation, retain the exact EFFECTIVE AccessEffect returned by charged-renewal establishment, derive its ordinary versus suspended-recovery classification from its immediate predecessor, and return that effect ID and classification in the locked reconciliation result.

On an exact reconciliation replay or retry where the commercial renewal was already applied but the RenewalAttempt has not yet reached `succeeded`, locate the exact historical renewal EFFECTIVE effect under the locked Subscription. Do not read the latest/current effect and assume it belongs to this renewal. Identify the effect using immutable renewal-occurrence evidence:

- `subscription_id` equals the locked Subscription ID.
- `disposition` is EFFECTIVE.
- `plan_revision_id` equals `RenewalAttempt.plan_revision_id`.
- `valid_until_at` equals `RenewalAttempt.period_end_at`.
- Entitlement kind and scope match the charged-renewal target.
- For a complete pair, `valid_from_at` equals `RenewalAttempt.period_start_at`.
- For a valid EFFECTIVE nil/nil target, `valid_from_at` is nil and the entitlement pair is nil/nil.
- `source_order_line_item_id` matches the Subscription source.

Do not use mutable current Subscription status, `current_contract_change_id`, the current/latest AccessEffect ID, worker memory, grant rows, or execution time as renewal-effect identity. Do not infer `source_version` from `RenewalAttempt.expected_subscription_version + 1`; other valid Subscription writes may occur before charged reconciliation. Use this mandatory bounded lookup contract: scope by the locked `subscription_id`; filter by all immutable renewal-occurrence evidence listed above; order by `source_version DESC`; `LIMIT 2`; exactly one row means use that effect, zero rows fail closed, and two rows fail closed as ambiguous durable history. Do not add a migration or index; use the existing `(subscription_id, source_version)` AccessEffect index to bound one-Subscription history access.

After identifying the exact historical renewal effect, read its immediate predecessor with `subscription_id = renewal_effect.subscription_id AND source_version < renewal_effect.source_version`, ordered by `source_version DESC`, limit one. This predecessor relationship is relative to the historical renewal effect, not whichever AccessEffect is currently latest. Classify from durable target history: predecessor disposition NON_EFFECTIVE means `:suspended_recovery`; a missing predecessor or EFFECTIVE predecessor means `:ordinary`.

Return the exact effect ID and classification in the locked reconciliation result. Use this identity and predecessor algorithm for first reconciliation, exact replay, and retry after EFFECTIVE execution failure. After the effect ID is passed to F1, F1 alone runs `AccessEffectCurrentnessFence.prove/1` and handles it as current or stale. Do not reject the reconciliation because its renewal effect is no longer latest. Preserve the existing successful-attempt replay/no-op behavior.

Dispatch after the reconciliation transaction commits:

- `:suspended_recovery`: call `execute_effective_access_effect_for_system(effect_id)` and skip `issue_subscription_source_grant_strict_for_system/2`.
- `:ordinary`: retain the existing strict issue path. The durable EFFECTIVE effect may also be selected later by EFFECTIVE recovery.

For the already-paid suspended-recovery handoff, `{:ok, :applied}`, `{:ok, :applied_projection_pending}`, `{:ok, :superseded}`, and `{:ok, :noop}` are all successful EFFECTIVE synchronization outcomes. In particular, if a newer AccessEffect becomes current after renewal reconciliation commits but before direct F1 execution, the renewal effect is superseded using the accepted lifecycle transitions, the newer target remains authoritative, and the paid renewal continues under existing reconciliation semantics. Do not call the legacy strict issue path or classify the paid renewal as failed because the effect became stale or projection delivery remains pending. An error from a correctness execution that failed before commit remains an error and follows the accepted failure/retry path; a post-commit projection failure returns `{:ok, :applied_projection_pending}`.

Do not derive this classification from current Subscription status, `RenewalAttempt.failure_code`, worker memory, EntitlementGrant state, or execution time. Stop if the exact renewal effect or predecessor history is missing, inconsistent, or ambiguous under the accepted F0.5 lane model.

## Ordinary-renewal writer coexistence

The F0 EFFECTIVE recovery selector covers every unresolved EFFECTIVE effect, including ordinary-renewal effects. JC-245 may therefore converge an ordinary-renewal target while its legacy issue writer remains active. JC-245 does not remove that writer and does not claim global source convergence.

Add compatibility tests for the same current EFFECTIVE target in both orders:

1. Legacy ordinary-renewal issue, then F1 convergence: final exact-source state matches the persisted AccessEffect target, including exact start and end.
2. F1 convergence, then legacy ordinary-renewal issue: the generic `:issue` upsert does not replace persisted `valid_from_at`, and final target state remains correct.

Add a real separate-PostgreSQL-connection contention test for the ordinary-renewal legacy grant writer versus F1 convergence, exercising both arrival orders: legacy writer obtains its grant-write position first and F1 arrives second; F1 obtains its convergence/source position first and the legacy writer arrives second. Use the same persisted EFFECTIVE target in both cases. Assert no deadlock; final active exact-source cardinality is one; exact `valid_from_at` and `valid_until_at` are preserved; status is active; `revoked_at` and `revoked_reason` are nil; and no other source is mutated. This proves only `SAME_TARGET_COMPATIBILITY_DURING_JC300_DEBT=YES`. Do not add a correctness lock to the legacy writer in JC-245.

These sequential and concurrent tests cover only the known same-target coexistence contract. They do not prove safety for a legacy write arriving after a newer Subscription target. Keep `GLOBAL_SOURCE_CONVERGENCE_IDEMPOTENCE=NOT_YET_PROVEN`; that compatibility debt remains for JC-300.

## Recovery and projection repair

Extend the existing recovery execution stream to consume F0's indexed `read_recoverable_effective_for_system` selector. Freeze the facade options and result fields:

- Preserve the NON_EFFECTIVE options `:execution_after_updated_at`, `:execution_after_id`, and `:skip_execution`, and result fields `:execution_count` and `:execution_cursor`. These retain their existing NON_EFFECTIVE meaning.
- Add EFFECTIVE options `:effective_execution_after_updated_at`, `:effective_execution_after_id`, and `:skip_effective_execution`, and result fields `:effective_execution_count` and `:effective_execution_cursor`.
- Keep `:projection_cursor` independent. `:failed_count` may remain the aggregate failure count across all recovery streams.

Freeze the worker JSON keys as `"effective_execution_after_updated_at"`, `"effective_execution_after_id"`, and `"skip_effective_execution"`. Require the EFFECTIVE cursor timestamp and ID to be both present or both absent. Reject/discard a half cursor through the existing worker/facade error convention. Preserve existing NON_EFFECTIVE names and semantics. The continuation worker carries the same frozen `as_of` and `sweep_id` and all non-nil cursors. A sweep is complete only when `effective_execution_cursor`, `execution_cursor`, and `projection_cursor` are all nil. One exhausted stream must not suppress another. Keep candidate pages bounded by the existing 1..500 selector limit. Do not replace or merge the NON_EFFECTIVE executor. Ordinary and suspended-recovery EFFECTIVE effects use the same executor and recovery selector.

The projection selector may continue to include both dispositions. Dispatch repair by the persisted AccessEffect disposition:

- EFFECTIVE: use the stable private reason constant `@effective_access_effect_projection_reason "effective_access_effect_applied"`. It is projection metadata only; it does not select or alter the target and is not derived from current Subscription status.
- NON_EFFECTIVE: preserve the existing suspension/cancellation reason behavior.

Keep this dispatch private behind the existing recovery facade; do not add a public facade unless implementation proves it necessary. Add a repair test for an active Subscription with an applied EFFECTIVE effect and pending projection evidence.

## Proposed changed files

Modify:

- `lib/store/subscriptions/facade.ex` — EFFECTIVE executor, fence-based failure recorder, locked renewal handoff classification, and private disposition-based projection dispatch.
- `lib/store/workers/run_subscription_access_effect_recovery_worker.ex` — independent EFFECTIVE execution cursor/args while retaining existing streams.
- `lib/store/support/governance/surface_registry.ex` — register the new system facade export.

Tests:

- Existing charged-renewal reconciliation tests — first-run, replay, retry, predecessor classification, and legacy-writer ordering.
- Existing `test/store/subscriptions/access_effect_effective_recovery_test.exs` — EFFECTIVE selector/recovery and active Subscription projection repair coverage.
- New focused EFFECTIVE executor tests under `test/store/subscriptions/`.
- Extend `test/store/subscriptions/source_fence_contention_test.exs` with real separate-connection F1 cases, including legacy-writer/F1 same-target contention in both arrival orders. This file is already run twice by `real_connections_required`, so no CI workflow change is needed.
- Recovery worker tests for independent cursors, ordinary EFFECTIVE recovery, failure retry, and disposition-based projection repair.

Do not modify Entitlements implementation unless concrete evidence shows the accepted F0 helper cannot serve F1. If that evidence appears, stop and report it before changing that boundary. No migration is authorized or currently expected.

## Implementation phases after plan approval

1. Add focused failing tests for executor lifecycle, pair/empty target semantics, wrong disposition, rollback, and exact-source isolation.
2. Implement the separate EFFECTIVE facade executor using the unchanged F0 fence and existing typed Entitlements helper. Keep convergence and APPLIED in one outer transaction.
3. Add the post-rollback failure recorder, reusing the same fence and lifecycle rules.
4. Add locked charged-renewal exact-historical-effect/predecessor classification and route only `:suspended_recovery` through F1. Keep the `:ordinary` legacy issue path.
5. Add the separate EFFECTIVE recovery cursor and private projection-reason dispatch.
6. Add same-target legacy/convergence compatibility tests and real PostgreSQL connection contention tests. Verify the real-connection file is included in both required CI repetitions.
7. Record the Performance & Scaling Review and Runtime Resource Safety Review, then run the checks required by JC-245. Do not claim a runtime dimension that remains unmeasured.

No implementation work starts until this plan receives final review and explicit authorization.

## Test matrix

| Area | Required proof |
|---|---|
| Fence and admission | Executor and failure recorder call the unchanged F0 fence. Fingerprint integrity and executability precede latest classification. Wrong disposition fails before lifecycle mutation or supersession. |
| Fingerprints and targets | V2 recomputation first; exact v1 fallback only for persisted nil `valid_from_at`; no fingerprint rewrite or reconstructed timestamp. Complete pair converges exact interval; EFFECTIVE nil/nil converges empty; half-pairs and execution-incomplete pairs fail closed. |
| Lifecycle and atomicity | REQUIRED/PENDING/FAILED_RETRYABLE success paths reach APPLIED as specified. Inject failure after grant mutation and at APPLIED; rollback leaves neither partial grants nor APPLIED. Failure recording re-proves in a new transaction. Verify the exact executor outcomes: committed projection success returns `:applied`; committed projection failure returns `:applied_projection_pending`; valid stale returns `:superseded`; terminal replay returns `:noop`; only pre-commit correctness/proof failures return `{:error, reason}`. |
| Idempotence and source isolation | Re-execution/retry converges idempotently. Other Subscription sources and non-subscription sources remain untouched. Exact-source active cardinality is zero for empty targets and exactly one for pair targets, never greater than target. |
| Duplicate workers | Two independent PostgreSQL connections execute the same effect; only one applies, the other observes terminal/no-op state, and there is no duplicate active target. Process-local locks do not count as proof. |
| Stale/current race | Separate connections race an old effect with a newer current effect; stale target cannot apply. Cover both executor-first and producer-first Subscription-lock arrival orders. |
| Producer/executor ordering | Under real connections, prove producer and executor serialize on the Subscription row in both lock-arrival orders and the committed latest target wins. |
| Rollback/retry | Failure after grant writes rolls back all grant mutations and APPLIED. Retry after failure reaches the exact target idempotently. APPLIED rollback is separately asserted. |
| Renewal lane classification | Cover first suspended recovery, replay after successful F1 execution, replay after FAILED_RETRYABLE execution, ordinary renewal with no predecessor, ordinary renewal with EFFECTIVE predecessor, and suspended recovery with NON_EFFECTIVE predecessor. Assert the same history rule is used on first run/replay/retry. |
| Historical renewal retry after newer target | Commit suspended charged-renewal commercial reconciliation and its EFFECTIVE effect, then interrupt the handoff before RenewalAttempt succeeds. Commit a newer target-changing AccessEffect, retry the paid reconciliation, and prove it identifies the original historical renewal effect from immutable occurrence evidence, retains its original predecessor classification, and passes that historical ID to F1. Assert F1 returns a successful stale/terminal outcome, the newer target remains authoritative, no legacy strict issue occurs, no newer target is overwritten, RenewalAttempt reaches succeeded, and no duplicate effect is established. Cover both a qualifying pre-commit F1 failure recorded as FAILED_RETRYABLE and, where cleaner through existing seams, a process boundary after durable F1 truth but before attempt success. Preserve successful-attempt replay/no-op behavior. |
| Renewal handoff race | Commit a newer target after suspended renewal reconciliation but before direct F1 execution. Assert the renewal effect becomes SUPERSEDED, the newer target remains current, the legacy strict issue path is not called, and the renewal attempt completes under existing reconciliation semantics. Treat APPLIED, APPLIED_PROJECTION_PENDING, SUPERSEDED, and NOOP as successful handoff results; a correctness execution error before commit remains an error and follows failure/retry. |
| Recovery and projection | Failed direct F1 execution is later recovered. Ordinary EFFECTIVE recovery works while the legacy writer remains. EFFECTIVE projection repair works for an active Subscription using the stable reason. Inject post-commit projection-delivery failure and assert the executor returns `{:ok, :applied_projection_pending}`, APPLIED grant/effect truth is unchanged, `projection_delivered_at` remains nil, the failure recorder is not invoked, and existing projection evidence remains repairable. NON_EFFECTIVE repair behavior stays unchanged. EFFECTIVE, NON_EFFECTIVE, and projection cursors advance independently. |
| Recovery interfaces | Assert the exact EFFECTIVE facade option/result and worker JSON names. A timestamp/ID half cursor is rejected; all three streams advance independently; one exhausted stream does not suppress another; continuation preserves all non-nil cursors plus `as_of` and `sweep_id`; sweep completion requires all three cursors nil. Existing NON_EFFECTIVE `execution_count` and `execution_cursor` retain their meanings. |
| Legacy coexistence | For one same current target, test sequential legacy issue -> F1 convergence and F1 convergence -> legacy issue, plus real separate-connection contention in both writer/convergence arrival orders. Assert no deadlock, exact persisted `valid_from_at` and `valid_until_at`, one active exact-source grant, active status, cleared revocation fields, and no other source mutation. Record `SAME_TARGET_COMPATIBILITY_DURING_JC300_DEBT=YES`. Do not test or claim safety for future-target legacy races; retain that for JC-300. |
| Resource evidence | Exercise a larger bounded exact-source history than existing 1/5/25 fixtures; record exact row count, SQL/query statement count, convergence duration where practical, lock-wait evidence, and observed memory/GC behavior. Repeat equivalent bounded runs before making a convergence/no-accumulation claim. |

## Performance & Scaling Review

- **Hot path:** executor and recovery are correctness-sensitive subscription access paths. Candidate lookup remains exact by effect ID; recovery remains bounded and uses the existing EFFECTIVE partial index and keyset ordering.
- **Database work:** no global AccessEffect or grant scans. The accepted F0 helper reads/locks all historical grant rows for one exact Subscription source, then uses set-oriented target upsert/revoke operations and a final limit-two active-set proof. JC-245 does not refactor that helper.
- **Measure and report:** exact-source row count in test evidence, statement/query count, lock wait during real-connection contention, convergence duration where practical, and observed memory/GC behavior. Use a larger bounded history fixture than the current 25-row maximum and equivalent repetitions. Report unavailable dimensions as `UNMEASURED`.
- **Accepted debt:** `SOURCE_CARDINALITY_BOUND=UNMEASURED`; `SOURCE_CARDINALITY_CAP_ADDED=NO`. Do not claim capacity or global convergence. Stop if measurements show pathological resource growth; any helper redesign requires separate admission.
- **Caching and recovery:** Redis/ETS/Cachex are projections only and cannot serialize or authorize this path. Oban uniqueness and retries aid delivery only; PostgreSQL Subscription `FOR UPDATE` is the source mutex. Keep projection invalidation post-commit and repairable.
- **Runtime Resource Safety Review:** report bounded candidate page, exact-source rows materialized, SQL statement count, observed lock wait, duration, and memory/GC dimensions. Do not claim runtime safety or convergence for an unmeasured dimension.

## Risks and edge cases

- A missing or ambiguous exact historical renewal effect/predecessor cannot be classified safely; stop rather than fall back to mutable state.
- An EFFECTIVE nil/nil target is valid and must revoke the exact source set without changing commercial Subscription status.
- A fingerprint-valid historical EFFECTIVE pair with nil start is still non-executable. The fence must reject it before latest/stale classification, Entitlements calls, or lifecycle writes.
- The generic ordinary-renewal `:issue` upsert remains a concurrent legacy writer until JC-300. Same-target orderings are tested; a future-target race remains outside F1's proof.
- Projection delivery may fail after commit. Persisted projection evidence and bounded repair must allow retry without repeating grant convergence as a new target.
- Existing worker cursor behavior must preserve independent streams and avoid starvation when EFFECTIVE and NON_EFFECTIVE effects are both due.
- The exact-source history remains unbounded in the accepted helper. If the larger bounded evidence demonstrates pathological resource growth, stop; do not add a cap or redesign F0 in JC-245.

## Stop conditions

Stop before implementation or stop the affected implementation portion if:

- `origin/main` moved from the accepted SHA/tree before implementation begins.
- Current source conflicts with accepted F0/F0.5 behavior, or the F0 fence order/API must change.
- Exact-source convergence cannot remain inside the Subscription-locked outer Repo transaction.
- Another writer/executor creates a second correctness authority or inserts target-changing effects without the Subscription lock.
- The renewal's exact historical EFFECTIVE effect and predecessor history cannot deterministically distinguish suspended recovery from ordinary renewal under the accepted lane model.
- Historical timestamp reconstruction, fingerprint rewriting, or changed frozen fingerprint semantics would be required.
- Runtime evidence shows pathological resource growth in the accepted exact-source helper.
- The work would mix JC-246 NON_EFFECTIVE execution into F1, remove the ordinary legacy writer, claim global source convergence, add an unauthorized migration, or perform the JC-300 writer cutover.

## Plan state

```text
IMPLEMENTATION_AUTHORIZED=NO
JC300_WRITER_CUTOVER_INCLUDED=NO
GLOBAL_SOURCE_CONVERGENCE_IDEMPOTENCE=NOT_YET_PROVEN
SOURCE_CARDINALITY_BOUND=UNMEASURED
SOURCE_CARDINALITY_CAP_ADDED=NO
F0_FENCE_ORDER_PRESERVED=YES
SOURCE_CARDINALITY_DEBT_REOPENED=NO
ORDINARY_EFFECTIVE_RECOVERY_BEHAVIOR=EXPLICIT
SUSPENDED_HANDOFF_REPLAY_PROOF=COMPLETE
EFFECTIVE_PROJECTION_REPAIR_RULE=COMPLETE
```
