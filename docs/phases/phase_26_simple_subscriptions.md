# Phase 26 — Simple Subscriptions (recurring orders, renewal intents, cancellation)

## Goal
Add **simple subscriptions** (fixed interval, fixed price) in a way that:
- Reuses the existing **Orders / Payments / Interlocks** machinery (no parallel payment system)
- Preserves the core blueprint law:

> Orders/Payments stay product-type agnostic.  
> Subscription-specific logic lives in `Store.Subscriptions` and orchestration services (not in web, not inside Order resources).

This phase delivers:
- Subscription plan modeling (monthly/annual, etc.)
- Subscription lifecycle state machine (`trialing` optional, `active`, `past_due`, `canceled`)
- Renewal scheduling via Oban workers (no cron magic required)
- Renewal order + payment intent creation that is **idempotent** per billing period
- Customer “manage subscription” surface (view + cancel)
- Admin view (list + inspect + cancel)

## Non-goals (later phases)
- Variable subscriptions (variants + subscription plan coupling)
- Upgrades/downgrades + proration
- Multi-item “bundle subscriptions”
- Invoice-style B2B billing terms
- Marketplace / multi-tenant billing (out of scope)

---

## Architecture

### New domain
- `Store.Subscriptions`

### Key concept: “Renewal is just another order”
Each renewal cycle:
1) Creates an **Order** (normal order resource) with line items representing the subscription charge
2) Creates a **PaymentIntent** (normal payment intent resource)
3) Applies payment success via the **existing interlock flow**
4) Emits receipts/notifications via the **existing post-commit + outbox** spine

Subscriptions do **not** invent new payment state. They coordinate existing state.

---

## Data model

### Resources
1) `Store.Subscriptions.Plan`
- Represents the commercial offer (interval, amount, currency)
- Fields:
  - `code` (unique, stable human key e.g. `"BASIC_MONTHLY"`)
  - `name`
  - `interval_unit` (`:month | :year`)
  - `interval_count` (e.g. 1, 12)
  - `amount_minor` (integer minor units)
  - `currency` (ISO-4217 string)
  - `is_active` (bool)
  - `metadata` (map) (optional)

2) `Store.Subscriptions.Subscription`
- The customer’s active/past subscription instance
- Fields:
  - `plan_id`
  - `user_id` (or `customer_id` depending on your auth model)
  - `status` (`:active | :past_due | :canceled`)
  - `started_at`
  - `current_period_start_at`
  - `current_period_end_at`
  - `next_renewal_at` (index this)
  - `cancel_at_period_end` (bool)
  - `canceled_at` (nullable)
  - `provider_customer_ref` (nullable, if needed)
  - `provider_payment_method_ref` (nullable, if you store a reference)
  - `last_payment_intent_id` (nullable)

3) `Store.Subscriptions.RenewalAttempt`
- The idempotency anchor for renewals (prevents duplicate renewals under retries/concurrency)
- Fields:
  - `subscription_id`
  - `period_start_at`
  - `period_end_at`
  - `renewal_key` (derived; unique)
  - `status` (`:pending | :succeeded | :failed`)
  - `order_id` (nullable)
  - `payment_intent_id` (nullable)
  - `failure_code` (nullable)
  - `failure_message` (nullable)

**Uniqueness**
- Unique index on `renewal_key`
  - recommended renewal_key: `subscription_id + ":" + period_start_at_iso8601`
- Index `subscription_id, period_start_at`
- Index `next_renewal_at` on `Subscription`

---

## Catalog integration

### Representing subscriptions in Catalog
Do **not** branch Orders by product type. Instead:
- In `Store.Catalog.Product`, add a `product_kind` enum:
  - `:simple | :digital | :subscription`
- For subscription products, link to `Store.Subscriptions.Plan`:
  - `subscription_plan_id` (nullable for non-subscription kinds)

