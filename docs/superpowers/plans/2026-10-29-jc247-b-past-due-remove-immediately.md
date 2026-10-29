# JC247-B Past-Due Remove-Immediately Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Establish and execute the purchased remove-immediately target at the first bound dunning transition and independently reconcile it from durable evidence.

**Architecture:** Subscription owns policy selection, the locked commercial transaction, and exact AccessEffect establishment. The exact bound RenewalAttempt supplies frozen policy; the post-update locked Subscription supplies provenance. The transaction returns the exact effect ID and disposition for postcommit F1 or F2 dispatch. F0.5 independently derives the same target; F2 admits a proven current NON_EFFECTIVE target without interpreting policy.

**Tech Stack:** Elixir, Phoenix, Ash 3, AshPostgres, Ecto, PostgreSQL, Oban, ExUnit, DevCore.

**Spec:** `docs/superpowers/specs/2026-10-29-jc247-b-past-due-remove-immediately-authority.md`

## Global Constraints

`IMPLEMENTATION_AUTHORIZED=NO`. This plan requires separate implementation authorization after review and merge. The accepted broader authority is `docs/superpowers/specs/2026-10-26-jc-247-purchased-access-policy-authority-correction.md`; supporting plans are `docs/superpowers/plans/2026-10-27-jc247-a-past-due-keep-during-grace.md` and `docs/superpowers/plans/2026-10-24-jc-246-non-effective-access-effect-executor.md`.

Production edits are limited to `lib/store/subscriptions/access_effect_target_order.ex` and `lib/store/subscriptions/facade.ex`. If any Entitlements file, Subscription, RenewalAttempt or AccessEffect resource, migration, Ash snapshot, CI workflow, worker API, or governance surface registry needs a change, stop with `STOP=UNEXPECTED_SCOPE_EXPANSION` and report why. Also stop for `STOP=F1_CORE_CHANGE_REQUIRED`, `STOP=F2_CORE_CHANGE_REQUIRED`, `STOP=ENTITLEMENTS_CHANGE_REQUIRED`, `STOP=ACCESS_EFFECT_SCHEMA_CHANGE_REQUIRED`, `STOP=SUBSCRIPTION_SCHEMA_CHANGE_REQUIRED`, `STOP=RENEWAL_ATTEMPT_SCHEMA_CHANGE_REQUIRED`, `STOP=MIGRATION_REQUIRED`, `STOP=NEW_PUBLIC_EXECUTOR_REQUIRED`, or `STOP=NEW_PRODUCTION_TEST_SEAM_REQUIRED` when applicable. Do not add compatibility wrappers without an actual caller. Do not modify JC247-A tests unless proven obsolete under accepted B authority.

```text
JC247_C_INCLUDED=NO
JC300_FINAL_CUTOVER_INCLUDED=NO
CANCELLATION_POLICY_INCLUDED=NO
TERM_END_INCLUDED=NO
LEGACY_DUNNING_POINTER_REPAIR_INCLUDED=NO
PRE_BINDING_FALLBACK_REPAIR_INCLUDED=NO
F1_CORE_CHANGE_REQUIRED=NO
F2_CORE_CHANGE_REQUIRED=NO
ENTITLEMENTS_CHANGE_REQUIRED=NO
ACCESS_EFFECT_SCHEMA_CHANGE_REQUIRED=NO
SUBSCRIPTION_SCHEMA_CHANGE_REQUIRED=NO
RENEWAL_ATTEMPT_SCHEMA_CHANGE_REQUIRED=NO
MIGRATION_REQUIRED=NO
```

## Review Focus

Review exact source locks, episode evidence, source transaction rollback, postcommit exact-ID dispatch and unchanged caller results, currentness and replay, F0.5 provenance repair, historical grant reasons, and both PostgreSQL lock arrival orders. F2 must never decide policy. No direct Entitlements producer write is allowed. No new public executor is allowed.

---

## File map and frozen contracts

