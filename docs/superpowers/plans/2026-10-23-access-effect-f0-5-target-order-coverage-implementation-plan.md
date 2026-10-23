# F0.5 AccessEffect Target-Order Implementation Plan

> **For agentic workers:** Use TDD for behavior changes. Stop on unclassified target-changing writers, Entitlements changes, or base drift.

**Goal:** Close ordinary-renewal and immediate-cancellation AccessEffect ordering gaps; repair historical unresolved ordering via bounded reconciliation; prove six-lane coverage.

**Architecture:** Pure `Store.Subscriptions.AccessEffectTargetOrder` for derivation/equivalence; `Store.Subscriptions.Facade` owns producers and reconciliation; `Store.Workers.ReconcileSubscriptionAccessEffectTargetOrderWorker` orchestrates sweeps.

**Tech Stack:** Elixir, Ash, PostgreSQL, Oban, ExUnit.

**Canonical Base:** `41a7fc998ad2d1bbb073f86c341df13a834dd6fa`

**Spec:** `docs/superpowers/specs/2026-10-23-access-effect-f0-5-target-order-coverage-design.md`

## Global constraints

- No JC-245/JC-246 execution, no grant cutover, no Entitlements file changes.
- No Subscription table scan; use one dedicated AccessEffect selector ordered by immutable `(inserted_at, id)` and its matching partial index.
- No Redis/Cachex/PubSub for correctness.
- Subscription `FOR UPDATE` remains source mutex.

## Phase A — Docs (this PR section)

- Install spec + plan; record base SHA.

## Phase B — `AccessEffectTargetOrder`

**Files:**

- `lib/store/subscriptions/access_effect_target_order.ex`
- `test/store/subscriptions/access_effect_target_order_test.exs`

**Behaviors:**

- `derive_current_target/2` for active/past_due/suspended/canceled only; fail closed otherwise.
- `target_evidence_equal?/2` ignoring source version.
- `evidence_from_access_effect/1`, `charged_renewal_establish_attrs/3`, `immediate_cancellation_establish_attrs/1`.

## Phase C — Charged-renewal producer

**Modify:** `lib/store/subscriptions/facade.ex`

- Replace suspended-only hook with `:applied` charged-renewal EFFECTIVE establishment.
- Nil/nil `valid_from_at` fix.
- Extend `test/store/subscriptions/sbh_10_05_charged_contract_reconciliation_test.exs` for ordinary renewal effect + preserved recovery tests.

## Phase D — Immediate-cancellation producer

**Modify:** `lib/store/subscriptions/facade.ex`

- After cancel transition, when `effective_mode == :now`, establish NON_EFFECTIVE before commit.
- Extend cancellation tests for effect + rollback.

## Phase E — Reconciliation facade

**Modify:** `lib/store/subscriptions/facade.ex`

- `run_access_effect_target_order_reconciliation_for_system/1`
- One `through_inserted_at` watermark and `(after_inserted_at, after_id)` cursor.
- Lock Subscription before the exact AccessEffect; use the locked candidate for terminal/currentness checks.
- Process at most the requested number of candidates, with a hard maximum of 500.

**Modify:** `lib/store/subscriptions/access_effect.ex`

- Add `read_target_order_candidates_for_system` with unresolved statuses only, no OFFSET, and immutable keyset ordering.
- Add `access_effects_target_order_reconciliation_index` on `(inserted_at, id)` for the same unresolved-status predicate.

**Generate:** PostgreSQL migration and `AccessEffect` resource snapshot.

**Files:**

- `test/store/subscriptions/access_effect_target_order_reconciliation_test.exs`

## Phase F — Worker

**Files:**

- `lib/store/workers/reconcile_subscription_access_effect_target_order_worker.ex`
- `test/store/workers/reconcile_subscription_access_effect_target_order_worker_test.exs`
- Register in `lib/store/support/governance/surface_registry.ex`
- Freeze `as_of` once and continue with one `(after_inserted_at, after_id)` cursor.
- Enqueue one continuation only when a page contains exactly the requested number of candidates.

## Phase G — Coverage proof

- Remove the constant-only lane count test.
- Document the six production lanes with source paths and focused test files; rerun the `establish_access_effect_for_system/1` source audit during review.
- Test the `updated_at` mutation race through the frozen immutable cursor.
- Prove cancel-now target evidence and transaction rollback on effect insertion failure.
- Prove producer-first and reconciliation-first source-lock contention with real database connections.
- Verify the new partial index definition and migration snapshot.

## Phase H — Acceptance

- Full affected tests + CI checks.
- PR Performance & Scaling Review: one indexed candidate query per page, one transaction per candidate, no more than 500 candidates per job, no correctness cache.
- PR Runtime Resource Safety Review: at most 500 candidate rows per page, sequential per-candidate transactions, one continuation job at most; repeated-load convergence/capacity remains unmeasured.
- Run the real-connection F0.5 contention proof twice in CI.

## STOP conditions

- Canonical `main` ≠ approved base without owner ack.
- New unclassified target-changing writer discovered.
- Immutable candidate discovery cannot use the matching partial index.
- A candidate can still escape the frozen sweep or Subscription is not the first correctness lock.
- Need to change Entitlements semantics or enter F1/F2/JC-300 scope.
