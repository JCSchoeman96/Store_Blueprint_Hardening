# JC247-C purchased cancellation policy implementation plan

> Runtime implementation is authorized by the merged JC247-C runtime-authorization amendment. Execute this already-approved plan with strict TDD and without semantic drift. Human merge remains required.

**Goal:** Make cancel-now access follow the purchased policy on the exact funded PlanRevision while preserving target-neutral scheduling and existing F1/F2 execution.

**Architecture:** The Subscription source transaction derives and persists the immutable AccessEffect target under the existing Subscription lock. The transaction returns the exact effect ID and disposition for post-commit F1 or F2 dispatch. F0.5 independently derives the same target from the locked Subscription and its exact funded revision.

**Tech stack:** Elixir, Phoenix, Ash 3.x, Ecto, PostgreSQL, Oban recovery already present.

---

## Base and preconditions

- Accepted base SHA: `b877e0c0b50fd7171c16a3a6ba4b6151681ce49c`.
- Accepted base tree: `3f2c44f28419dcb63761e105ea90e355db0eab4b`.
- JC247-A and JC247-B are accepted. JC247-B post-merge CI is already accepted; do not rerun it or reopen PR #196 for this plan.
- Before database-backed tests, run `devcore-project doctor`. Run tests through `devcore-project run test -- <command>`. Do not copy local database credentials into commands.
- Keep payment precedence, source lock order, F0/F0.5 currentness, F1/F2 execution, and post-commit projection behavior unchanged.

## File map

| File | Responsibility |
|---|---|
| `lib/store/subscriptions/access_effect_target_order.ex` | Validate and derive classified canceled source targets from immutable Subscription and funded PlanRevision evidence. |
| `lib/store/subscriptions/facade.ex` | Establish cancel-now and scheduled-boundary targets in their source transactions, return exact effect identity and internal email evidence, dispatch the exact effect after commit, and remove the legacy direct revoke. |
| `lib/store/comms/domain.ex` | Let cancellation callers pass immutable membership evidence into the existing access-ended outbox path without reading mutable Plan data. Keep the existing recipient, template, and outbox behavior. |
| `test/store/subscriptions/access_effect_target_order_test.exs` | Pure derivation cases and fail-closed evidence checks. |
| `test/store/subscriptions/access_effect_target_order_reconciliation_test.exs` | F0.5 independently rederives, covers, and repairs canceled targets. |
| `test/store/subscriptions/jc247_c_acceptance_matrix_test.exs` | Source transition, effect ID, access policy, replay, and history proofs. |
| `test/store/subscriptions/cancellation_renewal_authority_test.exs` | Preserve JC281/JC265 payment and cancellation precedence while checking AccessEffect outcomes. |
| `test/store/subscriptions/access_effect_target_order_contention_test.exs` | Producer-first and reconciler-first PostgreSQL lock proofs. |
| `test/store/subscriptions/sbh_40_02_durable_period_boundary_terminalization_test.exs` | Scheduled-boundary and late paid cancellation handoff coverage. |
| `test/store/comms/domain_test.exs` | Existing access-ended enqueue behavior with caller-proven membership evidence and no mutable Plan lookup. |

No worker change is expected because scheduled-boundary production is owned by the facade. Do not modify Entitlements production code, schemas, migrations, snapshots, indexes, public executor APIs, or the Comms architecture. The Comms change is limited to the existing enqueue path.

## Task 1: Derive cancel-now targets from exact funded evidence

**Files:** `lib/store/subscriptions/access_effect_target_order.ex`; `test/store/subscriptions/access_effect_target_order_test.exs`.

- [ ] **RED:** Add focused tests for `derive_cancel_now_target/2`. Cover `:remove_immediately`; `:keep_until_period_end` within the half-open funded interval with a pair; the same policy with nil/nil composition; and keep policy outside the interval. Assert every target field, including provenance, `valid_from_at`, and `valid_until_at`.
- [ ] **RED:** Add failure tests for wrong Subscription status, wrong cancellation reason, missing `canceled_at`, missing funded revision ID, mismatched passed revision ID, missing or reversed period bounds, unsupported policy value, and partial entitlement pair. Include the exact end boundary and prove `canceled_at == current_period_end_at` is NON_EFFECTIVE.
- [ ] Run `devcore-project run test -- mix test test/store/subscriptions/access_effect_target_order_test.exs`. Confirm the new cases fail for the missing or incorrect derivation before production changes.
- [ ] **Minimal GREEN:** Add the narrow target derivation helper. Read policy and composition from the passed PlanRevision only. Do not load SubscriptionPlan or change F1/F2.
- [ ] Rerun the same focused command and require PASS. Review the helper against every frozen interval and nil/nil rule in the authority document.