Create `test/store/subscriptions/jc247_b_remove_immediately_test.exs` and `test/store/subscriptions/jc247_b_acceptance_matrix_test.exs`; start the matrix with the first behavioral RED tests, not after implementation. Modify `test/store/subscriptions/access_effect_target_order_test.exs`, `test/store/subscriptions/access_effect_target_order_reconciliation_test.exs`, and `test/store/subscriptions/access_effect_non_effective_execution_test.exs`. Use `test/store/subscriptions/source_fence_contention_test.exs` and `test/store/subscriptions/access_effect_target_order_contention_test.exs` only where the race belongs. Use `test/store/subscriptions/sbh_20_05_success_vs_late_failure_dunning_test.exs` and `test/store/subscriptions/sbh_10_05_charged_contract_reconciliation_test.exs` for focused regression coverage as needed. Both `test/store/subscriptions/jc247_a_keep_during_grace_test.exs` and `test/store/subscriptions/jc247_a_acceptance_matrix_test.exs` must remain green.

The first authoritative verified bound payment failure or authentication-required bound dunning transition moves `active` to `past_due`. The exact `RenewalAttempt.charged_contract_snapshot.access_on_past_due` chooses policy. For `:remove_immediately`, the target is `disposition: :non_effective`, with nil `entitlement_kind`, `entitlement_scope_key`, `valid_from_at`, and `valid_until_at`. Preserve `source_order_line_item_id`, `current_contract_change_id` as `contract_change_id`, `current_plan_revision_id` as `plan_revision_id`, and `aggregate_version` as source version from the locked post-update Subscription. Prove the durable IDs are valid. Do not load mutable Plan or fetch a funded PlanRevision solely to derive empty composition.

The commercial transaction locks Subscription `FOR UPDATE`, then the exact bound RenewalAttempt `FOR UPDATE`; proves owner, episode and complete snapshot; updates the attempt; updates Subscription `active -> past_due`; derives from the post-update locked Subscription; establishes or reuses the exact AccessEffect; returns its exact ID and disposition; then commits. Establishment failure rolls back the Subscription transition and attempt mutation and leaves no effect. The producer does not write Entitlements.

Generalize the existing `keep_during_grace_establish_attrs/2`, `maybe_establish_first_transition_keep_grace_effect/3`, `keep_grace_access_effect_id`, and `sync_keep_grace_access_after_commit/1` shared path to `past_due_policy_establish_attrs/2`, `maybe_establish_first_transition_past_due_policy_effect/3`, `past_due_access_effect`, and `sync_past_due_access_after_commit/1` respectively, unless an actual caller makes a rename risky. Inspect all callers first; do not duplicate A and B pipelines. The handoff is nil or `%{id: exact_access_effect_id, disposition: :effective | :non_effective}`. After commit dispatch effective to `execute_effective_access_effect_for_system/1` and non-effective to the existing public `execute_suspension_access_effect_for_system/1`. Never add `execute_non_effective_access_effect_for_system/1` or query latest/current/effect by Subscription to choose the postcommit executor.

For each producer, `{:ok, :applied}`, `{:ok, :applied_projection_pending}`, `{:ok, :superseded}`, `{:ok, :noop}`, and `{:error, reason}` occur after commit and cannot replace the existing commercial result or roll it back. Payment failure retains `PAYMENT_FAILED`; authentication-required retains its existing result. Existing effect recovery handles execution failure. Preserve external `TARGET_ORDER_BLOCKED` and commercial diagnostics if internal establishment-error names change.

Replay state machine: first bound failure or authentication-required moves ACTIVE to PAST_DUE and creates one NON_EFFECTIVE policy effect. Same-episode retry/replay remains PAST_DUE, retains the exact dunning pointer, failed-payment boundary and frozen snapshot, and creates no second producer policy effect even if bookkeeping advances aggregate version. Exact paid recovery moves PAST_DUE to ACTIVE and establishes a newer EFFECTIVE target. The grace boundary moves PAST_DUE to SUSPENDED and establishes newer/current NON_EFFECTIVE suspension truth as applicable.

## Task 0: Implementation preflight

- [ ] Only after this plan PR is accepted and merged and implementation is separately authorized, confirm the Linear issue, acceptance criteria, and current authority. Fetch `origin`; record exact `origin/main` SHA and tree, verify the accepted plan and prerequisites on that SHA, and start the issue branch from it in the normal clean worktree. If the expected implementation base moved or authority changed, stop and re-evaluate before writing code.
- [ ] Read `.devcore/project.conf` and `.devcore/render-map.tsv`; run `devcore-project doctor`. If state is missing or stale, run `devcore-project plan` and `devcore-project activate`. Diagnose failures without exposing or requesting secrets. Use `devcore-project run test --` for database-dependent commands. Inspect the named current helper callers and existing telemetry/message barriers before changing them.

