# JC-246 / F2 NON_EFFECTIVE AccessEffect executor implementation plan

> Review plan only. Implementation is not authorized by this document.

**Goal:** Replace the partial NON_EFFECTIVE suspension executor with the accepted F0 exact-source convergence and currentness fence. Return a durable success result when only post-commit projection delivery remains pending.

**Architecture:** Store.Subscriptions.Facade owns the public transaction, AccessEffect lifecycle, F0 proof call, and APPLIED transition. It calls the unchanged Store.Entitlements exact-source convergence helper inside one PostgreSQL transaction. Cache invalidation and PubSub run after commit and remain repairable.

**Tech Stack:** Elixir, Phoenix, Ash 3.x, AshPostgres, Ecto, PostgreSQL, Oban, ExUnit.

- **Base:** c025ea1d50161a89927f5ca2785a2882b89cff7d
- **Tree:** 32e01ffca5362589c2cabc0eee32740e25df7d86
**Post-merge CI:** Run 40093194974 completed SUCCESS before this plan branch was created.

---

## Spec

F2 executes current NON_EFFECTIVE AccessEffects for the exact Subscription source. The accepted AccessEffectCurrentnessFence.prove/1 remains the sole CURRENT/STALE authority and must remain unchanged.

Preserve the F0 proof order:

1. Read the candidate ID only to obtain its Subscription ID.
2. Lock that Subscription row with PostgreSQL FOR UPDATE.
3. Lock the candidate AccessEffect row.
4. Require candidate.source_version <= subscription.aggregate_version. Equality is not required.
5. Validate persisted fingerprint integrity. Recompute v2 first. Only after a v2 mismatch, permit the exact v1 compatibility check when persisted valid_from_at is nil. Never rewrite fingerprint evidence.
6. Validate target executability separately from fingerprint integrity. An incomplete EFFECTIVE pair with nil start fails before latest/stale classification.
7. Read the latest AccessEffect and classify the candidate ID as current or stale.
8. Only after shared proof, admit NON_EFFECTIVE. Reject EFFECTIVE complete-pair and EFFECTIVE nil/nil candidates before lifecycle mutation, stale supersession, or grant mutation.
9. For an admitted stale candidate, use the legal PENDING path to SUPERSEDED. For an admitted current candidate, execute only REQUIRED, PENDING, or FAILED_RETRYABLE.
10. Build the existing typed convergence input from the locked source identity and persisted effect evidence. Do not read Plan state or infer the target from the current Plan.

For a current NON_EFFECTIVE effect, converge the complete exact-source grant set to zero active rows. Select revocation work by persisted status :active, not by ENT-T1 temporal classification at any as_of time. Keep persisted :revoked and :expired rows. Do not touch another Subscription or another source kind.

Successful correctness transaction transitions:

- REQUIRED -> PENDING -> APPLIED
- FAILED_RETRYABLE -> PENDING -> APPLIED
- PENDING -> APPLIED

Stale transitions:

- REQUIRED -> PENDING -> SUPERSEDED
- FAILED_RETRYABLE -> PENDING -> SUPERSEDED
- PENDING -> SUPERSEDED

APPLIED and SUPERSEDED are terminal and replay as no-op. Any exact-source convergence or APPLIED transition failure rolls back all grant and AccessEffect writes. After rollback, the separate failure-recording transaction repeats the frozen F0 proof and NON_EFFECTIVE admission before recording:

- REQUIRED -> PENDING -> FAILED_RETRYABLE
- PENDING -> FAILED_RETRYABLE
- FAILED_RETRYABLE remains unchanged.

If the effect became stale before failure recording, follow the legal supersession path. Wrong disposition, malformed proof, fingerprint mismatch, execution-incomplete target, source-version failure, or any other proof/admission failure must not create FAILED_RETRYABLE.

The public return contract is:

- {:ok, :applied}
- {:ok, :applied_projection_pending}
- {:ok, :superseded}
- {:ok, :noop}
- {:error, reason}

applied_projection_pending means grant truth and APPLIED committed, but post-commit projection delivery failed. It is a successful correctness outcome. Never run the failure recorder after commit.

## Architecture and compatibility

