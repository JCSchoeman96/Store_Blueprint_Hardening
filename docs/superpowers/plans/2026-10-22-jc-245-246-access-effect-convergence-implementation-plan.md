# JC-245/246 AccessEffect convergence implementation plan

> Review draft only. This plan does not authorize implementation.

**Goal:** Add one shared exact-source Entitlements convergence boundary, then implement separate EFFECTIVE and NON_EFFECTIVE AccessEffect executors and a later source-writer cutover.

**Architecture:** Subscription locks the exact source and candidate effect, validates the latest immutable target, and owns the APPLIED transition. Entitlements converges only that Subscription's complete zero-or-one grant set inside the caller's PostgreSQL transaction. Cachex invalidation and PubSub run after commit and remain repairable projections.

**Tech stack:** Elixir, Phoenix, Ash 3.x, AshPostgres, Ecto, PostgreSQL, Oban, ExUnit.

---

Status: A1 design pass. This is a high-level phased plan, not the detailed F0 execution plan. After review and acceptance of the authority documents, prepare and review a dedicated F0 implementation plan before starting F0. JC-245 and JC-246 remain blocked on F0 and the F0.5 source-order coverage gate. JC-300 is a separate later grant-writer cutover. No implementation is authorized by this draft.

- Reviewed base: 43d5487927af68b33df754c0ca0695b09fabacca
- Reviewed tree: 754f03502c9a4b8e6f049d6e6724340d6f31f5a8
- Review-start repository state: `main` at the reviewed base; these two drafts were the only untracked paths; one worktree.

## Scope and PR boundaries

Use the sequential Linear workflow from the repository instructions when a human admits each issue. Every implementation PR targets main, records its exact origin/main base SHA, and receives a human merge. Keep F0, F0.5, F1, F2, and F3 in separate PRs. Do not change issue state, create branches, or run implementation work under this review draft.

No NewYou policy or multi-target entitlement set belongs in these phases. Do not claim global exact-source convergence until F3 has cut over all retained writers.

## F0: shared convergence and source-fence foundation

**Purpose:** Give both executors one Entitlements mutation authority and one locked current-effect fence. Do not add an EFFECTIVE or NON_EFFECTIVE execution path in this PR.

**Expected future files:**

- Modify lib/store/entitlements/facade.ex.
- Modify lib/store/entitlements/entitlement_grant.ex.
- Modify lib/store/subscriptions/access_effect.ex to add the bounded effective recovery selector.
- Add the effective-recovery partial-index migration and generated AccessEffect snapshot.
- Add a typed convergence input and result under lib/store/entitlements/inputs/ and lib/store/entitlements/types/.
- Add the shared internal current-effect fence in lib/store/subscriptions/facade.ex.
- Add focused tests under test/store/entitlements/ and test/store/subscriptions/.

**Work:**

