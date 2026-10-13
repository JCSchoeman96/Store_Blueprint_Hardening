# JC-229 Renewal Collection Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Use `superpowers:test-driven-development` for implementation. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make subscription renewal provider collection derive from the immutable bound RenewalAttempt and remain durable, replay-safe, provider-verifiable, cancellation/suspension-safe, inventory-safe, and reusable by NewU.

**Architecture:** Add a Subscription-owned `RenewalCollectionAttempt` beneath each bound `RenewalAttempt`, with separate dispatch and financial axes. Build/reuse exact renewal Order/PaymentIntent from bound commercial evidence, commit an epoch-fenced dispatch claim before provider I/O, reconcile through accepted Payments finality semantics, and expose exact success identity for downstream JC-230 without applying the renewal itself.

**Tech Stack:** Elixir, Phoenix, Ash 3.x, AshPostgres/Ecto/PostgreSQL, Oban, ExUnit, current Store domain facades.

**Spec:** `docs/superpowers/specs/2026-10-13-jc-229-renewal-collection-lifecycle-design.md`

## Global Constraints

- Start from then-current `origin/main`; record exact base SHA.
- `origin/main` + Linear JC-229 + locked NewU CER decisions are canonical; old branch/governance pins are provenance only.
- PR #127 is evidence only; do not rebase/cherry-pick it wholesale.
- Preserve accepted JC-287, JC-282, JC-281, JC-265, and JC-327 behavior.
- Provider charge identity comes from bound `RenewalAttempt`; mutable Subscription/Plan state may only govern present-time authority/operations.
- One RenewalAttempt may have multiple collection ordinals; a fresh ordinal is allowed only after provider-certified terminal financial non-success.
- Persist `may_have_been_reached` before provider mutation.
- Pre-submission fence never means financial failure.
- `suspended` gets no new dispatch/collection authority; already-reached exact collections remain reconcilable.
- `canceled`/`expired` get no new renewal authority.
- Do not implement JC-230 renewal application/entitlements in this issue.
- Use exact reservation-generation guard/release behavior for physical renewals.
- Money is integer minor units + currency.
- Add no Redis/cache correctness dependency.
- Human merge required.

## Review Focus

1. **Ambiguous provider result after dispatch claim:** same collection/PI must remain authoritative; test crash/timeout and replay.
2. **Cancellation/suspension between local claim and provider activity:** no unauthorized new provider mutation; already-reached evidence remains reconcilable.
3. **Mutable plan/subscription drift after binding:** provider payload/order/PI must still match the bound RenewalAttempt.
4. **Physical reservation generation replacement race:** stale collection must never dispatch against or release the wrong generation.
5. **Provider observation reordering / stale local failure:** success/finality must follow accepted PaymentOutcomeResolver/provider evidence, not arrival order or local PI status.

---

### Task 0: Establish exact authority and baseline

**Files:**
- Read: `AGENTS.md`
- Read: Linear `JC-229`
- Read: locked NewU CER sources linked to JC-229 / reuse-gap lineage
- Read: `lib/store/subscriptions/renewal_attempt.ex`
- Read: `lib/store/subscriptions/facade.ex`
- Read: `lib/store/payments/interlocks.ex`
- Read: `lib/store/payments/payment_outcome_resolver.ex`
- Read: `lib/store/orders/domain.ex`
- Read: `lib/store/orders/inventory_reservations.ex`
- Read: relevant JC-281/282/265/287 conformance tests/docs
- Historical evidence only: PR #127

**Interfaces:**
- Consumes: accepted current-main behavior and locked CER decisions.
- Produces: exact base SHA, prerequisite map, CER conformance matrix, and explicit “do not change” invariants.

- [ ] **Step 1: Sync canonical main and create one short-lived issue branch**

```bash
git fetch origin
git switch main
git pull --ff-only
git status --short
git rev-parse HEAD
git switch -c jc-229-renewal-collection-lifecycle
```

Expected: clean tree, branch from current `origin/main`. Record exact SHA in working notes.

- [ ] **Step 2: If main != review-time `c5f2a7a430d7932e4106400f7863316c79fd88e7`, inspect intervening changes**