## Task 1: Shared remove-immediate target derivation

**Files:** `lib/store/subscriptions/access_effect_target_order.ex`; `test/store/subscriptions/access_effect_target_order_test.exs`; create the acceptance matrix file above.

- [ ] RED: Add `derive_remove_immediately_target/2` tests using Subscription and exact bound RenewalAttempt. Assert empty target, exact Subscription provenance, valid source IDs, and nil/nil composition without invented pair. Reject non-past-due status, pointer mismatch, owner mismatch, period-start versus current-period-end mismatch, missing `past_due_since_at`, missing `failed_payment_boundary_at`, invalid source order line item or current revision ID. Exercise complete snapshot proof at the facade boundary and reject incomplete snapshots there. Assert no mutable Plan or funded revision fetch is needed for the empty target. Add these cases to the matrix.
- [ ] Run `devcore-project run test -- mix test test/store/subscriptions/access_effect_target_order_test.exs test/store/subscriptions/jc247_b_acceptance_matrix_test.exs`; record intended missing-behavior failures.
- [ ] GREEN: Add `derive_remove_immediately_target/2`, returning `{:ok, target_evidence} | {:error, Error.t()}`. Factor only the common Subscription/RenewalAttempt episode guards: past-due state, exact pointer, owner, occurrence/period, `past_due_since_at`, `failed_payment_boundary_at`, and required Subscription provenance IDs. Keep funded PlanRevision identity and entitlement-composition proof only on `keep_during_grace`. `remove_immediately` validates that `current_plan_revision_id` is present and valid and persists it as Subscription provenance, but does not fetch or require the funded PlanRevision to derive the empty NON_EFFECTIVE target. Snapshot completeness is already proved by the facade using the existing charged-contract parser; do not add a second parser or interpret policy in this module. Generalize establishment attributes without altering target equality or source-version rules.
- [ ] Rerun the focused command and both JC247-A test files through DevCore; require PASS.

## Task 2: Narrow F2 past_due admission and revocation metadata

**Files:** `lib/store/subscriptions/facade.ex`; `test/store/subscriptions/access_effect_non_effective_execution_test.exs`; acceptance matrix.

- [ ] RED: For a proven current NON_EFFECTIVE effect and locked `past_due` Subscription, assert F2 revokes every ACTIVE exact Subscription-source grant with `revoked_reason="past_due_remove_immediately"`, leaves inactive and other-source grants unchanged, and retains projection reason `non_effective_access_effect_applied`. Malformed proof, fingerprint or version failure, wrong disposition, and unsupported source admission/evidence return an error without lifecycle or grant mutation. For a valid admitted NON_EFFECTIVE candidate classified STALE by `AccessEffectCurrentnessFence`, assert the existing lifecycle: REQUIRED -> PENDING -> SUPERSEDED, FAILED_RETRYABLE -> PENDING -> SUPERSEDED, or PENDING -> SUPERSEDED. Assert no grant convergence or mutation and return `{:ok, :superseded}`. Terminal APPLIED and SUPERSEDED replay retains existing noop behavior. Assert existing suspended `grace_expired`, canceled-period-end `canceled_period_end`, and canceled user-request `canceled_now` mappings remain unchanged.
- [ ] Run `devcore-project run test -- mix test test/store/subscriptions/access_effect_non_effective_execution_test.exs test/store/subscriptions/jc247_b_acceptance_matrix_test.exs`; record the intended failure.
- [ ] GREEN: Extend only locked-source admission/revocation metadata in `non_effective_access_effect_reason/1`. The immutable current effect is the access decision. Do not load RenewalAttempt, PlanRevision or Plan, inspect policy or `billing_status_reason`, decide disposition, or change F0 proof, fingerprints, `source_version <= aggregate_version`, current/latest classification, lifecycle, exact-source convergence, APPLIED/SUPERSEDED, recovery selector/index, or projection repair.
- [ ] Rerun the focused command; require PASS.

## Task 3: First payment-failure producer

**Files:** `lib/store/subscriptions/facade.ex`; `test/store/subscriptions/jc247_b_remove_immediately_test.exs`; `test/store/subscriptions/sbh_20_05_success_vs_late_failure_dunning_test.exs`; acceptance matrix.