1. Define the immutable input with subscription_id, user_id, disposition, optional complete kind/scope pair, exact valid_from_at and valid_to_at, reason metadata, access_effect_id, source_version, and target_fingerprint. Reject half-pairs and nil valid_from_at for a pair target.
2. Require `Repo.in_transaction?` before any grant read or write. Keep the exact Subscription `FOR UPDATE` lock as the source-level mutex through commit. Then lock only existing grant rows for `source_kind = subscription` and the exact `source_id`, ordered by native PostgreSQL UUID id ascending. Grant-row locks alone cannot serialize an empty source set.
3. Add a dedicated bounded EntitlementGrant create/upsert action for convergence. On identity conflict it writes exact `valid_from_at`, exact `valid_to_at`, `status: :active`, `revoked_at: nil`, and `revoked_reason: nil`. Verify the returned row's identity and all five state fields. Keep the generic `:issue` upsert fields and the resource `valid_from_at` default unchanged in F0. Existing paid-order and charged-renewal callers pass worker-time starts, so changing generic `:issue` would change their conflict replay behavior. If the dedicated action cannot provide one bounded Ash upsert with these values, stop F0 and request a bounded caller-impact review before changing `:issue`. Do not remove the default without separate proof.
4. Add an atomic-safe set revocation action. Use `Ash.bulk_update/4` with strategy `[:atomic]`. If Ash cannot apply the action as one atomic query update, fail the operation. Do not allow stream or per-record fallback.
5. For an EFFECTIVE pair, use the dedicated upsert for one target then bulk-revoke every other active grant in that source. For either empty target, bulk-revoke every active grant in that source. Keep historical non-active rows and all other source rows untouched.
6. Return complete-convergence evidence or an error. Do not translate a row failure into false or a successful count.
7. Add the post-commit Entitlements helper guard. It must fail closed while `Repo.in_transaction?` is true, invalidate Cachex first, broadcast second, and return the failing step. Preserve the existing projection repair evidence and selector.
8. Add one shared Subscription-side fence used later by both executors. Lock the Subscription and candidate AccessEffect. Require `source_version <= aggregate_version`, with no equality requirement. Recompute v2 from persisted fields first. Only after v2 mismatches, allow the exact v1 compatibility calculation when persisted `valid_from_at` is nil. Never rewrite fingerprints or reconstruct starts. Fail closed on any fingerprint mismatch. Validate target executability before stale handling: an EFFECTIVE pair with nil start is execution-incomplete even when v1 integrity passes, so do not call Entitlements, mark APPLIED, or mark it stale/superseded. EFFECTIVE nil/nil and the current NON_EFFECTIVE nil-start empty target remain legitimate. Read the latest effect ID and return current/stale evidence without lifecycle mutation. The separate JC-245 executor admits EFFECTIVE only; JC-246 admits NON_EFFECTIVE only. Reject a wrong disposition before stale supersession or any status transition. Build the typed input from persisted effect evidence; do not load Plan policy or start a transaction. Verify every effect-producing source transaction locks the same Subscription row before it inserts an effect; otherwise stop. Both JC-245 and JC-246 must keep this lock while invoking convergence and through commit, so a newer effect cannot become current before APPLIED.
9. Freeze the fingerprint byte contract in the shared fence: the current ordered v2 descriptor, deterministic Erlang term encoding, SHA-256, lowercase Base16, and the exact v1 descriptor that omits valid_from_at. Test v2-first validation, nil-start-only v1 fallback, and fail-closed behavior when a non-nil start has a v2 mismatch.
10. Add the bounded effective recovery selector with disposition effective, status required/pending/failed_retryable, updated_at/id keyset order, and limit 1..500. Add only its matching partial index `(updated_at, id) WHERE disposition = 'effective' AND status IN ('required', 'pending', 'failed_retryable')` and generated AccessEffect snapshot. Keep the existing non-effective and projection recovery indexes unchanged.

**F0 gate:** Focused tests prove outside-transaction failure, outer rollback, exact-source isolation, pair and empty-target convergence, exact start/end plus active and cleared revocation state, local transaction replay, rollback on mutation error, empty-source serialization by the Subscription lock, effect-writer serialization, v2-first fingerprint validation, nil-start-only v1 fallback, and the bounded effective selector. A matching v1 fingerprint on an EFFECTIVE pair with nil start must fail as execution-incomplete before convergence or APPLIED and must not become stale/superseded. The generic `:issue` action and start default remain unchanged. The effective index migration must match only the selector. Capture query or SQL telemetry proving database round trips do not grow with grant-row count, with at most two set-oriented grant DML statements for a pair target and one for an empty target. Record `LOCAL_TRANSACTION_IDEMPOTENCE=YES` and `GLOBAL_SOURCE_CONVERGENCE_IDEMPOTENCE=NOT_YET_PROVEN`. Run the required repository and issue checks. Include Performance & Scaling Review and Runtime Resource Safety Review. Do not claim measured capacity.

**F0 result:** One independently reviewable foundation PR. F1 and F2 remain blocked until F0 is accepted on main, the exact typed input, transaction guard, mutation bound, and shared fence exist there, and F0.5 source-order coverage is complete.

## F0.5: Subscription target-order coverage

**Purpose:** Ensure latest AccessEffect identity tracks every current Subscription target-changing transition before F1 or F2 can execute in production. This phase is separate from the later JC-300 grant-writer cutover.

**Current target-changing lanes classified at the A1 base:**