Keep execute_suspension_access_effect_for_system/1 as the public compatibility entrypoint. The caller audit found uses in recovery dispatch, focused subscription tests, and the governance surface registry. Do not add a second public executor for naming consistency. New internal names and tests should describe NON_EFFECTIVE execution because the effect can represent suspension, immediate cancellation, scheduled cancellation, or late paid cancellation.

Use the locked Subscription only for grant revocation reason metadata:

- A suspended Subscription uses grace_expired.
- A canceled Subscription with canceled_reason canceled_period_end uses canceled_period_end.
- Immediate cancellation uses the persisted immediate cancellation reason and maps to canceled_now.

Resolve this metadata only during locked correctness execution. If the persisted status/reason cannot identify one of these cases, stop rather than inventing policy. Projection invalidation uses a separate stable reason derived from persisted NON_EFFECTIVE disposition/evidence. Projection repair must not load Subscription or Plan state.

Keep the existing recovery API and selector frozen:

- Options: execution_after_updated_at, execution_after_id, skip_execution.
- Results: execution_count, execution_cursor.
- Keep the NON_EFFECTIVE selector and access_effects_non_effective_recovery_index unchanged and index-backed.
- Keep JC-245's independent EFFECTIVE cursor, options, results, selector, and worker JSON unchanged.

F2 executes NON_EFFECTIVE effects from failed-payment suspension, F0.5 immediate cancellation, scheduled boundary cancellation, and late paid cancellation terminalization. Do not remove the immediate-cancellation legacy revoke writer; that cutover belongs to JC-300. Do not change ordinary renewal's legacy issue behavior.

After approval, implement F2 in one focused PR targeting main. Human merge is required. This plan does not authorize implementation.

## Global constraints

- F0 is the only CURRENT/STALE authority. Preserve its proof order.
- Keep source_version <= aggregate_version. Equality is not required.
- Fingerprint validation precedes stale/latest classification.
- Target executability remains separate from fingerprint integrity.
- Disposition admission follows shared target validation and precedes lifecycle mutation or stale supersession.
- F2 admits NON_EFFECTIVE only.
- Keep EFFECTIVE pair and nil/nil rejection mutation-free.
- Do not change production code in lib/store/entitlements.
- Do not change AccessEffect selectors, indexes, snapshots, or migrations.
- Do not add a migration or lifecycle state.
- Do not enter JC-247 policy work or JC-300 writer cutover.
- Redis, Cachex, PubSub, Oban, and process memory remain outside correctness authority. PostgreSQL Subscription FOR UPDATE is the source mutex.
- Preserve NON_EFFECTIVE_REPLAY_IDEMPOTENT=LOCALLY_YES_GLOBALLY_NOT_PROVEN and GLOBAL_SOURCE_CONVERGENCE_IDEMPOTENCE=NOT_YET_PROVEN.

## Review focus

Review the transaction owner and rollback boundary. The public executor must fail closed before writes whenever Repo.in_transaction?() is already true. Exact-source convergence and APPLIED share that outer transaction. The Subscription lock stays held through commit.

Confirm every persisted active row is revoked, including rows classified FUTURE or ENDED by ENT-T1 at the selected test time. Historical revoked/expired rows and every unrelated source remain unchanged.

Confirm projection failure cannot change APPLIED or grant truth, cannot enter the failure recorder, leaves projection_delivered_at nil, and remains independently repairable. Cache invalidation precedes PubSub.

Confirm the existing NON_EFFECTIVE selector and partial index are unchanged and index-backed. Confirm the F1 recovery cursor/API and both immediate-cancellation and ordinary-renewal legacy writer boundaries remain unchanged.

## Exact files

Production:

- Modify lib/store/subscriptions/facade.ex only.

Focused tests:

