# JC247-A past-due keep-during-grace implementation plan

**Goal:** Derive and persist the purchased `keep_during_grace` target when an exact bound renewal first transitions a Subscription from `active` to `past_due`.

**Authority:** The accepted JC-247 policy authority is `docs/superpowers/specs/2026-10-26-jc-247-purchased-access-policy-authority-correction.md`; P0 is accepted at commit `c298832b073203c0bb668c6e8738dd335295fb46`, tree `ef138732bdb21e8110d292eef693c756eecf18a2`. Upon human approval and merge of this plan, its JC247-A-specific `past_due` nil-pointer and `past_due` `remove_immediately` deferred reconciliation outcomes supersede the older page-halting behavior for those two cases only. All other accepted JC247 authority remains unchanged. Do not edit the historical authority document to imply it previously contained this decision.

**Architecture:** Subscription owns the policy decision, locked source transition, target evidence, and AccessEffect establishment. The exact dunning RenewalAttempt supplies frozen policy; the Subscription's current funded PlanRevision supplies composition. The source transaction returns the exact new effect ID; F1 executes it after commit. Target-order reconciliation uses the same target rules and current locked Subscription provenance.

**Stack:** Elixir, Phoenix, Ash 3, PostgreSQL, Oban, ExUnit, DevCore.

**Authorization:** This document is for review only. Implementation requires separate explicit authorization. Before implementation, confirm accepted prerequisites, current `origin/main`, a clean normal worktree, and the exact branch base under the repository's sequential workflow. Do not create another worktree without human authorization. If the base has moved, re-evaluate this plan against current main before coding.

## Scope and file map

Production changes are limited to:

- `lib/store/subscriptions/access_effect_target_order.ex`: shared policy-aware keep-grace target derivation and target comparison.
- `lib/store/subscriptions/facade.ex`: exact evidence acquisition, source transaction establishment and ID handoff, postcommit F1 call, and F0.5 classifications.

Use existing tests in `test/store/subscriptions/access_effect_target_order_test.exs`, `access_effect_target_order_reconciliation_test.exs`, `access_effect_target_order_contention_test.exs`, `sbh_20_05_success_vs_late_failure_dunning_test.exs`, `sbh_10_05_charged_contract_reconciliation_test.exs`, `access_effect_effective_execution_test.exs`, and `access_effect_currentness_fence_test.exs`. Create `test/store/subscriptions/jc247_a_keep_during_grace_test.exs` for focused producer and integration behavior. Reuse existing real-connection fixtures and barriers for race tests.

Stop with `STOP=UNEXPECTED_SCOPE_EXPANSION` if implementation needs changes to RenewalAttempt, Subscription or AccessEffect resource definitions, Entitlements, migrations, F1 semantics, or F2 admission. Do not implement `remove_immediately`, cancellation policy, term-end behavior, legacy repair, or other JC300 writer cutover. PostgreSQL remains the correctness authority; no cache, polling, broad scans, or speculative indexes are introduced.

For failure-injection tests, reuse an existing test mechanism or a real validation or database failure boundary. Do not add a production test hook solely for a test. If one would otherwise be necessary, stop with `STOP=NEW_PRODUCTION_TEST_SEAM_REQUIRED`.

## Postcommit result contract

The commercial source transaction commits first. Preserve the existing notification and telemetry ordering, then invoke F1 with the exact effect ID after commit. The outcomes `:applied`, `:applied_projection_pending`, `:superseded`, and `:noop`, as well as `{:error, reason}`, must not roll back or otherwise alter committed commercial truth. Payment-failure callers retain their exact pre-JC247 outer payment-failure result, and authentication-required callers retain their exact pre-JC247 outer result. Do not replace either source-domain result with an F1 error. The existing AccessEffect execution failure and recovery mechanism owns recovery of failed effect execution. Explicitly test this contract for both producers and each outcome.

## Task 1: Characterize shared target derivation

**Files:** `test/store/subscriptions/access_effect_target_order_test.exs`; `lib/store/subscriptions/access_effect_target_order.ex`.