1. Initial paid-order Subscription creation creates a new source and has no prior effect to supersede. Its direct initial grant writer remains assigned to JC-300.
2. Ordinary charged renewal updates the current period and may apply a queued contract change, but does not establish an AccessEffect. F0.5 adds an EFFECTIVE effect in the locked reconciliation transaction. The strict legacy issue writer remains for JC-300.
3. Suspended charged-renewal recovery already creates an EFFECTIVE effect in the locked reconciliation transaction. F1 consumes it.
4. Failed-payment suspension already creates a NON_EFFECTIVE effect in the locked boundary transaction. F2 consumes it.
5. Immediate cancellation changes Subscription target state but only revokes grants after commit. F0.5 adds a NON_EFFECTIVE effect in the locked cancellation transaction. The legacy revoke remains for JC-300.
6. Scheduled boundary cancellation, including late paid cancellation terminalization, already creates a NON_EFFECTIVE effect in the locked transaction. F2 consumes it.

The current `past_due` transitions change dunning/status fields without changing the current period or PlanRevision, and the runtime does not read `access_on_past_due`. Scheduled cancellation intent and queued plan/variant changes keep the current target unchanged until boundary terminalization or renewal. Payment-method, provider-billing-reference, and dunning-counter writes do not change the target. The `activate_now` and `mark_expired_transition` actions have no production call sites in this base. If any of these semantics or producers change before F1/F2 activation, stop and reclassify the lane.

**Work:**

1. Establish the ordinary charged-renewal EFFECTIVE AccessEffect after the Subscription period/revision update and before the existing source lock releases. Use the renewal attempt's immutable entitlement pair and exact period start/end, and use the updated Subscription aggregate version plus its source order line, contract change, and PlanRevision evidence. Preserve effective nil/nil as a valid empty target. Do not use worker time.
2. Establish the immediate-cancellation NON_EFFECTIVE AccessEffect after the Subscription transition and before the cancellation transaction commits. Use the updated Subscription aggregate version and immutable source identity with an empty target. Keep the existing post-commit revoke writer until JC-300.
3. Reconfirm that suspended recovery, failed-payment suspension, and scheduled boundary cancellation still establish their effects under the same Subscription `FOR UPDATE` lock and in the authoritative transaction.
4. Reconcile pre-existing executable effects that may predate these new producers. Use bounded, resumable pages. Under each Subscription source lock, establish a new immutable effect for the exact supported current target so an older effect cannot remain the latest ID after an uncovered target change. Do not rewrite historical fingerprints, reconstruct a historical EFFECTIVE start, infer current target from grant rows, or use aggregate-version equality as an executor rule. If the current Subscription and immutable revision evidence cannot prove a complete current target, leave that source out of executor recovery and fail this gate rather than guessing.
5. Keep legacy grant writes in ordinary renewal and immediate cancellation. F0.5 establishes source-target order; JC-300 later cuts over grant writes.

**F0.5 gate:** Tests prove each target-changing producer writes the effect under the same locked Subscription and authoritative transaction, ordinary renewal and immediate cancellation produce the correct newest immutable target, and current stale effects cannot appear latest after a prior uncovered transition. The bounded reconciliation is resumable and fails closed when exact current source evidence is unavailable. Confirm all six current target-changing lanes are covered and that no newly added Subscription writer remains unclassified. Include Performance & Scaling Review and Runtime Resource Safety Review for the reconciliation and any recovery worker or selector it adds. F1 and F2 production activation before acceptance of this gate is prohibited.

**F0.5 result:** Source-target ordering coverage is complete. JC-245 and JC-246 may proceed as separate executor PRs. Direct grant-writer cutover remains in JC-300.

## F1: JC-245 EFFECTIVE executor

**Purpose:** Execute current EFFECTIVE AccessEffects using F0 after F0.5 source-order coverage is accepted. Keep the executor separate from JC-246.

**Expected future files:**

- Modify lib/store/subscriptions/access_effect.ex.
- Modify lib/store/subscriptions/facade.ex.
- Extend the existing bounded recovery worker and cursor args in lib/store/workers/run_subscription_access_effect_recovery_worker.ex.
- Add focused effective executor and recovery tests.

**Work:**