## Task 2: Make F0.5 canceled-source derivation policy-aware

**Files:** `lib/store/subscriptions/facade.ex`; `lib/store/subscriptions/access_effect_target_order.ex`; `test/store/subscriptions/access_effect_target_order_reconciliation_test.exs`.

- [ ] **RED:** Add an unresolved `user_request` canceled candidate whose exact funded revision selects keep-until-period-end. Assert the same complete EFFECTIVE target is `already_covered`. Add a mismatch case and assert F0.5 repairs or supersedes it with the current complete target. Add remove-immediately and nil/nil cases.
- [ ] **RED:** Add a `canceled_period_end` candidate with no need to load policy and assert NON_EFFECTIVE for both policy values. Add unknown reason, missing `canceled_at` on `user_request`, missing current revision or missing revision row, and invalid period evidence cases that fail closed. Seed a candidate with mismatched revision provenance and assert F0.5 repairs it from the exact locked source instead of trusting the candidate. Preserve terminal-candidate, newer-effect, cursor, and currentness behavior.
- [ ] Run `devcore-project run test -- mix test test/store/subscriptions/access_effect_target_order_reconciliation_test.exs test/store/subscriptions/access_effect_target_order_test.exs`. Confirm the new canceled cases fail before production changes.
- [ ] **Minimal GREEN:** Branch the current-target derivation by classified cancellation reason. Load only the exact `current_plan_revision_id` for `user_request`. Keep scheduled-boundary derivation policy-free. Leave candidate selection, source-first locking, currentness checks, cursor, counts, and executor behavior unchanged.
- [ ] Rerun both focused files and require PASS. Review that the source query is a primary-key lookup and that unknown reasons never fall back to status-only NON_EFFECTIVE.

## Task 3: Persist cancel-now policy targets atomically and remove the legacy writer

**Files:** `lib/store/subscriptions/facade.ex`, `lib/store/comms/domain.ex`; `test/store/subscriptions/jc247_c_acceptance_matrix_test.exs`, `test/store/comms/domain_test.exs`.

