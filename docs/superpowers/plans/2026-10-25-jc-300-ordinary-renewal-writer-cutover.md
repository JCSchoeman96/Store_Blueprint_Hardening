# JC-300 Ordinary Charged-Renewal Writer Cutover Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> Review plan only. Implementation is not authorized by this document.

**Goal:** Route only ordinary charged-renewal grant synchronization through the accepted JC-245/F1 executor using the exact EFFECTIVE AccessEffect ID returned by the committed renewal transaction.

**Architecture:** Keep paid renewal reconciliation and EFFECTIVE target establishment in the existing locked Subscription transaction. After commit, dispatch both already-classified renewal lanes through the existing F1 executor with the exact effect ID; let F1 re-prove currentness and keep projection/retry behavior under its accepted contract. Do not change Entitlements, F0/F1/F2 architecture, or any other legacy writer.

**Tech Stack:** Elixir, Phoenix/Ash, Ecto/PostgreSQL, `Store.Subscriptions.Facade`, accepted AccessEffect F1 executor, ExUnit.

**Spec:** docs/superpowers/specs/2026-10-25-jc-300-ordinary-renewal-writer-cutover-design.md

---

## Global Constraints

- Change only the ordinary charged-renewal legacy issue dispatch. Keep the already-F1 `:suspended_recovery` lane behavior intact.
- Carry and execute the exact EFFECTIVE AccessEffect ID returned by the committed renewal transaction. The caller must not select a latest effect after commit.
- Invoke F1 only after the commercial transaction commits. Paid commercial truth remains independent of F1 or Entitlements availability.
- Do not modify `lib/store/entitlements/**`, F0 currentness/fingerprint rules, F1 executor semantics, or F2 executor semantics.
- Add no migration, index, AccessEffect lifecycle state, or generic access abstraction.
- Keep initial paid activation on its existing legacy issue path.
- Keep the immediate-cancellation compatibility revoke unchanged; do not remove, gate, or route it in this slice.
- Keep JC-247 and its purchased policy behavior out of scope.
- Keep JC-300 final source-coverage proof and final production cutover open.

## Review Focus

1. EFFECTIVE pair target reaches F1 with the exact charged entitlement pair and immutable charged period boundaries.
2. EFFECTIVE nil/nil target becomes APPLIED with zero active grants for the exact Subscription source, nil `valid_from_at`, and `valid_until_at == attempt.period_end_at`; replay remains idempotent.
3. Existing immediate cancellation mode `:now` creates newer NON_EFFECTIVE B before T1 executes exact renewal effect A; F1 marks A SUPERSEDED and makes no stale grant.
4. An F1 correctness failure after commercial commit leaves paid truth committed and the exact effect recoverable through accepted F1 recovery.
5. Initial paid activation remains on its existing issue path.

## Authority and implementation boundary

Planning base: `d90adf8a88d327b5aad68d4561ec5901de614145` (`9a221107f40fcd7154fdd1a703f5db2ecd9a6a73`). Reconfirm the implementation branch starts from the current accepted `main` when implementation is separately authorized.

The commercial source transaction already returns `renewal_access_effect_id` and predecessor-derived `grant_writer_lane`. Preserve that handoff on first reconciliation, exact replay, and retry. Post-commit must call `execute_effective_access_effect_for_system(exact_effect_id)`; it must not query the latest effect, run inside the commercial transaction, or fall back to direct issue.

Future production scope: `lib/store/subscriptions/facade.ex` only. Future focused tests: `test/store/subscriptions/sbh_10_05_charged_contract_reconciliation_test.exs`, `test/store/subscriptions/sbh_10_06_contract_change_test.exs`, and the new real-connection proof `test/store/subscriptions/charged_renewal_access_effect_race_test.exs`. Add no production or test file outside those paths without stopping for scope review. Do not change `lib/store/entitlements/**`, delete the legacy issue API, alter initial paid activation, change F0/F1/F2 behavior, add a migration/index/lifecycle state, or claim JC-300 final cutover.