- [ ] Add focused failing tests for a bound pointer-bearing past-due episode. Assert the policy comes from the exact attempt snapshot and the pair comes from the funded revision. Use Revision B for the attempt policy and Revision A for the funded target; assert effect provenance identifies A, and its `contract_change_id` is the locked Subscription's current value, not the attempt's value.
- [ ] Assert pair targets are EFFECTIVE with the funded period start and failed-payment boundary. Assert nil/nil targets remain EFFECTIVE, with nil start and the same failed-payment boundary. Reject half-pairs, missing boundary, mismatched attempt owner, mismatched attempt period, and incomplete frozen evidence.
- [ ] Run `devcore-project run test -- mix test test/store/subscriptions/access_effect_target_order_test.exs`. Record the intended failures before changing production code. Characterize any unrelated failure before rerunning.
- [ ] Implement the smallest shared target-building rules in `access_effect_target_order.ex`. Validate the pointer, owner, occurrence and complete snapshot using the existing domain evidence; never derive the policy from a mutable Plan or infer it from status. Preserve active, suspended and canceled rules outside the affected past-due behavior.
- [ ] Re-run the focused test and confirm it passes. The producer and F0.5 must both use these same rules, not duplicate policy parsing.

## Task 2: First payment failure producer

**Files:** `lib/store/subscriptions/facade.ex`; `test/store/subscriptions/jc247_a_keep_during_grace_test.exs`; `test/store/subscriptions/sbh_20_05_success_vs_late_failure_dunning_test.exs`.

- [ ] Add failing tests for first bound failure from `active`, asserting the exact EFFECTIVE pair target, boundary, provenance, and one durable effect. Observe the source transaction before postcommit execution and prove derivation alone writes no Entitlements grants. Inject effect-establishment failure and assert the commercial update and attempt update roll back together.
- [ ] Add a test that captures the exact created effect ID at the postcommit F1 boundary. Prove F1 is not called inside the source transaction and the caller does not query the latest effect after commit. Test `:applied`, `:applied_projection_pending`, `:superseded`, `:noop`, and `{:error, reason}` against the frozen postcommit result contract: commercial truth remains committed, the exact pre-JC247 outer payment-failure result is preserved, and execution failures remain available to the accepted effect recovery mechanism.
- [ ] Run `devcore-project run test -- mix test test/store/subscriptions/jc247_a_keep_during_grace_test.exs test/store/subscriptions/sbh_20_05_success_vs_late_failure_dunning_test.exs`. Confirm the new assertions fail for the intended missing behavior.
- [ ] In the existing failure source transaction, retain lock order: Subscription `FOR UPDATE`, exact RenewalAttempt `FOR UPDATE`, existing owner/period/snapshot proof, attempt failure update, then `active -> past_due`. With the **post-update** Subscription and already-bound attempt, derive and establish the keep-grace effect at the updated aggregate version. Return its exact ID in the transaction result. Do not re-fetch the in-scope attempt.
- [ ] After commit and notifications, call `execute_effective_access_effect_for_system/1` with the returned ID. Use the existing effective recovery and projection semantics. For a snapshot of `remove_immediately`, do not establish a policy effect or call F2; leave that policy to JC247-B.
- [ ] Re-run the focused tests and confirm they pass. Confirm a replay or genuine retry that enters with `past_due` does not establish another JC247-A policy effect and does not require returning its original ID.

## Task 3: Authentication-required producer

**Files:** `lib/store/subscriptions/facade.ex`; `test/store/subscriptions/jc247_a_keep_during_grace_test.exs`; `test/store/subscriptions/sbh_20_05_success_vs_late_failure_dunning_test.exs`.

- [ ] Add failing tests for first bound `requires_action` from `active`, including the exact postcommit effect ID and the same shared target as payment failure. Test nil/nil composition as EFFECTIVE. Verify rollback when establishing the effect fails. Test `:applied`, `:applied_projection_pending`, `:superseded`, `:noop`, and `{:error, reason}` against the frozen postcommit result contract: commercial truth remains committed, the exact pre-JC247 auth-required outer result is preserved, and effect execution failures remain recoverable.
- [ ] Add replay coverage for an already-settled authentication-required episode: no new effect, no ID handoff requirement, and no second policy interpretation. Retain the existing paid-success, canceled, and suspended precedence behavior.
- [ ] Run the two focused test files and confirm the new first-transition assertions fail for the intended reason.
- [ ] Wire the same target derivation and effect establishment into the locked auth-required transition using the updated Subscription. Return the exact ID through its transaction result and call F1 only after commit. Keep an already-settled replay as a noop and preserve existing notification, telemetry and outer caller behavior.
- [ ] Re-run the focused tests and confirm they pass.