Checkout rules (MVP):
- A cart may contain **multiple** subscription items, but each subscription line produces its own `Subscription` instance.
- Subscription items do **not** require shipping (shipping selection step should skip if cart is only subscriptions/digital).

---

## Lifecycle & state machines

### Subscription state machine
Use `ash_state_machine` with transitions:
- `activate` (`:past_due | :canceled` -> `:active`) (admin only; generally not used automatically)
- `mark_past_due` (`:active` -> `:past_due`) (system)
- `cancel_now` (`:active | :past_due` -> `:canceled`) (user/admin)
- `cancel_at_period_end` (flag; does not immediately change status)

Rules:
- `cancel_at_period_end = true` means: do not schedule renewals beyond current period.
- `cancel_now` revokes future renewals and (optionally) revokes digital grants created by the subscription if you implement that later.

---

## Renewal scheduling (Oban)

### Worker approach (MVP, no cron dependency)
Add a periodic worker (choose one):
- Oban Cron plugin **if you already have it**, or
- a “poller” worker scheduled every X minutes

Worker algorithm (must be concurrency-safe):
1) Read due subscriptions:
   - `status = :active`
   - `next_renewal_at <= now()`
   - `cancel_at_period_end = false`
2) Claim N subscriptions at a time (avoid thundering herd):
   - Use a DB-level claim strategy (e.g. update-with-returning) or a `RenewalAttempt` unique insert per subscription/period.
3) For each claimed subscription:
   - Create/Reuse `RenewalAttempt` for the current period (idempotent)
   - Create an Order + PaymentIntent using deterministic idempotency keys
   - Enqueue provider charge / payment flow
   - Mark attempt succeeded/failed accordingly
   - Update subscription `current_period_*` and `next_renewal_at` only on success

**Important:** renewal logic must never run from web requests.

---

## Service surfaces (domain facades)

### `Store.Subscriptions` facade (examples)
- `create_subscription_from_paid_order/2`
  - called from the payment success orchestration path when an order line is `product_kind = :subscription`
- `cancel_subscription/2` (user/admin)
- `list_for_user/2` and `get_for_user!/2` (read surfaces with query contracts)
- `run_due_renewals/1` (worker entrypoint; internal only)

### Typed query contracts
Create structs in `Store.Subscriptions.Queries.*` for:
- user subscription list (filters: status, plan_code)
- admin list (filters: status, next_renewal window)

Web only parses params → struct.

---

## Idempotency & safety rules (must be enforced)

1) **One renewal per subscription per period**
- Enforced by `RenewalAttempt.renewal_key` unique index

2) **Provider calls must be replay-safe**
- Payment intent creation must use a deterministic idempotency key derived from `renewal_key`
- Webhooks are already replay-safe; keep using the same patterns

3) **No double period advancement**
- Subscription period fields update only when the renewal attempt is confirmed succeeded (payment applied once).

4) **Cancellation vs renewal race**
- If `cancel_now` happens while a renewal is in-flight:
  - Do not schedule the next period
  - Allow the in-flight payment attempt to settle, but avoid granting future access

---

## UI surfaces (minimal)
- Customer:
  - “My Subscriptions” list (read-only)
  - Subscription detail
  - Cancel now / cancel at period end (confirmed)
- Admin:
  - list subscriptions (filters)
  - inspect subscription + renewal attempts
  - cancel now

Use AshPhoenix.Form for cancellation actions.

---

## Tests (minimum)
- Creating a subscription from a paid subscription product order line is idempotent (replay-safe)
- Renewal worker:
  - runs twice concurrently → only one `RenewalAttempt` and one renewal Order created
- Cancellation:
  - cancel_now prevents future renewal attempts from being created
- Payment failure:
  - failed renewal marks attempt failed and sets subscription to `:past_due` (or keeps active but flags; pick one and test it)

---

## Acceptance criteria
- A customer can purchase a **subscription product** and see:
  - a `Subscription` created
  - a scheduled `next_renewal_at`