## Task 1: Freeze ordinary renewal dispatch behavior with focused tests

**Files:**
- Test: `test/store/subscriptions/sbh_10_05_charged_contract_reconciliation_test.exs`

- [ ] Replace the existing `an ordinary charged renewal with an EFFECTIVE predecessor keeps the legacy writer lane` expectation with an ordinary charged-renewal regression using the existing bound-renewal fixture. Reconcile through `Facade.reconcile_paid_subscription_renewal_for_system/2`; locate the unique EFFECTIVE effect from the immutable attempt evidence; assert the facade converges the exact entitlement pair with `valid_from_at == attempt.period_start_at` and `valid_until_at == attempt.period_end_at`, and the effect status is APPLIED.
- [ ] Wrap the reconciliation call in a process-scoped Erlang call trace for `{Store.Entitlements.Facade, :issue_subscription_source_grant_strict_for_system, 2}`. Assert no trace event is emitted for the ordinary renewal call. In `after`, disable tracing for the process and restore the trace pattern so no test instrumentation leaks.
- [ ] Assert the public result remains `{:ok, :reconciled}` on first reconciliation and `{:ok, :noop}` on successful exact replay. Assert replay leaves the Subscription period, PlanRevision, RenewalAttempt identity, AccessEffect count, and grant validity boundaries unchanged.
- [ ] Extend the existing `a charged nil/nil target keeps valid_from_at nil in its AccessEffect` test in this file. After cutover, assert the exact renewal effect ID executes through F1 and becomes APPLIED; the exact Subscription source has zero active grants; `valid_from_at` remains nil; `valid_until_at` remains `attempt.period_end_at`; no worker-time start is introduced; and exact replay preserves the target and is idempotent.
- [ ] Run the focused test through DevCore: `devcore-project run test -- mix test test/store/subscriptions/sbh_10_05_charged_contract_reconciliation_test.exs`. First run the new tests against the current ordinary direct-writer path and confirm the no-legacy-call/APPLIED assertions fail for that reason.

## Task 2: Route the exact ordinary effect through F1

**Files:**
- Modify: `lib/store/subscriptions/facade.ex`
- Test: `test/store/subscriptions/sbh_10_05_charged_contract_reconciliation_test.exs`

**Interfaces:**
- Produces the post-commit F1 dispatch contract for both already-classified lanes: `:ordinary` and `:suspended_recovery` receive the exact `renewal_access_effect_id` returned by the source transaction.
- F1 success outcomes `:applied`, `:applied_projection_pending`, `:superseded`, and `:noop` map to `:ok` synchronization; correctness errors remain normalized errors. Preserve the existing public reconciliation result mapping.

- [ ] Change only `sync_charged_renewal_access/4` dispatch. Make the existing `:ordinary` and `:suspended_recovery` lanes share the existing F1 execution and outcome mapping, guarded by a binary exact effect ID. Keep the invalid/missing classification error. Do not pass a target selected after commit.

The resulting dispatch must have this shape, reusing the existing function and exact outcome set:

```elixir
defp sync_charged_renewal_access(lane, effect_id, _subscription, _target)
     when lane in [:ordinary, :suspended_recovery] and is_binary(effect_id) do
  case execute_effective_access_effect_for_system(effect_id) do
    {:ok, outcome}
    when outcome in [:applied, :applied_projection_pending, :superseded, :noop] ->
      :ok

    {:error, reason} ->
      {:error, Normalize.normalize(reason)}

    other ->
      {:error,
       Error.new(
         "INTERNAL_ERROR",
         "EFFECTIVE charged-renewal handoff returned an invalid outcome",
         %{outcome: inspect(other)}
       )}
  end
end
```