- Create test/store/subscriptions/access_effect_non_effective_execution_test.exs for lifecycle, disposition, currentness, convergence, rollback, idempotence, and projection repair.
- Modify test/store/subscriptions/suspension_access_convergence_test.exs to update existing suspension-path assertions for the durable result contract and post-commit repair.
- Modify test/store/subscriptions/access_effect_execution_test.exs for public transaction ownership and unchanged NON_EFFECTIVE recovery cursor semantics where those cases fit existing fixtures.
- Modify test/store/subscriptions/access_effect_test.exs only to prove the existing NON_EFFECTIVE recovery index remains usable by its selector.
- Modify test/store/subscriptions/source_fence_contention_test.exs with the real PostgreSQL proof that the executor holds the Subscription mutex through convergence and APPLIED commit. This file already runs in the required real-connection CI job.
- Review without changing unless a direct regression requires it: test/store/subscriptions/access_effect_effective_execution_test.exs, test/store/subscriptions/access_effect_effective_recovery_test.exs, and test/store/workers/run_subscription_access_effect_recovery_worker_test.exs.

Do not modify Entitlements production modules, AccessEffect resource/index definitions, migrations, snapshots, recovery worker interfaces, or CI workflow files.

## Task-sized TDD steps

### Task 0: Implementation preflight after plan review

**Files:** None.

- [ ] After this plan is reviewed and JC-246 is explicitly admitted for implementation, fetch origin/main and record the exact implementation base SHA.
- [ ] Verify F0, F0.5, and F1 are accepted on that base and the F0 fence and typed convergence helper match the authority documents.
- [ ] Read .devcore/project.conf and .devcore/render-map.tsv. Run devcore-project doctor before database-dependent checks. Do not request or print DevCore-managed credentials.
- [ ] Stop before code if any frozen stop condition applies.

### Task 1: Make the public executor own its transaction

**Files:** lib/store/subscriptions/facade.ex; test/store/subscriptions/access_effect_non_effective_execution_test.exs.

- [ ] Write a failing test that calls the public executor inside an already-open Repo transaction. Assert a validation error and no lifecycle, source grant, projection evidence, or PubSub changes.
- [ ] Run the focused test and confirm current behavior fails the assertion.
- [ ] Add the Repo.in_transaction?() guard before opening the correctness transaction. The public executor must not join a caller transaction.
- [ ] Prove the normal call owns and commits the outer transaction. Read effect and grant state after the call from a separate transaction/connection.
- [ ] Inject a convergence failure during correctness execution. Prove grant changes and APPLIED roll back before a separate failure-recording transaction runs.
- [ ] Re-run the focused tests. Expected: nested execution writes nothing; owned success commits grant truth and APPLIED; owned failure commits neither.

### Task 2: Use the F0 proof and enforce disposition/lifecycle order

**Files:** lib/store/subscriptions/facade.ex; test/store/subscriptions/access_effect_non_effective_execution_test.exs.

- [ ] Add failing tests for REQUIRED success, PENDING success, FAILED_RETRYABLE retry success, and stale supersession from each executable status.
- [ ] Add terminal replay tests. APPLIED and SUPERSEDED NON_EFFECTIVE candidates return {:ok, :noop} without writes.
- [ ] Add EFFECTIVE complete-pair and EFFECTIVE nil/nil tests. Both return an error with unchanged lifecycle, grants, and projection state.
- [ ] Add proof-failure tests for fingerprint mismatch, malformed target, execution-incomplete EFFECTIVE pair, and candidate source version greater than aggregate version. Each fails before lifecycle mutation or failure recording.
- [ ] Add a test where source_version is less than aggregate_version while the candidate remains latest. It must still execute.
- [ ] Run the focused tests and confirm the old bespoke executor fails the new assertions.
- [ ] Replace bespoke NON_EFFECTIVE currentness/equality reads with AccessEffectCurrentnessFence.prove/1. Do not alter or reproduce the fence.
- [ ] After shared proof, reject wrong disposition before stale lifecycle transitions. For admitted stale candidates, use the existing legal PENDING-to-SUPERSEDED path.
- [ ] Re-run the tests. Expected: F0 proof order is unchanged; no equality requirement exists; proof/disposition failures write nothing.

### Task 3: Converge the exact NON_EFFECTIVE source

**Files:** lib/store/subscriptions/facade.ex; test/store/subscriptions/access_effect_non_effective_execution_test.exs.