Run a focused diff/log over subscriptions, payments, orders/inventory, workers, migrations, and hardening docs. Adjust this plan only where current accepted behavior requires it; document why.

- [ ] **Step 3: Build the NewU CER conformance matrix**

For each linked **locked** CER decision, record:
`CER decision -> generic Store invariant -> code owner -> proving test`.

Do not classify proposals/Pre-JIT questions as locked requirements.

- [ ] **Step 4: Baseline tests**

Run targeted accepted suites for renewal contract binding, payment outcome resolution, cancellation authority, suspension recovery, and inventory-generation guards before changing code.

Expected: PASS. Any pre-existing failure is documented before implementation.

- [ ] **Step 5: Commit design/spec only if repository practice expects it**

Add:
`docs/superpowers/specs/2026-10-13-jc-229-renewal-collection-lifecycle-design.md`

Commit:
`docs: lock JC-229 renewal collection design`

---

### Task 1: Add collection types, resource, schema invariants, and fresh migration

**Files:**
- Create: `lib/store/subscriptions/types/renewal_collection_dispatch_state.ex`
- Create: `lib/store/subscriptions/types/renewal_collection_financial_outcome.ex`
- Create: `lib/store/subscriptions/renewal_collection_attempt.ex`
- Modify: `lib/store/subscriptions/domain.ex`
- Create/modify: current Ash migration + snapshots generated from current main
- Test: `test/store/subscriptions/renewal_collection_attempt_test.exs`

**Interfaces:**
- Consumes: existing `RenewalAttempt`, `PaymentIntent`, Ash resource conventions.
- Produces:
  - `Store.Subscriptions.RenewalCollectionAttempt`
  - dispatch states `:not_started | :may_have_been_reached | :not_submitted`
  - financial outcomes `:unresolved | :requires_action | :verified_success | :verified_terminal_financial_non_success`

- [ ] **Step 1: Write failing resource/DB tests**

Tests must assert:
- ordinal > 0;
- unique `(renewal_attempt_id, collection_ordinal)`;
- one active collection per RenewalAttempt;
- unique non-null PaymentIntent;
- epoch/fence consistency;
- non-unresolved financial outcome requires PaymentIntent;
- invalid state strings rejected at DB level.

Run targeted file and verify FAIL because resource/table does not exist.

- [ ] **Step 2: Implement the two Ash enum types**

Exact values from spec; no extra values.

- [ ] **Step 3: Implement `RenewalCollectionAttempt`**

Use historical PR #127 field/action names as a starting point, revalidated against current Ash 3.x patterns.

Resource actions should include narrowly-scoped transitions equivalent to:
- `:create`
- `:assign_reservation_generation`
- `:claim_dispatch`
- `:fence_before_submission`
- `:resume_after_fence`
- `:attach_payment_intent`
- `:record_financial_outcome`

Terminal financial outcome regression must be impossible through actions.

- [ ] **Step 4: Register resource in `Store.Subscriptions` domain**

No public web exposure is required.

- [ ] **Step 5: Generate fresh migration/snapshot from current branch**

Do **not** copy old migration. Review SQL manually for all unique/partial/check constraints.

- [ ] **Step 6: Run targeted tests and migration consistency checks**

Expected: PASS.

- [ ] **Step 7: Commit**

`feat(subscriptions): add durable renewal collection resource`

---

### Task 2: Implement start/replay and ordinal allocation under locks

**Files:**
- Create: `lib/store/subscriptions/renewal_collection_attempts.ex`
- Test: `test/store/subscriptions/renewal_collection_attempt_test.exs`

**Interfaces:**
- Produces typed inputs and functions:
  - `%RenewalCollectionAttempts.StartInput{renewal_attempt_id:, now:}`
  - `start_for_system/1`
  - `payment_intent_key/1`

`payment_intent_key(collection_attempt_id)` must return:
`"renewal-collection:" <> collection_attempt_id`.

- [ ] **Step 1: Write failing tests**

