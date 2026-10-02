# Phase 27 — Variable Subscriptions

## GOAL

Implement the Phase 27 variable-subscription spine without violating the existing Orders-as-truth boundary:
- keep variant + plan coupling explicit through `VariantSubscriptionPlan`
- lock renewal pricing on the subscription contract
- prevent duplicate membership-style purchases while checkout is still pending
- move renewal execution off the single batch worker path with jittered per-subscription jobs

## LINKS CONSULTED

- `AGENTS.md`
- `docs/phases/phase_26_simple_subscriptions.md`
- `docs/phases/phase_27_variable_subscriptions.md`
- `docs/phases/phase_27a_membership_subscriptions_entitlements.md`
- `docs/phases/phase_28_production_readiness_release_checklist.md`
- `docs/governance/performance_scaling.md`
- `docs/governance/subscriptions_rollout_rollback.md`
- `docs/governance/enforcement_gates.md`

## DECISIONS / PINS

1. `Store.Subscriptions.VariantSubscriptionPlan` is the canonical Phase 27 variant-plan registry; no duplicate `VariantPlan` resource is introduced.
2. Multiple active plans per variant are allowed in Phase 27; the old one-active-plan-per-variant uniqueness index is removed by migration.
3. Subscription renewals charge locked `renewal_amount_minor` + `renewal_currency`, not mutable catalog pricing.
4. Queued plan/variant changes snapshot pending renewal price at request time via pending renewal amount/currency fields.
5. Renewal fan-out uses deterministic jitter derived from binary UUID state, not true random jitter.
6. Membership duplicate blocking uses current domain evidence that exists today:
   - open subscriptions with the same `membership_key`
   - open checkout drafts tied to pending-payment orders for the same user and membership plan
7. Subscription management remains inline on the existing account/admin detail routes; no dedicated manage routes are introduced.
8. Stripe payment-method updates use inline SetupIntent + Elements, not hosted Checkout redirect.
9. Current physical-renewal behavior and its unresolved safety gaps:
   - catalog and variant-plan blockers are retry-suppressed hard failures
   - inventory is reserved before Stripe and released on known failure paths, but the current `requires_action` path can release a hold while payment may still succeed
   - renewal preparation re-quotes shipping and writes the quote to the Order; a surge circuit breaker limits drift, while the current retry path can still re-quote or rewrite finalized totals
   - shipping and tax are not declared bound at checkpoint B. Under the blocked v0.1.27 target, retries after Order finalization must reuse durable Order shipping/tax evidence rather than re-quote or rewrite it
   - the accepted main SBH-10-04 amendment defines bounded cross-domain contracts for later admitted work; SUBS v0.1.28 continues to record SBH-10-04 as blocked and this merge does not change runtime behavior

## PLAN

1. Extend the `Subscription` contract and backfill pricing/dunning fields.
2. Add membership duplicate-purchase interlocks in cart add and checkout start.
3. Split the due-renewal worker into a due-tick worker and a per-subscription worker.
4. Add Phase 27 governance notes and update the subscriptions docs-sync gate so it validates Phase 27/27A notes instead of pinning Phase 26 forever.

## DONE

- Added Phase 27 subscription contract fields:
  - `variant_id`
  - `quantity`
  - `renewal_amount_minor`
  - `renewal_currency`
  - `membership_key`
  - `pending_variant_id`
  - `pending_subscription_plan_id`
  - `pending_renewal_amount_minor`
  - `pending_renewal_currency`
  - `change_effective_at`
  - `dunning_attempt_count`
  - `next_retry_at`
- Added migration `20260308090000_phase_27_subscription_contract_pricing_snapshots.exs` with backfill and new indexes/constraints.
- Added migration `20260308173000_phase_27_allow_multiple_active_variant_plans.exs` to drop the stale one-active-plan-per-variant uniqueness constraint.
- Updated subscription creation and renewal paths to populate/reset locked pricing and bounded dunning metadata.
- Added membership duplicate guards in:
  - `Store.Carts.Facade.add_item_for_user/3`
  - `Store.Checkout.start_from_cart/3` through `create_checkout!/3`
- Split renewal execution:
  - `Store.Workers.RunDueSubscriptionRenewalsWorker` now acts as the due tick
  - `Store.Workers.ProcessSubscriptionRenewalWorker` processes one subscription renewal
  - tick fan-out uses deterministic `schedule_in` jitter and unique per-subscription renewal args
- Added Stripe-first virtual checkout renewal spine:
  - mixed-cart initial checkout now requests saved-card-for-off-session semantics when any subscription line exists
  - zero-total subscription checkout switches Stripe payload generation to setup mode
  - renewal processing creates a real renewal order + local payment intent before requesting an off-session charge
  - Stripe off-session payloads include `local_intent_id`, `order_id`, `renewal_attempt_id`, `subscription_id`, and `renewal_key`
- Added webhook race protection:
  - canonical receipts now accept recurring events with no checkout session id
  - webhook payment-intent lookup now falls back to Stripe metadata `local_intent_id`
  - webhook hydration persists Stripe customer/payment-method refs onto the local `payment_intent`
- Added webhook-driven renewal completion:
  - paid renewal orders enqueue `Store.Workers.ReconcilePaidSubscriptionRenewalWorker`
  - renewal reconciliation advances the period once and promotes pending locked pricing/plan/variant snapshots
- Added initial subscription payment-method linkage inside subscription creation:
  - `EnsureSubscriptionsForPaidOrderWorker` now upserts `StoredPaymentMethod` from the successful local `payment_intent`
  - subscriptions are created with stored payment method linkage in the same transaction
- Added SCA/auth-required handling:
  - off-session `requires_action` marks the subscription `:past_due`
  - automatic blind retry is suppressed until grace expiry
  - a `payment_authentication_required` comms outbox path is available with the hosted action URL
- Added boundary-change/account/admin surfaces:
  - storefront product detail now exposes variant plan options and shareable `subscription_plan_key` state
  - account/admin subscription detail pages now support queued plan change, queued variant change, cancel now / cancel at period end, and inline Stripe card update
  - setup-intent webhooks update stored payment methods and immediately retry past-due subscriptions

## NEXT

1. Add broader governance coverage and Phase 27/27A closure gates.
2. Add end-to-end Stripe recurring coverage once a runnable host Mix toolchain is restored in this shell.

## BLOCKERS

- Local `mix` tooling in this shell currently resolves to missing `mise` shims, so compile/test verification for the new Stripe/virtual-checkout slice requires either restored host tooling or a working Elixir container path.

## COMMANDS RUN

- `bd dolt test`
- `bd status`
- `bd ready`
- `bd create ...`
- `bd update ... --claim`
- `bd close ...`
- `mix deps.get`
- `mix compile`
- `mix test test/store/governance/subscriptions_uniqueness_test.exs test/store/subscriptions/facade_test.exs`
- `mix test test/store/workers/subscriptions_run_due_renewals_worker_test.exs test/store/carts/facade_test.exs test/store/checkout/domain_test.exs test/store/subscriptions/facade_test.exs`

## GATES

- Focused subscription compile/tests: PASS
- Membership interlock cart/checkout tests: PASS
- Renewal tick/process worker tests: PASS
- Entitlement cache + membership comms focused tests: PASS

## PERFORMANCE & SCALING REVIEW

- Hot paths:
  - due-subscription selection
  - renewal fan-out enqueue
  - membership duplicate guard in cart/checkout
- Query shape:
  - due-subscription reads remain indexed on `(status, next_renewal_at)` with bounded `limit`
  - past-due retries are keyed off `(status, next_retry_at)`
  - membership duplicate guard checks indexed subscription rows and open checkout draft/order/cart joins
- Herd protection:
  - renewal fan-out schedules one job per subscription with deterministic jitter over a one-hour window
  - per-subscription renewal processing is isolated behind its own worker boundary
- Idempotency:
  - `RenewalAttempt` unique key remains the billing-period anchor
  - per-subscription renewal jobs are unique on worker args (`subscription_id + renewal_key`)
- Remaining risk:
  - physical renewals add one shipping quote call plus one reservation call per processed subscription
  - due-tick scans for past-due subscriptions should use the new partial index on unsuppressed retries

## SBH-20-01 — Optimistic Aggregate-Version Foundation

### Links consulted

- `AGENTS.md`
- `docs/governance/performance_scaling.md`
- `docs/hardening/subscriptions/SUBSCRIPTION_HARDENING_MASTER_REGISTER.md`
- `lib/store/subscriptions/subscription.ex`
- `lib/store/support/governance/transition_state.ex`
- `priv/resource_snapshots/repo/subscriptions/20260923141655.json`

### Decisions / pins

1. `Subscription.aggregate_version` is durable metadata initialized to `1` for existing rows. It does not claim historical mutation counts.
2. All eight material Subscription update actions invoke one Subscription-local change that delegates to Ash optimistic locking after action changes are known. It skips genuine attribute no-ops; `TransitionState` keeps its lock disabled so successful material writes increment once.
3. Facade stale updates map structurally recognized Ash `StaleRecord` failures to the existing `STALE_RECORD` code and reload the current row. They return the conflict without replaying the old payload because resolving these stale commands would require later race policy.
4. RenewalAttempt identity, claims, and race precedence remain unchanged.

### Plan

1. Add deterministic stale-writer, same-state, non-state, and two-writer tests before the resource change.
2. Add the Subscription version field, shared action lock, generated migration, and snapshot.
3. Normalize stale Subscription update errors locally and verify focused suites and project gates.

### Performance & Scaling Review

- Hot paths: renewal reconciliation, dunning updates, and payment-method reference updates use the Subscription write path. Account and admin management writes are warm.
- Database query count and N+1 risk: successful writes retain one version-checked update. Facade conflicts add one primary-key reload; they load no relationships, so there is no N+1 path.
- Indexes: the existing Subscription primary key supports version-checked updates and conflict reloads. No aggregate-version index is needed.
- Caching: PostgreSQL remains authoritative. This change adds no cache, TTL, invalidation, or stampede path.
- Oban uniqueness and idempotency: renewal job and RenewalAttempt behavior is unchanged. The existing renewal key remains the idempotency anchor.
- Telemetry and logging: no new telemetry or logging was added. Stale facade writes return `STALE_RECORD`; existing renewal telemetry remains unchanged.

## SBH-10-06 — Durable ContractChange / Future-Target Foundation

### Links consulted

- `AGENTS.md`
- `docs/governance/performance_scaling.md`
- `docs/governance/subscription_scheduling_terms.md`
- `docs/hardening/01_domain_map.md`
- `docs/hardening/subscriptions/SUBSCRIPTION_HARDENING_MASTER_REGISTER.md` v0.1.24
- `lib/store/subscriptions/plan_revision.ex`
- `lib/store/subscriptions/subscription.ex`
- `lib/store/subscriptions/facade.ex`
- `test/store/subscriptions/optimistic_aggregate_version_test.exs`

### Decisions / pins

1. `ContractChange` stores the exact `PlanRevision`, complete target variant and quantity, target amount/currency, effective boundary, instruction kind, predecessor/superseded identities, lifecycle state, and deterministic `ordering_version`.
2. `ordering_version` uses the next `Subscription.aggregate_version`. A PostgreSQL row lock checks the loaded version before the transaction changes a target; the Subscription action then performs the existing optimistic version update. The transaction supersedes the prior target, creates the new record, updates the current pointer, and writes compatibility projections together.
3. Plan-only and variant-only instructions derive untouched dimensions from the current authoritative ContractChange when one exists, otherwise from the live Subscription. Each instruction applies only its requested dimension and resolves a currently eligible revision for the resulting plan through `PlanRevision.get_effective_for_plan`; target amount and currency come from that immutable revision. A retired predecessor revision is never carried into a new instruction.
4. `RENEW_UNCHANGED` records the exact current live revision, even when it is retired, with the current Subscription's live variant, quantity, amount, and currency. It never reactivates an older ContractChange.
5. Historical `pending_*` values receive no guessed ContractChange backfill. New queue operations write ContractChange first; renewal blocks both a current queued ContractChange and unresolved legacy pending projections before attempt/order/payment/provider work. Paid reconciliation also fails closed when a current ContractChange or unresolved legacy projection exists; SBH-10-05 still owns charged-contract application.
6. Existing Subscription cancellation clears the current pointer and cancels an unbound queued target in the same transaction. Rescission writes a new `RENEW_UNCHANGED` instruction. No scheduled-cancellation redesign or RenewalAttempt binding is included.
7. Paid-reconciliation replay checks the fetched attempt's terminal state before loading current Subscription future-target authority. A succeeded attempt returns the existing noop result even if a ContractChange was queued after its successful reconciliation; attempts still requiring reconciliation remain fail-closed.

### Plan

1. Add the focused red proofs for exact revision retention, fail-closed selection, supersession, dimension scoping, cancellation/rescission, pointer lookup, renewal and reconciliation guards, stale writers, and PostgreSQL queued-target uniqueness.
2. Add the Subscription-owned `ContractChange` resource and domain registration. Generate the resource migration and Ash snapshot, plus the nullable Subscription pointer with `ON DELETE RESTRICT` and its task-specific snapshot in the same migration.
3. Implement queue, supersede, cancel, current-target lookup, and rescission in one PostgreSQL transaction per mutation. Normalize stale Subscription versions to `STALE_RECORD`.
4. Add the pre-provider renewal guard and paid-reconciliation guard without changing RenewalAttempt or Payments/Orders behavior.
5. Run the focused Subscription suites, migration check, format check, and `mix check`; record exact results before opening the draft PR.