- [ ] Add failing tests with several persisted active rows for one Subscription. Include an active EFFECTIVE-at-as_of row, a FUTURE row whose valid_from_at is after test as_of, and an ENDED row whose valid_until_at is at or before test as_of.
- [ ] Add persisted revoked and expired rows with existing revocation metadata. Assert they remain unchanged.
- [ ] Add another Subscription source for the same user and a non-subscription source. Assert both remain unchanged.
- [ ] Assert every active source row becomes revoked even when ENT-T1 classifies it FUTURE or ENDED. Do not filter mutation by current effectiveness or as_of.
- [ ] Assert locked execution records grace_expired for suspension, canceled_period_end for scheduled/late-paid cancellation, and canceled_now for immediate cancellation. If persisted cancellation evidence does not select one of these cases, stop.
- [ ] Build the existing SubscriptionSourceConvergenceInput from locked Subscription identity plus persisted AccessEffect target/version/fingerprint evidence. Use NON_EFFECTIVE with the required empty target and locked revocation metadata.
- [ ] Call the unchanged converge_subscription_source_grants_for_system/1 inside the correctness transaction. Require its complete success result before setting APPLIED.
- [ ] Re-run tests. Expected: the exact source has zero active grants; historical rows and every other source stay unchanged.

### Task 4: Prove failure recording and local replay

**Files:** lib/store/subscriptions/facade.ex; test/store/subscriptions/access_effect_non_effective_execution_test.exs; test/store/subscriptions/suspension_access_convergence_test.exs.

- [ ] Use the existing database-trigger failure pattern in the suspension convergence tests to reject a selected grant update after multiple source rows are locked.
- [ ] Assert all source rows remain unchanged and the rolled-back correctness attempt does not persist PENDING or APPLIED.
- [ ] In a separate transaction, repeat F0 proof and NON_EFFECTIVE admission before recording REQUIRED -> PENDING -> FAILED_RETRYABLE or PENDING -> FAILED_RETRYABLE. FAILED_RETRYABLE remains a no-op.
- [ ] Add a case where the candidate becomes stale before failure recording. Assert legal SUPERSEDED handling, not FAILED_RETRYABLE.
- [ ] Assert fingerprint, version, target, and disposition proof failures never reach the failure recorder.
- [ ] Replay an identical current effect after successful application. Assert no additional grant changes and terminal replay returns no-op. Keep NON_EFFECTIVE_REPLAY_IDEMPOTENT=LOCALLY_YES_GLOBALLY_NOT_PROVEN.
- [ ] Re-run focused tests. Expected: mutation failure cannot commit partial grants or APPLIED; only a still-current, admitted effect can become FAILED_RETRYABLE.

### Task 5: Separate committed correctness from projection delivery

**Files:** lib/store/subscriptions/facade.ex; test/store/subscriptions/access_effect_non_effective_execution_test.exs; test/store/subscriptions/suspension_access_convergence_test.exs.

- [ ] Add a failing test that forces post-commit Cachex invalidation or PubSub delivery to fail after convergence and APPLIED commit.
- [ ] Assert the public executor returns {:ok, :applied_projection_pending}, APPLIED and revoked grants remain committed, projection_delivered_at remains nil, and the failure recorder is not called.
- [ ] Use a stable NON_EFFECTIVE projection reason derived from persisted AccessEffect disposition/evidence. Keep grant revoked_reason metadata separate and determine it only during locked correctness execution.
- [ ] Change projection repair to require an APPLIED NON_EFFECTIVE effect with persisted projection user IDs. Do not load Subscription or Plan state to decide repair or projection reason.
- [ ] After APPLIED, change current Subscription status/reason to a different valid value and prove repair still succeeds from effect evidence alone.
- [ ] Assert the Entitlements projection helper invalidates Cachex before PubSub and records delivery only after both succeed.
- [ ] Re-run focused tests. Expected: projection failure is a successful committed execution and repair does not repeat grant convergence.

### Task 6: Preserve recovery interfaces and prove the NON_EFFECTIVE index

**Files:** lib/store/subscriptions/facade.ex; test/store/subscriptions/access_effect_execution_test.exs; test/store/subscriptions/access_effect_test.exs.