Cover:
- ordinal 1;
- active replay returns exact same row;
- concurrent start => one active row;
- success blocks future ordinal;
- terminal financial non-success + retry due => next contiguous ordinal;
- `requires_action` blocks next ordinal;
- ordinal gaps fail closed;
- incomplete/unbound RenewalAttempt fails closed;
- suspended/canceled/expired/current cancellation authority blocks creation of new collection;
- scheduled cancellation/withdrawn renewal authority blocks new collection as required by current JC-281 rules.

- [ ] **Step 2: Implement typed inputs and validation**

Reject raw/untyped shapes at the boundary.

- [ ] **Step 3: Implement lock ordering and ordinal allocation**

Preserve current accepted subscription/renewal lock order. Lock parent/collection rows so ordinal allocation has one durable authority.

- [ ] **Step 4: Validate complete bound RenewalAttempt**

Commercial fields are immutable source of truth. Fail closed on incomplete bound contract.

- [ ] **Step 5: Implement current dunning/authority gate**

A later ordinal requires:
- previous provider-certified terminal financial non-success;
- current retry/dunning authority;
- retry timing/policy derived from accepted bound/current policy split;
- no suspension/cancellation terminal authority.

Do not use mutable plan fields to redefine amount/currency/variant.

- [ ] **Step 6: Run concurrency test repeatedly**

Use deterministic barriers where practical; avoid timing sleeps as correctness proof.

- [ ] **Step 7: Commit**

`feat(subscriptions): allocate renewal collection attempts safely`

---

### Task 3: Add exact reservation-generation ownership, fence, and resume

**Files:**
- Modify: `lib/store/subscriptions/renewal_collection_attempts.ex`
- Use: `lib/store/orders/domain.ex`
- Use: `lib/store/orders/inventory_reservations.ex`
- Test: `test/store/subscriptions/renewal_collection_attempt_test.exs`
- Possibly add focused cross-domain race test if existing test layout warrants it.

**Interfaces:**
- Produces:
  - `%ReservationGenerationInput{}`
  - `assign_reservation_generation_for_system/1`
  - `%FenceInput{}`
  - `fence_before_submission_for_system/1`
  - `%ResumeInput{}`
  - `resume_after_fence_for_system/1`

- [ ] **Step 1: Write failing exact-generation tests**

Assert:
- physical generation must be exact/current/active before assignment/dispatch;
- assigning same exact generation is idempotent;
- assigning a different generation fails closed;
- stale generation cannot be released;
- fence vs generation replacement race cannot release replacement generation;
- nonphysical renewal does not require generation;
- fence keeps financial outcome `unresolved`;
- resume increments epoch exactly one.

- [ ] **Step 2: Integrate `Store.Orders.guard_exact_generation/4`**

Use the accepted guard in the transactionally correct place. Do not duplicate its logic.

- [ ] **Step 3: Implement pre-submission fence**

Only exact `not_started + expected_epoch` may fence. Exact generation release/fence and collection transition must serialize atomically.

- [ ] **Step 4: Implement resume**

Only exact `not_submitted + fenced_through_epoch == expected_epoch + unresolved` may resume to epoch+1.

- [ ] **Step 5: Run race tests**

Expected: one legal winner, no wrong generation release.

- [ ] **Step 6: Commit**

`feat(subscriptions): fence renewal collection inventory generations`

---

### Task 4: Bind exact Order and PaymentIntent from the immutable renewal contract

**Files:**
- Modify: `lib/store/subscriptions/renewal_collection_attempts.ex`
- Modify only as needed: `lib/store/subscriptions/facade.ex`
- Reuse/extend minimally: `lib/store/payments/interlocks.ex` and/or current `Store.Payments` domain API
- Reuse current Order domain surfaces
- Test: new focused `test/store/subscriptions/renewal_collection_binding_test.exs` or existing JC-229 test file

**Interfaces:**
- Produces:
  - `%AttachPaymentIntentInput{}`
  - `attach_payment_intent_for_system/1`
  - one exact Order per RenewalAttempt occurrence;
  - one exact PaymentIntent per collection.

- [ ] **Step 1: Write failing bound-contract tests**

