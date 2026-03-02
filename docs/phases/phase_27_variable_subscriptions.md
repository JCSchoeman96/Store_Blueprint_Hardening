# Phase 27 — Variable Subscriptions (variant-coupled plans, renewal-safe)

## Goal
Support **variable subscriptions** where the sellable is a **specific product variant** (e.g., size/color) plus a **subscription plan** (monthly/annual), while preserving the blueprint laws:

- Orders/Payments remain the *truth* for money and state transitions.
- Subscriptions are an orchestration layer that **creates renewal Orders**.
- Web remains an adapter (no ad-hoc Ash.Query logic).
- All renewals are **idempotent** and replay-safe.

This phase builds on:
- Phase 25 (Variants)
- Phase 26 (Simple subscriptions)
- Existing payment interlocks + refund semantics + post-commit notifications

---

## Scope (MVP)
- Variant-coupled subscription eligibility (a variant may be purchasable as subscription).
- Selecting a plan for a variant (e.g., monthly vs yearly).
- Creating subscription records from the first paid order.
- Creating renewal orders on schedule.
- Cancelling subscriptions (immediate or at period end).
- Changing variant or plan **only at period boundary** (no prorations in MVP).

### Non-goals (defer)
- Proration mid-cycle
- Pause/resume
- Trial periods
- Multi-item subscriptions / bundles
- Subscription discounts/promotions engine

---

## Domain & Resource Map

### Domain: `Store.Subscriptions`

#### Resources
1. `Store.Subscriptions.VariantPlan`
   - Purpose: declare which plans are valid for which variant
   - Fields:
     - `id` (uuidv7)
     - `variant_id` (FK → Catalog.ProductVariant)
     - `plan_id` (FK → Subscriptions.Plan)
     - `enabled` (boolean)
     - `sort_order` (int, optional)
   - Constraints:
     - unique `(variant_id, plan_id)`

2. `Store.Subscriptions.Subscription`
   - Purpose: the ongoing contract for renewals for one variant+plan
   - Fields (minimum):
     - `id` (uuidv7)
     - `user_id` (FK → Accounts.User)
     - `variant_id` (FK → Catalog.ProductVariant)
     - `plan_id` (FK → Subscriptions.Plan)
     - `status` (atom/state machine)
     - `current_period_start_at` (utc_datetime)
     - `current_period_end_at` (utc_datetime)
     - `next_renew_at` (utc_datetime)
     - `cancel_at_period_end` (boolean)
     - `canceled_at` (utc_datetime, nullable)
     - `created_from_order_id` (FK → Orders.Order) *(first paid order)*
     - `last_renewal_order_id` (FK → Orders.Order, nullable)
     - `payment_method_ref` (string, nullable; provider-specific token/mandate)
   - State machine (MVP):
     - `active`
     - `canceling` (cancel_at_period_end=true)
     - `canceled`
     - `past_due` (renewal failed; policy-driven retries)
   - Constraints:
     - index `user_id`
     - index `status`
     - index `next_renew_at`

3. `Store.Subscriptions.RenewalAttempt`
   - Purpose: durable record for each period renewal (idempotency anchor)
   - Fields:
     - `id` (uuidv7)
     - `subscription_id`
     - `renewal_key` (string) **unique**
     - `period_start_at`, `period_end_at`
     - `status` (:pending | :succeeded | :failed | :abandoned)
     - `order_id` (FK → Orders.Order, nullable)
     - `payment_intent_id` (FK → Payments.PaymentIntent, nullable)
     - `failure_code`, `failure_message` (nullable)
   - Constraints:
     - unique `renewal_key`
     - index `(subscription_id, period_start_at)`

---

## Key Principle: “Renewal is just another Order”
Renewals MUST create an `Orders.Order` using the existing order-building + pricing snapshot + interlocks pipeline.

- Renewal order lines reference the **variant** as the sellable.
- Price is snapshotted at order time (existing snapshot laws).
- Payment intent is created and processed using existing payment flows.

**Do NOT** add “subscription logic” inside Orders/Payments resources.

---

## Canonical Read/Write Surfaces (no web drift)

### Facade module (example)
- `Store.Subscriptions` is the only entrypoint for:
  - subscribing
  - scheduling renewals
  - running a renewal
  - canceling

### Typed inputs (query contracts)
- `Store.Subscriptions.Queries.SubscriptionIndexQuery`
- `Store.Subscriptions.Inputs.SubscribeToVariantInput`
- `Store.Subscriptions.Inputs.ChangePlanInput`
- `Store.Subscriptions.Inputs.ChangeVariantInput`

Web layer only does params → typed struct, then calls facade.

---

## Workflows

### 1) First purchase → subscription creation
**Preferred:** subscription is created **after first payment succeeds**, to avoid orphan subscriptions.

Flow:
1. Customer selects variant + plan during checkout.
2. Checkout creates an Order with:
   - one line item for the variant
   - metadata: `subscription_plan_id`, `subscription_variant_id`
3. Payment succeeds → interlock emits “order paid” effects.
4. A worker/interlock creates:
   - `Subscription` (status `active`)
   - `current_period_*` derived from plan interval
   - `next_renew_at`
   - `created_from_order_id`
5. Post-commit notify (existing pattern).

**Idempotency:** subscription creation must be replay-safe:
- unique constraint: `(user_id, created_from_order_id)` OR `(created_from_order_id)` on Subscription
- and/or an “apply once” registry like your payment success apply-once pattern.