- [ ] RED: Assert verified first bound failure creates exactly one NON_EFFECTIVE effect with complete target and post-update provenance. Capture the exact source-transaction effect ID/disposition at postcommit dispatch, prove no latest-effect selection and no producer Entitlements write. Force a real establishment failure using an existing test mechanism or validation/database boundary; assert attempt mutation, source transition, and effect all roll back. For each of the five postcommit outcomes in the frozen contract, assert committed source truth and unchanged `PAYMENT_FAILED` caller result. Preserve external `TARGET_ORDER_BLOCKED` behavior.
- [ ] Run `devcore-project run test -- mix test test/store/subscriptions/jc247_b_remove_immediately_test.exs test/store/subscriptions/sbh_20_05_success_vs_late_failure_dunning_test.exs test/store/subscriptions/jc247_b_acceptance_matrix_test.exs`; record intended failures.
- [ ] GREEN: Generalize the existing first-transition policy helper and settlement handoff once for both policies. After existing snapshot proof, select the shared derivation via `renewal_policy_from_attempt/1`; only keep-grace loads funded composition. Establish within the source transaction and pass exact ID/disposition through commit to the existing executor. Preserve existing notifications, telemetry, result and recovery semantics.
- [ ] Rerun the focused command and JC247-A tests; require PASS.

## Task 4: Authentication-required producer

**Files:** `lib/store/subscriptions/facade.ex`; `test/store/subscriptions/jc247_b_remove_immediately_test.exs`; `test/store/subscriptions/sbh_20_05_success_vs_late_failure_dunning_test.exs`; acceptance matrix.

- [ ] RED: Assert first bound authentication-required transition establishes the same empty target and exact-ID F2 handoff, with atomic rollback on establishment failure. Cover all five postcommit outcomes and assert the existing authentication-required outer result and committed truth. Replay the same episode and assert no second effect, retained pointer and boundary, and existing paid/canceled/suspended precedence.
- [ ] Run the Task 3 focused command; record intended failures.
- [ ] GREEN: Route this existing locked producer through the same generalized helper and handoff, preserving its source transaction, notification and telemetry ordering. Do not create a second establishment pipeline.
- [ ] Rerun the focused command and JC247-A tests; require PASS.

## Task 5: F0.5 policy-aware NON_EFFECTIVE reconciliation

**Files:** `lib/store/subscriptions/facade.ex`; `lib/store/subscriptions/access_effect_target_order.ex`; `test/store/subscriptions/access_effect_target_order_reconciliation_test.exs`; acceptance matrix.

- [ ] RED: Prove independently derived complete NON_EFFECTIVE evidence yields `already_covered` when equal. For the latest/current unresolved EFFECTIVE candidate whose target evidence no longer matches independently derived locked source evidence, prove the existing repair/supersession path creates a newer NON_EFFECTIVE target and dispatches it to F2. Reserve F0 STALE for currentness classification and its existing supersession semantics. Assert legacy nil pointer retains `:legacy_policy_unprovable` noop; owner, period, incomplete snapshot and missing episode evidence fail closed. Verify cursor/page continuation, bounded page behavior and unchanged public result shape and `noop_count`, `repaired_count`, `already_covered_count`; no `skipped_count`. Assert aggregate-version-only retry causes no target churn and a still-current older source version is valid under `source_version <= aggregate_version`.
- [ ] RED: For funded revision A and attempt X whose snapshot selects remove-immediately, create unresolved E1, then make separate ContractChange Y current during the same past-due episode. Assert policy remains X, target remains NON_EFFECTIVE, revision provenance remains funded A, and current locked Subscription contract-change provenance is Y. F0.5 repairs unresolved E1 with old provenance to newer complete Y evidence. Never derive policy from Y or overwrite Subscription provenance with `RenewalAttempt.contract_change_id`. Preserve existing terminal/newer-effect noops.
- [ ] Run `devcore-project run test -- mix test test/store/subscriptions/access_effect_target_order_reconciliation_test.exs test/store/subscriptions/access_effect_target_order_test.exs test/store/subscriptions/jc247_b_acceptance_matrix_test.exs`; record intended failures.
- [ ] GREEN: Remove `:jc247_b_policy_deferred` classification and its branches. Fetch the exact pointer attempt, prove complete snapshot with the existing parser, and choose shared remove derivation without fetching funded revision for empty composition. Keep the funded revision fetch in the keep-grace branch. Preserve `:legacy_policy_unprovable`, existing candidate locking, comparison, repair, supersession, dispatch, and result shape.
- [ ] Rerun the focused command and JC247-A tests; require PASS.