- [ ] **RED:** Add user and admin source-transition cases from `active`, `past_due`, and `suspended`. For remove-immediately, assert canceled status, `user_request`, NON_EFFECTIVE target, exact F2 effect ID, and `canceled_now`. Seed a non-nil dunning pointer, assert it is cleared in the source transaction, and keep the RenewalAttempt row as audit history.
- [ ] **RED:** Add keep-policy cases from active, past_due, and suspended for pair and nil/nil targets where the funded interval remains. Assert exact revision identity, exact period boundaries, terminal canceled commerce state, and EFFECTIVE F1 convergence through the stored period end. Add an outside-interval case and assert NON_EFFECTIVE F2. Assert the legacy direct revoke cannot revoke the F1 target after dispatch.
- [ ] **RED:** Assert EFFECTIVE keep-until-period-end never queues the access-ended message. For NON_EFFECTIVE cancel-now, assert the existing membership outbox is queued only when the exact funded PlanRevision has `entitlement_kind == :membership_access`, the established effect is NON_EFFECTIVE, and exact F2 returns `{:ok, :applied}` or `{:ok, :applied_projection_pending}`. Assert a non-membership revision does not queue the message even when mutable SubscriptionPlan says membership. Assert an F2 error, `:noop`, or `:superseded` result queues no message. Verify the transaction carries `effect_id`, disposition, and the membership boolean derived from the already-loaded revision. Verify the existing Comms enqueue path does not fetch mutable SubscriptionPlan for this decision or subject; preserve its recipient, template, and outbox idempotency, using a generic subject if it otherwise needs mutable Plan name/key.
- [ ] **RED:** Add a source-admission test proving a `pending` Subscription cannot enter the purchased cancellation producer. The private resource action accepts this state, but current customer/admin capabilities exclude it and accepted JC247-C semantics cover only funded active, past_due, and suspended sources.
- [ ] **RED:** Assert the source transaction establishes one AccessEffect and returns its exact ID plus disposition. Assert a repeated cancel-now request creates no second policy effect and never queries the latest effect after commit.
- [ ] Run `devcore-project run test -- mix test test/store/subscriptions/jc247_c_acceptance_matrix_test.exs test/store/subscriptions/sbh_20_02_renewal_immediate_cancellation_test.exs test/store/subscriptions/cancellation_renewal_authority_test.exs`. Confirm the new cases fail before production changes.
- [ ] **Minimal GREEN:** Under the existing Subscription-first source lock and payment-precedence checks, validate the supported source state, perform the existing cancellation update, fetch the exact funded PlanRevision by primary key, derive the target, establish or reuse the exact effect in the same transaction, and return its exact ID and disposition.
- [ ] **Minimal GREEN:** After commit, dispatch EFFECTIVE to existing F1 and NON_EFFECTIVE to existing F2 by the returned ID. Keep executor failure independent of committed cancellation truth. Remove the direct call to `revoke_subscription_entitlements_for_system/2`.
- [ ] **Minimal GREEN:** Return `effect_id`, disposition, and `membership_access_ended_email?` from the source transaction. Derive the boolean from the exact funded PlanRevision already loaded for target derivation. After exact F2 success, queue the existing membership outbox only when the flag is true and the effect is NON_EFFECTIVE. Update only the existing Comms enqueue path to accept that evidence and avoid mutable Plan reads. Keep the recipient, template, and outbox idempotency. Do not add an email field to AccessEffect, schema, deferred email, template, worker, or Comms architecture.
- [ ] Rerun the focused cancellation and acceptance tests and require PASS. Review exact transaction boundaries, dunning pointer clearing, no mutable Plan read for policy, and no latest-effect lookup.

## Task 4: Preserve scheduling neutrality and dispatch scheduled-boundary F2

**Files:** `lib/store/subscriptions/facade.ex`, `lib/store/comms/domain.ex`; `test/store/subscriptions/jc247_c_acceptance_matrix_test.exs`, `test/store/subscriptions/sbh_40_02_durable_period_boundary_terminalization_test.exs`, `test/store/comms/domain_test.exs`.

- [ ] **RED:** Add schedule, schedule replay, rescind, and rescind replay assertions. Status and current access target remain unchanged, and no AccessEffect is created by intent or rescission.
- [ ] **RED:** Extend direct due-worker boundary coverage for both `access_on_cancel` values. Assert active becomes canceled with `canceled_period_end`, `canceled_at` equals the exact funded boundary, the NON_EFFECTIVE effect ID is returned internally, F2 receives that ID after commit, the grant reason is `canceled_period_end`, and the dunning pointer is nil. Assert the public sweep result keeps exactly its current keys and exposes no effect ID.
- [ ] **RED:** Extend late paid reconciliation at the scheduled boundary. Assert it preserves the accepted payment result, establishes the same exact NON_EFFECTIVE boundary target inside the owning source transaction, and dispatches that exact F2 ID only after the outer transaction commits.
- [ ] **RED:** Assert the scheduled-boundary membership email uses exact funded PlanRevision membership evidence and queues only after exact F2 returns `{:ok, :applied}` or `{:ok, :applied_projection_pending}`. F2 error, `:noop`, and `:superseded` queue no new message in the direct path. Assert scheduled-notification replay cannot bypass the applied-effect check or read mutable Plan to determine membership.
- [ ] Run `devcore-project run test -- mix test test/store/subscriptions/jc247_c_acceptance_matrix_test.exs test/store/subscriptions/sbh_40_02_durable_period_boundary_terminalization_test.exs`. Confirm the new dispatch assertions fail before production changes.
- [ ] **Minimal GREEN:** Return the boundary effect ID, disposition, and internal membership flag from the transaction helper. Propagate them internally through the due-worker facade and late-reconciliation outcome, but preserve the public `run_due_scheduled_cancellations_for_system/1` result map (`due_count`, `canceled_count`, `failed_count`, `cursor`, `now`) without IDs or new fields. Dispatch existing F2 after each outer commit, then enqueue the existing scheduled-boundary access-ended message only after durable F2 application and when the immutable membership flag is true. Gate scheduled-notification replay on the exact current boundary effect being durable-applied. Keep schedule and rescind target-neutral and do not read `access_on_cancel` at the boundary.
- [ ] Rerun the focused scheduled-boundary and acceptance tests and require PASS. Review duplicate-worker replay, post-commit notifications, email behavior, and transaction ownership.