1. Consume the F0 effective recovery selector and extend recovery orchestration with an independent effective cursor. Do not replace the non-effective stream or merge its executor logic into JC-245.
2. Implement execute_effective_access_effect_for_system as a separate function. It must hold the exact Subscription `FOR UPDATE` source lock while it invokes the F0 shared target validator and Entitlements convergence, keep the lock through the APPLIED write and commit, then project after commit. It admits EFFECTIVE only. The candidate AccessEffect row lock protects that exact obligation; it does not replace the Subscription mutex.
3. For an effective pair, pass exact persisted valid_from_at and valid_until_at. For effective nil/nil, converge to an empty source set without making the Subscription commercially ineffective.
4. Thread the AccessEffect ID out of suspended charged-renewal recovery. In that branch, call the JC-245 executor and skip the old strict issue call. Keep the ordinary charged-renewal writer classified for JC-300.
5. Preserve replay behavior, retryable failure recording after rollback, and the applied-effect projection repair path.

**F1 gate:** Tests prove current effect execution, stale ID rejection, `source_version <= aggregate_version`, v2-first fingerprint validation, v1 fallback only for nil persisted starts, and exact fingerprint mismatch rejection. The shared validator checks integrity and executability; the JC-245 executor admits EFFECTIVE only. Test a complete EFFECTIVE pair and EFFECTIVE nil/nil execute, and a NON_EFFECTIVE effect rejects before lifecycle mutation, convergence, APPLIED, or SUPERSEDED. Test the historical EFFECTIVE pair whose nil-start v1 fingerprint passes integrity but whose execution fails closed before grant convergence, APPLIED, or stale/superseded classification. Verify REQUIRED -> PENDING, FAILED_RETRYABLE -> PENDING, and PENDING -> APPLIED only inside the successful outer transaction; after rollback, verify REQUIRED -> PENDING -> FAILED_RETRYABLE and PENDING -> FAILED_RETRYABLE, with FAILED_RETRYABLE unchanged. Verify the exact full grant state, local replay, rollback, the held Subscription lock at the shared convergence call, and independent recovery cursors. Verify the effective query uses the F0 partial index and that the old non-effective selector still uses its own index. Review Oban uniqueness and retry behavior. Include Performance & Scaling Review and Runtime Resource Safety Review. Global source convergence idempotence remains unproven until JC-300.

**F1 result:** One JC-245 PR. No JC-246 executor changes and no JC-300 writer cutover in this PR.

## F2: JC-246 NON_EFFECTIVE executor reconciliation

**Purpose:** Replace the current partial row-by-row suspension revocation with the F0 exact-source convergence authority after F0.5 source-order coverage is accepted. Keep JC-246 separate from JC-245.

**Expected future files:**

- Modify lib/store/subscriptions/facade.ex.
- Keep lib/store/subscriptions/access_effect.ex recovery selector/index unchanged.
- Add focused non-effective executor, transaction, replay, and projection-repair tests.

**Work:**

1. Route the existing suspension and scheduled-cancellation AccessEffect execution paths through the F0 shared target validator and typed convergence input. Hold the exact Subscription `FOR UPDATE` lock when invoking convergence and through commit. Admit NON_EFFECTIVE only.
2. Remove the aggregate_version equality rule. Require candidate ID to equal the latest effect ID and candidate.source_version <= locked aggregate_version. Validate fingerprint integrity v2-first; try v1 only after a mismatch and only when persisted `valid_from_at` is nil. Do not rewrite stored evidence or reconstruct historical starts. Check executability separately. Fail an EFFECTIVE pair with nil start as execution-incomplete before Entitlements or APPLIED, and do not classify it stale/superseded. Keep EFFECTIVE nil/nil and the current NON_EFFECTIVE nil-start empty target valid.
3. Converge NON_EFFECTIVE to an empty exact-source active set. Preserve the reason as caller-supplied metadata; do not make Entitlements load Subscription or Plan state.
4. Mark that effect APPLIED in the same outer transaction only after all source rows converge. Any error rolls back both grant changes and the effect transition.
5. Keep post-commit cache invalidation then PubSub. A projection failure leaves delivery evidence pending for repair and never reverses committed grants.
6. Keep the current non-effective recovery selector and partial index. Keep the effective selector and index introduced in F0 unchanged. Keep the current executor status semantics, with required, pending, and failed_retryable executable, applied and superseded non-executable.