## Task 6: Lifecycle and historical grant invariants

**Files:** `test/store/subscriptions/jc247_b_acceptance_matrix_test.exs`; `test/store/subscriptions/access_effect_non_effective_execution_test.exs`; `test/store/subscriptions/sbh_10_05_charged_contract_reconciliation_test.exs` as needed.

- [ ] RED: Assert same-attempt retry retains pointer, boundary and purchased snapshot without another policy effect; funded nil/nil yields empty NON_EFFECTIVE target. Assert exact-source convergence leaves other sources and historical inactive grants intact and projection reason remains `non_effective_access_effect_applied`.
- [ ] RED: Apply B revocation, then suspend and assert the old inactive row keeps `past_due_remove_immediately`, not `grace_expired`. Separately recover through exact paid attempt, assert a new ACTIVE grant, then run a later dunning/suspension and assert that newer row may be revoked with `grace_expired`; each historical reason remains unchanged. Assert exact paid recovery supersedes old non-effective truth.
- [ ] Run `devcore-project run test -- mix test test/store/subscriptions/jc247_b_acceptance_matrix_test.exs test/store/subscriptions/access_effect_non_effective_execution_test.exs test/store/subscriptions/sbh_10_05_charged_contract_reconciliation_test.exs`. Record whether each assertion already passes; characterize failures before narrow fixes within the production boundary. Rerun to PASS.

## Task 7: Deterministic concurrency and final acceptance

**Files:** `test/store/subscriptions/source_fence_contention_test.exs`; `test/store/subscriptions/access_effect_target_order_contention_test.exs`; `test/store/subscriptions/jc247_b_acceptance_matrix_test.exs`. Modify only the files needed for these cases.

- [ ] RED: Use independent PostgreSQL connections and existing `[:store, :subscriptions, :dunning]` telemetry/message barriers and source-grant lock barriers, with blocker evidence where needed. No sleeps and no production test hook. Prove recovery wins: commit newer EFFECTIVE paid truth before releasing old exact-ID F2; old effect is stale/SUPERSEDED or noop and recovered access stays active. Prove F2 wins: hold its source lock until it revokes old access and marks APPLIED, then let recovery acquire the lock and establish newer EFFECTIVE truth; final access is active. Assert no stale resurrection or revocation of recovered access.
- [ ] Run the relevant real-connection files through DevCore; record intended failure, make only boundary-permitted fixes, then rerun to PASS. Complete the acceptance matrix below and record evidence for every item.
- [ ] Run `devcore-project run test -- mix test test/store/subscriptions`; require PASS. Run `devcore-project run test -- mix format --check-formatted`, `devcore-project run test -- mix compile --warnings-as-errors`, `devcore-project run test -- mix check.static`, `devcore-project run test -- mix dialyzer`, `devcore-project run test -- mix ash_postgres.generate_migrations --check`, and `git diff --check`. Inspect for schema or snapshot drift.
- [ ] Run the full suite with a unique disposable `STORE_TEST_DB_SUFFIX`: `devcore-project run test -- mix test --max-failures 1`. Verify the DevCore child receives the suffix and identify the resulting database before running; never overwrite or drop an existing database.
- [ ] Run two separate real-connection processes, each with a different fresh disposable suffix and `STORE_BENCH_POOL_SIZE=4 STORE_BENCH_WRITER_POOL_SIZE=4`: `devcore-project run test -- mix test --only real_connections test/store/subscriptions/source_fence_contention_test.exs test/store/subscriptions/access_effect_target_order_contention_test.exs`. Include every newly created real-connection B test in both runs. Verify the child receives suffix and pool settings; record both results and blocker evidence.
- [ ] Characterize every failure. The only accepted baseline exception is `test/store/support/http/req_client_test.exs` where the expected `Req.TransportError` with `reason=:timeout` succeeded and only the `elapsed < 2000ms` wall-clock assertion failed. Any other failure is `STOP=UNCHARACTERIZED_TEST_FAILURE`; never waive it blindly.
- [ ] Review exact base SHA, head SHA, diff, changed files, acceptance matrix, lifecycle, database invariants, concurrency, retry/replay, crash/recovery, security and performance. Require exact-head CI PASS for `check_static`, `real_connections_required`, `test_pr_strict`, `dialyzer_required`, `performance_smoke_required`, and `performance_smoke_chaos_required`. Human merge is required.

