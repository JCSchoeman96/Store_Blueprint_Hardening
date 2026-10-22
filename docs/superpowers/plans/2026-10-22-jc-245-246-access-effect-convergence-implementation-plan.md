# JC-245/246 AccessEffect convergence implementation plan

> Review draft only. This plan does not authorize implementation.

**Goal:** Add one shared exact-source Entitlements convergence boundary, then implement separate EFFECTIVE and NON_EFFECTIVE AccessEffect executors and a later source-writer cutover.

**Architecture:** Subscription locks the exact source and candidate effect, validates the latest immutable target, and owns the APPLIED transition. Entitlements converges only that Subscription's complete zero-or-one grant set inside the caller's PostgreSQL transaction. Cachex invalidation and PubSub run after commit and remain repairable projections.

**Tech stack:** Elixir, Phoenix, Ash 3.x, AshPostgres, Ecto, PostgreSQL, Oban, ExUnit.

---

Status: A1 design pass. This is a high-level phased plan, not the detailed F0 execution plan. After review and acceptance of the authority documents, prepare and review a dedicated F0 implementation plan before starting F0. JC-245 and JC-246 remain blocked on F0. JC-300 is a separate later gate. No implementation is authorized by this draft.

- Reviewed base: 43d5487927af68b33df754c0ca0695b09fabacca
- Reviewed tree: 754f03502c9a4b8e6f049d6e6724340d6f31f5a8
- Review-start repository state: `main` at the reviewed base; these two drafts were the only untracked paths; one worktree.

## Scope and PR boundaries

Use the sequential Linear workflow from the repository instructions when a human admits each issue. Every implementation PR targets main, records its exact origin/main base SHA, and receives a human merge. Keep F0, F1, F2, and F3 in separate PRs. Do not change issue state, create branches, or run implementation work under this review draft.

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
8. Add one shared Subscription-side fence used later by both executors. Lock the Subscription and candidate AccessEffect. Require `source_version <= aggregate_version`, with no equality requirement. Recompute v2 from persisted fields first. Only after v2 mismatches, allow the exact v1 compatibility calculation when persisted `valid_from_at` is nil. Never rewrite fingerprints or reconstruct starts. Fail closed on any fingerprint mismatch. Validate target executability before stale handling: an EFFECTIVE pair with nil start is execution-incomplete even when v1 integrity passes, so do not call Entitlements, mark APPLIED, or mark it stale/superseded. EFFECTIVE nil/nil and the current NON_EFFECTIVE nil-start empty target remain legitimate. Then require latest effect ID equality for convergence and an executable status. Build the typed input from persisted effect evidence; do not load Plan policy or start a transaction. Verify every effect-producing source transaction locks the same Subscription row before it inserts an effect; otherwise stop. Both JC-245 and JC-246 must keep this lock while invoking convergence and through commit, so a newer effect cannot become current before APPLIED.
9. Freeze the fingerprint byte contract in the shared fence: the current ordered v2 descriptor, deterministic Erlang term encoding, SHA-256, lowercase Base16, and the exact v1 descriptor that omits valid_from_at. Test v2-first validation, nil-start-only v1 fallback, and fail-closed behavior when a non-nil start has a v2 mismatch.
10. Add the bounded effective recovery selector with disposition effective, status required/pending/failed_retryable, updated_at/id keyset order, and limit 1..500. Add only its matching partial index `(updated_at, id) WHERE disposition = 'effective' AND status IN ('required', 'pending', 'failed_retryable')` and generated AccessEffect snapshot. Keep the existing non-effective and projection recovery indexes unchanged.

**F0 gate:** Focused tests prove outside-transaction failure, outer rollback, exact-source isolation, pair and empty-target convergence, exact start/end plus active and cleared revocation state, local transaction replay, rollback on mutation error, empty-source serialization by the Subscription lock, effect-writer serialization, v2-first fingerprint validation, nil-start-only v1 fallback, and the bounded effective selector. A matching v1 fingerprint on an EFFECTIVE pair with nil start must fail as execution-incomplete before convergence or APPLIED and must not become stale/superseded. The generic `:issue` action and start default remain unchanged. The effective index migration must match only the selector. Capture query or SQL telemetry proving database round trips do not grow with grant-row count, with at most two set-oriented grant DML statements for a pair target and one for an empty target. Record `LOCAL_TRANSACTION_IDEMPOTENCE=YES` and `GLOBAL_SOURCE_CONVERGENCE_IDEMPOTENCE=NOT_YET_PROVEN`. Run the required repository and issue checks. Include Performance & Scaling Review and Runtime Resource Safety Review. Do not claim measured capacity.

