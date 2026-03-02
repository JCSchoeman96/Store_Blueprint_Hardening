# Subscription Scheduling, Terms, Access & Dunning (Authoritative)

**Status:** Governance law (must be followed by all subscription implementations)  
**Last updated:** 2026-02-27

This document defines the **subscription flexibility contract** for the Store Blueprint:
- daily / monthly / yearly (and every-N)
- bill on start anniversary vs normalized day-of-month
- short-lived terms (days/months/years) vs never-ending
- access removal rules when unpaid/ended
- retries (dunning), grace periods, notifications/reminders
- replay safety (idempotency), concurrency safety, and performance expectations

It applies to:
- Physical product subscriptions (Phase 26/27)
- Membership/entitlement subscriptions (Phase 27A)

It does **not** change the core blueprint law:
> Orders/Payments remain product-type agnostic. Subscription logic is orchestration.

---

## 1) Core Concepts (must be explicit)

Every subscription MUST model these independently:

1. **Cadence** — how often billing occurs
2. **Anchor** — what date/time billing is aligned to
3. **Term** — when the subscription ends (if ever)
4. **Access policy** — what happens to access/benefits when unpaid or ended
5. **Dunning** — retries, grace periods, cancellation rules
6. **Notifications** — reminders and failure/expiry messaging

Do not infer these from dates or “magic defaults”.

---

## 2) Cadence (interval unit + count)

### Required fields (Plan)
- `interval_unit`: `:day | :month | :year`
- `interval_count`: integer ≥ 1 (default 1)

Examples:
- Daily: `{:day, 1}`
- Every 3 days: `{:day, 3}`
- Monthly: `{:month, 1}`
- Quarterly: `{:month, 3}`
- Yearly: `{:year, 1}`

### Law
- Cadence determines the **length of a billing period** and how `next_renewal_at` is computed.
- Cadence must be used consistently for:
  - period windows (`current_period_start_at` / `current_period_end_at`)
  - renewal scheduling (`next_renewal_at`)
  - term consumption (cycles)

---

## 3) Anchor rules (start anniversary vs normalized billing day)

Anchoring MUST be explicit. Two MVP modes are supported:

### Required fields (Plan)
- `anchor_mode`: `:start_anniversary | :fixed_day_of_month`
- `anchor_day_of_month`: integer 1–31 (required if `fixed_day_of_month`)
- `billing_timezone`: IANA timezone string (store default recommended: `Africa/Johannesburg`)

### Anchor modes
#### A) `:start_anniversary` (bill on the day/time you started)
- Billing aligns to the subscription’s `started_at` (or first paid activation time).
- Example: starts 2026-03-05 09:00 → renews every month on day 5 at 09:00 in billing timezone.

#### B) `:fixed_day_of_month` (normalize everyone to a specific day)
- Billing aligns to a configured day-of-month.
- Example: “bill on the 1st” or “bill on the 25th” regardless of signup date.

### End-of-month rule (required)
If `anchor_day_of_month` exceeds the number of days in the target month:
- bill on the **last day of that month** at the configured time.

Examples:
- Day 31 in April → bill Apr 30
- Day 31 in February → bill Feb 28/29

### Law
- `next_renewal_at` MUST be computed using `billing_timezone`.
- Store all timestamps in UTC, but compute anchors using the timezone and then convert to UTC.

---

## 4) Term (few days/months/years vs never-ending)

Term is separate from cadence. MVP supports:

### Required fields (Plan or Subscription)
- `term_mode`: `:until_canceled | :fixed_cycles | :fixed_end_at`
- `term_cycles`: integer ≥ 1 (required if `fixed_cycles`)
- `term_end_at`: datetime (required if `fixed_end_at`)

Examples:
- “Only lasts 10 days” → cadence `{:day, 1}` + term `fixed_cycles=10`
- “Only lasts 6 months” → cadence `{:month, 1}` + term `fixed_cycles=6`
- “Only lasts 2 years” → cadence `{:year, 1}` + term `fixed_cycles=2`
- “Never ending” → `:until_canceled`

### Term consumption rules (required)
- `fixed_cycles`: decrement by 1 **only on successful period extension**.
- `fixed_end_at`: subscription expires when `now >= term_end_at` (timezone-normalized comparison).

### Law
- When term ends, the subscription must transition to `:canceled` (or `:expired` if you distinguish) and must not schedule further renewals.
- Entitlements (if any) must expire/revoke according to access policy (see below).

---

## 5) Access policy (what happens to access/benefits)

This applies primarily to **membership/entitlement subscriptions**, but the rules must still exist even for physical subscriptions (for support clarity).

### Required fields (Plan)
- `access_on_past_due`: `:keep_during_grace | :remove_immediately`
- `access_on_cancel`: `:keep_until_period_end | :remove_immediately`
- `access_on_term_end`: `:remove_at_end` (fixed; do not keep past the end)

### Membership implementation law (Phase 27A)
- Access MUST be represented by `EntitlementGrant` validity:
  - `valid_to_at` = membership `current_period_end_at`
  - `revoked_at` when access is removed immediately (past_due cancel/term end)
- Access checks MUST use a **cached entitlement set** (Phase 29) and must not cause N+1 DB reads in hot paths.

### Physical subscription law
- If subscription is physical and is `:past_due` and policy removes access immediately, you still do not “remove shipping”; you simply do not create a paid renewal order.
- Never ship without paid status.

---

## 6) Dunning (retries + grace period) — deterministic, plan-driven

Dunning must be explicit and deterministic.

### Required fields (Plan)
- `grace_period_days`: integer ≥ 0 (default 7)
- `max_retry_attempts`: integer ≥ 0 (default 3)
- `retry_schedule_hours`: list of non-negative integers (e.g. `[0, 24, 72]`)