- [ ] Keep the accepted commercial transaction unchanged: it locks the Subscription, applies the paid period/revision and ContractChange, establishes the EFFECTIVE target, and returns the exact effect ID and lane. Preserve the historical-effect replay lookup and predecessor classification.
- [ ] Remove the now-unreferenced private direct-sync wrappers used only by the ordinary lane: `sync_charged_renewal_entitlement/2`, `sync_charged_renewal_entitlement_in_transaction/2`, `issue_charged_renewal_grant/2`, `current_subscription_for_entitlement_sync/1`, and `project_subscription_entitlement_sync/2`. Keep `issue_subscription_source_grant_strict_for_system/2` and initial paid activation's `maybe_issue_entitlement/2` path unchanged.
- [ ] Preserve post-commit order: notify source transaction notifications, emit the existing paid-renewal sync boundary, execute F1 with the exact ID, then mark the RenewalAttempt succeeded. Do not query “latest” between commit and F1.
- [ ] Re-run the focused test from Task 1. Confirm the exact effect is APPLIED, the strict direct-issue function trace remains absent, and exact replay is unchanged.
- [ ] Commit the production dispatch and focused regression together with message `fix(subscriptions): route ordinary renewal through F1`.

## Task 3: Preserve initial activation and charged contract selection

**Files:**
- Test: `test/store/subscriptions/sbh_10_05_charged_contract_reconciliation_test.exs`
- Test: `test/store/subscriptions/sbh_10_06_contract_change_test.exs`

- [ ] Add or extend the initial paid-order issuance regression in the existing subscription test context. Prove initial paid activation still uses its separate `issue_subscription_entitlement_for_system/2` path and creates its existing grant; do not create an AccessEffect or route this path through the renewal dispatcher.
- [ ] Extend the queued contract-change paid-renewal test to assert the exact EFFECTIVE effect and resulting F1 grant use the PlanRevision, entitlement pair, and original period boundaries bound to the charged RenewalAttempt. Do not read mutable public Plan state during F1 execution.
- [ ] Assert no worker/execution time becomes `valid_from_at` or `valid_until_at`; both remain the charged attempt's persisted boundaries.
- [ ] Run `devcore-project run test -- mix test test/store/subscriptions/sbh_10_05_charged_contract_reconciliation_test.exs test/store/subscriptions/sbh_10_06_contract_change_test.exs`.
- [ ] Commit these regression tests with message `test(subscriptions): preserve renewal source boundaries`.

## Task 4: Prove exact-effect supersession with PostgreSQL barriers

**Files:**
- Create: `test/store/subscriptions/charged_renewal_access_effect_race_test.exs`

**Interfaces:**
- Consume Task 2's exact `renewal_access_effect_id` handoff: T1 must call F1 with A.id after the commercial commit.
- Produce B through the current public API `Store.Subscriptions.Facade.cancel_subscription_for_user(fixture.customer, fixture.subscription.id, :now)`. Its current path is `run_cancel_with_authorized_retry/4` → `run_cancel_now_or_noop/2` → `run_cancel/3` → `cancel_subscription_in_transaction/4`, which calls `lock_subscription_aggregate_version/1` and `maybe_establish_immediate_cancellation_access_effect/2`; `AccessEffectTargetOrder.immediate_cancellation_establish_attrs/1` creates the NON_EFFECTIVE target in that transaction.
- Current-main evidence: `test/store/subscriptions/access_effect_target_order_contention_test.exs` asserts the latest target after this `:now` API is NON_EFFECTIVE, and `test/store/subscriptions/cancellation_renewal_authority_test.exs` covers this API during the paid-renewal access-sync pause.
- Leave `finalize_immediate_cancellation/2` and its compatibility revoke unchanged. Do not use scheduled cancellation or JC-247 policy behavior.
- If this API cannot create B in the planned race fixture without JC-247 behavior, stop; do not substitute another cancellation lane.

