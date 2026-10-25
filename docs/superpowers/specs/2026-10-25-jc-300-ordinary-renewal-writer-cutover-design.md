# JC-300 Slice A: Ordinary Charged-Renewal Writer Cutover Design

> Review-only design. This document does not authorize implementation.

## Decision

Replace only the ordinary charged-renewal direct Entitlements issue call with the accepted JC-245/F1 executor, invoked after the paid-renewal source transaction commits and given the exact `AccessEffect.id` returned by that transaction. Keep initial paid activation, immediate-cancellation revocation, and every other direct writer for the later JC-300 cutover. This slice closes the specific stale renewal grant bypass that blocks JC-247; it does not claim complete source coverage or production cutover.

## Authority and base

Repository: `JCSchoeman96/Store_Blueprint_Hardening`

Base SHA: `d90adf8a88d327b5aad68d4561ec5901de614145`

Base tree: `9a221107f40fcd7154fdd1a703f5db2ecd9a6a73`

Accepted prerequisites: F0, F0.5, JC-245/F1, and JC-246/F2. AccessEffect source-order coverage is complete for the currently classified F0.5 target-changing lanes.

The accepted F1 contract requires the executor to receive an exact effect ID and run its own unchanged `AccessEffectCurrentnessFence` proof. It accepts `:applied`, `:applied_projection_pending`, `:superseded`, and `:noop` as successful synchronization outcomes for an already-paid renewal. JC-245 intentionally retained ordinary charged-renewal issuance for JC-300. JC-300 final source coverage, legacy writer removal, and production-cutover proof remain later work.

## Verified current ownership

### Ordinary renewal source transaction

`Store.Subscriptions.Facade.reconcile_paid_subscription_renewal_for_system/2` validates the bound `RenewalAttempt` and exact payment handoff, then calls `reconcile_authorized_paid_renewal/3`. That path calls `reconcile_paid_renewal_attempt/1`, which owns a `Repo.transaction/1` around `reconcile_paid_renewal_attempt_in_transaction/1`.

Within that transaction, the code reads the immutable PlanRevision, locks the Subscription with the renewal `FOR UPDATE` helper, locks any matching ContractChange, validates the charged-contract identity, applies the commercial period/revision change, and establishes the charged-renewal EFFECTIVE AccessEffect. First reconciliation returns a map containing `renewal_access_effect_id` and `grant_writer_lane`. Exact replay and retry locate the historical effect for that renewal and return its ID and predecessor-derived lane through the same map. The effect identity comes from immutable renewal evidence; this slice must not replace that lookup or infer an effect from the latest row.

`charged_renewal_effect_handoff/4` classifies the effect as `:suspended_recovery` only when its immediate predecessor is NON_EFFECTIVE. An EFFECTIVE predecessor or no predecessor classifies it as `:ordinary`. This classification is already returned from the locked reconciliation result.

### Current post-commit legacy issue call

`finish_paid_renewal_reconciliation/4` runs after the commercial transaction returns. It delivers the transaction's notifications, emits the existing `[:store, :subscriptions, :paid_renewal_access_sync]` telemetry boundary, calls `sync_charged_renewal_access/4`, and only then marks the RenewalAttempt succeeded.

Today `sync_charged_renewal_access(:ordinary, ...)` ignores the returned effect ID and calls `sync_charged_renewal_entitlement/2`. That path opens a second transaction, locks the Subscription, and calls `EntitlementsFacade.issue_subscription_source_grant_strict_for_system/2`; projection is delivered after that transaction. This writer does not run AccessEffect currentness. The `:suspended_recovery` branch already calls `execute_effective_access_effect_for_system/1` with the exact ID.

### Initial paid activation is isolated

Initial paid-order issuance is routed through `maybe_issue_entitlement/2` and `issue_subscription_entitlements_after_commit/1`, which call `issue_subscription_entitlement_for_system/2`. This is separate from the ordinary renewal `sync_charged_renewal_access/4` route. Slice A changes only the ordinary renewal dispatch clause and its focused tests; it does not alter, delete, or route initial activation through F1.

## Target architecture

The commercial transaction remains the authority for paid renewal truth and continues to commit the paid period, charged contract, and exact EFFECTIVE AccessEffect atomically. Its result hands the exact effect ID to the post-commit path. After the existing notification and telemetry boundary, ordinary renewal passes that ID to `execute_effective_access_effect_for_system/1`; it never queries for “latest” after commit. F1 starts and owns its own correctness transaction, re-proves currentness, converges the persisted target, and records APPLIED or SUPERSEDED under its accepted transaction contract. Projection remains post-commit under F1.