Mutate current Subscription/Plan after RenewalAttempt binding and prove provider-facing/order-facing:
- amount remains `attempt.amount_minor`;
- currency remains `attempt.currency`;
- variant/quantity remain bound values;
- period identity remains bound;
- existing conflicting Order blocks before provider call;
- existing conflicting PI blocks before provider call.

- [ ] **Step 2: Reuse/create the renewal Order through accepted domain surfaces**

Do not create a second order if the exact bound order already exists and validates.

- [ ] **Step 3: Create/reuse PaymentIntent with exact collection idempotency key**

`renewal-collection:<collection_attempt_id>`

Same collection replay => same PI. Later collection ordinal => distinct PI.

- [ ] **Step 4: Persist exact PI association and enforce one-to-one**

Do not make legacy `RenewalAttempt.payment_intent_id` the new authority.

- [ ] **Step 5: Run targeted tests**

Expected: no provider mutation occurs on persisted evidence mismatch.

- [ ] **Step 6: Commit**

`feat(subscriptions): bind renewal collection to exact order and payment intent`

---

### Task 5: Implement epoch-fenced dispatch-before-provider-I/O

**Files:**
- Modify: `lib/store/subscriptions/renewal_collection_attempts.ex`
- Modify: renewal orchestration in `lib/store/subscriptions/facade.ex`
- Modify only if necessary: current renewal worker
- Reuse: current Payments domain/provider dispatch surface
- Test: `test/store/subscriptions/renewal_collection_dispatch_test.exs`

**Interfaces:**
- Produces:
  - `%DispatchInput{}`
  - `claim_dispatch_for_system/1`
  - orchestration that commits claim before provider mutation.

- [ ] **Step 1: Write failing dispatch/crash tests**

Prove:
- exact epoch claim is CAS;
- stale epoch loses;
- claim requires exact PI and valid physical generation when physical;
- claim transition commits before provider call;
- injected crash after claim/before provider response leaves `may_have_been_reached`;
- replay uses same PI/key;
- timeout/unknown response never creates a fresh collection/PI.

- [ ] **Step 2: Implement dispatch claim**

Allowed only from `not_started` at expected epoch, after exact identity/authority checks.

- [ ] **Step 3: Place transaction boundary before outbound provider call**

No provider I/O inside the DB transaction that establishes dispatch claim.

- [ ] **Step 4: Re-check cancellation/suspension authority immediately before new provider mutation**

If authority has been withdrawn and the provider has not been reached:
- perform legal fence/release;
- zero provider mutation.

Do not re-check mutable plan fields to change commercial payload.

- [ ] **Step 5: Execute provider mutation through accepted Payments surface**

Do not bypass provider adapter/domain boundaries.

- [ ] **Step 6: Commit**

`feat(subscriptions): fence renewal provider dispatch by epoch`

---

### Task 6: Reconcile exact provider financial outcome through accepted Payments finality

**Files:**
- Modify: `lib/store/subscriptions/renewal_collection_attempts.ex`
- Reuse/extend minimally: Payments typed system/domain API
- Use: `lib/store/payments/payment_outcome_resolver.ex`
- Test: `test/store/subscriptions/renewal_collection_outcome_test.exs`

**Interfaces:**
- Produces:
  - `%RefreshFinancialOutcomeInput{}`
  - `refresh_financial_outcome_for_system/1`

- [ ] **Step 1: Write failing finality tests**

Assert:
- local PI failure alone does not create terminal collection failure;
- provider `requires_action` => active `requires_action`;
- provider exact success => `verified_success`;
- provider-certified terminal non-success => terminal collection outcome;
- reordered provider observations cannot regress success;
- `not_submitted` never affects financial outcome;
- refresh reads/reconciles the exact PI only.

- [ ] **Step 2: Reuse JC-287/282 provider evidence/finality path**

Do not implement provider-status precedence in Subscriptions.

- [ ] **Step 3: Map accepted Payments outcome to collection outcome**

Only accepted provider-finality evidence may create terminal financial non-success.

- [ ] **Step 4: Make identical refresh idempotent**

Terminal states remain monotonic.

- [ ] **Step 5: Commit**

`feat(subscriptions): reconcile renewal collection financial outcome`

---

### Task 7: Integrate collection lifecycle into renewal orchestration

