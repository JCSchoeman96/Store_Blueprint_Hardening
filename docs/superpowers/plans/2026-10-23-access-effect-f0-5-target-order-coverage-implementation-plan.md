# F0.5 AccessEffect Target-Order Implementation Plan

> **For agentic workers:** Use TDD for behavior changes. Stop on unclassified target-changing writers, Entitlements changes, or base drift.

**Goal:** Close ordinary-renewal and immediate-cancellation AccessEffect ordering gaps; repair historical unresolved ordering via bounded reconciliation; prove six-lane coverage.

**Architecture:** Pure `Store.Subscriptions.AccessEffectTargetOrder` for derivation/equivalence; `Store.Subscriptions.Facade` owns producers and reconciliation; `Store.Workers.ReconcileSubscriptionAccessEffectTargetOrderWorker` orchestrates sweeps.

**Tech Stack:** Elixir, Ash, PostgreSQL, Oban, ExUnit.

**Canonical Base:** `41a7fc998ad2d1bbb073f86c341df13a834dd6fa`

**Spec:** `docs/superpowers/specs/2026-10-23-access-effect-f0-5-target-order-coverage-design.md`

## Global constraints

- No JC-245/JC-246 execution, no grant cutover, no Entitlements file changes.
- No Subscription table scan; reuse existing recovery reads/indexes.
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
- Dual cursors; per-candidate transaction; page fail on blocker.

**Files:**

- `test/store/subscriptions/access_effect_target_order_reconciliation_test.exs`

## Phase F — Worker

**Files:**

- `lib/store/workers/reconcile_subscription_access_effect_target_order_worker.ex`
- `test/store/workers/reconcile_subscription_access_effect_target_order_worker_test.exs`
- Register in `lib/store/support/governance/surface_registry.ex`

## Phase G — Coverage proof

- Six-lane inventory test module or extensions.
- Producer vs reconciliation race (real connections where required).
- Index usage assertion in reconciliation read tests (mirror effective recovery tests).

## Phase H — Acceptance

- Full affected tests + CI checks.
- PR with Performance & Scaling Review (cold Postgres, indexes reused, caches N/A).

## STOP conditions

- Canonical `main` ≠ approved base without owner ack.
- New unclassified target-changing writer discovered.
- Need to change Entitlements semantics or add migrations.