### 2) Scheduled renewal (Oban)
1. Scheduler queries for subscriptions with `next_renew_at <= now` and status `active` or `past_due`.
2. For each subscription:
   - compute `renewal_key = "sub:<id>:<period_start_iso>"` (stable)
   - `RenewalAttempt.create_or_reuse` (unique key)
3. If attempt already has order/payment intent and is succeeded → exit.
4. Create renewal Order (via Checkout/Orders builder) with:
   - variant line
   - shipping: **only if physical** (see Phase 22). For subscription physical items, shipping must be quotable deterministically.
5. Create payment intent and process per provider rules.

### 3) Plan change (MVP boundary only)
- Plan changes are allowed **only at period boundary**.
- Implementation:
  - write a “pending change” on Subscription (optional), applied by renewal worker at next cycle.
  - OR require cancel + resubscribe (simplest).

### 4) Variant change (MVP boundary only)
- Same rule: boundary only.
- Validate that (new_variant_id, plan_id) exists in `VariantPlan` enabled.

### 5) Cancellation
- `cancel_now`: status → `canceled`, next_renew_at cleared; no further renewals.
- `cancel_at_period_end`: status → `canceling`, flag set; renewal worker cancels when reaching boundary.

---

## Policies & Authorization
- Customer can read only their subscriptions.
- Customer can request cancel on their subscriptions.
- Only admin can mutate plan definitions and variant-plan mappings.
- Renewal workers act as system actor (explicit).

---

## Data Integrity Rules (Invariants)
- A subscription must reference an **enabled** `(variant_id, plan_id)` mapping at time of creation.
- RenewalAttempt uniqueness prevents duplicate renewals per period.
- Renewals never mutate prior Orders; they create new Orders with new snapshots.
- Subscription status transitions are controlled; renewal worker must not renew if `canceled`/`canceling` with boundary reached.
- Refunds:
  - refunds do not automatically cancel subscription unless policy says so; if you choose “refund cancels”, it must be explicit and tested.

---

## Performance & Scaling Review (single-tenant)
- Renewal scheduler should batch by `next_renew_at` index; no full scans.
- Cache variant-plan eligibility for storefront selection (ETS/Cachex with short TTL).
- Avoid heavy relationship loads in scheduler; fetch minimal fields.

---

## Tests (minimum)
1. **Create-once**: first paid order creates subscription once (replay webhook doesn’t create duplicates).
2. **Renewal idempotency**: same period renewal runs twice → one RenewalAttempt, one Order, one PaymentIntent.
3. **Cancel semantics**: cancel_now prevents renewal; cancel_at_period_end renews until boundary then stops.
4. **Eligibility**: invalid variant-plan pair rejected at subscribe and at renewal boundary change.
5. **Past_due**: failed renewal marks subscription past_due and schedules retry (policy-defined, MVP can be “one retry”).

---

## Acceptance Criteria
- Customer can purchase a variant as a subscription with plan selection.
- Subscription created only after successful payment and is replay-safe.
- Renewal orders are created automatically and are replay-safe.
- Cancels work and prevent unwanted renewals.
- No subscription-specific logic leaks into Orders/Payments domains.

---

## Governance Impact
- No global governance updates required **if**:
  - renewals are workers-only
  - provider adapters remain pure
  - orders/payments remain the money truth
- If you later add proration/pause/trials, add governance addenda before implementing.

---

## Enterprise addendum (variable subscriptions done safely)

### Variant lifecycle & compatibility
Variable subscriptions couple a **variant** with a **plan**. This creates real-world drift:

- Variants can be archived
- Option sets can change
- Inventory may be constrained

**Rules**
- Archived variants: no new signups; existing subscriptions continue until changed/canceled.
- If a variant is discontinued and cannot be fulfilled:
  - set `Subscription.status = :paused` (or `:past_due`) with `billing_status_reason = :variant_unavailable`
  - notify customer and allow selection of a replacement variant

### Physical vs digital fulfillment per renewal
Do not branch Orders core logic. Instead:

- Renewal creates a normal `Order` with line items referencing the sellable variant
- Fulfillment rules determine whether shipping applies:
  - physical variants → shipping quote + fulfillment
  - digital variants → shipping is skipped; digital grants issued post-payment

### Inventory on renewal (physical goods)
If the renewal variant is physical and inventory is tracked:

- At renewal order creation time:
  - verify availability
  - apply holds/reservations using the same “no oversell” pattern as one-time checkout
- If out of stock:
  - do not create a payment intent
  - set subscription `:paused` with reason `:out_of_stock`
  - notify customer/admin

### Plan/variant changes (boundary-only, no proration)
MVP is boundary-only (as already stated). Make it explicit in data:

- `Subscription.pending_plan_id`
- `Subscription.pending_variant_id`
- `Subscription.change_effective_at` (timestamp; typically current period end)

**Rules**
- Apply pending changes only when generating the next `renewal_key`
- Clear pending fields once applied
- If a pending variant becomes invalid before effective time:
  - keep pending fields, mark reason, notify customer to choose again

### Required indexes (minimum)
- `subscriptions (status, next_renewal_at)`
- `subscriptions (variant_id)` for admin/support
- `variant_plans (variant_id, plan_id)` unique
- `renewal_attempts (subscription_id, renewal_key)` unique

### Acceptance criteria additions (variable subscriptions)
A “variable subscriptions” implementation is only accepted when:
- Variant/plan coupling is explicit and validated (no implicit lookups)
- Renewals respect inventory/fulfillment rules (no charging when out of stock)
- Plan/variant changes apply only at boundaries and are replay-safe
- Archived/discontinued variants do not break renewals silently (system pauses with reason + notification)