**Files:**
- Modify: `lib/store/subscriptions/facade.ex`
- Modify: current `ProcessSubscriptionRenewalWorker` file discovered on branch
- Modify only as needed: `lib/store/subscriptions/renewal_attempt.ex`
- Tests: existing renewal worker/contract/cancellation/suspension suites plus JC-229 integration tests

**Interfaces:**
- Consumes Tasks 2–6.
- Produces current renewal orchestration:
  `bound RenewalAttempt -> active collection -> exact order/PI -> reservation -> dispatch/reconcile`.

- [ ] **Step 1: Write failing integration tests around the existing worker**

Cases:
- first due renewal;
- same job replay;
- mutable plan changes after binding;
- ambiguous provider result;
- requires_action;
- certified terminal failure then later dunning retry;
- physical vs nonphysical renewal.

- [ ] **Step 2: Replace mutable-state payment construction with bound-attempt construction**

The worker/facade may read mutable Subscription state for authority, status, retry due date, and physical availability only.

- [ ] **Step 3: Ensure one RenewalAttempt + one Order survives collection retries**

Do not turn collection retry into a new commercial renewal occurrence.

- [ ] **Step 4: Remove any success-authority dependence on legacy `RenewalAttempt.payment_intent_id`**

Preserve backward compatibility only where required for old data; new JC-229 path must use collection identity.

- [ ] **Step 5: Run existing renewal suites**

No regressions in contract binding, idempotency, dunning, or worker behavior.

- [ ] **Step 6: Commit**

`refactor(subscriptions): route renewal initiation through collection lifecycle`

---

### Task 8: Prove cancellation and suspension precedence across the new collection lifecycle

**Files:**
- Modify only if necessary: `lib/store/subscriptions/facade.ex`
- Modify only if necessary: `lib/store/payments/interlocks.ex`
- Test: extend `test/store/subscriptions/cancellation_renewal_authority_test.exs`
- Test: extend JC-265 suspension/recovery tests
- Test: JC-229 deterministic race file if clearer

**Interfaces:**
- Produces no new product policy; proves compatibility with accepted JC-281/265 behavior.

- [ ] **Step 1: Add deterministic cancellation-vs-dispatch barriers**

Prove:
- cancellation wins before claim => zero provider call;
- claim wins first => cancellation cannot relabel it `not_submitted`;
- late exact success after cancellation-first => payment truth + exactly one remediation refund + no reactivation/stock consumption.

- [ ] **Step 2: Add suspension barriers**

Prove:
- suspension before new dispatch => zero new provider mutation;
- no new collection ordinal while suspended;
- already-`may_have_been_reached` collection remains reconcilable;
- late exact success feeds current recovery semantics, preserving original renewal period boundaries.

- [ ] **Step 3: Verify cancellation/recovery lock ordering**

No deadlock-prone new lock-order inversion.

- [ ] **Step 4: Commit**

`test(subscriptions): prove collection cancellation and suspension precedence`

---

### Task 9: Define and test the exact JC-230 success handoff

**Files:**
- Modify/create the smallest internal typed result/event structure consistent with current architecture
- Tests: JC-229 integration tests

**Interfaces:**
- Produces exact success identity containing:
  - `order_id`
  - `renewal_attempt_id`
  - `collection_attempt_id`
  - `payment_intent_id`

It must **not** extend subscription periods or grant entitlements.

- [ ] **Step 1: Write failing test for exact handoff identity**

Prove all four IDs refer to the same exact collection/order/PI lineage.

- [ ] **Step 2: Implement typed handoff/result**

Do not invoke JC-230 effects.

- [ ] **Step 3: Add regression test that stale legacy `RenewalAttempt.payment_intent_id` cannot win**

- [ ] **Step 4: Commit**

`feat(subscriptions): expose exact renewal success identity`

---

### Task 10: Performance, migration, full validation, and PR evidence

**Files:**
- Modify: performance tests/notes as appropriate
- Modify: lifecycle/invariant docs only where current repository practice requires it
- PR body

**Interfaces:**
- Produces reviewable exact-head evidence.

- [ ] **Step 1: Measure current query counts**

