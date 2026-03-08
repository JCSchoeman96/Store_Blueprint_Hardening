# Phase 27A — Membership Subscriptions & Entitlements

## GOAL

Implement the Phase 27A membership hardening that fits the existing subscription engine:
- memberships stay inside `Store.Subscriptions` contracts plus `Store.Entitlements`
- duplicate membership purchase is blocked for active/past-due subscriptions and in-flight pending checkouts
- entitlement caching stays simple and coherent on the hot path

## LINKS CONSULTED

- `AGENTS.md`
- `docs/phases/phase_27a_membership_subscriptions_entitlements.md`
- `docs/phases/phase_27_variable_subscriptions.md`
- `docs/governance/subscriptions_rollout_rollback.md`
- `docs/governance/performance_scaling.md`

## DECISIONS / PINS

1. Membership identity is `subscription.membership_key`, derived from `entitlement_scope_key` for `:membership_access` plans.
2. Phase 27A does not auto-extend or merge duplicate membership purchases.
3. Duplicate membership protection must run in both cart add and checkout start to close the multi-tab pending-order race.
4. The eventual entitlement cache architecture is Phase 27A-local `Cachex + PubSub`; no Redis layer is introduced for this hot path.
5. Membership management lives on the same account/admin subscription detail surfaces as non-membership contracts; there is no parallel membership UI.
6. Cached entitlement evaluation must re-check `valid_to_at` against the current clock at read time; TTL never grants extra access after expiry.
7. Renewal reminders are sent only for `:active` memberships at `7`, `3`, and `1` day offsets.
8. Revocation UX is LiveView `push_event` plus client toast/modal handling, not flash-based rerender churn.

## PLAN

1. Extend subscriptions with `membership_key`.
2. Add a centralized system guard in `Store.Subscriptions.Facade`.
3. Add a cached `entitlement_set_for_user/1` read surface with post-commit invalidation.
4. Add membership lifecycle comms for reminders and access end.
5. Record Phase 27A decisions in phase notes and governance docs.

## DONE

- Added `membership_key` to the durable subscription contract and fixture/migration paths.
- Added `Store.Subscriptions.Facade.ensure_membership_purchase_allowed_for_system/2`.
- Guard blocks membership purchase when:
  - the user already has an open subscription with the same `membership_key`
  - the user already has an open checkout draft whose pending-payment order still carries the same membership plan in the current cart state
- Added focused coverage for:
  - active membership blocking add-to-cart
  - pending membership checkout blocking add-to-cart
  - pending membership checkout blocking a second checkout start after cart mutation
- Account/admin inline boundary-change surfaces now reuse the same duplicate-membership protections because all subscription cart and checkout mutations continue to pass through the guarded facades.
- Added `Store.Entitlements.Cache` with Cachex-backed hot caching and `Store.Entitlements.Facade.entitlement_set_for_user/1`.
- Cache fill uses a single-flight Cachex fallback so concurrent misses for one user trigger one DB read.
- Cache invalidation is broadcast over `Store.PubSub` only after successful entitlement writes return, and every invalidation evicts the local cache first.
- Cached entitlement access re-evaluates `valid_to_at` at read time via `effective_grants/2` and `has_entitlement?/4`.
- Added LiveView entitlement invalidation handling:
  - `AccountLive`
  - `SubscriptionsLive.Index`
  - `SubscriptionsLive.Show`
  - `ShopLive.Show`
- Revocation/membership-change UX now uses `push_event("membership_expired", ...)` and a client toast path instead of LiveView flash churn.
- Added membership comms:
  - `renewal_reminder`
  - `access_ended`
- Added subscription-backed outbox rows with `subscription_id` and new email templates for reminder/end-of-access delivery.
- Added hourly `EnqueueMembershipRenewalRemindersWorker`.
- Reminder rules:
  - `7`, `3`, and `1` day offsets
  - `status == :active` only
  - idempotent by `subscription_id + renewal_key + days_before`
- Added membership access-ended email enqueue on terminal membership loss:
  - cancel-now
  - grace-expired expiry

## NEXT

1. Add broader entitlement-aware storefront/account gating surfaces that declare required entitlements and redirect after invalidation.
2. Add the Phase 27/27A closure/performance bead coverage and final full-gate verification.

## BLOCKERS

- Host `mix` still resolves through missing `mise` shims; validation requires the Dockerized Elixir fallback until the host toolchain is repaired.

## COMMANDS RUN

- `docker run ... mix deps.get`
- `docker run ... MIX_ENV=test mix test test/store/entitlements/facade_test.exs test/store/comms/domain_test.exs test/store/subscriptions/facade_test.exs test/store/governance/subscriptions_phase_26_test.exs test/store_web/live/subscriptions_live_test.exs`

## GATES

- Focused entitlement/comms/subscription/live tests: PASS

## PERFORMANCE & SCALING REVIEW

- Hot paths:
  - entitlement checks on authenticated storefront/account/live surfaces
  - checkout start for carts with membership plans
  - hourly reminder sweep
- Query shape:
  - open-subscription check uses `user_id + membership_key`
  - pending-checkout guard uses `checkout_drafts -> orders -> cart_items -> subscription_plans`
  - entitlement cache fill reads active grants for one `user_id`
  - reminder sweep reads active membership subscriptions in hourly windows keyed off `next_renewal_at`
- Caching:
  - Cachex TTL is `60s`
  - invalidation is PubSub fanout per-user topic
  - cache hits still evaluate `valid_to_at` against current time
  - single-flight cache fill prevents miss stampedes per user key
- Remaining risk:
  - pending membership protection still depends on checkout-draft/cart evidence because pending orders do not yet persist membership-key snapshots independently
  - reminder sweep is hourly-window based, so operational downtime longer than the window could defer a reminder until the next renewal cycle
