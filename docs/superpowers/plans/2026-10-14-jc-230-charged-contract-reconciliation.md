# JC-230 charged-contract reconciliation implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Apply a successful renewal's exact bound commercial contract to the existing Subscription and continue its matching entitlement consequence safely across replay.

**Architecture:** Keep JC-229's exact collection handoff and PaymentApplication check unchanged. Apply RenewalAttempt values and exact PlanRevision identity in one transaction that locks Subscription then its exact ContractChange. Recognize exact replay before rejecting ambiguous future targets. Sync entitlements from the attempt's charged snapshot after commit.

**Tech Stack:** Elixir, Ash 3.x, Ecto/PostgreSQL, ExUnit, Oban.

**Spec:** `docs/superpowers/specs/2026-10-14-jc-230-charged-contract-reconciliation-design.md`

## Global constraints

- `origin/main` is canonical. The exact base SHA is `e8616ab1cdbea866600265037e65d88bbf90b84c`.
- Preserve the JC-229 four-ID handoff and exact PaymentApplication PaymentIntent identity.
- Do not use mutable SubscriptionPlan or pending/current future-target values as paid-contract authority.
- Keep writes on existing Subscription and ContractChange resources. No schema migration is expected.
- Deliver Ash notifications only after commit.
- Keep money as integer minor units plus currency, use exact UUID lookups, and preserve system-actor rules.
- Do not implement JC-233, SBH-50, Payments redesign, or PayStack runtime behavior.
- Mark RenewalAttempt succeeded only after the immediate access consequence.

## Review focus

- Retired bound PlanRevision: revision A must still apply after revision B is published.
- Exact replay after commercial commit: it must run before future-target ambiguity checks.
- Cancel-now terminal replay: exact financial evidence must not reactivate a canceled Subscription or reissue access.
- ContractChange target mismatch: every mismatch must fail without commercial writes, transition, or attempt success.
- First application with a moved period or queued/pending future target: fail and preserve the future target.
- Exact collection and PaymentApplication evidence: still required when the attempt already says succeeded.

## Task 1: Add focused red tests

**Files:**
- Create: `test/store/subscriptions/sbh_10_05_charged_contract_reconciliation_test.exs`

**Interfaces:**
- Reuse SubscriptionsFixtures and RenewalCollectionAttempts.success_handoff_for_system/1.
- Keep test setup in this file. Do not change production code.

- [x] Add a real ContractChange-bound renewal through checkpoint B and exact collection success. Assert current main fails with VALIDATION_ERROR and the charged-contract reconciliation message.
- [x] Cover unchanged renewal plus exact revision, variant, non-default quantity, amount, currency, period, and membership projection. Mutate mutable projections after binding and prove drift is never applied.
- [x] Cover first ContractChange transition, exact replay, and separate mismatches for revision, variant, quantity, amount, currency, effective boundary, and Subscription identity. Assert all mismatches preserve Subscription fields, ContractChange status, and attempt status.
- [x] Retire bound revision A, create revision B, and prove A applies. Queue later ContractChange B before first application and prove fail-closed preservation.
- [x] Exercise the crash window by raising from [:store, :subscriptions, :paid_renewal_access_sync], checking the commercial commit while the attempt remains non-succeeded, queueing B, then retrying and checking A's target and unchanged Subscription aggregate version.
- [x] Prove wrong collection ID, wrong PaymentIntent ID, mismatched PaymentApplication PaymentIntent, and stale RenewalAttempt.payment_intent_id cannot select a payer.
- [x] Preserve active, past_due, and suspended recovery plus authority-withdrawn late-success remediation.
- [x] Run `mix test test/store/subscriptions/sbh_10_05_charged_contract_reconciliation_test.exs` against unchanged production code. Confirm expected red results and fix test setup errors before implementation.
- [x] Check `git diff --check` and verify this task changed no production file.

## Task 2: Extend existing aggregate actions

**Files:**
- Modify: `lib/store/subscriptions/subscription.ex`, update :extend_period.
- Modify: `lib/store/subscriptions/contract_change.ex`, actions.
- Test: focused JC-230 tests and `test/store/subscriptions/optimistic_aggregate_version_test.exs`.

**Interfaces:**
- Subscription.:extend_period accepts current_plan_revision_id and quantity, and excludes all future-target fields.
- ContractChange.:apply is private/system-only, accepts no fields, validates bound_to_renewal, filters on that state, and sets applied.

