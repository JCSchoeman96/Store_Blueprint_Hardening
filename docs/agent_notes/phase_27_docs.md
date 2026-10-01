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
9. Current physical renewal behavior has bounded safety gaps for sequential collections:
   - catalog and variant-plan blockers are retry-suppressed hard failures
   - inventory is reserved before Stripe, but the current `requires_action` path releases the hold while the payment can still succeed
   - the current retry path can re-quote shipping and rewrite totals; a surge circuit breaker limits drift but does not replace reuse of finalized Order totals
   - the SBH-10-04 amendment records the future correction; this governance change does not alter runtime behavior

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

## SBH-50 Entitlements shared-authority amendment (2026-09-30)

### Links consulted

- [`SBH-50 Entitlements shared-authority amendment`](../governance/sbh_50_access_effect_entitlements_authority_amendment.md)
- [`SBH-10-04 cross-domain authority amendment`](../governance/sbh_10_04_cross_domain_authority_amendment.md)
- [`Side Effects Quarantine`](../governance/side_effects_quarantine.md)
- [`Subscription invariant registry`](../hardening/03_invariant_registry.md)
- Official [`Ecto.Repo.in_transaction?/0`](https://ecto.hexdocs.pm/Ecto.Repo.html#in_transaction?/0), [`Ash actions`](https://ash.hexdocs.pm/actions.html), [`Ash create actions`](https://ash.hexdocs.pm/create-actions.html), and [`AshPostgres.Repo`](https://ash-postgres.hexdocs.pm/AshPostgres.Repo.html) documentation
- Accepted SUBS evidence `ec3a4d75175732b6ce95f3f288783591a1b1504b`, Master Register v0.1.32 §52
- Live Linear records for JC-300, JC-245, and JC-246, checked 2026-09-30

### Decisions and pins

- The governance branch is based on canonical main `a74d3f05a5f250300d0c2293f294e77785f6818f` and consumes accepted SUBS evidence at `ec3a4d75175732b6ce95f3f288783591a1b1504b`.
- The grant is limited to the common Subscription-source Entitlements convergence seam used by JC-245 and JC-246. It does not transfer Subscription lifecycle, target policy, or generic Entitlements ownership.
- The future function requires an explicit caller-owned `Store.Repo` PostgreSQL transaction and must fail closed outside it. It does not start or commit the outer transaction. An Ash action transaction or `after_transaction` hook is not proof that the outer source/effect transaction committed.
- The caller supplies immutable target evidence. Entitlements does not load mutable Plan or Subscription state, choose policy, determine current AccessEffect, or mark an AccessEffect `APPLIED`.
- The function converges the complete exact source `(source_kind = :subscription, source_id = subscription_id)`. An effective target leaves only its exact kind/scope active, and a non-effective target leaves no active grant for that source. Other sources remain untouched.
- `valid_from_at` may not come from worker execution time. Existing durable starts may be preserved; new grants require durable source evidence. A missing historical start boundary stops implementation at SUBS target authority.
- Grant mutation returns complete success or an error that prevents the outer transaction from committing. Partial counts and swallowed per-row errors are not success.
- Cachex invalidation and PubSub happen only after the successful outer commit. Projection failure is visible and retryable; retry repairs projections without repeating grant truth.
- JC-300, JC-245, and JC-246 remain non-READY. No task base, Linear update, SUBS register edit, or JC-223 edge change is part of this amendment.

### Plan

1. Independently review the new governance document against canonical main and the accepted SUBS evidence.
2. Run exact-base, changed-path, documentation, governance, and repository checks.
3. Open a PR against `main`; do not merge it.
4. After human merge and independent merge-tree verification, let SUBS consume the canonical authority in a separate bounded register/admission update.
5. Only a later implementation admission may add the typed input/result and focused Entitlements tests within the granted paths.

### Performance & Scaling Review

- **Hot:** The future executor locks the exact Subscription-source grant set and performs bounded convergence writes in the caller-owned transaction. Implementation evidence must include query counts, lock scope, and N+1 risk. No runtime query is added here.
- **Warm:** EntitlementSet remains a Cachex read projection with the existing 60-second TTL. Invalidation is post-commit only. No Redis, ETS, or authorization-cache authority is added.
- **Cold:** A committed grant mutation with failed cache or PubSub projection is retried through an idempotent projection helper. Projection repair does not rerun grant mutation. No generic outbox is authorized.
- **Indexes:** The later implementation must use the existing source index and grant identity without a migration or broad user scan. It must report whether exact-source locks use those indexes.
- **Oban and idempotency:** This amendment changes no worker uniqueness. A projection retry must remain safe after an already-`APPLIED` AccessEffect.
- **Telemetry and logging:** Future implementation must record source identity, target fingerprint, convergence result, transaction result, cache result, broadcast result, and projection retry outcome.

### Verification

- `git diff --check`: required and run before PR.
- Exact-base diff and changed-path audit: required. Only the new governance document and this Phase 27 note may change.
- Runtime, test, dependency, schema, migration, Ash snapshot, worker, configuration, SUBS register, Linear, and JC-223 edge audits: required to remain unchanged.
- `MIX_DEPS_PATH=/home/jcschoeman96/projects/current/Store_Blueprint_Hardening-subscriptions/deps MIX_BUILD_PATH=/home/jcschoeman96/projects/current/Store_Blueprint_Hardening-subscriptions/.worktrees/governance-sbh-50-entitlements-shared-authority/_build mix check`: static and documentation gates passed (`check.req_usage`, web-boundary gates, naming, API, moduledoc, docs notes, and subscriptions docs sync). The command then failed while creating `Store.Repo` because the test database connection lacked the `:password` credential. Full test execution remains pending a configured database environment.