- [ ] Create a dedicated `ExUnit.Case` module tagged `@moduletag :real_connections`. Build and commit the exact paid RenewalAttempt/order/collection fixture using the existing subscription fixture and collection-handoff APIs; require at least three Repo connections as the accepted contention suite does.
- [ ] Add a real-connection test that runs paid renewal reconciliation in T1 and blocks its existing `[:store, :subscriptions, :paid_renewal_access_sync]` telemetry callback after the source transaction commits. The barrier handler must send an explicit ready message and wait for an explicit release message; do not sleep.
- [ ] While T1 is paused, call `Store.Subscriptions.Facade.cancel_subscription_for_user(fixture.customer, fixture.subscription.id, :now)` for T2 and commit the resulting newer NON_EFFECTIVE effect B. The existing immediate-cancellation compatibility revoke may run unchanged after that commit. Release T1. Assert it executes the exact old effect A through F1, A becomes SUPERSEDED, B remains latest, no grant is created from A, and the paid renewal period/charged revision remain committed.
- [ ] Add the inverse-order test on independent PostgreSQL connections. Pause F1 A at its exact-source convergence barrier while it holds the Subscription mutex, invoke the same `:now` cancellation API for T2, and prove T2 waits on T1. Release F1, assert A commits APPLIED before T2 commits B, and assert final grant state follows B with no deadlock.
- [ ] Assert both tests use distinct PostgreSQL backend PIDs, deterministic barrier messages/lock evidence, and the same exact paid source. Do not use `Process.sleep/1` as race evidence.
- [ ] Record `IMMEDIATE_CANCEL_COMPAT_REVOKE_CHANGED=NO`, `JC247_POLICY_PATH_USED=NO`, and `SCHEDULED_REMOVE_POLICY_ASSUMED=NO` in the race proof.
- [ ] Run ordinary tests with `devcore-project run test -- mix test test/store/subscriptions/sbh_10_05_charged_contract_reconciliation_test.exs`. Run the new `@moduletag :real_connections` file by itself in a separate process with `devcore-project run test -- mix test test/store/subscriptions/charged_renewal_access_effect_race_test.exs --include real_connections`. Keep default Sandbox configuration unchanged.
- [ ] Commit the deterministic contention proof with message `test(subscriptions): prove renewal effect supersession`.

## Task 5: Prove post-commit failure and recovery semantics

**Files:**
- Test: `test/store/subscriptions/sbh_10_05_charged_contract_reconciliation_test.exs`

**Interfaces:**
- Consume the accepted JC-245/F1 failure and recovery contract without changing executor semantics: qualifying correctness rollback remains recoverable through existing FAILED_RETRYABLE selection; projection failure remains APPLIED with projection pending and uses existing repair.

- [ ] Inject a correctness failure in F1 convergence using the existing database-failure test pattern: add a `NOT VALID` CHECK constraint on `entitlement_grants` that rejects `status = 'active'` for the fixture's exact `source_id`, run reconciliation, then drop the constraint. Assert the commercial renewal transaction already committed the paid period/revision, ContractChange, and exact EFFECTIVE effect; assert reconciliation returns the existing normalized error and does not compensate or duplicate commercial truth.
- [ ] Assert F1 records a qualifying rolled-back failure as FAILED_RETRYABLE. Remove the injected failure, set `cursor_start = DateTime.add(retryable_effect.updated_at, -1, :microsecond)` and `as_of = DateTime.add(retryable_effect.updated_at, 1, :microsecond)`, then call `Facade.run_subscription_access_effect_recovery_for_system/1` with `limit: 100`, `as_of: as_of`, `effective_execution_after_updated_at: cursor_start`, and `effective_execution_after_id: "00000000-0000-0000-0000-000000000000"`. Assert the same effect applies. Retry reconciliation and assert it finds the same historical effect, does not extend the period/create another effect, marks the attempt succeeded, and returns the existing successful result.
- [ ] Inject a post-commit projection delivery failure separately with a `NOT VALID` CHECK constraint on `access_effects` that rejects a non-nil `projection_delivered_at`. Assert F1 returns `:applied_projection_pending`, facade reconciliation returns `{:ok, :reconciled}`, commercial and grant truth stay committed, and `Facade.repair_suspension_access_effect_projection_for_system(effect.id)` clears the pending evidence after dropping the constraint without changing the grant rows.
- [ ] Assert no F1 correctness error is swallowed, no compensation is added, and no failure recorder is invoked for the projection-pending outcome.
- [ ] Run `devcore-project run test -- mix test test/store/subscriptions/sbh_10_05_charged_contract_reconciliation_test.exs`.
- [ ] Commit the failure and projection regressions with message `test(subscriptions): preserve renewal effect recovery`.