**F2 gate:** Tests prove NON_EFFECTIVE executes and both EFFECTIVE variants, a complete pair and nil/nil, reject before lifecycle mutation, convergence, APPLIED, or SUPERSEDED. Revoke every same-source grant whose persisted status is `:active`, including rows ENT-T1 classifies FUTURE or ENDED at the supplied `as_of`. Persisted `:revoked` and `:expired` rows may remain as history. Do not filter active rows by their temporal classification. Prove no other source changes, the Subscription lock is held when shared convergence runs, one mutation failure rolls back all work, local transaction replay is idempotent, projection failure is repairable, and the existing selector remains index-backed. Retain `NON_EFFECTIVE_REPLAY_IDEMPOTENT=LOCALLY_YES_GLOBALLY_NOT_PROVEN` and `GLOBAL_SOURCE_CONVERGENCE_IDEMPOTENCE=NOT_YET_PROVEN`. Include Performance & Scaling Review and Runtime Resource Safety Review.

**F2 result:** One JC-246 PR. Do not add the effective selector/index or rewrite the shared foundation here.

## F3: JC-300 source-writer cutover

**Purpose:** Remove the remaining direct Subscription-source grant writers and prove complete source coverage. This phase remains separate from both executor PRs.

**Current lanes assigned to F3:**

- Initial paid-order subscription issue. Today errors are counted as skipped and this path has no AccessEffect.
- Ordinary charged-renewal issue. F0.5 adds source-order effect evidence; the grant writer remains the strict single-grant helper until JC-300.
- Immediate cancellation revoke. F0.5 adds source-order effect evidence; the post-commit legacy revoker remains until JC-300 and still discards its result.

F0.5 establishes source-order effects for ordinary charged renewal and immediate cancellation, but their issue/revoke grant writers remain in JC-300. The suspended recovery lane moves to JC-245. The effect-driven non-effective lane moves to JC-246. Re-audit every direct Ash and Repo mutation, facade export, admin/system caller, worker, and transition at the F3 base. If a new or unclassified source writer appears, stop and record it before cutover.

**F3 gate:** Show that each source-changing operation establishes the right immutable AccessEffect in its authoritative transaction, that every production grant write passes through the shared source fence, that retained legacy helpers cannot be called after activation, and that effect retries cannot be overwritten by a bypass writer. Include concurrency, replay, rollback, migration, performance, and runtime-resource evidence required by the current issue. Only after this gate may the team claim global exact-source convergence.

## Cross-phase acceptance rules

- Subscription and AccessEffect remain currentness and target authorities. Entitlements owns only the actual exact-source grant set and its post-commit projection helper.
- The lock order is Subscription, candidate AccessEffect, then exact-source grants ordered by native UUID id. Never sort lock keys as UUID strings.
- The Subscription `FOR UPDATE` row is the source-level mutex. Candidate AccessEffect lock protects the obligation; grant-row locks protect only rows that exist. `GRANT_ROW_LOCKS_ALONE_ARE_INSUFFICIENT=YES` and `SUBSCRIPTION_SOURCE_LOCK_REQUIRED=YES`. JC-245 and JC-246 both hold the Subscription lock while invoking shared convergence and through commit.
- Latest effect ID plus `source_version <= aggregate_version` proves currentness only after F0.5 has ordered all current target-changing lanes and reconciled pre-existing executable effects. Keep F1 and F2 inactive until that acceptance gate passes. Do not restore aggregate-version equality.
- The shared validator checks target integrity and executability for either disposition. JC-245 admits EFFECTIVE only, and JC-246 admits NON_EFFECTIVE only. A wrong executor changes no lifecycle status, grants, APPLIED, or SUPERSEDED state.
- Successful execution transitions REQUIRED -> PENDING, FAILED_RETRYABLE -> PENDING, or leaves PENDING unchanged, then transitions PENDING -> APPLIED in the same transaction as convergence. After rollback, failure recording uses REQUIRED -> PENDING -> FAILED_RETRYABLE, PENDING -> FAILED_RETRYABLE, and FAILED_RETRYABLE no-op after repeating the current-effect/source-lock proof.
- Fingerprint integrity uses the exact current serialization. Check v2 first. Only after a v2 mismatch may v1 be checked, and only when persisted `valid_from_at` is nil. Integrity does not make a nil-start EFFECTIVE pair executable.
- The shared exact-target upsert writes exact `valid_from_at`, exact `valid_to_at`, active status, and nil revocation fields. Keep generic `:issue` and the `valid_from_at` default unchanged unless a separate bounded caller-impact review authorizes a change.
- The only target cardinalities are the three defined in the A1 authority design: one exact active pair, effective empty set, and non-effective empty set.
- New effective recovery indexing is additive. Keep the old non-effective selector/index and projection repair selector/index.
- F0 alone owns the effective recovery selector, its partial index, and the matching resource snapshot. F1 consumes them and adds recovery orchestration without a migration.
- PostgreSQL remains data authority. Cachex remains the hot raw-set read projection with the existing 60-second TTL. Redis and ETS do not become correctness state.
- Oban handles bounded retries and recovery only. It never determines currentness or target order.
- `LOCAL_TRANSACTION_IDEMPOTENCE=YES`. `GLOBAL_SOURCE_CONVERGENCE_IDEMPOTENCE=NOT_YET_PROVEN`; do not claim global convergence before the F3 source-writer cutover.
- No global scan or cross-source lock. No unbounded per-grant mutation loop. No external I/O inside the authoritative transaction.
- Query count, lock duration, cache projection latency, and per-source row cardinality remain unmeasured until implementation gathers evidence. Capacity and convergence claims require at least two equivalent bounded repetitions.
- Runtime-affecting PRs include Runtime Resource Safety Review for memory, GC, mailbox behavior, cleanup, and post-load convergence. Documentation-only work records NOT_APPLICABLE with a reason.
- Each PR records its exact base and head SHAs, changed files, acceptance evidence, tests, CI, review, Performance & Scaling Review, Runtime Resource Safety Review, and remaining risks. Human merge is required.