### Performance & Scaling Review

- Hot path: renewal checks current-target authority before creating a RenewalAttempt, order, payment intent, or provider request. A pointer or unresolved pending projection fails closed from the already-loaded Subscription row. When both are absent, an indexed queued-target lookup detects an orphaned/inconsistent current target before provider work. No cache is added.
- Warm path: each queue command reads the Subscription and current target. When a current ContractChange exists, it also loads that target's exact PlanRevision to recover its plan dimension; it then reads the requested plan/variant, active attachment, and one exact EFFECTIVE revision for the resulting plan. Its transaction adds one aggregate row lock, up to one current-target lookup, one latest-instruction lookup, and two writes for the first target or three when superseding. Cancellation adds one row lock, up to one current-target lookup, and at most two writes. Predecessor lookup sorts by the unique `(subscription_id, ordering_version)` index. No loop or per-row N+1 load is required.
- Cold path: the immutable ContractChange rows remain in PostgreSQL. Foreign keys restrict deletion of the Subscription, PlanRevision, Variant, or linked ContractChange history.
- Indexes: unique `(subscription_id, ordering_version)`, a partial unique `(subscription_id)` for `status = 'queued'`, and lookup indexes for Subscription, target revision, target variant, and predecessor/superseded links.
- Caching: no ETS/Redis cache, TTL, invalidation, or stampede path is added. PostgreSQL remains authoritative.
- Oban: renewal job uniqueness and `RenewalAttempt` idempotency do not change. A queued future target prevents renewal work before Oban processing can initiate provider work.
- Telemetry/logging: existing renewal telemetry remains in place. No new event is needed for the bounded target foundation.

### Verification record

- Baseline passed before production edits; see task execution record for exact counts and pre-existing warnings.
- Baseline before production edits: facade 16/0, plan revision 27/0, SBH-10-02 binding 11/0, aggregate version 8/0, replay concurrency 1/0, and `mix check` 668/0. Migration generation check and `git diff --check` passed.
- New focused ContractChange suite: 16 tests, 0 failures after the review fixes. It includes stale aggregate-version writers and two unboxed PostgreSQL writers competing for the partial unique current-target index.
- Final focused suite set after the review fixes: 79 tests, 0 failures. Final `mix check`: 684 tests, 0 failures; Credo checked 5,610 functions with no issues, and security scan found no vulnerabilities.
- `mix ash_postgres.generate_migrations --check`, `mix format --check-formatted`, and `git diff --check` passed.
- Existing warnings: Ecto reports the historical out-of-order migration `20260902123000` after this task's migration `20260923202226`; test compilation reports unused optional defaults in `renewal_attempt_monotonicity_test.exs` and `stored_payment_method_revocation_test.exs`; ExDoc reports hidden nested inventory-admission types referenced in docs; and the test run logs intermittent Postgrex client disconnects. The baseline also emitted optional-dependency/compiler and DB-client warnings. No warning was attributed to this task's source after the review fixes.
- Migration paths: `priv/repo/migrations/20260923202226_sbh_10_06_contract_change_foundation.exs`, `priv/resource_snapshots/repo/contract_changes/20260923202227.json`, and `priv/resource_snapshots/repo/subscriptions/20260923202228.json`.
- The task-specific Subscription pointer is nullable, restrict-on-delete, and has no data backfill. There is no ContractChange binding on RenewalAttempt. Renewal and paid reconciliation fail closed for current/orphan ContractChanges and unresolved legacy future projections.
- Review fixes: composed dimension-scoped queue tests cover plan A then variant B and variant B then plan A, preserving complete target A+B while resolving the resulting plan's current EFFECTIVE revision. The plan-then-variant proof corrupts all legacy target projections between commands and verifies the second instruction follows the authoritative ContractChange. A succeeded reconciliation replay test queues a later ContractChange and verifies the replay returns `{:ok, :noop}` without changing the Subscription or target.

## SBH-10-03 — Immutable RenewalAttempt Charged-Contract Snapshot

### Links consulted