## Task 6: Performance, scaling, and final focused review

**Files:**
- No additional production files.
- Update this implementation PR description with measured evidence; do not edit this planning document during implementation unless the plan is separately reviewed.

- [ ] Measure SQL counts on the same charged-renewal fixture before/after dispatch. Report commercial transaction queries separately from post-commit synchronization. Expected shape: source transaction query count is unchanged; the old direct-grant transaction is replaced by one F1 currentness/convergence transaction with bounded exact-effect candidate lookup, Subscription lock, AccessEffect lock, latest-effect read, exact-source convergence, and APPLIED write. Report the actual numeric delta and avoid assuming strict issue and convergence have equal SQL counts.
- [ ] Record locks: source reconciliation Subscription `FOR UPDATE`, then applicable ContractChange lock; post-commit F1 Subscription mutex, candidate AccessEffect lock, currentness proof, exact-source grant lock/convergence, and APPLIED commit. Confirm F1 remains outside the source transaction.
- [ ] Record transaction counts for the two slice-specific phases (one commercial source transaction plus one post-commit synchronization transaction), with existing attempt-success bookkeeping and projection calls identified separately and unchanged. Record target cardinality (one charged entitlement pair or nil/nil empty target) and the exact-source grant row count. Slice A adds no grant-collection query; accepted F1 convergence can encounter historical rows and has no hard row cap established here, so report actual row counts and do not claim a bound. Record retry/recovery behavior under injected failure.
- [ ] Measure expected post-commit latency against the current direct issue path using equivalent fixtures. Explain that source commit latency is not coupled to F1; do not claim 100k-concurrency certification.
- [ ] Confirm no Redis, Cachex, ETS, GenServer, PubSub, Oban, mutable Plan, or worker-time policy/currentness authority was added. Confirm existing indexes are used and no new index is introduced without EXPLAIN evidence.
- [ ] Complete a Runtime Resource Safety Review: confirm the dispatch adds no process, mailbox, cache, timer, or long-lived resource; record observed exact-source grant rows, process memory/GC deltas, and cleanup behavior using the existing bounded resource fixture. Treat one run as diagnostic. Make memory, convergence, or no-accumulation claims only after at least two equivalent bounded repetitions.
- [ ] Run `git diff --check`, the focused subscription tests above, required repository checks, and the real-connection tests. Report exact CI head and all failures; do not weaken existing gates.

## Acceptance and debt disposition

```text
ORDINARY_RENEWAL_LEGACY_WRITER_DEBT=CLOSED_BY_THIS_SLICE
INITIAL_PAID_ACTIVATION_LEGACY_WRITER_DEBT=UNCHANGED
IMMEDIATE_CANCEL_LEGACY_REVOKE_DEBT=UNCHANGED
JC300_FINAL_SOURCE_COVERAGE=OPEN
JC300_FINAL_CUTOVER=OPEN
JC247_UNBLOCKED_AFTER_SLICE=YES_AFTER_IMPLEMENTATION_REVIEW_AND_ACCEPTANCE
```

The slice is complete only when exact-ID handoff, both PostgreSQL race orders, initial activation isolation, failure recovery, projection repair, and the measured performance review pass. The slice does not authorize JC-247 implementation or JC-300 final cutover. Human review and merge remain required.
