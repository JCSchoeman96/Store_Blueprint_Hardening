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
9. Physical renewals are now charge-safe:
   - catalog and variant-plan blockers are retry-suppressed hard failures
   - inventory is reserved before Stripe and explicitly released on known failure paths
   - shipping is re-quoted live, but large quote drift is blocked by a surge circuit breaker

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
3. One bound RenewalAttempt and one Order remain the commercial occurrence.
   Sequential collection attempts receive distinct durable identities,
   PaymentIntents, and provider idempotency keys. A replacement Order cannot
   be used for a dunning retry.
4. Ambiguous provider outcomes replay the same collection attempt, PaymentIntent,
   and provider key. A new collection attempt requires durable evidence of
   terminal provider/payment non-success and an eligible dunning decision.
   `requires_action` stays on the same attempt and PaymentIntent. A local
   `cancelled` or expired state after possible submission is not terminal proof.
5. A physical collection attempt needs its own reservation generation. A
   terminal reservation is never reactivated. Its hold remains active through
   a prepared attempt that a worker could submit, `requires_action`, or an
   unknown provider result. A local TTL cannot release the hold by itself. A
   pre-submission `not_submitted` dispatch requires a durable fence that
   prevents any worker from starting provider work; resumption retains the
   same collection and PaymentIntent/provider identities.
6. `docs/governance/inventory_reservations.md` now records the target lifecycle.
   Frozen S0-ARCH-01 still uses `order_id + variant_id` for admission and
   recovery. Its owner must accept a compatible collection identity before
   Orders or InventoryAdmission implementation begins.
7. No Orders, InventoryAdmission, Payments, provider, migration, Ash snapshot,
   or Subscription collection-record implementation authority is assigned.
   The governance target defines per-collection PaymentIntent and provider key
   identity; the previous SBH-10-04 implementation grant is superseded and
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
   Orders/Payments source contract, provider implementation, or dependency edge.
   It amends the provider governance target and leaves implementation blocked.
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
    `renewal_key`; the v0.1.27 target derives both identities from a durable
    `collection_attempt_id`. The current `requires_action` path releases the
    physical reservation; this remains an unmodified runtime safety gap.
13. SBH-10-05's payment-application and reconciliation semantics remain
    unchanged. The current path's ability to associate a later collection
    PaymentIntent without replacing the RenewalAttempt's original pointer has
    not been proven; resolve that boundary or stop before re-admission.

### Plan

1. Update the master register's current status, SBH-10-04 authority requirements,
   and latest serial verdict while preserving v0.1.26 as historical evidence.
2. Record the physical collection hold target and InventoryAdmission gate in
   `docs/governance/inventory_reservations.md`.
3. Align renewal key targets in checkout/provider interlocks and distinguish
   the blocked target from current runtime observations in the domain map and
   lifecycle registry.
4. Review the exact-base diff for docs-only paths and verify that the JC-223
   dependency table is unchanged.
5. Open a separate governance PR from the exact accepted SUBS tip. Keep PR #78
   draft and unmerged. Complete independent review, exact-head CI, and human
   merge gates before any new implementation admission.

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
- Caching: no Redis or cache behavior changes. S0-ARCH-01 remains frozen; a
  future owner-approved design must preserve PostgreSQL as inventory truth and
  carry the generation through admission and recovery.
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
  `08b28937c001b4f35350bcf5de6fdd052fc7a4c3`, exact parent, exact-head CI
  `36144853740` success.
- At this note's reviewed head, governance PR #79 is `OPEN / DRAFT` at
  `3eb280a944979061cdd3dc26d5aadd5cb745cb0d`, with exact parent
  `0016237646f9fddfc2364680b8cc9ddeb7c10655`. Exact-head CI run
  `36155890705`, attempt 2, passed all five required jobs. Attempt 1's standard
  performance smoke observer exceeded its Store.Repo pool-utilization cap for
  two samples; latency and query targets passed, chaos smoke passed, and the
  rerun passed. Independent review found no remaining substantive conflict.
- Governance amendment paths are the master register, inventory reservations,
  checkout interlocks, payment provider contract, subscription domain map,
  lifecycle registry, and this Phase 27 note (seven paths). No runtime or
  schema path changes.
- Governance PR merge and post-merge verification remain pending.