## Task 5: Prove payment precedence and F0.5 lock ordering

**Files:** `test/store/subscriptions/cancellation_renewal_authority_test.exs`; `test/store/subscriptions/access_effect_target_order_contention_test.exs`; `test/store/subscriptions/charged_renewal_access_effect_race_test.exs` only if existing JC265 coverage needs a narrow assertion.

- [ ] **RED:** Extend JC281 payment-first and cancellation-first tests to assert the unchanged commercial outcomes and the resulting current access target. Extend JC265 cancel-now versus paid-recovery/access-sync coverage so the winning source result owns the exact target and stale execution cannot change the final grant set.
- [ ] **RED:** Extend the current F0.5 contention harness for cancellation producer first and reconciler first. Use separate real PostgreSQL connections and existing blocker evidence. Do not use sleeps or add production test hooks.
- [ ] Run `devcore-project run test -- mix test test/store/subscriptions/cancellation_renewal_authority_test.exs test/store/subscriptions/access_effect_target_order_contention_test.exs test/store/subscriptions/charged_renewal_access_effect_race_test.exs`. Confirm the added access assertions fail before production changes.
- [ ] **Minimal GREEN:** Change only the narrow source handoff or target derivation bug exposed by a failing proof. Do not alter JC281/JC265 payment precedence, source lock order, F0 currentness, F1/F2 core, or recovery architecture.
- [ ] Rerun each race file and require PASS. Inspect PostgreSQL blocker evidence and verify both lock-arrival orders reach the same target dictated by the committed source truth.

## Task 6: Complete acceptance and review

**Files:** Focused tests listed above; both JC247-C documents only if test evidence exposes a documentation error.

- [ ] Verify the full acceptance matrix in the authority document: target-neutral schedule/rescind; scheduled boundary F2; cancel-now remove for all supported source states; keep pair and nil/nil for all supported source states; outside-interval NON_EFFECTIVE; fail-closed evidence; replay; historical grants; dunning identity; and exact executor IDs.
- [ ] Run `devcore-project doctor` before database-backed verification. Then run `devcore-project run test -- mix test test/store/subscriptions` and require PASS. Do not weaken or skip a required check.
- [ ] Run `devcore-project run test -- mix format --check-formatted`, `devcore-project run test -- mix compile --warnings-as-errors`, `devcore-project run test -- mix check.static`, and `devcore-project run test -- mix dialyzer`. Run `git diff --check` and inspect generated schema/snapshot state. No schema or migration change is allowed by this authority.
- [ ] Complete the "Performance & Scaling Review" and "Runtime Resource Safety Review" in the implementation PR. Measure query count and Subscription lock time for the exact PlanRevision lookup. Confirm no scan, new index, cache, extra source lock, or N+1 fan-out. Keep F0.5 pages bounded and report any unmeasured dimension honestly.
- [ ] Review the exact base SHA, head SHA, diff, changed files, cancellation lifecycle, PostgreSQL invariants, payment precedence, replay, crash recovery, security, and performance. Stop if a schema, migration, Entitlements, F1/F2 core redesign, term-end, JC300, or new public executor change becomes necessary. Human merge is required.

## Acceptance matrix

