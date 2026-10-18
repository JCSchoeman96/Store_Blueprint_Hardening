# JC-250 Grandfathered Retired-Contract Renewal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fail closed when checkpoint B encounters a DRAFT/never-effective current or queued PlanRevision while preserving exact EFFECTIVE/RETIRED historical renewal authority.

**Architecture:** Keep the existing exact-revision renewal selection and ContractChange consumption paths. Reuse `ensure_revision_has_purchase_history/1` in memory after the exact PlanRevision is already loaded; do not add current-EFFECTIVE selection, a database lookup, a new resource, or a new lifecycle. Prove the two missing fail-closed paths first, then retain the already-frozen grandfathering and replay behavior with focused regression proof.

**Tech Stack:** Elixir, Ash 3.x, Ecto/PostgreSQL, ExUnit, Oban.

**Spec:** `docs/hardening/subscriptions/SUBSCRIPTION_HARDENING_MASTER_REGISTER.md` section 57 / v0.1.37 JC-250 contract.

## Global Constraints

- Exact `task_base_sha`: `e48c596e23c64ccfca1d49f9509082c0e36416ef`.
- Implementation branch: `subs-task/sbh-60-02-grandfathered-renewals`.
- Preserve the exact Subscription-bound or durable ContractChange target PlanRevision; never fall forward to the current public EFFECTIVE revision.
- `EFFECTIVE` and legitimate historical `RETIRED` revisions are valid existing-renewal evidence; `DRAFT`/never-effective/unproven revisions fail closed before checkpoint B/provider work.
- New-sale and newly queued change selection remain current-EFFECTIVE authority and are not changed here.
- Preserve ContractChange ordering/supersession, RenewalAttempt occurrence identity, paid reconciliation, dunning/recovery, cancellation/expiry terminal rules, and provider/payment/fulfilment blockers.
- No schema, migration, Ash snapshot, dependency, worker, cache, Payments, Orders, Entitlements, provider, Catalog-core, or shared-authority changes.
- Prefer zero new queries: validate the already-loaded exact PlanRevision in memory.

## Review Focus

- Reusable exact current revision path must apply the history guard as well as the fetched-current path.
- Queued ContractChange target that was legitimately EFFECTIVE then RETIRED must remain valid; only DRAFT/unproven history fails.
- A newer EFFECTIVE public revision must never replace the existing bound retired revision.
- Failure must occur before RenewalAttempt/provider work and must not fabricate history or mutate the queued change.
- Same-occurrence replay/recovery and post-B retirement must remain on the immutable B-bound contract.

---

### Task 1: Add deterministic red proof for the two missing guards

**Files:**
- Create: `test/store/subscriptions/sbh_60_02_grandfathered_retired_contract_renewal_test.exs`

**Interfaces:**
- Reuse `SubscriptionsFixtures`, `Store.Repo`, `Facade.process_due_subscription_renewal_for_system/2`, `PlanRevision`, `ContractChange`, and `RenewalAttempt`.
- Test corruption only through direct test-database updates; production APIs must not gain corruption helpers.

- [ ] **Step 1:** Add a test that replaces an existing Subscription's `current_plan_revision_id` with a same-plan DRAFT revision, calls due-renewal processing, expects `VALIDATION_ERROR / purchased plan revision was never effective`, and asserts no RenewalAttempt exists.
- [ ] **Step 2:** Add a test that queues a valid ContractChange, replaces only its target revision with a same-plan/same-price DRAFT revision, calls due-renewal processing, expects the same fail-closed error, asserts no RenewalAttempt exists, and asserts the ContractChange remains queued.
- [ ] **Step 3:** Run `mix test test/store/subscriptions/sbh_60_02_grandfathered_retired_contract_renewal_test.exs` on unchanged production code and record both tests failing for the missing history guard rather than setup errors.
- [ ] **Step 4:** Run `git diff --check`; confirm no production file changed in the red commit.

### Task 2: Reuse the existing history guard at checkpoint B

**Files:**
- Modify: `lib/store/subscriptions/facade.ex`
- Test: `test/store/subscriptions/sbh_60_02_grandfathered_retired_contract_renewal_test.exs`

**Interfaces:**
- Consume existing private `ensure_revision_has_purchase_history/1` unchanged.
- Produce no new public API and no new persistence.

- [ ] **Step 1:** In all unchanged-current-contract `renewal_binding_selection/3` branches, call `ensure_revision_has_purchase_history(revision)` after exact revision/plan ownership is established and before contract binding.
- [ ] **Step 2:** In the queued `ContractChange` `renewal_binding_selection/3` branch, call the same guard immediately after loading the exact target revision and before price/contract validation and binding.
- [ ] **Step 3:** Run the focused JC-250 test file and confirm both red cases pass.
- [ ] **Step 4:** Run existing exact-retired-current and ContractChange binding tests to confirm `RETIRED` remains accepted and no current-EFFECTIVE fallback was introduced.

### Task 3: Complete grandfathering regression proof and repository verification

**Files:**
- Extend: `test/store/subscriptions/sbh_60_02_grandfathered_retired_contract_renewal_test.exs` only where existing tests do not already prove the v0.1.37 matrix.
- Update this plan with executed evidence only.

**Interfaces:**
- Existing tests remain authoritative for overlapping SBH-10-03, SBH-20-03, and SBH-10-05 behavior; do not duplicate large scenarios without a proof gap.

- [ ] **Step 1:** Prove exact retired current revision remains authoritative with a newer EFFECTIVE revision and with zero current EFFECTIVE revisions.
- [ ] **Step 2:** Prove a legitimately queued target that becomes RETIRED remains exact at B with no fall-forward.
- [ ] **Step 3:** Run the focused file plus `sbh_10_03_renewal_contract_snapshot_test.exs`, `sbh_20_03_renewal_vs_contract_change_test.exs`, and `sbh_10_05_charged_contract_reconciliation_test.exs`.
- [ ] **Step 4:** Run `mix format --check-formatted`, `git diff --check`, `mix ash_postgres.generate_migrations --check`, `mix check`, and `mix check.types`.
- [ ] **Step 5:** Run required normal and mobile-realistic performance smoke gates; record query/performance evidence and verify no additional lookup was introduced.
- [ ] **Step 6:** Open a draft implementation PR to `hardening/subscriptions`, record exact head/CI, and leave merge to independent review/human decision.