## Task 4: Policy-aware F0.5 reconciliation

**Files:** `lib/store/subscriptions/facade.ex`; `lib/store/subscriptions/access_effect_target_order.ex`; `test/store/subscriptions/access_effect_target_order_reconciliation_test.exs`; `test/store/subscriptions/access_effect_target_order_contention_test.exs`.

- [ ] Add failing tests that a current keep-grace effect is `already_covered` when only dunning bookkeeping advanced the aggregate version. Check that `covered?/2` compares all target evidence but not source version. Assert reconciliation and the source producer derive identical complete evidence and never restore the old period-end target.
- [ ] Add pointer-owner and occurrence-period mismatch tests that fail closed without an effect write. Add nil-pointer and `remove_immediately` candidates followed by an eligible candidate in the same bounded page. Assert explicit `:legacy_policy_unprovable` and `:jc247_b_policy_deferred` outcomes, no attempt heuristic or mutable-policy lookup, no effect mutation, and continued page processing. Check cursor advancement and re-selection in a fresh sweep; confirm independent F1 recovery still accepts a persisted legacy effect.
- [ ] Run `devcore-project run test -- mix test test/store/subscriptions/access_effect_target_order_reconciliation_test.exs test/store/subscriptions/access_effect_target_order_test.exs`. Record the intended failures.
- [ ] Under the locked Subscription, use an exact pointer PK read for a pointer-bearing past-due candidate. Prove attempt owner, period, and frozen snapshot completeness, then load the exact funded revision and call the shared target builder. Never call the existing nil-pointer period-search fallback for this policy path. Return the internal non-mutating classifications `:legacy_policy_unprovable` and `:jc247_b_policy_deferred`; both increment the existing `noop_count`, so the page continues and the selected-page cursor advances. Preserve the public reconciliation result-map shape; do not introduce `skipped_count` or any other public field. Add assertions for these counts and the unchanged result shape.
- [ ] Preserve the existing source-version and fingerprint uniqueness, candidate/current effect locks, currentness fencing, and target-order repair semantics. Reject malformed nonnil evidence rather than guessing. Do not add F1, F2, Entitlements, or schema changes.
- [ ] Re-run the two test files and confirm they pass. Run the existing target-order contention file under the required real-connection gate in Task 7.

## Task 5: Episode replay and contract-change provenance

**Files:** `test/store/subscriptions/jc247_a_keep_during_grace_test.exs`; `test/store/subscriptions/sbh_10_05_charged_contract_reconciliation_test.exs`; `test/store/subscriptions/access_effect_target_order_reconciliation_test.exs`.

- [ ] Add a failing exact-failure replay and a separate genuine retry failure test. In each, assert the same dunning pointer, anchor, failed-payment boundary, funded revision and frozen policy remain, while authorized bookkeeping and aggregate version may advance. Assert neither path establishes a second JC247-A producer effect or requires the first effect ID. Verify a still-latest unresolved first effect remains recoverable after bookkeeping advances.
- [ ] Add the contract-change regression: bind attempt X while consuming its queued change, fail X and create keep-grace effect E1, then queue separate change Y during the same dunning episode. Assert X remains the policy source, the funded pair and boundary stay fixed, and the Subscription's current `contract_change_id` becomes Y. When E1 remains unresolved and latest under the locks, and the derived evidence differs only in Y provenance, F0.5 MUST invoke its existing repair semantics, establish the newer complete effect at the current source version, and supersede unresolved E1. It must not read policy or composition from Y. If E1 is terminal or a newer effect exists by lock time, preserve the existing terminal or currentness noop. Never replace Subscription provenance with `X.contract_change_id`.
- [ ] Run the affected focused files. Record whether the regression cases already pass because of Tasks 1-4; if they fail, characterize the failure and make only the narrow changes needed to satisfy them. A changed target caused solely by a separate commercial provenance transition is distinct from replay.

## Task 6: Currentness, source isolation, and deterministic races

