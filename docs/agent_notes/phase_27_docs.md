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
8. The implementation branch and `task_base_sha` remain unassigned until after the human merge decision and independent post-merge verification of the exact merge commit and tree. The accepted SUBS tip then becomes the prospective base for JC-228 / SBH-10-03.

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