Measure representative operations:
- first collection start;
- active replay;
- terminal->next ordinal;
- PI binding;
- dispatch claim;
- pre-submission fence;
- financial refresh.

Record actual current numbers. Do not reuse PR #127 historical counts.

- [ ] **Step 2: Review indexes and query plans where warranted**

Confirm no obvious N+1 or unbounded collection scan on hot path.

- [ ] **Step 3: Verify migration/snapshot alignment**

Run repository-standard migration generation/check commands and inspect exact generated SQL.

- [ ] **Step 4: Run targeted affected suites**

Include:
- JC-229 tests;
- renewal contract snapshot;
- renewal monotonicity;
- cancellation authority;
- suspension recovery;
- payment outcome resolver / payment interlocks;
- inventory reservation generation;
- worker tests.

- [ ] **Step 5: Run repository-required full checks**

At minimum the project’s normal strict checks (`mix check` or exact repo equivalent) and performance smokes required by current CI.

- [ ] **Step 6: Inspect exact diff**

```bash
git status --short
git diff <recorded-base-sha>...HEAD --stat
git diff <recorded-base-sha>...HEAD
```

Review for:
- accidental NewU-specific policy;
- JC-230 leakage;
- mutable plan/subscription commercial reads;
- provider I/O before durable dispatch claim;
- stale-generation access;
- terminal outcome regression;
- cancellation/suspension bypass;
- undocumented raw SQL;
- broad unrelated refactors.

- [ ] **Step 7: Open focused PR to `main`**

PR must include:
- exact base/head SHA;
- JC-229 acceptance mapping;
- NewU CER conformance matrix;
- lifecycle tables;
- DB invariants/indexes;
- concurrency/crash/replay evidence;
- “Performance & Scaling Review”;
- migration note;
- test commands/results;
- explicit statement that PR #127 was evidence only and JC-230 remains out of scope.

- [ ] **Step 8: Wait for exact-head CI and independent review**

Do not merge automatically. Human merge required.

## Final Stop Conditions

Stop only the affected portion and report the exact unresolved decision if:

1. a locked NewU CER requirement materially conflicts with current accepted Store semantics;
2. current main has changed the JC-281/282/265/287/327 contract in a way this plan does not cover;
3. provider API cannot expose exact verification/finality without a new cross-domain design decision;
4. physical inventory semantics cannot be serialized with the accepted exact-generation guard/release seams;
5. the migration would require destructive interpretation of existing production-like data;
6. JC-229 acceptance would require implementing JC-230 effects.

Do **not** stop for obsolete branch pins, JC-340 re-admission language, or PR #142 governance state.

## Completion Report Required From Agent

Return:

1. base SHA and head SHA;
2. branch and PR;
3. exact files changed;
4. CER conformance table;
5. lifecycle/state changes;
6. DB constraints/indexes/migration summary;
7. deterministic race/crash tests added;
8. targeted + full validation commands/results;
9. query-count/performance evidence;
10. remaining risks/blockers;
11. explicit confirmation that no JC-230 renewal application was implemented;
12. explicit confirmation that provider construction uses bound RenewalAttempt commercial identity.

## Execution record

- Branch: `jc-229-renewal-collection-lifecycle`
- Exact base SHA: `c5f2a7a430d7932e4106400f7863316c79fd88e7` (`origin/main` after fetch)
- Linear: JC-229 is `In Progress`; JC-228, JC-281, JC-282, JC-287, JC-265, and JC-327 are `Done`.
- CER evidence: the conformance matrix in the design notes uses only confirmed NewYou acceptance requirements recorded on JC-229. `CER-UPD-001` is excluded because Linear marks it as accepted working input, not Product Law.
- Baseline validation: `devcore-project run test -- mix test test/store/subscriptions/sbh_10_03_renewal_contract_snapshot_test.exs test/store/subscriptions/renewal_attempt_monotonicity_test.exs test/store/subscriptions/cancellation_renewal_authority_test.exs test/store/subscriptions/suspension_access_convergence_test.exs test/store/payments/payment_outcome_resolver_test.exs test/store/orders/inventory_reservation_generation_test.exs` passed with 84 tests and 0 failures.