- `AGENTS.md`
- `docs/governance/idempotency.md`
- `docs/governance/immutable_snapshots.md`
- `docs/governance/performance_scaling.md`
- `docs/governance/subscription_scheduling_terms.md`
- `docs/hardening/01_domain_map.md`
- `docs/hardening/subscriptions/SUBSCRIPTION_HARDENING_MASTER_REGISTER.md` v0.1.25
- [PR #74](https://github.com/JCSchoeman96/Store_Blueprint_Hardening/pull/74)
- [Exact-head CI run 35969741252](https://github.com/JCSchoeman96/Store_Blueprint_Hardening/actions/runs/35969741252)

### Decisions / pins

1. The v0.1.25 governance-only transition closes `SBH-10-06` with `AUTHORITY_ASSIGNED` as completed provenance and moves `SBH-10-03` from `BLOCKED_DEPENDENCY / NONE` to `READY / AUTHORITY_ASSIGNED`. The frozen JC-223 graph does not change.
2. Checkpoint B durably binds the renewal occurrence to its exact `PlanRevision`, variant, quantity, amount/currency, period, nullable consumed `ContractChange`, relevant Subscription aggregate version/evidence boundary, and immutable commercial/access-policy evidence.
3. Existing RenewalAttempts receive no fabricated charged-contract history. Historical rows may remain compatibility-unbound where evidence cannot be proven. After the capability is active, renewal cannot cross checkpoint B or begin provider/payment work without a complete durable binding.
4. Binding consumes only the exact queued ContractChange. It transitions that row from `QUEUED` to `BOUND_TO_RENEWAL` and removes it as the Subscription's current unbound target atomically with the B-bound occurrence. Later ContractChanges have new identity and cannot change the bound occurrence.
5. Retries reuse the stored binding. This grant does not include `BOUND_TO_RENEWAL → APPLIED`, provider construction, paid reconciliation, or heuristic historical backfill.
6. Schema authority is limited to one `renewal_attempts` migration and its Ash snapshot, with only the foreign keys, indexes, checks, and compatibility constraints needed for durable charged-contract evidence.
7. The grant covers `Store.Subscriptions.RenewalAttempt`, minimum `Store.Subscriptions.Facade` bind orchestration, and the one governed `Store.Subscriptions.ContractChange` transition. `Store.Subscriptions.Subscription` is authorized only for aggregate-version-protected checkpoint-B consumption of the current target: verify the expected `aggregate_version` and exact `current_contract_change_id`, clear that pointer and its compatibility projections (`pending_variant_id`, `pending_subscription_plan_id`, `pending_renewal_amount_minor`, `pending_renewal_currency`, and `change_effective_at`), and perform the normal single aggregate-version increment. No unrelated Subscription mutation is authorized. Focused fixtures/tests are included; the exclusions in the master register remain in force.
8. The user explicitly admitted JC-228 / SBH-10-03 for implementation at `b0e005a9611c27d3ed93e8ca03fac34d1064a217` on `subs-task/sbh-10-03-renewal-contract-snapshot`. The implementation must stay on that exact base and must stop if it would need rebasing.

### Plan

1. Add focused tests for exact charged-contract capture, atomic B-bound consumption of the current queued ContractChange, authoritative Subscription-version checks, retry reuse, and fail-closed behavior when any required evidence is missing.
2. Add the Subscription-owned RenewalAttempt fields and generate one `renewal_attempts` migration plus its Ash snapshot. Add only evidence constraints required by the frozen contract.
3. Implement the minimum facade transaction that verifies the expected Subscription `aggregate_version` and exact current pointer, freezes the complete occurrence, transitions that exact ContractChange to `BOUND_TO_RENEWAL`, clears `current_contract_change_id` and its compatibility projections, and performs one aggregate-version increment in the same commit.
4. Preserve existing RenewalAttempt idempotency and ensure the existing renewal flow cannot begin provider/payment work until the bind transaction commits. Stop if this requires a surface outside the bounded grant.
5. Run focused Subscription tests, migration and snapshot checks, formatting, and `mix check`; record actual results in the implementation PR. Create the named implementation branch only after the governance merge and independent post-merge verification.

### Performance & Scaling Review

- Hot path: the checkpoint-B bind is on the renewal path. This governance change has no runtime query or write path. The implementation must keep the bind transaction bounded and avoid per-line or per-target N+1 loads.
- Warm/cold paths: renewal status and account reads remain unchanged. Historical compatibility review is a cold administrative path and must not trigger heuristic backfill.
- Database queries and indexes: this PR adds zero queries and indexes. The implementation review must record the measured bind query count and explain the exact Subscription, PlanRevision, ContractChange, and RenewalAttempt reads/writes. The migration may add only the evidence foreign keys, lookup indexes, uniqueness, and checks needed for the contract.
- Caching: PostgreSQL remains authoritative. Add no ETS, Redis, or Cachex cache, TTL, invalidation, or stampede path.
- Oban uniqueness and idempotency: preserve the existing Subscription/renewal-key uniqueness and Oban uniqueness. Retries reuse the same charged-contract binding; this grant adds no worker or queue.
- Telemetry and logging: this governance change adds no instrumentation. The implementation should retain existing renewal telemetry and must not log commercial/access-policy snapshot contents.

### Verification record

- Governance amendment base verified as `d39df761d8c83a1cede055506ba224b212e87038`; `origin/main` observed at `1fb29528e63a255cf86f1810d99b2372a55923cc`.
- PR #74 is merged. Exact-head CI run `35969741252` succeeded on `d9791d97e9878b7523ca6ac8228241ee96f884f2`.
- Certified-head and merge trees both resolve to `3313a4f2429bdf2f7b08795f6c2e44780b48bea4`.
- Post-merge verification: PASS.

### Implementation admission and decisions

- `task_base_sha`: `b0e005a9611c27d3ed93e8ca03fac34d1064a217`
- Branch: `subs-task/sbh-10-03-renewal-contract-snapshot`
- The admitted base was checked before changes and the branch was created from that exact commit. No rebase was performed.
- The live renewal key continues to identify the existing Subscription boundary. A queued target’s purchased `period_end_at` is advanced from the exact target `PlanRevision`; the unchanged/live case also uses its exact current `PlanRevision`.
- The new `charged_contract_version` discriminator distinguishes null-only historical compatibility rows from a complete version 1 binding. There is no historical backfill.
- Charged amount/currency are stored once in the dedicated RenewalAttempt fields: unchanged renewals use the Subscription's locked live price, while queued target prices must match their exact PlanRevision. The versioned policy map snapshots cadence, term, retry, access, and entitlement semantics without duplicating price evidence.
- A new queued-target bind records the pre-consumption aggregate version, writes the attempt and transitions/clears the exact queued target in one database transaction. The target path increments the Subscription once; the no-target path does not write the Subscription.
- `ContractChange.ordering_version` records the aggregate version at instruction ordering time. A later authorized Subscription update may advance `aggregate_version` while preserving that current target, so B verifies the locked expected aggregate version, exact current pointer, queued ownership/status, and effective boundary without equating the two version fields.
- A previously bound attempt is validated and reused before inspecting a later ContractChange or rebuilding evidence. An unbound compatibility attempt fails closed.
- Past-due retry expiry uses the already-bound attempt's captured grace policy; an unbound historical row cannot reach retry processing.
- The normal renewal flow reconstructs its existing in-memory checkout contract from the bound attempt after commit. Nonterminal paid reconciliation requires a complete B binding; ContractChange-bound attempts still stop at the SBH-10-05 boundary, and the succeeded-attempt replay short circuit remains first.
- The queued renewal regression composes a future plan with a different future variant, verifies the populated compatibility projections, then applies a legitimate provider-reference aggregate update before B. It proves B binds that exact target against the newer aggregate version and clears all five projections in the single target-consumption increment.

### Implementation plan

1. Add focused red tests for target cadence/pricing and variant, populated projections, atomic consumption, reuse, corrupt evidence, stale consumers, and paid reconciliation boundaries.
2. Add nullable charged-contract evidence and one completeness constraint to RenewalAttempt; generate one RenewalAttempt migration and its snapshot.
3. Add the private queued-only ContractChange transition and exact Subscription target-consumption action.
4. Bind/reuse the occurrence in the facade before claim, order, payment-intent, or provider work, and derive the purchased period from the selected exact PlanRevision.
5. Run the focused and neighboring suites, fresh migration, snapshot drift, `mix check`, independent review, and exact-head PR CI.

### Implementation performance and scaling review

- Hot path: one Subscription renewal occurrence passes through checkpoint B before order/payment/provider work. PostgreSQL remains the binding authority.
- Query shape: telemetry measured 45 SQL query events for a one-subscription unchanged renewal end to end. The count includes the existing order/payment/provider path; the 64-query focused-test ceiling guards against growth. The B transaction has fixed per-occurrence work: at most two RenewalAttempt identity reads around one Subscription row lock, one fresh Subscription read, one current/orphan ContractChange lookup, one exact PlanRevision read, one SubscriptionPlan identity read, and one RenewalAttempt insert/upsert. A target adds one ContractChange update and one Subscription update. There is no per-line or per-target loop.
- Writes and indexes: no-target binding writes only the RenewalAttempt. Target consumption writes the attempt, the exact ContractChange transition, and the Subscription projection clear/version increment. Existing unique `(subscription_id, renewal_key)` supports retries; no new lookup index was justified.
- Caching: no ETS, Redis, or Cachex path is added. There is no TTL or invalidation work.
- Oban uniqueness and idempotency: worker uniqueness and the RenewalAttempt composite identity are unchanged. Retries reuse the stored evidence.
- Telemetry and logging: existing renewal telemetry is retained; the policy snapshot is not logged.

### Implementation verification record

- Focused command: `mix test test/store/subscriptions/sbh_10_03_renewal_contract_snapshot_test.exs test/store/subscriptions/sbh_10_06_contract_change_test.exs test/store/subscriptions/sbh_10_02_contract_binding_test.exs test/store/subscriptions/renewal_attempt_monotonicity_test.exs test/store/subscriptions/replay_concurrency_test.exs test/store/subscriptions/facade_test.exs` — 64 tests, 0 failures.
- Full required gate: `mix check` — exit 0; 697 tests, 0 failures; Credo checked 5,680 modules/functions with no issues. Documentation generation completed.
- Migration: a fresh `MIX_ENV=test` database created and migrated successfully, including `20260924203729_sbh_10_03_renewal_contract_snapshot.exs`.
- Drift/format: `mix ash_postgres.generate_migrations --check`, `mix format --check-formatted`, and `git diff --check` passed.
- Changed implementation paths: `lib/store/subscriptions/renewal_attempt.ex`, `lib/store/subscriptions/contract_change.ex`, `lib/store/subscriptions/subscription.ex`, `lib/store/subscriptions/facade.ex`, `priv/repo/migrations/20260924203729_sbh_10_03_renewal_contract_snapshot.exs`, `priv/resource_snapshots/repo/renewal_attempts/20260924203730.json`, `test/store/subscriptions/sbh_10_03_renewal_contract_snapshot_test.exs`, and the orphan-target expectation in `test/store/subscriptions/sbh_10_06_contract_change_test.exs`.
- Warnings during the full gate were the pre-existing out-of-order `20260902123000` migration, unused optional test helper defaults, hidden nested inventory-admission types referenced by ExDoc, and an intermittent Postgrex client disconnect log. They did not fail the gate.

## SBH-10-03 closure and JC-229 / SBH-10-04 admission — v0.1.26 governance

### Links consulted

- `AGENTS.md`
- `docs/governance/idempotency.md`
- `docs/governance/immutable_snapshots.md`
- `docs/governance/payment_provider_contract.md`
- `docs/governance/performance_scaling.md`
- `docs/governance/subscription_scheduling_terms.md`
- `docs/hardening/01_domain_map.md`
- `docs/hardening/subscriptions/SUBSCRIPTION_HARDENING_MASTER_REGISTER.md`
- [Implementation PR #76](https://github.com/JCSchoeman96/Store_Blueprint_Hardening/pull/76)
- [Exact-head CI run 36100025589](https://github.com/JCSchoeman96/Store_Blueprint_Hardening/actions/runs/36100025589)

### Decisions / pins

1. The v0.1.26 amendment re-verified live `main` at
   `1fb29528e63a255cf86f1810d99b2372a55923cc` and live
   `hardening/subscriptions` at `3caf13361f53285c8f21300eee2e1f40d5989d3b`.
   It starts from that exact SUBS base and changes no production code, tests,
   migrations, Ash snapshots, dependencies, or JC-223 graph edges.
2. SBH-10-03 closes from `READY / AUTHORITY_ASSIGNED` to
   `CLOSED / AUTHORITY_ASSIGNED` as completed provenance only. Its
   task-specific RenewalAttempt migration, Ash snapshot, Subscription, and
   ContractChange authority is exhausted and non-reusable.
3. Closure evidence is PR #76, certified implementation
   `fc6772f31757d3f8b5cc2774ae5ecdeb299cd783`, exact-head CI run
   `36100025589`, merge commit `3caf13361f53285c8f21300eee2e1f40d5989d3b`,
   matching certified-head and merge trees
   `e2355abe3508694b83fb7e0180d10b09b86fbed3`, and post-merge verification
   PASS.
4. JC-229 remains SBH-10-04 — Renewal Initiation Uses Bound Contract.
   SBH-10-04 transitions from `BLOCKED_DEPENDENCY / EXTERNALIZED` to
   `READY / EXTERNALIZED` because the frozen `SBH-10-03` dependency is
   closed. It is the only canonical READY implementation/proof row.
5. SBH-10-04 may read the bound `RenewalAttempt`, orchestrate initiation
   through `Store.Subscriptions.Facade`, and use focused Subscription
   fixtures/tests. Existing Orders and Payments public/system boundaries may
   be used only as already exposed. The existing provider boundary remains
   externalized. No migration or Ash snapshot authority is assigned.
6. After checkpoint B, provider initiation must use the bound attempt or
   durable artifacts created from that binding. The implementation must prove
   occurrence A remains authoritative after mutable Subscription and legally
   mutable Plan/catalog state changes, a later ContractChange becomes current,
   and retries reuse A's existing Order and PaymentIntent.
7. The proof must preserve A's variant, quantity, amount, currency,
   PlanRevision and plan identity, and purchased period. Provider request
   amount, currency, and occurrence identifiers must trace to A's durable
   evidence. Compatibility-unbound attempts cannot start provider work, and
   no mutable `pending_*` field is provider commercial authority.
8. The existing PR #76 handoff through `effective_renewal_contract/1`,
   bound Order pricing snapshots, PaymentIntent values, persisted provider
   charge values, and retry identities is a partial implementation seam. It
   does not itself close SBH-10-04.
9. Stop and return to governance if correctness needs provider contract
   changes, Payments or Orders core changes, Entitlements core, migrations,
   Ash snapshots, generic Support/error infrastructure, Redis/ETS/Cachex,
   GenServer or distributed locks, or SBH-10-05 paid reconciliation semantics.
10. This amendment assigns no implementation branch or
    `task_base_sha`. Only after independent review, exact-head CI, human
    merge, and independent post-merge commit/tree verification may a separate
    explicit implementation admission assign
    `subs-task/sbh-10-04-bound-renewal-initiation` and its exact base.

### Plan

1. Update the master register's current prose, shared-authority register,
   issue-state matrix, and latest serial verdict. Preserve the earlier
   v0.1.25 verdict as historical evidence.
2. Record the same closure evidence, bounded SBH-10-04 contract, and performance
   review in this phase note.
3. Review the diff for documentation-only paths and confirm the dependency
   table itself remains unchanged.
4. Create the governance PR from the exact base. Leave merge and post-merge
   verification to the required independent and human gates.

### Performance & Scaling Review

- Hot path: renewal provider initiation remains a hot path. This governance
  amendment makes no runtime change.
- Warm/cold paths: existing focused Subscription fixtures cover SBH-10-03
  attempt and identity reuse. SBH-10-04 must add its own post-checkpoint-B
  provider-initiation proof. This documentation change adds no runtime reads
  or writes.
- Database queries and N+1 risk: this change adds zero queries. The future task
  must record the post-checkpoint query count and show that mutable current
  Subscription/Plan state does not add per-item lookups.
- Indexes: this change assigns no migration or index authority.
- Caching: PostgreSQL remains the binding authority. This grant adds no
  ETS/Redis/Cachex cache, TTL, invalidation, or stampede behavior.
- Oban uniqueness and idempotency: retain the existing RenewalAttempt,
  Order, PaymentIntent, renewal-key, and worker uniqueness behavior. Retries
  must reuse the same occurrence identities.
- Telemetry and logging: add no instrumentation through this governance
  grant. The future task must trace provider amount, currency, and occurrence
  identifiers to durable A evidence without logging policy snapshot contents.

### Verification record

- Exact amendment base checked as
  `3caf13361f53285c8f21300eee2e1f40d5989d3b`.
- PR #76 closure evidence is recorded above. The governance amendment's exact
  head, CI, merge, and post-merge verification are pending the serial PR gates.

## SBH-10-04 collection-attempt authority blocker — v0.1.27 governance

### Links consulted

- `AGENTS.md`
- `docs/governance/inventory_reservations.md`
- `docs/governance/idempotency.md`
- `docs/governance/checkout_interlocks.md`
- `docs/governance/payment_provider_contract.md`
- `docs/governance/subscription_scheduling_terms.md`
- `docs/governance/tax_shipping.md`
- `lib/store/subscriptions/facade.ex`
- `docs/hardening/01_domain_map.md`
- `docs/hardening/02_lifecycle_registry.md`
- `docs/hardening/s0_inventory_reservation_admission_architecture.md`
- `docs/hardening/subscriptions/SUBSCRIPTION_HARDENING_MASTER_REGISTER.md`
- [PR #78](https://github.com/JCSchoeman96/Store_Blueprint_Hardening/pull/78)
- [Exact-head CI run 36144853740](https://github.com/JCSchoeman96/Store_Blueprint_Hardening/actions/runs/36144853740)

### Decisions / pins

1. The amendment starts from the exact accepted SUBS tip
   `0016237646f9fddfc2364680b8cc9ddeb7c10655`. Remote `main` was verified at
   `1fb29528e63a255cf86f1810d99b2372a55923cc`, and
   `hardening/subscriptions` matched the exact base.
2. JC-229 / SBH-10-04 moves from `READY / EXTERNALIZED` to
   `BLOCKED_SHARED_AUTHORITY`. No canonical implementation/proof row is READY.
   The JC-223 dependency graph is unchanged. SBH-10-05 stays
   `BLOCKED_DEPENDENCY`, and its paid-application semantics remain unchanged.
   This v0.1.27 amendment also replaces one frozen Stage B renewal rule: a new
   collection after verified terminal financial non-success receives distinct
   collection, PaymentIntent, and provider idempotency identities. All other
   frozen Stage B law remains unchanged.
3. One bound RenewalAttempt and one Order remain the commercial occurrence.
   The blocked Subscription target uses sequential collection identities,
   PaymentIntents, and provider idempotency keys against that same occurrence.
   A replacement Order cannot be used for a dunning retry.
4. Under the blocked target, ambiguous provider outcomes replay the same
   collection attempt, PaymentIntent, and provider key. A new collection
   attempt would require durable evidence of terminal provider/payment
   non-success and an eligible dunning decision. `requires_action` stays on
   the same attempt and PaymentIntent. A local `cancelled` or expired state
   after possible submission is not terminal proof.
5. The proposed physical collection target uses a reservation generation per
   collection attempt, but it does not supersede current inventory law. Until
   the InventoryAdmission owner approves and records the required amendment,
   the current one-row identity, terminal lifecycle, TTL, and S0-ARCH-01 rules
   remain authoritative. Any future target would keep a hold through a
   prepared attempt that a worker could submit, `requires_action`, or an
   unknown provider result. A local TTL alone would not release it. A
   pre-submission `not_submitted` dispatch would require a durable fence.
6. `docs/governance/inventory_reservations.md` records that blocked target.
   Frozen S0-ARCH-01 still uses `order_id + variant_id` for admission and
   recovery. Its owner must approve an amendment before that identity or
   recovery contract can be superseded.
7. No Orders, InventoryAdmission, Payments, provider, migration, Ash snapshot,
   or Subscription collection-record implementation authority is assigned.
   The checkout, inventory, and provider sections record future targets only.
   Current cross-domain contracts remain in force until their owners approve
   changes. The previous SBH-10-04 implementation grant is superseded and
   cannot support more code.
8. PR #78 remains open and draft. Head
   `08b28937c001b4f35350bcf5de6fdd052fc7a4c3` is one commit on exact
   `task_base_sha` `0016237646f9fddfc2364680b8cc9ddeb7c10655`. Its four changed
   paths are `docs/agent_notes/phase_27_docs.md`,
   `lib/store/subscriptions/facade.ex`,
   `test/store/subscriptions/facade_test.exs`, and
   `test/store/subscriptions/sbh_10_04_bound_renewal_initiation_test.exs`.
   The focused renewal group ran 69 tests with zero failures; the new
   SBH-10-04 file contains five tests. `mix check` ran 702 tests with zero
   failures and strict Credo reported no findings. Migration drift and
   formatting checks passed. Exact-head CI run `36144853740` passed all five
   required jobs: `check_static`, `test_pr_strict`,
   `performance_smoke_required`, `performance_smoke_chaos_required`, and
   `dialyzer_required`. One unchanged virtual-renewal measurement was 45
   queries before and after; the new checks use returned Order rows and
   PaymentIntent structs without per-line lookups. This is partial evidence
   for Order snapshot verification, PlanRevision evidence, PaymentIntent
   consistency, and physical total tracing. It does not prove a real decline
   and later collection attempt.
9. This amendment changes no production code, tests, migration, Ash snapshot,
   Orders/Payments source contract, or provider implementation. It amends one
   frozen Stage B renewal identity/recovery rule, records blocked targets for
   later owner review, and leaves implementation blocked. The JC-223
   dependency graph is unchanged.
10. Current Catalog weight and descriptive fields are not checkpoint-B
    RenewalAttempt evidence. This amendment does not declare them B-bound or
    add them to the RenewalAttempt snapshot. They remain separate fulfillment,
    shipping, and tax inputs under their governing policy; the durable Order
    must retain finalized evidence. They cannot change A's recurring base
    variant, quantity, unit amount, or currency. If a mutable Catalog field can
    redefine that base and no A evidence recovers it, stop and return to
    governance.
11. Revalidate the current stored payment method and provider selection before
    provider work. The payment-method change and revocation race remains in
    SBH-80-03 and is not absorbed into this amendment.
12. The currently observed renewal PI key and Stripe provider key both reuse
   `renewal_key`; the blocked v0.1.27 target uses a durable
   `collection_attempt_id` for each later collection identity. The current
   `requires_action` path releases the physical reservation; this remains an
   unmodified runtime safety gap.
13. Every PaymentIntent must be durably attributable to its exact collection
   attempt and RenewalAttempt occurrence, and successful reconciliation must
   identify the exact successful evidence without ambiguity or destructive
   history rewriting. The meaning of the legacy single
   `RenewalAttempt.payment_intent_id` remains unresolved for a later explicit
   Subscription, Payments, and SBH-10-05 authority decision. The collection
   ordinal is separate from the existing `RenewalAttempt.attempt_no` failure
   and dunning counter.

### Plan

1. Update the master register's current status, SBH-10-04 authority requirements,
   and latest serial verdict while preserving v0.1.26 as historical evidence.
2. Record the physical collection hold target and InventoryAdmission gate in
   `docs/governance/inventory_reservations.md`.
3. Align renewal key targets in checkout/provider interlocks and distinguish
   the blocked target from current runtime observations in the domain map and
   lifecycle registry.
4. Review the exact-base diff for docs-only paths and verify that the JC-223
   dependency table is unchanged. Reconcile the bounded Stage B amendment and
   keep all unapproved cross-domain targets explicitly blocked.
5. Keep PR #78 draft and unmerged. Complete independent review, exact-head CI,
   and human merge gates before any new implementation admission.

### Performance & Scaling Review

- Hot path: renewal initiation and physical inventory reservation remain hot.
  This governance change adds no runtime behavior.
- Warm/cold paths: no runtime path, query, or worker changed. Future
  implementation must measure the same renewal query baseline and include
  provider decline, ambiguous outcome, authentication, and re-reservation
  cases.
- Database queries and N+1 risk: this amendment adds zero database queries.
  Future collection lookup must stay constant work per occurrence and avoid
  per-line or per-reservation target lookups.
- Indexes: this amendment assigns no index or migration authority. A future
  reservation-generation identity needs Orders and InventoryAdmission owner
  review before schema design.
- Caching: no Redis or cache behavior changes. S0-ARCH-01 remains authoritative;
  any future owner-approved amendment must preserve PostgreSQL as inventory
  truth and carry the generation through admission and recovery.
- Oban uniqueness and idempotency: occurrence scheduling remains keyed by the
  existing renewal occurrence. Provider transport retries use one stable key
  per collection attempt. A later collection uses a different durable
  collection identity. No worker uniqueness changes are authorized here.
- Hold resolution: unknown or authentication-required collection outcomes may
  retain physical stock holds until provider reconciliation; future work must
  measure the impact of prolonged holds and report unresolved-hold age.
- Telemetry and logging: this amendment adds no instrumentation. Future work
  must expose unresolved collection/hold age without logging payment method or
  provider secrets.

### Verification record

- Accepted amendment base: `0016237646f9fddfc2364680b8cc9ddeb7c10655`.
- Observed `origin/main`:
  `1fb29528e63a255cf86f1810d99b2372a55923cc`.
- PR #78 remains `OPEN / DRAFT`, head
  `08b28937c001b4f35350bcf5de6fdd052fc7a4c3`, with exact parent and passing
  exact-head CI run `36144853740`.
- PR #79 remains `OPEN / DRAFT` against the accepted amendment base. Its
  current exact head and exact-head CI run are recorded in the live PR
  description at [PR #79](https://github.com/JCSchoeman96/Store_Blueprint_Hardening/pull/79)
  after CI completes for the corrected head. The description is the
  current-head provenance record so this committed note does not embed a
  self-invalidating hash or run ID.
- The independent review reported material governance conflicts and requested
  the corrections recorded in this note. Independent review of the corrected
  head is pending; no PASS is claimed.
- The changed paths remain the master register, inventory reservations,
  checkout interlocks, payment provider contract, subscription domain map,
  lifecycle registry, and this Phase 27 note. No runtime or schema path changes.
- Governance PR merge and post-merge verification remain pending.

## JC-289 / SBH-50-06 AccessEffect foundation admission for v0.1.28 governance

### Links consulted

- `AGENTS.md`
- `docs/hardening/subscriptions/SUBSCRIPTION_HARDENING_MASTER_REGISTER.md`
- `docs/agent_notes/phase_27_docs.md`
- `docs/phases/phase_27_variable_subscriptions.md`
- `docs/phases/phase_27a_membership_subscriptions_entitlements.md`
- `docs/governance/subscription_scheduling_terms.md`
- `docs/governance/state_machines.md`
- `docs/governance/idempotency.md`
- `docs/governance/performance_scaling.md`
- `docs/phases/phase_29_performance_architecture_optimizations.md`
- `docs/hardening/01_domain_map.md`
- `docs/hardening/02_lifecycle_registry.md`
- [PR #78, partial SBH-10-04 evidence](https://github.com/JCSchoeman96/Store_Blueprint_Hardening/pull/78)
- [PR #79, merged v0.1.27 governance](https://github.com/JCSchoeman96/Store_Blueprint_Hardening/pull/79)

### Decisions / pins

1. This governance amendment starts at the exact accepted
   `hardening/subscriptions` base `c66fb843beeb25e4943ceb6119b1ed7de3999964`
   on `subs-governance/sbh-50-06-access-effect-admission`. PR #79 merged at
   that base. This record supersedes the earlier v0.1.27 verification text
   below that said PR #79 remained open and draft.
2. Only SBH-50-06 changes state:
   `BLOCKED_SHARED_AUTHORITY / BLOCKED_SHARED_AUTHORITY` to
   `READY / AUTHORITY_ASSIGNED`. It is the sole canonical READY
   implementation/proof row. SBH-10-04 remains
   `BLOCKED_SHARED_AUTHORITY`; SBH-10-05 and SBH-50-02 through SBH-50-05
   remain `BLOCKED_DEPENDENCY`. The JC-223 graph is unchanged.
3. The later SBH-50-06 implementation may add one Subscription-owned
   `Store.Subscriptions.AccessEffect` resource, an optional task-local status
   or value type, resource registration, bounded Facade create/reuse and
   transition functions, focused Subscription fixtures/tests, one PostgreSQL
   table/index migration and matching Ash/Postgres snapshot, and Phase 27
   implementation evidence. This authority expires when SBH-50-06 closes and
   cannot be reused by SBH-50-02 through SBH-50-05. No other migration or
   snapshot is authorized.
4. `AccessEffect` records the desired Commerce access target and the need for
   downstream convergence. It is not an EntitlementGrant. Subscription and
   AccessEffect record desired access; `Store.Entitlements` remains the
   authority for actual grants. No Entitlements production file, resource,
   value, cache behavior, migration, snapshot, grant/revoke action, or facade
   may change.
5. Preserve the JC-222 lifecycle exactly:

   ```text
   REQUIRED → PENDING → APPLIED
   PENDING → FAILED_RETRYABLE → PENDING
   PENDING → SUPERSEDED
   ```

   `APPLIED` and `SUPERSEDED` are terminal for that obligation identity. Do
   not add `PROCESSING`, `SUSPENDED`, `CANCELED`, or generic event-sourcing
   states. A stale `REQUIRED` or `FAILED_RETRYABLE` obligation must pass through
   `PENDING` to `SUPERSEDED` atomically, with no external operation between
   transitions.
6. Each obligation belongs to one Subscription and records its source identity
   and source version. The aggregate version may be captured at the
   access-changing commit as provenance, but it is not the current target
   version. Unrelated Subscription writes do not supersede access targets.
   Durable AccessEffect target ordering determines current-target precedence.
7. Store immutable target evidence for disposition, applicable entitlement
   kind and scope, any required validity boundary, exact Subscription contract
   and PlanRevision provenance, source version, and a deterministic target
   fingerprint. The later executor must not derive its target from mutable
   `SubscriptionPlan` state.
8. Replaying the same source version and canonical target reuses one durable
   row. Different target evidence for that source version fails closed. A
   database uniqueness constraint and transactional locking or compare-and-swap
   must prevent duplicate rows, stale payload overwrite, and older target
   promotion. Current-target lookup uses a Subscription/source-order index and
   does not scan all history.
9. This admission proves only that the obligation layer can identify and
   suppress stale work before it is current or executable. It does not prove
   that an already-running stale worker cannot race an Entitlements mutation;
   SBH-50-02 / SBH-50-03 own that later proof.
10. SBH-50-06 does not add a worker, executor, retry scheduling, issuance or
    revocation recovery, access-policy enforcement, entitlement repair, cache
    repair, generic convergence infrastructure, or lifecycle-source rewiring.
    It does not change Subscription truth to ease effect execution. If any stop
    condition in the master-register contract requires broader authority, stop
    and return to governance.
11. The prospective implementation branch is
    `subs-task/sbh-50-06-access-effect-foundation`. No implementation
    `task_base_sha` is assigned until the governance PR passes independent
    review and exact-head CI, a human merges it, and independent verification
    confirms the merge commit and tree. The accepted post-governance SUBS tip
    will then be the task base.
12. PR #78 remains open and draft as partial proof for blocked SBH-10-04. It is
    unrelated to this admission.

### Plan

1. Record the v0.1.28 row transition and bounded authority in the canonical
   Subscription master register.
2. Record the admission contract and evidence pointers in this Phase 27 note.
3. Confirm that the exact-base diff contains only these two governance/evidence
   documents and leaves the JC-223 dependency graph and all other row states
   unchanged.
4. Run the required repository gate, open the governance PR, then complete
   independent review and exact-head CI. Human merge and independent
   post-merge commit/tree verification remain required before JC-289 can be
   admitted for implementation.

### Performance & Scaling Review

- Hot paths: later create, replay, and current-target lookup paths are hot
  Subscription paths. This governance amendment changes no runtime behavior.
- Warm/cold paths: this amendment adds no query, worker, or cache path. No
  historical scan is allowed for current-target lookup.
- Database queries and N+1 risk: this amendment executes zero application
  queries. The implementation proof must record query counts separately for
  create, replay, and current-target lookup, and check for N+1 reads.
- Indexes: the AccessEffect migration authority covers indexes that bound
  lookup by Subscription and source ordering. PostgreSQL remains the authority.
- Caching: no Redis, ETS, Cachex, GenServer, or distributed lock is justified.
  No cache semantics or invalidation are part of this task.
- Oban uniqueness and idempotency: no AccessEffect worker or enqueue path is
  authorized here. Durable database uniqueness plus transactional locking or
  compare-and-swap enforce obligation identity and target ordering.
- Telemetry and logging: this amendment adds none. The implementation evidence
  should report replay reuse, conflicting-target rejection, stale suppression,
  and query counts without logging sensitive target payloads.

### Verification record

- The branch was created from exact base
  `c66fb843beeb25e4943ceb6119b1ed7de3999964`.
- PR #79 merged at `c66fb843beeb25e4943ceb6119b1ed7de3999964`, which is the
  current `hardening/subscriptions` tip at this amendment base.
- PR #78 remains `OPEN / DRAFT` for blocked SBH-10-04 and is unrelated to this
  admission.
- [PR #82](https://github.com/JCSchoeman96/Store_Blueprint_Hardening/pull/82)
  is the live record for exact-head CI and review status. Human merge and
  independent post-merge commit/tree verification remain pending.
- The intended changed paths are this note and
  `docs/hardening/subscriptions/SUBSCRIPTION_HARDENING_MASTER_REGISTER.md`.
  No production code, tests, migration, Ash snapshot, dependency, worker, or
  Entitlements file is in scope.

## SBH-10-04 cross-domain governance amendment (2026-09-26)

### Links consulted

- [`SBH-10-04 cross-domain authority amendment`](../governance/sbh_10_04_cross_domain_authority_amendment.md)
- [`Checkout interlocks`](../governance/checkout_interlocks.md)
- [`Payment provider contract`](../governance/payment_provider_contract.md)
- [`Inventory & Reservations`](../governance/inventory_reservations.md)
- Accepted SUBS evidence at `c66fb843beeb25e4943ceb6119b1ed7de3999964`: `docs/hardening/subscriptions/SUBSCRIPTION_HARDENING_MASTER_REGISTER.md` §§23.3 and 47, and `docs/governance/payment_provider_contract.md` §4.

### Decisions and pins

- The cross-domain grant is based on canonical `main` `1fb29528e63a255cf86f1810d99b2372a55923cc` and SUBS evidence tip `c66fb843beeb25e4943ceb6119b1ed7de3999964`.
- One RenewalAttempt and one renewal Order remain the commercial occurrence. Sequential collection attempts get their own durable identities and PaymentIntent/provider idempotency keys.
- `requires_action` remains unresolved. The existing runtime release behavior is a known gap; this governance task makes no runtime change.
- The later collection reuses the finalized Order totals. It does not re-quote or rewrite shipping or tax.
- SBH-10-05 remains separate and must reconcile against the exact successful PaymentApplication PaymentIntent and collection evidence.
- JC-223 edges remain unchanged: SBH-10-04 depends on SBH-10-03; SBH-10-05 depends on SBH-10-03 and SBH-10-04.

### Plan

1. Merge the governance PR to canonical `main`.
2. Verify the exact merge commit and tree independently.
3. Complete a separate S0 governance/task admission for the typed renewal-key and exact-key recovery path, including any S0-scoped implementation required by that admission; pass its required review, merge, and independent post-merge commit/tree verification.
4. Only after the S0 admission merges and verifies, create the separate SUBS governance re-admission amendment against the then-current accepted tip and recheck current source compatibility. The SUBS amendment must not mark SBH-10-04 `READY` from the governance PR alone.
5. Assign a new SBH-10-04 task base only after that SUBS amendment merges and receives independent post-merge verification.

### Performance & Scaling Review

- **Hot:** Renewal collection creation, physical inventory holds, payment dispatch, provider status/cancel reconciliation, webhooks, and paid application. This docs-only change adds no production query. The later implementation must measure each path's query count and N+1 risk.
- **Warm:** No cache is added. PostgreSQL remains inventory authority; Redis remains bounded admission coordination. Generic checkout TTL and stock invalidation remain unchanged; unresolved renewal generations bypass generic TTL cleanup until exact release evidence exists. No cache stampede protection is added to this admission path; database locks and uniqueness constraints control reservation concurrency.
- **Cold:** Provider and database ambiguity use bounded reconciliation; exhaustion leaves the collection unresolved, keeps the hold active, and requires operator review. Collection workers reuse the durable collection ID on retry.
- **Indexes:** The task-specific Orders migration adds one active generation partial index while retaining the globally unique `reservation_key`. Subscription indexes enforce unique collection ordinal, a unique nullable `payment_intent_id` association, and at most one unresolved collection per RenewalAttempt.
- **Oban and idempotency:** Existing occurrence scheduling remains keyed by subscription and `renewal_key`; collection reconciliation jobs are unique by collection ID and dispatch epoch, and each provider operation targets the same collection PaymentIntent.
- **Telemetry and logging:** Record dispatch epoch, fenced-through epoch, fence result, provider reconcile/cancel result, verified outcome, collection ID, local intent ID, reservation key, recovery result, and PaymentApplication result separately.

### Verification

- `STORE_TEST_DB_SUFFIX=sbh1004 mix check`: PASS; 576 tests, 0 failures, Credo clean, and documentation generated. Existing low-confidence Sobelow findings and generated-documentation warnings are outside this docs-only change.
- `git diff --check`: PASS.
- Changed files are governance and agent-note Markdown only; no runtime code, tests, migration, or Ash snapshot changed.

### Reconciliation status at the accepted runtime base

The accepted main contract documents bounded target contracts for Orders, Payments, InventoryAdmission, and provider behavior for later, separately admitted work. It does not admit SBH-10-04 for Subscription implementation or assign a new task base. The SUBS v0.1.28 authority record remains controlling for SUBS issue status: SBH-10-04 is still `BLOCKED_SHARED_AUTHORITY`, and only SBH-50-06 is admitted as READY. The earlier v0.1.27 statements that no owning-surface contract amendment existed describe the state before the accepted main amendment; current target contracts are defined by the merged governance documents. No SBH-10-04 runtime implementation is introduced by this reconciliation.

## JC-289 / SBH-50-06 NewYou conformance correction — v0.1.29 governance (2026-09-30)

This entry is a new evidence record. The preceding v0.1.28 admission section
and its PR #82 history remain unchanged. The v0.1.29 amendment supersedes only
the bounded JC-289 contract details stated below; it does not rewrite the
historical admission or alter JC-222, JC-223, or earlier SUBS authority.

### Links consulted

- `AGENTS.md` and `docs/agent_rules/active_workstreams.md` from current `origin/main`
- `docs/hardening/subscriptions/SUBSCRIPTION_HARDENING_MASTER_REGISTER.md`, §§23.3, 48, and 49
- `docs/hardening/01_domain_map.md`
- `docs/hardening/02_lifecycle_registry.md`
- `docs/governance/subscription_scheduling_terms.md`
- `docs/governance/state_machines.md`
- `docs/governance/idempotency.md`
- `docs/phases/phase_27_variable_subscriptions.md`
- `docs/phases/phase_27a_membership_subscriptions_entitlements.md`
- [NewYou authority README at main `3c8c05278ad3601823af2f57d53fba1bc8a5f5cc`](https://github.com/JCSchoeman96/NewYou/blob/3c8c05278ad3601823af2f57d53fba1bc8a5f5cc/docs/00_platform/README.md)
- [NewYou current authority manifest v1.0.0](https://github.com/JCSchoeman96/NewYou/blob/3c8c05278ad3601823af2f57d53fba1bc8a5f5cc/docs/00_platform/CURRENT_AUTHORITY_MANIFEST_v1.0.0.json)
- [NewYou Product `00_PLATFORM_v1.5.1.md`](https://github.com/JCSchoeman96/NewYou/blob/3c8c05278ad3601823af2f57d53fba1bc8a5f5cc/docs/00_platform/00_PLATFORM_v1.5.1.md)
- [NewYou Decisions `01_DECISIONS_v1.5.0.md`](https://github.com/JCSchoeman96/NewYou/blob/3c8c05278ad3601823af2f57d53fba1bc8a5f5cc/docs/00_platform/01_DECISIONS_v1.5.0.md)
- [NewYou Architecture `03_ARCHITECTURE_v1.1.1.md`](https://github.com/JCSchoeman96/NewYou/blob/3c8c05278ad3601823af2f57d53fba1bc8a5f5cc/docs/00_platform/03_ARCHITECTURE_v1.1.1.md)
- [NewYou Domain Map `04_DOMAIN_MAP_v1.2.0.md`](https://github.com/JCSchoeman96/NewYou/blob/3c8c05278ad3601823af2f57d53fba1bc8a5f5cc/docs/00_platform/04_DOMAIN_MAP_v1.2.0.md)
- [NewYou Roadmap `05_ROADMAP_v1.1.5.md`](https://github.com/JCSchoeman96/NewYou/blob/3c8c05278ad3601823af2f57d53fba1bc8a5f5cc/docs/00_platform/05_ROADMAP_v1.1.5.md)
- [PR #82, v0.1.28 SBH-50-06 admission](https://github.com/JCSchoeman96/Store_Blueprint_Hardening/pull/82)
- [PR #78, unrelated open JC-229 / SBH-10-04 work](https://github.com/JCSchoeman96/Store_Blueprint_Hardening/pull/78)
- Current JC-289 description and relations: **controller-verified live Linear evidence** supplied on 2026-09-30; this record does not claim a local Linear inspection.

### Decisions / pins

1. This correction starts from the exact accepted SUBS tip
   `f621d2db355d3ef2c1531f73b0c698a323cc768e`, on
   `subs-governance/sbh-50-06-newyou-conformance`. At edit time, fetched
   `origin/hardening/subscriptions` still equalled that SHA. Current
   `origin/main` was `a74d3f05a5f250300d0c2293f294e77785f6818f`.
2. Controller-verified live Linear evidence records JC-289 as open, Linear
   status `Backlog`, canonical state `READY`, shared authority
   `AUTHORITY_ASSIGNED`, and loop eligibility `No`. PR #82 did not complete the
   issue. Its description retains the 2026-09-26 focused NewYou evaluation and
   requires this bounded correction before implementation. Its blockers JC-227
   / SBH-10-02 and JC-231 / SBH-20-01 are both `Done`. JC-289 continues to block
   JC-245 / SBH-50-02, JC-246 / SBH-50-03, JC-247 / SBH-50-04, JC-239 /
   SBH-30-04, and JC-242 / SBH-40-02. Related authority remains JC-222,
   JC-223, JC-244, JC-248, JC-262, JC-264, and JC-276.
3. NewYou `main` was inspected at
   `3c8c05278ad3601823af2f57d53fba1bc8a5f5cc`. Its current README routes to
   `docs/00_platform/README.md`; authority manifest
   `CURRENT_AUTHORITY_MANIFEST_v1.0.0.json` routes the current Product
   v1.5.1, Decisions v1.5.0, Architecture v1.1.1, Domain Map v1.2.0, and
   Roadmap v1.1.5. The reusable requirement is transactionally durable
   authoritative intent with post-commit asynchronous consequence execution.
   NewYou-specific Product Law is not copied into Store law.
4. First-class durable `AccessEffect` remains accepted because it has its own
   durability, lifecycle, replay/idempotency, ordering, supersession, and
   reconciliation semantics:

   ```text
   Subscription / AccessEffect = desired Commerce access target and obligation
   Store.Entitlements          = actual entitlement/grant authority
   ```

5. One AccessEffect means one complete canonical Subscription-derived desired
   access outcome for one source version. It is not one EntitlementGrant
   forever. The current Store target remains scalar: disposition,
   zero-or-one applicable Subscription entitlement kind/scope, validity
   boundary where applicable, exact Subscription commercial-contract
   provenance, exact PlanRevision provenance, source version, and deterministic
   fingerprint/conflict identity covering the complete target. A future
   recurring-component model requires separate authority. This amendment
   authorizes no generic target-set child resource, arbitrary JSON effect/event
   envelope, arbitrary effects collection, multi-component Subscription
   model, or additional entitlement structure.
6. The create/reuse primitive must compose with a caller-owned PostgreSQL
   transaction. Future authoritative Subscription access-changing truth and
   its durable AccessEffect obligation must be capable of one atomic
   PostgreSQL commit. If the obligation cannot be recorded, the caller must be
   able to roll back the source mutation. AccessEffect creation cannot be
   forced to occur only post-commit, in an isolated transaction, through an
   async job, or by external side effect. No Entitlements mutation occurs in
   that transaction; Entitlements convergence stays post-commit/asynchronous.

   ```text
   authoritative Subscription access-changing truth
   +
   durable AccessEffect obligation
   =
   one atomic authoritative PostgreSQL commit
   ```
7. The lifecycle and transition constraints remain unchanged from JC-222:

   ```text
   REQUIRED → PENDING → APPLIED
   PENDING → FAILED_RETRYABLE → PENDING
   PENDING → SUPERSEDED
   ```

   `APPLIED` and `SUPERSEDED` remain terminal. Stale `REQUIRED` or
   `FAILED_RETRYABLE` obligations pass atomically through `PENDING` to
   `SUPERSEDED` when the frozen graph requires it, with no Entitlements
   operation between transitions. No new states or lifecycle shortcuts are
   introduced.
8. JC-289's implementation proof must establish all of the following:
   - creating an AccessEffect inside a caller-owned outer PostgreSQL transaction
     and rolling back that transaction leaves no new AccessEffect persisted;
   - exact replay for the same Subscription, source version, and complete
     target reuses one durable identity;
   - materially different target evidence at the same source version fails
     closed;
   - unrelated aggregate writes may create legal source-version gaps between
     AccessEffects;
   - unrelated later aggregate writes do not stale the latest target, and
     current determination does not require
     `effect.source_version == subscription.aggregate_version`;
   - older obligations cannot become current after a newer target exists;
   - `APPLIED` and `SUPERSEDED` cannot reopen; and
   - the deterministic target fingerprint covers disposition, scalar
     entitlement kind/scope where applicable, validity boundary where
     applicable, exact Subscription contract provenance, exact PlanRevision
     provenance, and source version.
9. JC-289 performs no Entitlements production mutation or external access
   side effect. No Entitlements source, migration, snapshot, state, facade,
   grant/revoke action, or cache behavior is authorized.
10. No JC-223 dependency edge, JC-222 lifecycle law, Domain ownership,
    Entitlements authority/contract, SBH-50-02 through SBH-50-05 authority,
    SBH-30-04 authority, SBH-40-02 authority, or Subscription commercial
    lifecycle semantics changes. No Entitlements `:suspended` state is added.
11. This governance amendment assigns no implementation `task_base_sha` and
    creates no implementation branch or code. The prospective implementation
    branch remains `subs-task/sbh-50-06-access-effect-foundation`. Admission
    remains gated on governance PR independent review, exact-head CI, human
    merge, independent post-merge merge-commit/tree verification, and refresh
    of `hardening/subscriptions` before a separate task-base assignment.

### Plan

1. Append a bounded v0.1.29 clarification to the Master Register and preserve
   the v0.1.28 admission as historical evidence.
2. Add this separate Phase 27 evidence record without rewriting the prior
   PR #82 record.
3. Verify the exact-base diff contains only these two authorized Markdown
   files, run `git diff --check` and the repository governance/documentation
   gates, and verify the JC-222 lifecycle and JC-223 graph are unchanged.
4. Open a governance PR to `hardening/subscriptions`. Independent review,
   exact-head CI, human merge, and independent post-merge verification remain
   gates before implementation admission.

### Performance & Scaling Review

- **Hot:** Future create/replay and current-target lookup occur on
  Subscription access paths. This governance amendment adds no runtime path.
- **Warm/cold:** No new worker, query, cache, or external call is added here.
  Current-target lookup remains bounded and must not scan effect history.
- **Database queries and N+1:** This amendment executes no application query.
  Implementation tests must record create, replay, and current-target query
  counts and check for N+1 reads. PostgreSQL remains durable truth.
- **Indexes:** Existing task-specific authority covers indexes for
  Subscription and source ordering; this correction adds no index or schema
  authority.
- **Caching:** No ETS/Redis cache, TTL, invalidation, or stampede behavior is
  introduced or authorized.
- **Oban and idempotency:** This correction adds no job or worker path. Durable
  AccessEffect identity and transactional locking/compare-and-swap remain
  business-truth concerns; queue machinery is not business truth.
- **Telemetry/logging:** No production telemetry or logging change is made.
  Implementation evidence should report replay reuse, conflict rejection,
  stale suppression, and bounded query counts without exposing target payloads.

### Verification record

- The fetched `origin/hardening/subscriptions` matched the exact amendment base
  before editing. Only the two authorized governance/evidence documents are in
  scope.
- The v0.1.28 PR #82 record above remains historical; it is not rewritten to
  attribute the later NewYou correction to that admission.
- The task remains governance-only. No implementation `task_base_sha` is
  assigned, and implementation admission remains subject to the gates in
  section 49 of the Master Register.

## JC-289 / SBH-50-06 implementation evidence

### Authority and scope

- Implementation branch: `subs-task/sbh-50-06-access-effect-foundation`.
- Exact implementation base: `a67958f36cf8e243b260d72d3cab3bd8e48d5b28`,
  the verified PR #93 merge commit on `hardening/subscriptions`.
- Authority: JC-289 / SBH-50-06 was admitted against Master Register v0.1.29
  after independent tree verification. This section records the separate
  implementation proof and does not amend the historical governance records
  above.
- The user explicitly authorized `lib/store/support/governance/surface_registry.ex`
  as a bounded scope expansion solely to register the six new
  `Store.Subscriptions.Facade` system exports. The existing consumer set was
  preserved. No other registry entry, allowed consumer, naming rule, or
  governance behavior changed.
- Runtime scope is limited to the AccessEffect resource and task-local value
  types/input, Subscription domain registration, six narrow façade
  operations, focused tests, one generated migration and its matching
  snapshot, this evidence, and the specifically authorized registry entry.
  No Entitlements, worker, provider, queue, cache, Subscription lifecycle, or
  dependency code was changed.

### Implementation decisions

- `Store.Subscriptions.AccessEffect` persists one complete desired access
  outcome per Subscription source version. Its entitlement kind/scope is
  either the complete pair or nil/nil. The PostgreSQL constraint enforces both
  directions of that invariant.
- Target evidence includes disposition, optional validity boundary, immutable
  source order line, ContractChange and PlanRevision provenance, source
  version, lifecycle status, timestamps, and deterministic target fingerprint.
- The identity is protected by a PostgreSQL unique constraint on
  Subscription + source version. Current lookup is bounded by the same unique
  composite B-tree index, which PostgreSQL scans backward for descending
  source-version order; the duplicate descending index was removed.
- Target fingerprint v1 is a SHA-256 digest over deterministic term encoding
  of a versioned `:store_subscriptions_access_effect_target` descriptor and
  every canonical field: Subscription ID, source version, disposition,
  entitlement kind, scope, validity boundary, source order line item ID,
  ContractChange ID, and PlanRevision ID. Nil values are encoded explicitly.
- Establishment takes the Subscription row lock, checks exact-version replay
  and fingerprint conflict under that lock, then reads the newest effect with
  descending source version and limit one. For a new identity, a source
  version greater than the locked `Subscription.aggregate_version` fails
  closed, while a lower source version remains valid. Exact historical replay
  is checked first and still succeeds after the aggregate advances. Aggregate
  equality is not the current-target rule. A stale lower version than the
  newest durable target is rejected; a newer version is inserted normally
  and older nonterminal state is superseded in the same PostgreSQL
  transaction. Database uniqueness is the final identity backstop; Ash upsert
  is not used.
- New targets must match the immutable entitlement kind/scope of the bound
  PlanRevision. An effective target must match exactly, including nil/nil
  when the revision has no entitlement. A non-effective target may use nil/nil
  or the same revision pair. Mutable SubscriptionPlan state is not consulted.
- The establishment primitive joins an outer `Store.Repo.transaction/1` and
  returns its result before outer commit. The rollback test proves a caller
  can roll back both source work and a newly created AccessEffect.
- Only the six bounded façade operations are public. Supersession is an
  internal part of establishing a newer authoritative target; there is no
  callable standalone supersede operation. Required and retryable-failed
  supersession pass through Pending; Pending supersedes directly; Applied and
  Superseded remain terminal. The stale-PENDING test proves that locked
  durable state prevents a caller's stale struct from reopening a superseded
  effect. No Entitlements operation or post-commit notification is produced.

### Verification record

- Focused AccessEffect tests: 20 tests, 0 failures on the correction head,
  covering complete entitlement pairs and database enforcement, identity replay,
  same-version conflict, both race proofs, competing versions in both lock
  arrival orders, actual aggregate-version gaps from unrelated Subscription
  writes, future source rejection, PlanRevision target matching, stale writes,
  lifecycle edges/terminal states, stale-struct transition rejection, field
  immutability, fingerprint coverage,
  outer rollback, bounded query counts/index use, and absence of access side
  effects. Race coordination observes PostgreSQL lock blocking; it does not
  use sleep-based interleavings.
- Existing neighboring Subscription replay, optimistic-version,
  ContractChange, PlanRevision, and façade suites: 68 tests, 0 failures on the
  correction head.
- Full `mix check` on isolated test database suffix `sbh5006fix3`: 738 tests,
  0 failures. The static checks, strict Credo, security scan, and documentation
  generation completed. The check reported existing warnings listed below.
- `check.surface_naming` passed with exactly six registered AccessEffect
  façade exports. Formatting and
  `mix ash_postgres.generate_migrations --check` passed.
- Migration and snapshot: exactly one generated migration,
  `priv/repo/migrations/20260930091321_sbh_50_06_access_effect_foundation.exs`,
  and exactly one matching snapshot,
  `priv/resource_snapshots/repo/access_effects/20260930091322.json`. A fresh
  database applied the full migration history in order. Migration generation
  `--check` reports clean alignment.
- Query-count evidence from the focused SQL trace: first establishment uses
  four data queries (Subscription lock, exact identity lookup, bounded newest
  target lookup, insert); exact replay uses two (Subscription lock and exact
  identity lookup); current-target lookup uses one bounded query. The
  `EXPLAIN` plan is `Limit` over `Index Scan Backward using
  access_effects_unique_subscription_source_version_index`, with a
  `subscription_id` index condition. The same-version
  race leaves one row and both writers return the same identity; different
  source versions preserve the newest target.
- Caller-owned rollback: passed; the effect is absent after outer rollback.
- `git diff --check`: passed on the correction diff. Formatting, strict Credo,
  and `mix ash_postgres.generate_migrations --check`: passed.

### Performance & Scaling Review

- **Hot:** Establish/replay and current-target lookup are Subscription
  orchestration calls. The parent Subscription row lock serializes a single
  Subscription's target establishment and allows unrelated Subscriptions to
  proceed independently.
- **Warm/cold:** Historical evidence is cold. Current target reads are
  one-row bounded by `ORDER BY source_version DESC LIMIT 1`; no history scan
  or N+1 relationship load is used.
- **Database queries and indexes:** Establishment is four data queries,
  replay is two, and current lookup is one. The unique identity index backs
  replay arbitration and bounded current lookup (PostgreSQL backward scan).
  There is no duplicate descending index. The concurrency tests verify
  PostgreSQL blocking and row counts rather than application-only
  read-before-write behavior.
- **Caching:** No cache, ETS, Redis, TTL, invalidation, or stampede mechanism
  was introduced. PostgreSQL is the durable source of truth.
- **Oban and idempotency:** No worker/job path is added. Business replay
  identity is the PostgreSQL Subscription/source-version constraint plus the
  complete target fingerprint, not queue uniqueness.
- **Telemetry/logging:** No production telemetry or logging changes are
  introduced. The façade does not log target evidence.

### Warnings and limits

- Repository tests emit existing unused optional-argument warnings in
  `renewal_attempt_monotonicity_test.exs` and
  `stored_payment_method_revocation_test.exs`; strict Credo reports no issues.
- Sobelow reports existing low-confidence findings outside the AccessEffect
  implementation. Documentation generation also reports existing hidden
  nested-type references in the Orders inventory admission module.
- The repository migration tests explicitly rerun older migration modules
  after the current newest version and emit Ecto migration-order warnings.
  The clean fresh-database migration itself ran in timestamp order and
  completed successfully.
- This evidence records local implementation validation. The task PR's
  exact-head CI and independent controller review remain tracked on the PR; no
  merge or final acceptance is claimed here.

## JC-289 / SBH-50-06 implementation closure — v0.1.30 governance (2026-09-30)

This entry is a separate post-merge closure record. The governance admission
sections above (including v0.1.28 PR #82 and v0.1.29 NewYou conformance) and
the implementation evidence section immediately preceding this entry remain
historical records and are not rewritten to imply merge verification existed at
implementation-authoring time.

### Links consulted

- `AGENTS.md`
- `docs/agent_rules/active_workstreams.md` from current `origin/main`
- `docs/hardening/subscriptions/SUBSCRIPTION_HARDENING_MASTER_REGISTER.md` v0.1.29 → v0.1.30 closure amendment
- [Implementation PR #94](https://github.com/JCSchoeman96/Store_Blueprint_Hardening/pull/94)
- [Exact-head CI run 36704326821](https://github.com/JCSchoeman96/Store_Blueprint_Hardening/actions/runs/36704326821)
- [PR #78, unrelated open JC-229 / SBH-10-04 work](https://github.com/JCSchoeman96/Store_Blueprint_Hardening/pull/78)

### Closure evidence

```text
task base (task_base_sha)     = a67958f36cf8e243b260d72d3cab3bd8e48d5b28
successful final impl head    = 152e006e6d2c68489c5c49a16f842c72e08a38cb
merge commit                  = da485d8e70b46c379ae205a90b5558c2851657a9
certified-head tree           = 42043d0c1db2ba298b5bef7cdcb78558dd3573de
merge tree                    = 42043d0c1db2ba298b5bef7cdcb78558dd3573de
exact-head required CI run    = 36704326821 (all five required jobs PASS)
independent implementation review = PASS (controller-verified)
merged-on-target verification = origin/hardening/subscriptions at merge SHA above
Linear JC-289                 = Done (controller-verified post-merge evidence)
repository test result        = 738 tests, 0 failures (exact-head CI)
migrations / snapshots        = exactly one JC-289 migration and one matching snapshot
```

### Scope and boundaries preserved

- Final bounded scope: Subscription-owned `AccessEffect` foundation only; no
  Entitlements production mutation, worker, cache, or external access side
  effect.
- No post-merge content drift: merge tree is content-identical to the certified
  final implementation head.
- JC-222 lifecycle and JC-223 dependency edges remain unchanged.
- Downstream issue admission (JC-245, JC-246, JC-247, JC-248, JC-239,
  JC-242, and others) remains separate; satisfying the JC-289 prerequisite does
  not READY-promote those rows.

### Verification record (governance amendment only)

- Closure amendment base verified as
  `da485d8e70b46c379ae205a90b5558c2851657a9` before editing.
- Only the two authorized governance/evidence documents are in scope for this
  closure PR.
- Independent controller review of the governance PR remains pending; this note
  does not claim final PASS for the closure amendment itself.

## v0.1.31 SBH-50 access-convergence rollout-order review

### Links consulted

- [Repository instructions](../../AGENTS.md).
- Current [active-workstream registry](../agent_rules/active_workstreams.md)
  read from origin/main at a74d3f05a5f250300d0c2293f294e77785f6818f.
- [Subscription Hardening Master Register](../hardening/subscriptions/SUBSCRIPTION_HARDENING_MASTER_REGISTER.md)
  v0.1.30 at the exact review base, including the JC-223 matrix, SBH-50 law,
  and v0.1.30 closure.
- [Subscription domain map](../hardening/01_domain_map.md).
- [Subscription lifecycle registry](../hardening/02_lifecycle_registry.md).
- [JC-223 live Linear contract](https://linear.app/jc-dev/issue/JC-223/sbh-00-05-freeze-first-executable-dependency-graph-and-hardening).
- [JC-245 live Linear contract](https://linear.app/jc-dev/issue/JC-245/sbh-50-02-durable-active-entitlement-issuance-recovery).
- [JC-246 live Linear contract](https://linear.app/jc-dev/issue/JC-246/sbh-50-03-durable-terminal-entitlement-revocation-recovery).
- [JC-247 live Linear contract](https://linear.app/jc-dev/issue/JC-247/sbh-50-04-enforce-access-on-past-due-and-access-on-cancel).
- [JC-230 live Linear contract](https://linear.app/jc-dev/issue/JC-230/sbh-10-05-reconciliation-applies-charged-contract-only).
- [JC-229 live Linear contract](https://linear.app/jc-dev/issue/JC-229/sbh-10-04-renewal-initiation-uses-bound-contract).
- Runtime sources: [AccessEffect](../../lib/store/subscriptions/access_effect.ex),
  [Subscriptions facade](../../lib/store/subscriptions/facade.ex),
  [Entitlements facade](../../lib/store/entitlements/facade.ex), and
  [Entitlements cache](../../lib/store/entitlements/cache.ex).

### Decisions and pins

1. The review branch starts from
   16df6f77eea01c148acc3fa0856a7bc81aa74025, the fetched
   origin/hardening/subscriptions tip. The registry's dynamic status entry
   still names f621d2db355d3ef2c1531f73b0c698a323cc768e, but its SUBS path,
   branch, upstream, and ownership match the live workstream. The registry is
   not changed.
2. The current AccessEffect foundation has no production source-path caller
   and no executor. Immediate cancellation and grace expiry commit Subscription
   truth, then directly mutate Entitlements. PAST_DUE and scheduled cancellation
   do not establish effects from their access policies. An older active effect
   can therefore remain the latest durable target after direct Entitlements
   mutation.
3. The governing invariant is that no AccessEffect executor becomes
   production-eligible until every access-changing source transition that can
   supersede a target establishes a newer target under the same source-order
   authority. The complete scenario matrix, current state, source transaction,
   target owner, and executor owner are recorded in Master Register section 51.
4. The pressure test covers pending active effects followed by immediate
   cancellation, grace expiry, PAST_DUE policy changes, and scheduled
   cancellation policy changes; it also covers old active versus newer
   non-effective execution, old revoke versus active recovery, and scope A
   versus scope B. Direct Entitlements mutation, queue state, worker state,
   grant state, Cachex, PubSub, and Subscription aggregate equality are not
   ordering evidence. Aggregate version remains provenance and may have gaps.
5. The three frozen issue contracts cannot safely sequence production
   eligibility on their own. JC-245 and JC-246 execute active and
   non-effective targets but do not own all target-producing transitions.
   JC-247 derives policy targets but does not execute them. No current contract
   defines the state that keeps executors ineligible until source coverage and
   the shared fence are proven. The decision is
   GOVERNED_WORK_ITEM_SPLIT_REQUIRED. No JC or SBH identifier is assigned.
6. The minimum separately governable capability is a complete access-source
   coverage matrix plus an executor cutover gate. It covers initial paid
   activation; contract and entitlement-scope changes; paid renewal from the
   exact JC-230 result; PAST_DUE, grace, and suspension; immediate cancellation;
   scheduled cancellation, rescission, and period-boundary expiry. Each path
   must atomically establish a changed target with source truth or prove the
   current target remains exact. It must prevent un-fenced legacy writes and
   require both dispositions to share the same execution fence.
7. Ownership remains exact. JC-247 selects and records purchased-policy
   targets. JC-245 executes active targets and consumes the exact paid contract
   from JC-230. JC-246 executes non-effective targets and does not infer them
   from status. JC-245 and JC-246 reuse one executor fence. No policy moves to
   JC-245 or JC-246, and JC-247 gains no execution behavior.
8. JC-230 remains Backlog and is blocked by JC-228 and JC-229. JC-229 remains
   unresolved. No charged-contract interpretation is imported into JC-245.
   The bounded Entitlements shared authority remains unassigned. JC-245,
   JC-246, and JC-247 remain Backlog / non-executable. Canonical READY
   implementation/proof rows remain zero. No implementation task_base_sha or
   production implementation branch is assigned.
9. JC-222 lifecycle law remains unchanged. JC-223 remains
   CONTRACT_FROZEN / CANONICAL with its existing edges. This source-coverage
   and production-eligibility gate is not a JC-223 dependency edge, so no
   graph amendment or supersession is made. PR #78 remains untouched.

### Plan

1. Append the v0.1.31 correction after the v0.1.30 historical section in the
   Master Register.
2. Record this review, its source links, ownership boundaries, plan, and
   performance review in this Phase 27 note.
3. Inspect the exact-base diff, verify only the Master Register and this note
   changed, check that historical JC-222 law and JC-223 edges are unchanged,
   confirm zero READY implementation rows and no task base, and run
   git diff --check plus the repository governance and documentation gates.
4. Push the governance branch and open a PR against hardening/subscriptions.
   Do not merge. PR exact-head CI and independent review remain acceptance
   gates; this note does not claim implementation admission or final PASS.

### Performance & Scaling Review

- Hot paths are Subscription source commits and future active/non-effective
  AccessEffect execution. This governance review adds no runtime path.
- Warm behavior includes the per-user Entitlements Cachex entry and PubSub
  invalidation. Neither cache state nor message delivery may order targets.
  Future invalidation must follow the Entitlements transaction commit.
- Cold work includes later repair and reconciliation. It must remain bounded
  and indexed; no full history scan is added by this review.
- The change runs no application database queries. Future implementation
  must measure source-write, current-target, and Entitlements query counts and
  check N+1 risk.
- The existing Subscription/source-version index bounds current-target reads.
  This review adds no index or migration authority.
- No Oban worker, uniqueness rule, or idempotency key changes here. Durable
  AccessEffect ordering remains authoritative; Oban can trigger recovery but
  cannot establish target precedence.
- No telemetry or logging changes are made.

## v0.1.32 JC-300 / SBH-50-07 source-coverage and executor-cutover freeze

### Goal

Validate the post-JC-223 AccessEffect source-coverage finding and freeze only
the coverage matrix and production-eligibility gate. JC-300 receives no source
transition, business-policy, executor, Entitlements, or implementation
authority from this governance record.

### Links consulted

- [Repository instructions](../../AGENTS.md).
- Current [active-workstream registry](../agent_rules/active_workstreams.md)
  and the v0.1.31 source-coverage evidence in this Phase 27 note.
- [Subscription Hardening Master Register](../hardening/subscriptions/SUBSCRIPTION_HARDENING_MASTER_REGISTER.md),
  v0.1.31 before this amendment and section 52 after it.
- Live tracker evidence supplied on 2026-09-30 for
  [JC-300](https://linear.app/jc-dev/issue/JC-300/access-effect-source-order-coverage-and-executor-production-cutover),
  [JC-223](https://linear.app/jc-dev/issue/JC-223/sbh-00-05-freeze-first-executable-dependency-graph-and-hardening),
  [JC-230](https://linear.app/jc-dev/issue/JC-230/sbh-10-05-reconciliation-applies-charged-contract-only),
  [JC-239](https://linear.app/jc-dev/issue/JC-239/sbh-30-04-enforce-failed-payment-suspension-boundary),
  [JC-242](https://linear.app/jc-dev/issue/JC-242/sbh-40-02-durable-period-boundary-terminalization),
  [JC-245](https://linear.app/jc-dev/issue/JC-245/sbh-50-02-durable-active-entitlement-issuance-recovery),
  [JC-246](https://linear.app/jc-dev/issue/JC-246/sbh-50-03-durable-terminal-entitlement-revocation-recovery),
  and
  [JC-247](https://linear.app/jc-dev/issue/JC-247/sbh-50-04-enforce-access-on-past-due-and-access-on-cancel).
- Runtime source: [AccessEffect](../../lib/store/subscriptions/access_effect.ex),
  [Subscriptions facade](../../lib/store/subscriptions/facade.ex),
  [Entitlements facade](../../lib/store/entitlements/facade.ex), and
  [Entitlements cache](../../lib/store/entitlements/cache.ex).
- The current repository-wide GitHub and workspace-wide Linear searches,
  including archived issues, returned zero exact `SBH-50-07` matches.

### Decisions and pins

1. A successful local narrow fetch refreshed `origin` and confirmed
   `origin/hardening/subscriptions` and `FETCH_HEAD` both equal
   `e2e01a7572488e9012b88e80e8ee36fd1e1a6e8c`. The dedicated governance
   worktree is clean before editing and based on that exact SHA.
2. The source audit confirmed both direct grant and direct revoke bypasses:
   initial paid activation and paid renewal grant directly; immediate
   cancellation and grace expiry revoke directly. No production source caller
   currently establishes AccessEffect. PAST_DUE/grace and scheduled
   cancellation/rescission targets are missing; suspension and period-boundary
   terminalization capabilities are absent from current runtime. The paid
   renewal path does not consume JC-230's exact charged-contract result.
3. Current Entitlements issue/revoke APIs do not meet the shared stale-safe
   executor boundary. Exact source convergence, caller-owned transaction
   composition, complete results, write-failure propagation, and after-commit
   cache/PubSub remain a separate, unassigned authority gate.
4. The frozen invariant prohibits production eligibility until every
   access-changing source transition establishes its correct complete target
   in the source transaction or proves the existing current target exact.
   The shared Postgres fence must serialize source authority, re-read the
   current AccessEffect, prove the exact effect remains current, converge
   Entitlements under the same fence, and record APPLIED only for that target.
5. Master Register section 52 contains the 16-row mandatory matrix. It records
   lifecycle owner, transaction/evidence, disposition/scope/boundary,
   target-change rule and source-version provenance, derivation/execution
   ownership, stale-work proof, and the legacy direct mutation to remove or
   fence for initial paid activation, non-entitled activation, kind/scope
   changes, other access-changing ContractChanges, paid renewal, PAST_DUE
   entry/continuation, grace expiry, suspension, immediate/scheduled
   cancellation, rescission, period-boundary terminalization, governed expiry,
   recovery, and scope A to B replacement.
6. The exact boundaries remain: JC-247 interprets purchased
   `access_on_past_due` / `access_on_cancel`; JC-245 executes effective targets;
   JC-246 executes non-effective targets; JC-230 supplies paid-renewal
   charged-contract truth; JC-239 owns failed-payment suspension; JC-242 owns
   period-boundary terminalization. JC-300 owns coverage and cutover proof
   only.
7. JC-300 is recorded as a new finding after the JC-223 freeze and advances
   `CANDIDATE → VALIDATED → CONTRACT_FROZEN`. The assigned identifier is
   `SBH-50-07 — Access-Source Coverage and Executor Production Cutover`.
   JC-223's historical edges remain unchanged; JC-300 is related only and no
   formal graph edge is added. Existing JC-245/246/247 relations are unchanged.
8. JC-300 remains Backlog in Linear pending merged and independently verified
   governance evidence. It has no implementation authority, READY state, or
   `task_base_sha`. JC-245, JC-246, and JC-247 remain non-executable; the
   Entitlements shared authority is unassigned; canonical READY
   implementation/proof rows remain zero.
9. Source capability blockers use `BLOCKED_DEPENDENCY`; the separate
   Entitlements seam is recorded as `BLOCKED_SHARED_AUTHORITY`. These are
   separate gates. The frozen JC-223 dependency graph, post-JC-223 capability
   gates, and shared-authority requirement are not conflated.
10. No production code, tests, migrations, Ash snapshots, dependencies,
    configuration, workers, Entitlements code, active-workstream registry,
    or Linear state is changed. The docs-sync gate requires the existing
    Phase 27/27A notes and does not require another file to register the ID.

### Plan

1. Append the v0.1.32 provenance, source findings, invariant, complete coverage
   matrix, ownership and capability gates, and cutover proof to Master Register
   section 52.
2. Record the same decisions, evidence links, scope, and performance review in
   this Phase 27 note.
3. Inspect the exact-base diff. Confirm only the Master Register and this note
   changed; confirm v0.1.32, globally unused identifier before assignment,
   post-JC-223 provenance, matrix dimensions, separated ownership, unchanged
   JC-223 edges, zero READY rows, no task base, and no implementation or
   Entitlements authority.
4. Run `git diff --check`, formatting and documentation/governance gates, and
   full `mix check` where supported. Push the governance branch and open a PR
   against `hardening/subscriptions`; do not merge. Independent review and
   exact-head CI remain pending. Do not update Linear before post-merge
   verification.

### Performance & Scaling Review

- Hot paths are Subscription source transitions and future active/non-effective
  AccessEffect execution. This governance edit adds no runtime path.
- It performs no application database queries. Future work must record source,
  current-target, and Entitlements query counts and N+1 risk.
- Existing Subscription/source-version indexes must bound current-target
  reads. This review authorizes no index, migration, or full history scan.
- No cache or TTL changes are made. Cache invalidation and PubSub follow commit
  and cannot establish target order.
- No Oban worker or idempotency policy changes are made. Missing enqueue must
  be recoverable from durable AccessEffect state; queue order is not authority.
- No telemetry or logging changes are made.

## v0.1.33 Entitlements shared-authority consumption

### Goal

Consume the bounded Entitlements shared-authority grant that became canonical
on `main` after PR #98. This update removes the separate shared-authority
blocker from SBH-50-07 while keeping its source-capability blocker and keeping
JC-300, JC-245, and JC-246 non-executable.

### Links consulted

- [Repository instructions](../../AGENTS.md), read from canonical `origin/main`.
- [Current active-workstream registry](../agent_rules/active_workstreams.md), read from canonical `origin/main`.
- [Subscription Hardening Master Register](../hardening/subscriptions/SUBSCRIPTION_HARDENING_MASTER_REGISTER.md), v0.1.32 §52 at exact SUBS base `ec3a4d75175732b6ce95f3f288783591a1b1504b`.
- [Canonical Entitlements authority amendment](../governance/sbh_50_access_effect_entitlements_authority_amendment.md) from canonical main `a57d359ffe8fba0435d23d68d6243173d194f243`.
- [PR #98](https://github.com/JCSchoeman96/Store_Blueprint_Hardening/pull/98), merged as `a57d359ffe8fba0435d23d68d6243173d194f243` from certified head `e43f760934bd62071d3ee079420d21a229e37cec`.
- Live tracker records for [JC-300](https://linear.app/jc-dev/issue/JC-300/sbh-50-07-access-source-coverage-and-executor-production-cutover), [JC-245](https://linear.app/jc-dev/issue/JC-245/sbh-50-02-durable-active-entitlement-issuance-recovery), [JC-246](https://linear.app/jc-dev/issue/JC-246/sbh-50-03-durable-terminal-entitlement-revocation-recovery), [JC-230](https://linear.app/jc-dev/issue/JC-230/sbh-10-05-reconciliation-applies-charged-contract-only), [JC-229](https://linear.app/jc-dev/issue/JC-229/sbh-10-04-renewal-initiation-uses-bound-contract), [JC-228](https://linear.app/jc-dev/issue/JC-228/sbh-10-03-immutable-renewalattempt-charged-contract-snapshot), [JC-239](https://linear.app/jc-dev/issue/JC-239/sbh-30-04-enforce-failed-payment-suspension-boundary), and [JC-242](https://linear.app/jc-dev/issue/JC-242/sbh-40-02-durable-period-boundary-terminalization).

### Decisions / pins

1. The governance branch starts from exact SUBS authority
   `ec3a4d75175732b6ce95f3f288783591a1b1504b`. Canonical main is
   `a57d359ffe8fba0435d23d68d6243173d194f243`.
2. PR #98's certified head `e43f760934bd62071d3ee079420d21a229e37cec` and
   merge commit have the identical tree
   `277d6c898da068c109f4bc8d42b8ce5e45abb9a5`. Exact-head CI run
   `36773404741` passed all five required jobs, and the repository evidence is
   3 properties, 605 tests, and 0 failures.
3. PR #98 is governance/docs-only. It adds no shared runtime, dependency,
   schema, configuration, provider, or CI integration requirement. SUBS reads
   the canonical amendment by reference and does not merge `main` merely to
   obtain it. Future implementation admission must inspect current `main`
   again.
4. The consumed grant is a current unused bounded Entitlements authority for
   the common Subscription-source exact convergence primitive and its
   post-outer-commit Cachex/PubSub projection helper. It does not move
   Subscription lifecycle, target selection, source ordering,
   current-AccessEffect selection, or policy authority to Entitlements. It is
   not completed provenance and does not admit implementation. It is jointly
   assigned to `SBH-50-02` / JC-245 for active/effective execution and recovery
   through the common fence and to `SBH-50-03` / JC-246 for non-effective
   execution and recovery through the same fence. SBH-50-07 / JC-300 consumes
   proof that the required common seam has authority; it does not own
   implementation of that seam. This is one explicit common-seam exception to
   the row-specific authority rule, not a programme-wide Entitlements grant.
5. The state transition is:

   ```text
   SBH-50-07 implementation/proof: BLOCKED_DEPENDENCY / No
   SBH-50-07 Entitlements shared-authority gate:
     BLOCKED_SHARED_AUTHORITY / unassigned
     → AUTHORITY_ASSIGNED / current bounded grant
   ```

   This removes only the shared-authority blocker. Source capabilities remain
   incomplete, so SBH-50-07 remains `BLOCKED_DEPENDENCY`.
6. JC-300 remains `Backlog / CONTRACT_FROZEN / READY No` with no formal
   `blocks` or `blockedBy` edge. JC-245 and JC-246 remain Backlog and
   non-executable. Canonical READY implementation/proof rows remain zero, and
   `implementation task_base_sha = none`.
7. JC-230 remains Backlog and blocked by JC-229; JC-228 is Done. JC-239
   remains blocked by JC-230 and its other recorded lifecycle prerequisites.
   JC-242 remains blocked by JC-229, JC-230, and its other recorded
   prerequisites. JC-247 remains the policy-target owner. No JC-300 formal
   dependency edge is added, and historical JC-223 edges are unchanged.
8. The source-capability blockers remain explicit: exact paid-renewal truth
   from JC-230, suspension lifecycle from JC-239, period-boundary
   terminalization from JC-242, policy-driven target establishment from JC-247,
   and the later JC-245/JC-246 executor work. The combined state is:

   ```text
   CONTRACT_FROZEN
   + Entitlements authority assigned
   + source capabilities incomplete
   = still non-executable
   ```

9. AccessEffect persists `valid_until_at` but has no explicit target
   `valid_from_at`. Future Entitlements work must preserve an existing durable
   start when correct and require exact durable start evidence for a new grant.
   It must not use worker execution time. If a covered case needs a historical
   start that AccessEffect cannot represent or deterministically provide, stop
   at SUBS target authority and request the smallest upstream contract change.
   This amendment does not authorize an AccessEffect schema change.
10. This update does not select JC-245, JC-246, or the next upstream task. Once
    this governance PR is merged and independently verified, run a fresh
    serial-admission review against the then-current repository. The JC-229 to
    JC-230 chain may be the most consequential blocker, but no admission is
    made here.

### Shared-authority reconciliation

Section 24 now records the PR #98 grant as a current unused bounded common-seam
authority on both executor rows:

```text
SBH-50-02 / JC-245
shared authority = AUTHORITY_ASSIGNED
scope = exact PR #98 bounded Entitlements convergence seam
execution consequence = BLOCKED_DEPENDENCY / non-executable

SBH-50-03 / JC-246
shared authority = AUTHORITY_ASSIGNED
scope = exact same common PR #98 convergence seam
execution consequence = BLOCKED_DEPENDENCY / non-executable
```

The authority applies only to these explicitly named rows and the bounded
surface. It is not reusable as a programme-wide Entitlements grant. SBH-50-07
/ JC-300 remains `AUTHORITY_ASSIGNED` only as proof that the required common
seam has authority; it does not own seam implementation. SBH-50-04 and
SBH-50-05 remain `EXTERNALIZED` and must still stop if their work would require
Entitlements core modification.

### Plan

1. Update the Master Register to v0.1.33, preserve §52 as historical evidence,
   record the current Entitlements authority assignment, and keep all source
   and validity blockers explicit.
2. Append this Phase 27 evidence with the authority pins, live issue state,
   validity-start stop rule, main-to-SUBS integration decision, and performance
   review.
3. Check the exact-base diff and changed paths. Verify PR #98 provenance,
   certified/merge tree equality, zero READY rows, no task base, unchanged
   JC-223 edges, no formal JC-300 dependency edge, and no production
   integration from main.
4. Run `git diff --check`, documentation/governance checks, and full `mix check`
   where the local environment supports them. Open a PR against
   `hardening/subscriptions`; do not merge or update Linear.

### Performance & Scaling Review

- Hot paths: This docs-only update adds no runtime path or application query. Future source and executor work must report source-write, current-target, and Entitlements query counts and N+1 risk.
- Warm paths: Cachex and PubSub remain read projections. Invalidation follows the outer transaction commit. The existing 60-second `EntitlementSet` TTL, cache keys, and stampede behavior are unchanged.
- Cold paths: Projection failure after a committed grant mutation must be repaired by the idempotent post-commit helper without rerunning grant truth. No generic outbox is added.
- Indexes: Future exact-source locking must use the existing EntitlementGrant source index and avoid a broad user scan. No index or migration is authorized here.
- Oban and idempotency: No worker uniqueness changes are made. Projection retries must remain safe after an already-`APPLIED` AccessEffect and must not repeat the grant mutation.
- Telemetry and logging: This amendment adds no instrumentation. Future implementation must record source identity, target fingerprint, convergence result, outer-transaction result, cache invalidation result, broadcast result, and projection retry outcome.

### Verification record

- Worktree: `.worktrees/governance-sbh-50-entitlements-authority-consumption`.
- Branch: `subs-governance/sbh-50-entitlements-authority-consumption`.
- Exact task base: `ec3a4d75175732b6ce95f3f288783591a1b1504b`.
- Changed paths are limited to the Master Register and this Phase 27 note.
- PR review, exact-head CI, human merge, and post-merge tree verification are
  pending. This note does not claim implementation admission or final PASS.

## v0.1.34 JC-229 / SBH-10-04 renewal initiation re-admission

### Links consulted

- [`AGENTS.md`](../../AGENTS.md), including branch, worktree, authority, and
  closure rules.
- [`active_workstreams.md`](../agent_rules/active_workstreams.md), read from
  canonical `origin/main` and the current SUBS worktree.
- [`SUBSCRIPTION_HARDENING_MASTER_REGISTER.md`](../hardening/subscriptions/SUBSCRIPTION_HARDENING_MASTER_REGISTER.md),
  v0.1.33 at the exact SUBS base.
- [`sbh_10_04_cross_domain_authority_amendment.md`](../governance/sbh_10_04_cross_domain_authority_amendment.md).
- [`checkout_interlocks.md`](../governance/checkout_interlocks.md),
  [`payment_provider_contract.md`](../governance/payment_provider_contract.md),
  and [`inventory_reservations.md`](../governance/inventory_reservations.md).
- [`s0_inventory_reservation_admission_architecture.md`](../hardening/s0_inventory_reservation_admission_architecture.md).
- Current source in `lib/store/subscriptions`, `lib/store/payments`,
  `lib/store/orders`, `lib/store/workers`, the S0 exact-generation migration,
  and focused exact-generation tests.
- [PR #78](https://github.com/JCSchoeman96/Store_Blueprint_Hardening/pull/78),
  [PR #117](https://github.com/JCSchoeman96/Store_Blueprint_Hardening/pull/117),
  [PR #118](https://github.com/JCSchoeman96/Store_Blueprint_Hardening/pull/118),
  and [PR #119](https://github.com/JCSchoeman96/Store_Blueprint_Hardening/pull/119).

### Decisions and pins

1. The governance branch is `governance/subs-sbh-10-04-readmission`, based on
   `bf56afdd4d329a95c1739cce327b19fb1777815f`. The accepted SUBS tree is
   `7c3b5b3fd5367edf965e3b48b5128a9dd73d8dc4`. Canonical `main` is
   `aa90dd56a0325b0ada0df610067f9b9549bd4e5f`.
2. PR #117's certified head is `aaf33a1abf68d65c00b8cf10a43225350c5bbdc5`,
   merged as `f2d3ed27476d1d8bfdda2a28dcdbfe6a1d02e2d9`, with exact-head CI
   `36968312583` passing all five jobs. PR #118 merged as `e99237aa3a4a46d9ed7250d3eb9426bd9f2bee4f` and kept JC-229 blocked.
3. PR #119's corrected certified head is
   `b29d03596ee848677301d6478354d5d61b75180f`, merged as
   `bf56afdd4d329a95c1739cce327b19fb1777815f`. The certified and merge trees
   are equal. Exact-head CI `36977385707` passed all five jobs with 3
   properties, 789 tests, and 0 failures.
4. PR #78 remains stale open/draft evidence. It is not rebased, resumed, or
   merged. No implementation `task_base_sha` is assigned by this amendment.
5. The current SUBS source now has the exact renewal-generation key and the
   typed `InventoryAdmission` and `Orders` reserve, recover, release, and
   consume operations. PostgreSQL remains inventory authority. Generic paths
   exclude renewal-generation keys, terminal rows are not reactivated, and the
   partial active-pair index prevents two active generations for one Order and
   variant.
6. The current reconciliation handoff remains unsafe for sequential
   collections. The admitted implementation must carry exact `order_id`,
   `renewal_attempt_id`, `collection_attempt_id`, and `payment_intent_id`, then
   fail closed on mismatched durable evidence. It must not redefine SBH-10-05,
   rewrite the legacy RenewalAttempt pointer, or promote mutable pending state.
7. SBH-10-04 transitions `BLOCKED_SHARED_AUTHORITY → READY` with a bounded
   `AUTHORITY_ASSIGNED` grant. SBH-10-05 remains `BLOCKED_DEPENDENCY / No`.
   No other row is promoted, and the JC-223 dependency graph is unchanged.

### Plan

1. Update the Master Register to v0.1.34, superseding the current blocked
   verdict with the exact-base source review and bounded authority assignment.
2. Record the same authority pins, links, handoff boundary, scope, and
   performance review in this Phase 27 note.
3. Confirm that the exact-base diff changes only this Master Register and this
   note. Confirm no runtime, migration, snapshot, dependency, configuration,
   or task branch changes.
4. Run `git diff --check`, documentation/governance checks, and full `mix check`.
   Push the governance branch and open a PR against `hardening/subscriptions`.
   Request independent review and exact-head CI, then stop. Do not merge or
   begin Phase B implementation.

### Performance & Scaling Review

- Hot paths: future collection creation/replay, exact reservation generation
  reserve/recover/release/consume, provider webhook success, and exact
  reconciliation handoff.
- Warm paths: ambiguous provider recovery and bounded authentication or
  cancellation reconciliation for one collection identity.
- Cold paths: governance review and unresolved operator recovery. This note and
  its register amendment add no application query.
- PR #117 measured exact reserve-new at 10 queries, exact replay at 4,
  recovery at 1, release at 9, and consume at 9. The exact operations use
  bounded key lookups and row locks. Future collection work must report query
  counts and N+1 risk.
- Current authority indexes are the global reservation-key uniqueness,
  partial active `(order_id, variant_id)` index, and PaymentApplication Order
  and PaymentIntent indexes. No index or migration is authorized here.
- Availability invalidation remains after PostgreSQL mutation. Redis remains
  coordination only. No TTL, ETS, Redis, Cachex, or stampede policy changes.
- No Oban uniqueness change is made. Future workers must use exact collection
  identity and remain replay-safe; queue order is not payment or inventory
  authority.
- No telemetry changes are made. Future implementation must record collection
  identity, dispatch epoch, financial outcome, exact PaymentIntent attribution,
  and unresolved age without provider secrets.

### Verification record

- Worktree: `.worktrees/governance-subs-sbh-10-04-readmission`.
- Branch: `governance/subs-sbh-10-04-readmission`.
- Exact governance base: `bf56afdd4d329a95c1739cce327b19fb1777815f`.
- Canonical main observed: `aa90dd56a0325b0ada0df610067f9b9549bd4e5f`.
- Changed paths are limited to this Phase 27 note and the Master Register.
- PR review, exact-head CI, human merge, and independent post-merge tree
  verification remain required. This note does not claim runtime completion.