**Files:** `test/store/subscriptions/access_effect_effective_execution_test.exs`; `test/store/subscriptions/access_effect_currentness_fence_test.exs`; `test/store/subscriptions/access_effect_target_order_contention_test.exs`; `test/store/subscriptions/jc247_a_keep_during_grace_test.exs`.

- [ ] Add or extend tests for a still-latest effect at version V1 executing after bookkeeping advances the Subscription to V2. Assert V1 is accepted when V1 <= V2, its fingerprint is valid, and no newer effect exists. No F1 equality-to-aggregate rule may be introduced.
- [ ] Use deterministic barriers and independent PostgreSQL connections where concurrency proof is needed. Cover the first-transition F1 call paused against newer cancellation, paid recovery, and suspension effects. Test both meaningful lock arrival orders and assert stale exact-ID execution cannot overwrite newer truth. Do not add sleeps.
- [ ] Assert F1 convergence leaves unrelated EntitlementGrant sources intact. Assert target derivation and source effect establishment make no direct Entitlements write. Verify replay, auth replay, rollback, stale execution, and later target reconciliation do not add a direct Entitlements writer.
- [ ] Run the focused executor, fence and integration tests. Run real-connection contention proof twice as specified in Task 7. Characterize any failure before rerun.

## Task 7: Verification and review evidence

- [ ] Read `.devcore/project.conf` and `.devcore/render-map.tsv`; run `devcore-project doctor`. If local state is missing or stale, run `devcore-project plan` and `devcore-project activate`. Diagnose any bootstrap failure without requesting or printing secrets. Run database-dependent commands through DevCore.
- [ ] Run the focused JC247-A, target-order, dunning, charged-contract reconciliation, EFFECTIVE execution and currentness tests named above. Include broader `test/store/subscriptions` coverage.
- [ ] Run `devcore-project run test -- mix format --check-formatted`, `devcore-project run test -- mix compile --warnings-as-errors`, `devcore-project run test -- mix check.static`, `devcore-project run test -- mix dialyzer`, and `devcore-project run test -- mix ash_postgres.generate_migrations --check`. Check generated migration and resource-snapshot paths for unexpected drift; do not generate or retain a migration for this slice. Run `git diff --check`.
- [ ] Run the full test suite with a unique disposable `STORE_TEST_DB_SUFFIX` through `devcore-project run test -- mix test --max-failures 1`; ensure the suffix is actually present in the DevCore child environment and identify the resulting disposable database before execution. Do not drop or overwrite an existing database.
- [ ] Run the required real-connection tests in two separate processes with a unique disposable suffix and sufficient pools: `STORE_BENCH_POOL_SIZE=4 STORE_BENCH_WRITER_POOL_SIZE=4 devcore-project run test -- mix test --only real_connections test/store/subscriptions/source_fence_contention_test.exs test/store/subscriptions/access_effect_target_order_contention_test.exs`. Include any new real-connection test file in both repetitions. Verify that the DevCore child sees the suffix and pool settings. Record both results and any blocking evidence.
- [ ] Review the exact base, head, changed files, this plan's acceptance criteria, locks, effect fingerprints, recovery, failure/paid/cancel/suspension and queued-contract races. Require CI and review evidence for the exact head, including the repository's required static, strict, Dialyzer, real-connections and performance jobs. Human merge is required.
- [ ] Include a Performance & Scaling Review in the eventual PR: classify dunning pointer, frozen snapshot and AccessEffect as cold durable PostgreSQL correctness state; report exact lookup/query counts, N+1 and index evidence, no cache authority or new polling, Oban uniqueness/idempotency, and telemetry. Include a Runtime Resource Safety Review with measured or explicitly `UNMEASURED` dimensions; do not claim convergence or capacity without adequate bounded repetitions.
- [ ] Characterize any failed check before rerunning. Stop on changed authority, unprovable snapshot or funded revision, ambiguous boundary, lock-order inversion, unexpected scope expansion, F1/F2/Entitlements/schema change, or uncharacterized test failure. Do not weaken checks.

## Final scope gates

```text
F1_CHANGE_REQUIRED=NO
F2_CHANGE_REQUIRED=NO
ENTITLEMENTS_CHANGE_REQUIRED=NO
ACCESS_EFFECT_SCHEMA_CHANGE_REQUIRED=NO
MIGRATION_REQUIRED=NO

IMPLEMENTATION_AUTHORIZED=NO
```