Interpretation:
- Attempt 1 occurs at hour offset 0 (immediate retry allowed).
- Subsequent attempts occur at configured offsets.
- Attempts beyond `max_retry_attempts` are forbidden.

### Required fields (Subscription)
- `past_due_since_at`
- `billing_status_reason` (e.g. `:payment_failed`, `:missing_payment_method`, `:out_of_stock`, `:variant_unavailable`)

### State transition law (minimum)
- On renewal payment failure:
  - set `status = :past_due`
  - set `past_due_since_at = now`
  - set `billing_status_reason = :payment_failed`
- Retry until:
  - success → `:active` and extend period, clear past_due markers
  - grace expires (`now > past_due_since_at + grace_period_days`) → `:canceled` with `canceled_reason = :dunning_expired`

### Missing payment method
- If `provider_billing_ref` is missing at renewal time:
  - do not create a payment intent
  - set `:past_due` with reason `:missing_payment_method`
  - send “update payment method” notification

### Inventory/fulfillment blockers (physical)
- If renewal cannot be fulfilled (out of stock, shipping invalid, etc.):
  - do not charge
  - set `:paused` or `:past_due` with reason `:out_of_stock` (choose one; be consistent)
  - notify customer/admin

This avoids “charged but cannot ship” incidents.

---

## 7) Notifications & reminders (Comms spine, idempotent)

All reminders/notifications MUST go through the Phase 23 Comms Outbox + workers.

### Plan-configurable notifications (recommended)
- `remind_before_days`: list (e.g. `[7, 1]`)
- `remind_on_payment_failure`: boolean
- `remind_before_grace_expires_days`: integer (e.g. 1)

### Idempotency law for notifications
Every notification job MUST have a deterministic idempotency key:
- e.g. `(subscription_id, type, target_period_end_at)`
and a DB uniqueness constraint in the outbox to prevent duplicates.

### Required notification types (minimum)
- Upcoming renewal reminder(s)
- Payment failed / action required
- Grace period ending soon
- Subscription canceled / ended
- Membership access ended (if access removed)

---

## 8) Scheduling implementation (Oban-only, no external cron dependency)

Renewal and reminder scheduling MUST be Oban-driven.

### Allowed patterns
1) **Oban Cron plugin**: a tick job runs every minute (or 5 minutes).
2) **Self-scheduling tick**: job re-enqueues itself on completion.

### Tick worker rules (performance)
- Query due subscriptions by `next_renewal_at <= now` (batched).
- Must use indexes:
  - `subscriptions(status, next_renewal_at)`
- Must cap batch size and avoid per-row N+1 loads.
- Must enqueue per-subscription renewal attempt jobs with uniqueness.

---

## 9) Idempotency & concurrency safety (must be enforced)

### Renewal key (required)
Every billing period must have a unique, deterministic `renewal_key`, e.g.:
- `renewal_key = "sub:{subscription_id}:end:{period_end_iso8601}"`

### Required uniqueness
- DB unique: `renewal_attempts(subscription_id, renewal_key)`
- Oban uniqueness: job args include `subscription_id` + `renewal_key`

### Race law
If two workers attempt the same renewal:
- One inserts the `RenewalAttempt` and proceeds.
- The other hits uniqueness and must **reuse** the existing attempt (no new order/payment intent).

### Webhook replay law
Webhook repeats must not create duplicate “paid extensions”:
- renewal order/payment application must be replay-safe (interlocks enforce apply-once)
- membership/grant issuance must be idempotent (unique constraints)
- outbox notifications must be idempotent (unique keys)

---

## 10) Required indexes (minimum set)

### Subscriptions
- `subscriptions(status, next_renewal_at)`
- `subscriptions(user_id)` (self lookups)
- `subscriptions(plan_id)` (admin/analytics)

### Renewal attempts
- unique: `renewal_attempts(subscription_id, renewal_key)`
- index: `renewal_attempts(inserted_at)`

### Entitlement grants (membership)
- index: `(user_id, valid_to_at, revoked_at)`
- unique: `(source_id, entitlement_code)` (or `(membership_id, entitlement_id)`)

---

## 11) Governance tests (must exist once implemented)

The following governance tests MUST exist before declaring subscriptions “done”:

1) **Anchor correctness**
- fixed_day_of_month handles Feb/30-day months as end-of-month
- start anniversary renews on the same day/time in timezone

2) **Term correctness**
- fixed_cycles ends exactly after N successful extensions
- until_canceled never ends automatically

3) **Access policy correctness (membership)**
- access persists through grace if configured
- access removed on cancel/term end
- grants are revoked/expired deterministically

4) **Dunning correctness**
- bounded retries follow schedule
- grace expiry cancels deterministically
- missing payment method transitions to past_due without charging

5) **Idempotency**
- renewal_key uniqueness prevents duplicates under race
- webhook/job replay does not duplicate grants/emails/orders

6) **Notifications idempotency**
- reminders do not duplicate under worker retry/replay

---

## 12) Implementation note (where these rules live)
- Plan fields live in the Plan resources (Phase 26/27/27A).
- Computation lives in `Store.Subscriptions.Scheduler` (pure functions) and `Store.Subscriptions` facade.
- Side effects:
  - renewal execution via workers
  - notifications via Comms outbox workers
  - no outbound IO in web; webhook verify + enqueue only

---

## Appendix: Recommended enums (for consistency)
- `billing_status_reason`: `:payment_failed | :missing_payment_method | :out_of_stock | :variant_unavailable | :canceled_by_user | :dunning_expired`
- `canceled_reason`: `:user_request | :admin_override | :dunning_expired | :term_ended | :provider_canceled`