The existing suspended-recovery path already applies the same accepted F1 outcome mapping. The smallest routing change is to use that same F1 dispatch for both already-classified lanes while requiring a binary exact effect ID. Keep the existing invalid/missing-lane error path. Do not change currentness, fingerprints, disposition admission, retry recording, projection repair, F2, or Entitlements.

For an ordinary renewal, successful F1 outcomes are `:applied`, `:applied_projection_pending`, `:superseded`, and `:noop`. The first two mean the exact effect was already converged or is durably APPLIED with projection repair pending; the latter two mean replay is terminal or a newer desired target has won. All allow the already-paid reconciliation to continue to its existing attempt-success bookkeeping. An F1 correctness error remains an error from the public reconciliation call under the existing contract.

## Commercial commit and post-commit failure contract

The renewal source transaction commits before F1 starts. A post-commit F1 error cannot roll back the verified paid order, the Subscription period/revision update, the ContractChange application, or the exact AccessEffect. Preserve the current public facade shape: successful reconciliation returns `{:ok, :reconciled | :noop}`; an error from post-commit synchronization is returned as `{:error, normalized_reason}`. Since `mark_attempt_succeeded/3` follows synchronization today, a correctness error leaves that bookkeeping retryable while commercial truth remains committed. Exact replay must rediscover the same renewal effect and must not extend the period or create a second effect.

For a qualifying rolled-back F1 correctness failure, the accepted F1 failure recorder leaves the exact effect `FAILED_RETRYABLE`; the existing EFFECTIVE recovery selector can retry it. If F1 reports a currentness/validation error that is not eligible for failure recording, preserve that error without inventing a retry transition. A projection failure after F1 commit is `{:ok, :applied_projection_pending}`, not a correctness error; the facade continues its existing success path and F1's projection repair evidence remains authoritative. Do not swallow executor errors, compensate commercial state, or make payment outcome depend on grant delivery.

## Required stale-target race

Use the existing synchronous paid-renewal telemetry boundary as a deterministic gate between the commercial commit and post-commit F1 invocation. The boundary runs after the source transaction returns, so the test can pause T1 without holding the Subscription lock.

```text
T1 renewal transaction:
  lock Subscription FOR UPDATE
  reconcile paid occurrence
  establish exact EFFECTIVE effect A
  return A.id and :ordinary
  commit

T1 pauses at paid_renewal_access_sync telemetry boundary

T2 cancellation:
  lock Subscription FOR UPDATE
  establish newer NON_EFFECTIVE effect B
  commit

T1 resumes:
  execute_effective_access_effect_for_system(A.id)
  F1 locks the Subscription and A, proves B is newer
  A becomes SUPERSEDED; no grant mutation is made from A
```

Assert the paid period and charged revision remain committed, B is latest and NON_EFFECTIVE, A is SUPERSEDED, the exact source has no active grant after T2's accepted cancellation path, and no stale grant from A appears after T1 resumes. The test must use independent PostgreSQL connections, the telemetry barrier, and explicit release messages; sleeps are not race evidence.

Also test the inverse order with independent connections: let T1's F1 executor reach its exact-source convergence barrier while it holds the Subscription mutex; start T2 cancellation and prove it is blocked behind T1; release F1 and assert A is APPLIED before allowing T2 to commit B. Assert final state follows B and no deadlock occurs. Reuse the established PostgreSQL lock-barrier style from the subscription source-fence contention tests.

## Required functional proof

The implementation tests must establish all of the following:

1. Ordinary paid renewal executes its exact EFFECTIVE effect through F1 and converges the exact charged target and original period boundaries.
2. The ordinary renewal call does not invoke `issue_subscription_source_grant_strict_for_system/2`. Use a process-scoped Erlang call trace around the reconciliation call and assert no call trace for that function; always disable the trace pattern in `after` cleanup.
3. Initial paid-order issuance still uses its existing `issue_subscription_entitlement_for_system/2` path and is otherwise unchanged.
4. F1 application is exact and replay-safe: first execution applies the persisted pair and validity bounds; replay is a terminal no-op.
5. The newer NON_EFFECTIVE race above defeats exact old effect A; the inverse order applies A before B is allowed to commit.
6. A forced F1 correctness failure after the paid transaction leaves commercial fields and AccessEffect committed, returns the established error result, and leaves the exact effect recoverable through existing FAILED_RETRYABLE recovery. A retry must not reapply the period or duplicate the effect.
7. A post-commit projection failure returns projection-pending success, does not undo commercial truth or F1 convergence, and remains repairable by the existing projection path.
8. A queued contract-change renewal uses the exact charged-contract target already bound to the RenewalAttempt and established by the source transaction.
9. Execution uses the persisted effect and exact ID; no mutable Plan read, post-commit latest-effect query, worker-time validity boundary, or period extension is introduced.
10. Existing F1 replay, currentness, retry, and projection semantics remain unchanged.