## Acceptance matrix

Record the test and result for each proof. Tasks 1-7 own these proofs respectively as indicated.

1. First payment failure creates exactly one NON_EFFECTIVE effect (3).
2. Authentication-required first transition creates exactly one NON_EFFECTIVE effect (4).
3. Exact effect ID reaches postcommit F2 without a latest-effect query (3, 4).
4. F2 revokes every ACTIVE exact Subscription-source grant with `past_due_remove_immediately` (2).
5. Historical inactive grants remain unchanged (2, 6).
6. Other-source grants remain unchanged (2, 6).
7. Nil/nil funded composition produces NON_EFFECTIVE without an invented pair (1, 6).
8. Same-attempt retry creates no second policy effect (4, 6).
9. F0.5 independently derives NON_EFFECTIVE (5).
10. F0.5 repairs a latest/current unresolved EFFECTIVE candidate whose target evidence differs from the independently derived locked source target to NON_EFFECTIVE (5).
11. Legacy nil pointer remains fail-closed/noop (5).
12. Pointer owner mismatch fails closed (1, 5).
13. Attempt period mismatch fails closed (1, 5).
14. Incomplete snapshot fails closed (1, 5).
15. Missing episode evidence fails closed (1, 5).
16. ContractChange Y changes effect provenance but not attempt-X policy authority (5).
17. `source_version <= aggregate_version` remains accepted without equality (5).
18. Exact paid recovery supersedes old NON_EFFECTIVE truth (6, 7).
19. Stale F2 cannot revoke recovered access (7).
20. Suspension after B revoke does not rewrite old grant reason (6).
21. A recovery-created newer grant may later be revoked `grace_expired` (6).
22. Projection reason stays `non_effective_access_effect_applied` (2, 6).
23. F2 rejects unsupported source states and evidence (2).
24. No direct Entitlements production writer is added (3, 7).
25. JC247-A keep-during-grace remains unchanged (1, 3-5).
26. Establishment failure atomically rolls back the first source transition (3, 4).
27. Postcommit F2 failure cannot rewrite commercial caller results (3, 4).
28. Both meaningful PostgreSQL lock arrival orders are deterministic (7).
29. No new public executor is added (3, 7).
30. No new migration, schema, or index is introduced without new evidence (0, 7).

## Performance & Scaling Review

```text
CORRECTNESS_AUTHORITY=PostgreSQL
REDIS_CORRECTNESS_ROLE=NONE
CACHE_CORRECTNESS_ROLE=NONE
HOT_WARM_CACHE=NONE_REQUIRED_FOR_JC247_B
REDIS_STRUCTURES=NONE_REQUIRED_FOR_JC247_B
TTL=NOT_APPLICABLE_TO_CORRECTNESS_STATE
INDEXES=NO_NEW_INDEX_EXPECTED
INVALIDATION_PUBSUB=UNCHANGED
```

Subscription dunning identity is cold durable correctness state; RenewalAttempt frozen snapshot is cold durable correctness evidence; AccessEffect is a cold durable correctness obligation; EntitlementGrant is durable projection state. The current attempt uses an exact primary-key lookup, current revision provenance uses existing FK/PK identity, AccessEffect selectors and indexes exist, and F2 exact-source convergence is existing bounded behavior. Existing F2 postcommit projection invalidation and PubSub remain the only cache/PubSub side effect. Add no Redis, ETS, Cachex or GenServer correctness state, polling, attempt scans, timestamp ordering, N+1 relationship loading, or speculative indexes. Query-ceiling changes require measured evidence. Report hot/warm/cold classification, DB query counts and N+1 risk, indexes, cache TTL/invalidation/stampede considerations, Oban uniqueness/idempotency, and telemetry/logging in the implementation PR.

## Runtime Resource Safety Review

For changed hot paths, the implementation PR must measure or explicitly mark `UNMEASURED`: new query count, removed query count, exact-PK lookup count, source grant cardinality used for bounded F2 proof, and memory, mailbox and GC impact where existing F2 resource tests measure it. Do not loosen an existing query ceiling speculatively. Do not claim capacity, runtime safety or convergence where a relevant dimension is unmeasured. Convergence or no-accumulation claims require at least two equivalent bounded repetitions; a single run is diagnostic.