**F0 result:** One independently reviewable foundation PR. F1 and F2 remain blocked until it is accepted on main and the exact typed input, transaction guard, mutation bound, and shared fence exist there.

## F1: JC-245 EFFECTIVE executor

**Purpose:** Execute current EFFECTIVE AccessEffects using F0. Keep the executor separate from JC-246.

**Expected future files:**

- Modify lib/store/subscriptions/access_effect.ex.
- Modify lib/store/subscriptions/facade.ex.
- Extend the existing bounded recovery worker and cursor args in lib/store/workers/run_subscription_access_effect_recovery_worker.ex.
- Add focused effective executor and recovery tests.

**Work:**

1. Consume the F0 effective recovery selector and extend recovery orchestration with an independent effective cursor. Do not replace the non-effective stream or merge its executor logic into JC-245.
2. Implement execute_effective_access_effect_for_system as a separate function. It must hold the exact Subscription `FOR UPDATE` source lock while it invokes the F0 current-effect fence and Entitlements convergence, keep the lock through the APPLIED write and commit, then project after commit. The candidate AccessEffect row lock protects that exact obligation; it does not replace the Subscription mutex.
3. For an effective pair, pass exact persisted valid_from_at and valid_until_at. For effective nil/nil, converge to an empty source set without making the Subscription commercially ineffective.
4. Thread the AccessEffect ID out of suspended charged-renewal recovery. In that branch, call the JC-245 executor and skip the old strict issue call. Keep the ordinary charged-renewal writer classified for JC-300.
5. Preserve replay behavior, retryable failure recording after rollback, and the applied-effect projection repair path.

**F1 gate:** Tests prove current effect execution, stale ID rejection, `source_version <= aggregate_version`, v2-first fingerprint validation, v1 fallback only for nil persisted starts, and exact fingerprint mismatch rejection. Test the historical EFFECTIVE pair whose nil-start v1 fingerprint passes integrity but whose execution fails closed before grant convergence, APPLIED, or stale/superseded classification. Also prove EFFECTIVE nil/nil and current NON_EFFECTIVE nil-start empty targets execute. Verify the exact full grant state, local replay, rollback, the held Subscription lock at the shared convergence call, and independent recovery cursors. Verify the effective query uses the F0 partial index and that the old non-effective selector still uses its own index. Review Oban uniqueness and retry behavior. Include Performance & Scaling Review and Runtime Resource Safety Review. Global source convergence idempotence remains unproven until JC-300.

**F1 result:** One JC-245 PR. No JC-246 executor changes and no JC-300 writer cutover in this PR.

## F2: JC-246 NON_EFFECTIVE executor reconciliation

**Purpose:** Replace the current partial row-by-row suspension revocation with the F0 exact-source convergence authority. Keep JC-246 separate from JC-245.

**Expected future files:**

- Modify lib/store/subscriptions/facade.ex.
- Keep lib/store/subscriptions/access_effect.ex recovery selector/index unchanged.
- Add focused non-effective executor, transaction, replay, and projection-repair tests.

**Work:**

1. Route the existing suspension and scheduled-cancellation AccessEffect execution paths through the F0 current-effect fence and typed convergence input. Hold the exact Subscription `FOR UPDATE` lock when invoking convergence and through commit.
2. Remove the aggregate_version equality rule. Require candidate ID to equal the latest effect ID and candidate.source_version <= locked aggregate_version. Validate fingerprint integrity v2-first; try v1 only after a mismatch and only when persisted `valid_from_at` is nil. Do not rewrite stored evidence or reconstruct historical starts. Check executability separately. Fail an EFFECTIVE pair with nil start as execution-incomplete before Entitlements or APPLIED, and do not classify it stale/superseded. Keep EFFECTIVE nil/nil and the current NON_EFFECTIVE nil-start empty target valid.
3. Converge NON_EFFECTIVE to an empty exact-source active set. Preserve the reason as caller-supplied metadata; do not make Entitlements load Subscription or Plan state.
4. Mark that effect APPLIED in the same outer transaction only after all source rows converge. Any error rolls back both grant changes and the effect transition.
5. Keep post-commit cache invalidation then PubSub. A projection failure leaves delivery evidence pending for repair and never reverses committed grants.
6. Keep the current non-effective recovery selector and partial index. Keep the effective selector and index introduced in F0 unchanged. Keep the current executor status semantics, with required, pending, and failed_retryable executable, applied and superseded non-executable.