## A1 handoff

    AUTHORITY_REVIEW=REQUIRED
    ACCESS_TARGET_ORDER_COVERAGE_REQUIRED=YES
    TARGET_CHANGING_LANES_CLASSIFIED=6
    TARGET_ORDER_REVIEW_REQUIRED=0
    F0_5_ORDER_COVERAGE_REQUIRED_BEFORE_F1_F2_ACTIVATION=YES
    F1_F2_ACTIVATION_BEFORE_ORDER_COVERAGE=NO
    REQUIRED_TO_PENDING=YES
    FAILED_RETRYABLE_TO_PENDING=YES
    PENDING_TO_APPLIED_ONLY=YES
    POST_ROLLBACK_FAILURE_TRANSITIONS=EXPLICIT
    F1_DISPOSITION=EFFECTIVE_ONLY
    F2_DISPOSITION=NON_EFFECTIVE_ONLY
    WRONG_EXECUTOR_MUTATION=NO
    ACTIVE_TEMPORALLY_FUTURE_REVOKED_BY_NON_EFFECTIVE=YES
    ACTIVE_TEMPORALLY_ENDED_REVOKED_BY_NON_EFFECTIVE=YES
    PERSISTED_REVOKED_EXPIRED_HISTORY_MAY_REMAIN=YES
    GRANT_ROW_LOCKS_ALONE_ARE_INSUFFICIENT=YES
    SUBSCRIPTION_SOURCE_LOCK_REQUIRED=YES
    JC245_AND_JC246_HOLD_SOURCE_LOCK_AT_CONVERGENCE=YES
    LOCAL_TRANSACTION_IDEMPOTENCE=YES
    GLOBAL_SOURCE_CONVERGENCE_IDEMPOTENCE=NOT_YET_PROVEN
    AFTER_AUTHORITY_ACCEPTANCE=CREATE_DETAILED_F0_IMPLEMENTATION_PLAN
    SHARED_FOUNDATION_ADMISSION=READY_FOR_PLAN
    F0_5=REQUIRED_SOURCE_ORDER_COVERAGE_PHASE
    JC245_ADMISSION=BLOCKED_ON_SHARED_FOUNDATION_AND_F0_5_ORDER_COVERAGE
    JC246_ADMISSION=BLOCKED_ON_SHARED_FOUNDATION_AND_F0_5_ORDER_COVERAGE
    JC300=SEPARATE_LATER_GATE
    IMPLEMENTATION_AUTHORIZED=NO
    NEXT_ACTION=STOP_FOR_EXACT_BYTE_REVIEW
