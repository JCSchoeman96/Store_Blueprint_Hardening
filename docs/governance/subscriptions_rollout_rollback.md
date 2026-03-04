# Subscriptions Rollout & Rollback Runbook (Phase 26)

## Purpose

Operational guardrails for phased subscriptions rollout, rollback, and reconciliation.

## Feature Flags

- `:subscription_features, :expose_purchase?`
- `:subscription_features, :provider_managed_mode_enabled?`
- `:subscription_features, :immediate_switching_enabled?`
- `:payments, :enabled_providers` (backend hard gate; fail-closed)
- `:payments, :default_purchase_provider_for_ui` (UI hint only)

Defaults are fail-closed (`false`) until each stage is validated.

## Deploy Gate (MUST)

Before deploy:

1. `mix check`
2. `mix check.types`
3. `mix test test/store/subscriptions test/store/entitlements test/store/workers/subscriptions_*`
4. Verify migration plan for `phase_26_simple_subscriptions` is present and reversible.

## Rollout Stages

1. **Schema + workers only**
   - run migrations
   - keep purchase exposure off
2. **Internal validation**
   - enable manual admin/support validation
   - verify webhook replay and renewal idempotency
3. **Customer exposure**
   - set `expose_purchase?` to `true`
   - monitor renewal and entitlement telemetry

## Rollback

If severe regression is detected:

1. Disable `expose_purchase?` immediately.
2. Disable `provider_managed_mode_enabled?` and `immediate_switching_enabled?`.
3. Set `enabled_providers` to an empty list (or remove the affected provider).
4. Pause recurring worker execution by stopping `RunDueSubscriptionRenewalsWorker` cron entry.
5. Run reconciliation command set (below).

Do not run destructive state rewrites from web/controllers.

## Reconciliation Commands

Use these for safe post-incident recovery:

1. Re-run activation replay for affected paid orders by enqueueing:
   - `Store.Workers.EnsureSubscriptionsForPaidOrderWorker`
2. Re-run renewal tick idempotently by enqueueing:
   - `Store.Workers.RunDueSubscriptionRenewalsWorker`
3. Reconcile entitlements by replaying subscription renewal/activation facades for affected subscription IDs.

All reconciliation must remain worker/domain-facade driven.

## Disabled Provider Webhooks (Evidence-First)

When a provider is disabled:

1. Known + signature-verified webhook receipts are still persisted.
2. Worker processing is blocked and receipt is marked failed with `PAYMENT_PROVIDER_DISABLED`.
3. No domain transitions are applied while disabled.