**F2 gate:** Tests prove all active source rows are revoked, including future-start and expired rows; no other source changes; the Subscription lock is held when shared convergence runs; one mutation failure rolls back all work; local transaction replay is idempotent; projection failure is repairable; and the existing selector remains index-backed. Retain `NON_EFFECTIVE_REPLAY_IDEMPOTENT=LOCALLY_YES_GLOBALLY_NOT_PROVEN` and `GLOBAL_SOURCE_CONVERGENCE_IDEMPOTENCE=NOT_YET_PROVEN`. Include Performance & Scaling Review and Runtime Resource Safety Review.

**F2 result:** One JC-246 PR. Do not add the effective selector/index or rewrite the shared foundation here.

## F3: JC-300 source-writer cutover

**Purpose:** Remove the remaining direct Subscription-source grant writers and prove complete source coverage. This phase remains separate from both executor PRs.

**Current lanes assigned to F3:**

- Initial paid-order subscription issue. Today errors are counted as skipped and this path has no AccessEffect.
- Ordinary charged-renewal issue. Today it writes through the strict single-grant helper and has no AccessEffect.
- Immediate cancellation revoke. Today it uses the legacy post-commit revoker and discards its result.

The suspended recovery lane moves to JC-245. The effect-driven non-effective lane moves to JC-246. Re-audit every direct Ash and Repo mutation, facade export, admin/system caller, worker, and transition at the F3 base. If a new or unclassified source writer appears, stop and record it before cutover.

**F3 gate:** Show that each source-changing operation establishes the right immutable AccessEffect in its authoritative transaction, that every production grant write passes through the shared source fence, that retained legacy helpers cannot be called after activation, and that effect retries cannot be overwritten by a bypass writer. Include concurrency, replay, rollback, migration, performance, and runtime-resource evidence required by the current issue. Only after this gate may the team claim global exact-source convergence.

## Cross-phase acceptance rules

- Subscription and AccessEffect remain currentness and target authorities. Entitlements owns only the actual exact-source grant set and its post-commit projection helper.
- The lock order is Subscription, candidate AccessEffect, then exact-source grants ordered by native UUID id. Never sort lock keys as UUID strings.
- The Subscription `FOR UPDATE` row is the source-level mutex. Candidate AccessEffect lock protects the obligation; grant-row locks protect only rows that exist. `GRANT_ROW_LOCKS_ALONE_ARE_INSUFFICIENT=YES` and `SUBSCRIPTION_SOURCE_LOCK_REQUIRED=YES`. JC-245 and JC-246 both hold the Subscription lock while invoking shared convergence and through commit.
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
    GRANT_ROW_LOCKS_ALONE_ARE_INSUFFICIENT=YES
    SUBSCRIPTION_SOURCE_LOCK_REQUIRED=YES
    JC245_AND_JC246_HOLD_SOURCE_LOCK_AT_CONVERGENCE=YES
    LOCAL_TRANSACTION_IDEMPOTENCE=YES
    GLOBAL_SOURCE_CONVERGENCE_IDEMPOTENCE=NOT_YET_PROVEN
    AFTER_AUTHORITY_ACCEPTANCE=CREATE_DETAILED_F0_IMPLEMENTATION_PLAN
    SHARED_FOUNDATION_ADMISSION=READY_FOR_PLAN
    JC245_ADMISSION=BLOCKED_ON_SHARED_FOUNDATION
    JC246_ADMISSION=BLOCKED_ON_SHARED_FOUNDATION
    JC300=SEPARATE_LATER_GATE
    IMPLEMENTATION_AUTHORIZED=NO
    NEXT_ACTION=STOP_FOR_REVIEW