1. Scheduling and rescission create no AccessEffect, including replay.
2. Scheduled boundary produces one NON_EFFECTIVE `canceled_period_end` target for both policy values and post-commit F2 receives its exact ID.
3. Cancel-now remove-immediately from active, past_due, and suspended produces a terminal Subscription, exact NON_EFFECTIVE effect, F2 `canceled_now`, and cleared dunning pointer.
4. Cancel-now keep-until-period-end within the funded interval produces EFFECTIVE pair or nil/nil target with exact revision and validity evidence; Subscription remains canceled.
5. Keep-until-period-end outside the funded interval produces NON_EFFECTIVE and exact F2.
6. Missing `canceled_at`, missing or mismatched funded revision, unsupported cancellation reason, invalid period bounds, and incomplete pair fail closed.
7. F0.5 independently derives canceled targets, returns `already_covered` for equal complete evidence, repairs a different current target, and preserves stale/terminal replay semantics.
8. The exact effect ID reaches the correct executor after commit. No path queries the newest effect after commit.
9. The legacy cancel-now direct revoke is absent, and F1 keep access remains effective through the funded boundary.
10. EFFECTIVE keep-until-period-end never queues an access-ended email. Cancel-now queues the existing membership message only when exact funded `PlanRevision.entitlement_kind` is `:membership_access`, the established effect is NON_EFFECTIVE, and exact F2 durably applies (`:applied` or `:applied_projection_pending`). F2 failure, `:noop`, or `:superseded` queues no message. Mutable `SubscriptionPlan` is not read for email eligibility. Scheduled-boundary email follows the same immutable membership evidence and queues only after durable F2 application. The email does not decide access correctness.
11. Inactive historical grants retain their prior reason. Other source grants remain unchanged.
12. JC281 and JC265 payment precedence remains unchanged in payment-first and cancellation-first schedules.
13. F0.5 and the cancellation producer serialize in both deterministic PostgreSQL lock-arrival orders.
14. The scheduled sweep public result keys remain `due_count`, `canceled_count`, `failed_count`, `cursor`, and `now`; effect IDs and email evidence remain internal.
15. The email is not correctness authority. JC247-C does not make F2 application and outbox enqueue one atomic transaction. A crash after F2 commits but before outbox enqueue can omit this best-effort communication. Closing that gap requires separate Comms/outbox authority and is outside JC247-C.
16. No migration, schema change, Entitlements change, new public executor, or new worker architecture is introduced.

## Performance & Scaling Review

The only new policy read is an exact `PlanRevision` primary-key lookup for cancel-now and for each bounded F0.5 `user_request` candidate. Reuse the funded revision already loaded in each cancellation source transaction for target derivation and membership email evidence, including scheduled-boundary email eligibility. Do not load mutable `SubscriptionPlan` for email selection or subject text. Keep the existing recipient, template, and outbox idempotency; use a generic subject if the current subject needs mutable Plan name/key. The current cancel-now source flow does not retain the funded revision, so fetch it by exact ID. Do not add a relationship scan. This adds at most one fixed revision query inside the existing warm cancellation transaction, no second transaction, no new correctness lock, and no new index. The scheduled-notification replay must check membership and durable F2 application through its existing bounded candidate query or a bounded batch query; do not add a per-subscription lookup loop or an unbounded scan. Measure its query count and confirm no N+1. Measure transaction query and lock-time deltas. `CORRECTNESS_AUTHORITY=PostgreSQL`; `CACHE_CORRECTNESS_ROLE=NONE`. Keep exact F1/F2 dispatch outside the source transaction after commit. Outbox enqueue remains post-commit, and email failure does not change cancellation truth. Oban uniqueness and recovery remain unchanged.

## Runtime Resource Safety Review

No process, mailbox, cache, or resource lifecycle is added. Measure cancellation transaction duration with the exact revision read. Confirm F0.5 continues to hold at most its bounded candidate page and releases each transaction before moving on. Measure repeated bounded reconciliation only when claiming convergence or no accumulation; one run is diagnostic. Mark other relevant dimensions UNMEASURED until evidence exists.

## Stop conditions

- `MAIN_MOVED` or accepted tree mismatch before implementation starts.
- `AUTHORITY_CONTRADICTION` or unknown cancellation reason that cannot be classified.
- Canceled-at or funded PlanRevision evidence is not durable after the transition.
- F1 source admission, F2 canceled mapping, Entitlements, or schema would need core redesign.
- Migration, new public executor, term-end behavior, JC300 cutover, new payment precedence, provider behavior, or new worker architecture is required.
- The legacy direct revoke cannot be removed or safely gated at the shared facade path.
- Avoiding a mutable Plan read in the existing cancellation email enqueue path would require a broader Comms redesign.
- A deterministic payment or F0.5 race contradicts the accepted source ordering.

## Authorization boundary

```text
IMPLEMENTATION_AUTHORIZED=YES
MERGE_AUTHORIZED=NO
```