- [ ] Add regression coverage for NON_EFFECTIVE options execution_after_updated_at, execution_after_id, and skip_execution, plus execution_count and execution_cursor.
- [ ] Verify cursor keyset ordering and skip behavior remain unchanged.
- [ ] Add a PostgreSQL EXPLAIN assertion for the current selector predicate, ordered by updated_at/id and bounded by the existing limit. Assert use of access_effects_non_effective_recovery_index. Disable sequential scans locally in the test only if planner cost on the small fixture otherwise chooses a sequential scan.
- [ ] Run existing EFFECTIVE recovery and recovery-worker tests unchanged. Assert JC-245 option names, cursor fields, JSON keys, and stream progress remain unchanged.
- [ ] Make no changes to lib/store/subscriptions/access_effect.ex, the recovery worker, selectors/indexes, or migrations.
- [ ] Re-run recovery tests. Expected: NON_EFFECTIVE and EFFECTIVE cursors retain separate semantics.

### Task 7: Prove the source mutex with real PostgreSQL connections

**Files:** test/store/subscriptions/source_fence_contention_test.exs.

- [ ] Add a :real_connections test using two independent PostgreSQL connections, existing barriers, and pg_blocking_pids evidence.
- [ ] Hold the executor inside exact-source convergence with a test-only PostgreSQL barrier after it has acquired the Subscription row lock.
- [ ] Start a second task that attempts a target-changing operation for that Subscription. Assert PostgreSQL reports the executor as blocker while convergence and APPLIED are still uncommitted.
- [ ] Release the barrier, await executor commit, then assert the producer proceeds and the committed latest target is correct.
- [ ] Prove ordering with barriers and PostgreSQL blocker evidence, not sleeps. Bounded polling may observe a blocker but does not decide the winner.
- [ ] Run the real-connection file twice. Expected: the Subscription row lock serializes the producer through convergence and APPLIED commit.

### Task 8: Record bounded resource evidence and run full validation

**Files:** lib/store/subscriptions/facade.ex; focused test files listed above.

- [ ] Measure a bounded exact-source fixture larger than the existing small test sets. Record exact row count, SQL/query count, convergence duration, and lock/blocker evidence when exercised.
- [ ] Record memory and GC measurements where practical. Mark any unavailable dimension UNMEASURED.
- [ ] Use at least two equivalent bounded repetitions for any convergence/no-accumulation claim. Do not claim 100k-user capacity.
- [ ] Confirm hot/warm/cold work, exact-source index use, no N+1 grant mutation, no new cache layer, and unchanged Oban uniqueness/idempotency.
- [ ] Complete the Runtime Resource Safety Review with memory, GC, mailbox, cleanup, and post-load convergence evidence. Mark unsupported dimensions UNMEASURED.
- [ ] Run the verification commands below. Fix failures without weakening required checks.
- [ ] Review the final diff against the authority design. Confirm production scope is lib/store/subscriptions/facade.ex only and no migration, selector/index edit, F0 fence edit, Entitlements implementation edit, or JC-300 writer cutover entered scope.

## Verification commands

Before local database-dependent commands, read .devcore/project.conf and .devcore/render-map.tsv, then run devcore-project doctor. Use DevCore's TEST environment for all local tests.

- Focused executor, suspension integration, recovery, selector, projection, F1 regression, and worker tests:
  - `devcore-project run test -- mix test test/store/subscriptions/access_effect_non_effective_execution_test.exs test/store/subscriptions/suspension_access_convergence_test.exs test/store/subscriptions/access_effect_execution_test.exs test/store/subscriptions/access_effect_test.exs test/store/subscriptions/access_effect_effective_execution_test.exs test/store/subscriptions/access_effect_effective_recovery_test.exs test/store/workers/run_subscription_access_effect_recovery_worker_test.exs`
- Real PostgreSQL source-lock proof, run twice:
  - `devcore-project run test -- mix test --only real_connections test/store/subscriptions/source_fence_contention_test.exs test/store/subscriptions/access_effect_target_order_contention_test.exs`
- Full repository check including tests:
  - `devcore-project run test -- mix check`
- CI strict test command:
  - `devcore-project run test -- mix test --max-failures 1`
- Verify generated resource snapshots and migrations have no drift:
  - `devcore-project run test -- mix ash_postgres.generate_migrations --check`
- Verify whitespace and inspect scope:
  - `git diff --check`
  - `git status --short`
  - `git diff --stat`

## Performance & Scaling Review

