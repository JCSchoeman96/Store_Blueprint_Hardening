# Subscriptions Rollout & Rollback Runbook (Phase 26/27)

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
4. Verify migration plan for subscription contract / renewal worker changes is present and reversible.

## Rollout Stages

1. **Schema + workers only**
   - run migrations
   - keep purchase exposure off
2. **Internal validation**
   - enable manual admin/support validation
   - verify webhook replay and renewal idempotency
   - verify due-renewal fan-out enqueues one per `subscription_id + renewal_key`
   - verify jittered renewal jobs do not burst immediately
   - verify inline Stripe SetupIntent card-update flow updates the stored payment method and immediately retries past-due subscriptions
   - verify physical renewals reserve inventory before Stripe and eagerly release reservations on known failure paths
   - verify physical-renewal shipping surge blocks move subscriptions to retry-suppressed `:past_due`
3. **Customer exposure**
   - set `expose_purchase?` to `true`
   - monitor renewal tick/process worker telemetry and entitlement outcomes
   - monitor `ReconcilePaidSubscriptionRenewalWorker` lag so paid renewal orders do not sit unreconciled
   - monitor account/admin subscription detail usage for queued boundary changes and setup-intent failures
   - monitor entitlement cache invalidation fanout and membership reminder/access-ended outbox delivery

## Rollback

If severe regression is detected:

1. Disable `expose_purchase?` immediately.
2. Disable `provider_managed_mode_enabled?` and `immediate_switching_enabled?`.
3. Set `enabled_providers` to an empty list (or remove the affected provider).
4. Pause recurring worker execution by stopping `RunDueSubscriptionRenewalsWorker` cron entry.
5. If required, pause `ProcessSubscriptionRenewalWorker` queue execution to stop in-flight renewal fan-out.
6. If required, pause `ReconcilePaidSubscriptionRenewalWorker` queue execution to stop boundary-period advancement.
7. Run reconciliation command set (below).

Do not run destructive state rewrites from web/controllers.

## Reconciliation Commands

Use these for safe post-incident recovery:

1. Re-run activation replay for affected paid orders by enqueueing:
   - `Store.Workers.EnsureSubscriptionsForPaidOrderWorker`
2. Re-run renewal tick idempotently by enqueueing:
   - `Store.Workers.RunDueSubscriptionRenewalsWorker`
3. Re-run individual renewal processing idempotently by enqueueing:
   - `Store.Workers.ProcessSubscriptionRenewalWorker`
4. Re-run paid renewal reconciliation idempotently by enqueueing:
   - `Store.Workers.ReconcilePaidSubscriptionRenewalWorker`
5. Reconcile entitlements by replaying subscription renewal/activation facades for affected subscription IDs.
6. Re-run membership reminder sweep idempotently by enqueueing:
   - `Store.Workers.EnqueueMembershipRenewalRemindersWorker`

All reconciliation must remain worker/domain-facade driven.

## Disabled Provider Webhooks (Evidence-First)

When a provider is disabled:

1. Known + signature-verified webhook receipts are still persisted.
2. Worker processing is blocked and receipt is marked failed with `PAYMENT_PROVIDER_DISABLED`.
3. No domain transitions are applied while disabled.