- [x] Add action assertions for revision/quantity, rejection of future-target attributes, and allowed ContractChange transitions.
- [x] Run those assertions and confirm they fail before production changes.
- [x] Update :extend_period. Add current_plan_revision_id and quantity. Remove pending_variant_id, pending_subscription_plan_id, pending_renewal_amount_minor, pending_renewal_currency, and change_effective_at from its accepted list. Preserve status and dunning recovery changes.
- [x] Add :apply. Make it private, non-atomic, accept no fields, validate current status is bound_to_renewal, filter on that state, and set applied. Add no reverse transition.
- [x] Run focused JC-230 tests and optimistic aggregate-version tests. Action assertions should pass; end-to-end reconciliation remains red until Task 3.

## Task 3: Apply and replay the exact charged contract

**Files:**
- Modify: `lib/store/subscriptions/facade.ex`, authorized renewal reconciliation, transactional application, and strict entitlement sync.
- Test: focused JC-230 test file.

**Interfaces:**
- The commercial transaction returns :applied or :already_applied, updated Subscription, charged entitlement target, and notifications.
- Lock order is Subscription row then optional exact ContractChange row.
- Keep external reconciliation results and authority-withdrawn remediation compatible.

- [x] Add facade assertions that attempt status alone does not skip exact evidence or commercial checks, and that exact replay runs before future-target checks without changing aggregate version.
- [x] Run focused tests and confirm current facade fails these cases.
- [x] Build entitlement target from the attempt snapshot or existing attempt-policy parser. Pass it and updated Subscription to strict sync. Do not fetch SubscriptionPlan for paid target selection.
- [x] Add one commercial Repo.transaction. Read exact PlanRevision by primary key without sale-status checks. Lock Subscription, load and lock exact ContractChange when present, validate all immutable fields, detect exact replay first, enforce the preceding-period boundary and future-target guard on first apply, update Subscription from attempt values, then transition ContractChange. Roll back on every failure.
- [x] After commit, deliver notifications, emit [:store, :subscriptions, :paid_renewal_access_sync], sync the charged entitlement target, then mark the attempt succeeded with the successful collection's PaymentIntent. Preserve the existing authority-withdrawn remediation path.
- [x] Run the focused file and inspect the production diff. Confirm the four-ID handoff and Payments core remain unchanged.

## Task 4: Verify affected behavior and performance

- [x] Run each required suite:
  `mix test test/store/subscriptions/sbh_10_05_charged_contract_reconciliation_test.exs`
  `mix test test/store/subscriptions/sbh_10_06_contract_change_test.exs`
  `mix test test/store/subscriptions/renewal_attempt_monotonicity_test.exs`
  `mix test test/store/subscriptions/cancellation_renewal_authority_test.exs`
  `mix test test/store/workers/reconcile_paid_subscription_renewal_worker_test.exs`
- [x] Run affected suspension/late-success, renewal collection lifecycle, Payments exact-application, and Entitlements subscription-source tests. The combined affected suite passed: 186 tests, 0 failures.
- [x] Measure query counts using repository query telemetry: first application 19, exact replay 15, unchanged renewal 15. Exact revision, Subscription, and ContractChange reads use primary-key indexes; subscription-scoped target lookup uses the existing ContractChange subscription index and queued partial index. No N+1 reads were observed.
- [x] Run `mix format --check-formatted`, `git diff --check`, `mix ash_postgres.generate_migrations --check`, and strict Credo. Run `mix compile --warnings-as-errors`.
- [x] Run `mix check`: static gates passed, 1093 tests ran, and one unrelated subscription-detail query-count assertion failed at 15 vs <=14. The same failure reproduced on the detached clean-base worktree at the exact base SHA. Remaining Credo, security, and docs steps completed.
- [x] Run `mix check.types`; Dialyzer passed successfully.
- [ ] Run repository normal performance smoke and mobile_realistic chaos performance smoke in CI. Record profile, exact SHA, counts, ceilings, and result.
- [ ] Complete independent review of the exact final head, then confirm locks, replay/crash paths, lifecycle, performance, and scope. Fix critical/important findings and rerun affected checks.

## Task 5: Push and open the draft PR

- [ ] Record base SHA, exact head SHA, commits, worktree status, red evidence, tests, query counts, performance, migration alignment, and CI status.
- [ ] Push the exact reviewed head and open a draft PR to main titled `feat(subscriptions): reconcile exact charged renewal contract`.
- [ ] Include a Performance & Scaling Review in the PR: hot/warm/cold classification, query count and N+1 risk, indexes, cache/TTL/invalidation/stampede behavior, Oban uniqueness/idempotency, and telemetry/logging.
- [ ] Immediately register the full PR URL with this thread. Verify all five CI jobs on the exact head SHA: check_static, test_pr_strict, dialyzer_required, performance_smoke_required, and performance_smoke_chaos_required.
- [ ] Leave the PR in draft for independent review. Do not merge.