- Hot path: one NON_EFFECTIVE effect locks one Subscription, one candidate effect, and the exact source grant set. PostgreSQL is the only correctness mutex.
- Warm writes: the accepted F0 helper locks exact-source grant rows and uses its existing set-oriented convergence operations. It revokes every persisted active row and verifies the final active set. No per-grant application loop or broad user-wide revoke is allowed.
- Cold recovery: keep the bounded NON_EFFECTIVE selector, cursor, and partial index unchanged. Prove the selector remains index-backed.
- Query count and N+1: measure SQL/query count and source row count. Do not assume query count from the helper name. Any per-row mutation or full-table scan is a stop.
- Indexes: no index, selector, snapshot, or migration changes are authorized.
- Cache: Cachex remains a projection with its existing TTL. Invalidate it after commit, then publish PubSub. Do not introduce Redis/ETS correctness state or stampede logic.
- Oban: retain current recovery jobs, uniqueness, bounded pagination, and retry behavior. Oban only schedules work.
- Telemetry: report convergence duration, exact source row count, SQL/query count, lock/blocker evidence, projection failures, cursor progress, and observed memory/GC behavior. Do not log user data.
- Capacity: source cardinality and capacity remain UNMEASURED. A bounded fixture does not establish 100k-user capacity or global source convergence.

## Runtime Resource Safety Review

The implementation PR must report candidate page bound, exact source rows materialized, SQL/query count, convergence duration, lock wait, process mailbox, cleanup, and memory/GC dimensions where measurable. Mark unsupported dimensions UNMEASURED. Do not claim runtime safety, convergence, or capacity for an unmeasured dimension. This documentation-only plan has no runtime resource claim.

## Success conditions

- Required lifecycle, proof-order, source-convergence, rollback, replay, projection, recovery, and real PostgreSQL contention tests pass.
- Public nested transaction calls fail closed before writes.
- F0 remains the sole currentness authority and source_version may be less than aggregate_version.
- Only current NON_EFFECTIVE effects mutate exact-source grants. Every persisted active row is revoked; revoked/expired history and other sources remain untouched.
- Grant truth and APPLIED commit together. Projection failures return {:ok, :applied_projection_pending} and never create FAILED_RETRYABLE.
- Projection repair uses persisted effect evidence without mutable Subscription or Plan inference.
- NON_EFFECTIVE selector/index/API and independent F1 cursor/API remain unchanged.
- JC-300 cutover remains excluded and both frozen report flags remain unchanged.
- Implementation remains unauthorized until human review of this plan and implementation PR.

## Stop conditions

Stop before implementation or stop the affected portion if:

- Post-merge CI run 40093194974 is not SUCCESS, or the planning base differs from c025ea1d50161a89927f5ca2785a2882b89cff7d.
- F0 currentness fence, proof order, or typed convergence contract must change.
- Any Entitlements production change is required.
- The AccessEffect selector/index must change or a migration is required.
- A new lifecycle state or JC-247 policy decision is required.
- JC-300 cutover enters scope, including removal of the immediate-cancellation legacy revoke writer or change to ordinary renewal issue behavior.
- Immediate cancellation's persisted Subscription reason cannot be mapped deterministically during locked execution.
- NON_EFFECTIVE projection invalidation cannot use stable persisted effect disposition/evidence without new durable fields.
- Exact rollback-safe convergence cannot use the accepted F0 boundary.
- Source-lock contention or bounded resource evidence shows the accepted F0 design is insufficient.
- Any test requires sleeps as the race correctness proof.

## Plan state

- `ACCESS_TARGET_ORDER_COVERAGE=COMPLETE`
- `F0_CURRENTNESS_SOLE_AUTHORITY=YES`
- `F1_EFFECTIVE_EXECUTOR=ACCEPTED`
- `F2_DISPOSITION=NON_EFFECTIVE_ONLY`
- `NON_EFFECTIVE_REPLAY_IDEMPOTENT=LOCALLY_YES_GLOBALLY_NOT_PROVEN`
- `GLOBAL_SOURCE_CONVERGENCE_IDEMPOTENCE=NOT_YET_PROVEN`
- `JC300_CUTOVER_INCLUDED=NO`
- `IMPLEMENTATION_AUTHORIZED=NO`