- The renewal worker can run and:
  - create exactly one renewal order/payment intent per period
  - apply payment success through existing interlocks
- Customer can cancel (now or end-of-period) and renewal scheduling respects it.
- No web layer contains ad-hoc Ash queries or direct Ash calls (existing enforcement gates apply).

---

## Governance impact
This phase introduces **new invariants** (renewal idempotency, period advancement rules).  
No global governance doc changes are required **if** you implement the uniqueness + worker-only orchestration rules above, but you should plan a future governance addendum for subscription-specific invariants once the MVP stabilizes.

---

## Enterprise addendum (completeness for real billing)

This section tightens the subscription model so it is **production-usable** and **cloneable** without hidden assumptions.

### Payment method storage (how renewals are actually charged)
A subscription renewal needs a durable **provider billing reference**. Keep it minimal:

- Store on `Subscription`:
  - `provider_customer_ref` (string, nullable until first successful payment links a customer)
  - `provider_billing_ref` (string, nullable; e.g., mandate/authorization/payment-method token)
  - `billing_status_reason` (enum/string; for support visibility)

**Rules**
- Do not attempt to “reconstruct” a billing reference from an order later.
- Provider adapter code must treat these refs as opaque strings.
- Only the provider adapter may interpret the meaning of the ref.

**Update payment method (MVP)**
- Customer triggers an “Update payment method” flow.
- Provider returns a setup/authorization success callback via webhook.
- Worker updates `Subscription.provider_billing_ref` and clears `billing_status_reason`.

### Dunning & retries (minimal, but real)
You need explicit rules for failed renewals so the system is not ambiguous:

- On renewal payment failure:
  - set `Subscription.status = :past_due`
  - set `past_due_since` timestamp
  - set `billing_status_reason = :payment_failed`

- Retry strategy (MVP):
  - up to `N` retries (default 3) during `grace_period_days` (Plan field, default 7)
  - retries are Oban-only, idempotent per attempt

- If grace expires:
  - set `Subscription.status = :canceled`
  - set `canceled_reason = :dunning_expired`
  - emit customer notification via Comms spine (Phase 23)

### Renewal scheduling strategy (do not rely on external cron)
Prefer Oban-native scheduling. Two acceptable patterns:

1) **Oban Cron plugin** (`Oban.Plugins.Cron`) runs a small “renewal tick” worker every minute.
2) **Self-scheduling tick**: worker enqueues its next run on completion.

**Hard rule:** the tick worker must batch safely:
- query only due subscriptions (`next_renewal_at <= now`)
- limit per run
- use keyset pagination if needed
- never do per-subscription N+1 loads

### Renewal locking & concurrency safety
For enterprise safety, assume multiple nodes/workers:

- Enforce a unique constraint on `RenewalAttempt.renewal_key`
- Use Oban uniqueness on “renewal job” args (`subscription_id + renewal_key`)
- Only one renewal order may be created per `renewal_key`

If two workers race:
- one inserts the `RenewalAttempt` row
- the other receives a unique violation and must return the existing attempt

### Refund interaction (keep rules explicit)
Refunding a renewal does **not automatically** cancel a subscription unless policy says so.

MVP policy recommendation:
- Refund **does not** cancel by default
- Admin-only action: `cancel_after_refund` sets `cancel_at_period_end` or `cancel_now`
- If you must auto-cancel, encode it as a Plan flag: `refund_cancels_subscription?`

### Required indexes (minimum)
- `subscriptions (status, next_renewal_at)`
- `renewal_attempts (subscription_id, renewal_key)` unique
- `renewal_attempts (inserted_at)` for operational queries

### Acceptance criteria additions (enterprise)
A “simple subscriptions” implementation is only accepted when:
- A stored billing ref exists and is used for renewals
- Failed renewals reliably transition into `:past_due` and retry deterministically
- Grace-period expiry deterministically cancels
- No duplicate renewals occur under webhook/job replay or multi-node concurrency
- All side effects (emails) are outbox + worker driven