## Scope boundary

The future production change is limited to `lib/store/subscriptions/facade.ex`. Focused tests belong under `test/store/subscriptions/**`. No changes are authorized to `lib/store/entitlements/**`, F0 currentness/fingerprint semantics, F1 executor architecture, F2, migrations, initial paid activation, cancellation/scheduled-boundary writers, PAST_DUE/suspension/rescission policy, JC-247, JC-248, NewYou target sets, or generic event/outbox infrastructure. Do not delete `issue_subscription_source_grant_strict_for_system/2` or any other legacy API.

## Performance & Scaling Review

**HOT:** locked Subscription and already-bound RenewalAttempt/PlanRevision evidence; commercial renewal transaction; AccessEffect target establishment; post-commit F1 currentness and exact-target execution. **WARM:** none required for correctness. **COLD durable authority:** PostgreSQL Subscription, RenewalAttempt, PlanRevision, AccessEffect, grant, and projection history. Redis, Cachex, ETS, GenServer memory, PubSub, Oban, and worker time have no policy or source-order authority.

Before Slice A, the lane has the commercial source transaction plus a separate post-commit direct-grant transaction. After Slice A it has the same commercial source transaction plus a separate post-commit F1 currentness/convergence transaction. No additional query is added to the source transaction: its exact effect ID is already in the returned map. The post-commit `latest` query is part of F1's required currentness fence; it replaces no caller-side latest lookup because none is added. F1's proof performs bounded reads for the exact effect candidate, locked Subscription, locked effect, and latest effect, then runs the existing exact-source convergence and APPLIED write. The old direct transaction also locks the Subscription and performs the strict issue operation. Record the measured before/after SQL count on the same fixture in the implementation PR; report the structural delta as `F1 bounded currentness reads + F1 convergence SQL - strict issue SQL`, without claiming an absolute count from this docs-only inspection.

Lock order remains separate across the two transactions. Commercial reconciliation reads the immutable revision, locks the Subscription, then locks the applicable ContractChange before updating the source and inserting its effect. F1 then locks the Subscription, candidate AccessEffect, validates latest order, converges the one Subscription source target, and commits APPLIED; it does not run inside the commercial transaction. The existing renewal identity is one bound RenewalAttempt per Subscription and billing period; replay's immutable-evidence lookup is scoped to one Subscription and bounded with `LIMIT 2`, failing closed for ambiguity. Each effect target is one entitlement pair or the accepted nil/nil empty target. F1's existing exact-source convergence can encounter historical grant rows for that source; accepted F1 tests exercise 128 rows, but this slice does not establish a hard maximum. Slice A adds no grant-collection query. Record actual source-row cardinality and query behavior during implementation; do not claim that F1's existing collection work is bounded by a fixed row cap. No new index is planned: retain the accepted AccessEffect primary-key lookup, `(subscription_id, source_version)` history/currentness index, F0 EFFECTIVE recovery partial index, and existing exact-source indexes used by F1.

Expected added post-commit latency is the bounded F1 proof and convergence transaction in place of the direct issue transaction; it does not delay commercial commit. Projection calls remain the existing F1 post-commit projection path. A retryable correctness failure can cause an additional F1 recovery attempt; effect identity and renewal replay prevent duplicate commercial updates. Measure the before/after query count and latency with equivalent fixtures, and inspect retry amplification under an injected failure. Per-subscription work remains serialized by PostgreSQL; 100k-concurrency capacity is not certified by this slice.

### Runtime Resource Safety Review

The dispatch adds no process, mailbox, cache, timer, or long-lived resource; it invokes the existing synchronous F1 executor after commit. F1's exact-source convergence may process historical grant rows, so implementation review must report observed row count, process memory/GC deltas, and cleanup behavior using the existing bounded resource fixture. One run is diagnostic only. Make no memory, convergence, or no-accumulation claim unless at least two equivalent bounded repetitions support it; do not claim 100k capacity.

## Debt disposition and exit gate

```text
ORDINARY_RENEWAL_LEGACY_WRITER_DEBT=CLOSED_BY_THIS_SLICE
INITIAL_PAID_ACTIVATION_LEGACY_WRITER_DEBT=UNCHANGED
IMMEDIATE_CANCEL_LEGACY_REVOKE_DEBT=UNCHANGED
JC300_FINAL_SOURCE_COVERAGE=OPEN
JC300_FINAL_CUTOVER=OPEN
```

This slice is bounded independently of JC-300 final cutover and removes the ordinary renewal bypass that blocks JC-247. JC-247 becomes eligible to resume only after Slice A is implemented, reviewed, and accepted; this planning document alone does not authorize either implementation.
