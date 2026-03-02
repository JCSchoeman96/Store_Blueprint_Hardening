# Phase 27A — Membership subscriptions (entitlements, access, benefits)

**Status:** Optional expansion (enterprise-grade)  
**Last updated:** 2026-02-27

## Goal
Support “membership” subscriptions (recurring billing for **access/benefits**, not shipments) while preserving the blueprint laws:

- Orders/Payments remain the truth for money and paid/refund transitions.
- Web remains an adapter (no side effects; webhook verify + enqueue only).
- No product-type branching in Orders core. Membership-specific effects live in `Store.Memberships/Store.Entitlements`.
- Idempotent, replay-safe: webhook retries and Oban retries never duplicate memberships/grants.

This phase is intentionally conservative:
- It enables **membership access gating** (content, pricing benefits, free shipping rules, etc.).
- It does **not** build a “full billing portal” UX (defer), but it defines the domain spine cleanly.

---

## Scope (MVP)
1) Membership plans that bill monthly/annual (same interval model as Phase 26).
2) Membership lifecycle: active → past_due → canceled (with grace period).
3) Entitlement grants issued post-payment and revoked on cancellation/refund policy.
4) Customer actions:
   - view membership status
   - cancel at period end (MVP)
5) Admin actions:
   - create/update plans
   - override membership status (step-up required)

---

## Non-goals (defer)
- Proration, partial refunds with complex entitlement arithmetic
- “Self-serve billing portal” (provider-hosted portal can be integrated later)
- Advanced entitlement rules engine (ABAC/OPA style)
- Team/family memberships (multi-user grants)

---

## Architecture
### New domains
- `Store.Memberships` — membership plan + subscription lifecycle
- `Store.Entitlements` — access/benefits representation + grants

### Key concept: “Membership fulfillment is access, not shipping”
Membership renewals still create **normal Orders** (or reuse the renewal pipeline) but *instead of shipping/fulfillment* they produce/extend **entitlement grants**.

**Rule:** do not represent membership as a special Order type. If you need something sellable in the catalog, represent it as a sellable with `fulfillment_kind = :membership` (handled outside Orders).

---

## Data model (resource map)

### `Store.Memberships.MembershipPlan`
Fields (minimum):
- `id` (uuidv7)
- `code` (string, unique, stable)
- `name` (string)
- `interval_unit` (`:month | :year`)
- `interval_count` (integer, default 1)
- `price_minor` (integer) + `currency` (ISO 4217)
- `grace_period_days` (integer, default 7)
- `is_active` (boolean)
- `created_at/updated_at`

Notes:
- Price is stored in minor units; display formatting is handled by COMM/receipt layer.
- Plans are immutable in meaning; if you need a new price, create a new plan version (optional) or update with explicit rules.

### `Store.Memberships.Membership`
Fields (minimum):
- `id`
- `user_id` (owner)
- `plan_id`
- `status` (`:active | :past_due | :canceled`)
- `current_period_start_at`
- `current_period_end_at`
- `next_renewal_at`
- `past_due_since_at` (nullable)
- `canceled_at` (nullable)
- `canceled_reason` (nullable enum/string)
- Provider refs:
  - `provider_customer_ref` (nullable)
  - `provider_billing_ref` (nullable; mandate/payment-method token)
  - `billing_status_reason` (nullable; support visibility)

Constraints:
- unique: `(user_id, plan_id)` for “one membership per plan”
- index: `(status, next_renewal_at)` for renewal tick

### `Store.Entitlements.Entitlement`
Represents a named capability/benefit. Minimal model:
- `code` (string, unique) — e.g. `discount_percent_10`, `free_shipping`, `content_premium`
- `name` (string)
- `metadata` (map/json, optional)

This resource can be admin-managed or hard-coded; blueprint recommends a resource for auditability.

### `Store.Entitlements.EntitlementGrant`
Fields (minimum):
- `id`
- `user_id` (owner)
- `source_type` (`:membership`)
- `source_id` (membership_id)
- `entitlement_code` (string) OR `entitlement_id` (fk)
- `valid_from_at`
- `valid_to_at`
- `revoked_at` (nullable)
- `revoked_reason` (nullable)

Constraints:
- unique: `(source_id, entitlement_code)` for idempotent issuance
- index: `(user_id, valid_to_at, revoked_at)` for fast checks

---

## Policies & authorization (must be explicit)
### MembershipPlan
- Public/customer: read only active plans (optional; if you show plans publicly)
- Admin: full CRUD (step-up required for updates affecting billing)
- System: may read for renewal scheduling

### Membership
- Owner: read own membership + cancel actions
- Admin: read all + override status (step-up required)
- System: create/update for renewals and webhook-driven transitions

### Entitlement / EntitlementGrant
- Owner: read own grants
- Admin: read all; revoke grants with step-up
- System: create/revoke grants post-payment and on cancellation

---

## Workflows (replay-safe)

### 1) Initial purchase → membership activation
Trigger: payment success interlock (worker) for an order containing a membership sellable.

Steps (worker-only):
1) Ensure membership exists:
   - upsert by `(user_id, plan_id)` in a transaction
2) Set period window:
   - If new: set `current_period_start_at = now`, `end_at = now + interval`
   - If existing and active: extend from `current_period_end_at`
3) Issue entitlement grants (idempotent):
   - create/update grants with `valid_to_at = membership.current_period_end_at`
4) Enqueue receipt/confirmation email via Comms spine

Idempotency keys:
- membership upsert is guarded by unique `(user_id, plan_id)`
- grants guarded by unique `(source_id, entitlement_code)`

### 2) Scheduled renewal (Oban-only)
Approach:
- Renewal tick worker queries memberships due (`next_renewal_at <= now`) in batches.
- For each membership:
  - derive `renewal_key = membership_id + current_period_end_at` (or next_renewal_at)
  - create a renewal attempt row unique on `renewal_key`
  - create a renewal Order + PaymentIntent via provider adapter
  - on payment success: extend membership period and grants

Hard rule:
- Never charge if `provider_billing_ref` is missing. Set `:past_due` with reason `:missing_payment_method`.

### 3) Failure / dunning
On renewal payment failure:
- set `status = :past_due`
- set `past_due_since_at = now`
- set `billing_status_reason = :payment_failed`
- retry up to N times during grace period (plan-configurable; default 3 retries in 7 days)
- when grace expires:
  - set `status = :canceled`
  - set `canceled_reason = :dunning_expired`
  - revoke grants (see below)
  - notify customer (Comms)

### 4) Cancellation (customer)
MVP: cancel at period end
- action `cancel_at_period_end`
- sets `canceled_at = current_period_end_at`
- keeps grants valid until end
- renewal tick must skip memberships with `canceled_at` set (if cancellation effective)

Optional (later):
- `cancel_now` (immediate revoke) — admin only for MVP.

### 5) Refund interaction (explicit policy)
Refunding a membership renewal does **not automatically cancel** unless policy says so.

Blueprint MVP recommendation:
- Refund does not cancel by default.
- Admin action `cancel_after_refund` can set cancel_at_period_end or cancel_now.
- If you need auto-cancel: encode as plan flag `refund_cancels_membership?` and implement in the refund worker.

---

## Entitlement evaluation (how the store uses membership)
To apply membership benefits (discounts/free shipping/content gating), do NOT query grants ad-hoc in web.

Canonical approach:
- Add a `Store.Entitlements.for_user/1` surface returning a compact “entitlement set”
- Cache it:
  - Hot: ETS/Cachex per user (short TTL, e.g. 30–120s)
  - Warm: Redis per user (TTL 5–30m)
- Invalidate on:
  - membership status change
  - grant creation/revoke
  - plan change

Usage examples:
- Pricing: compute discounts from entitlement set
- Shipping: apply free shipping based on entitlement
- Content: gate pages/features based on entitlement

---

## Service surfaces (domain facades)
Add canonical entrypoints (examples):

### `Store.Memberships`
- `list_active_plans(actor, query)`
- `get_membership_for_user(actor)`
- `cancel_at_period_end(actor, membership_id)`
- `admin_override_status(actor, membership_id, status)` (step-up)
- `ensure_membership_from_paid_order(actor, order_id)` (SYSTEM/worker)

### `Store.Entitlements`
- `entitlement_set_for_user(actor)` (cached read surface)
- `grant_membership_entitlements(membership_id)` (SYSTEM)
- `revoke_membership_entitlements(membership_id, reason)` (SYSTEM/admin)

Typed query contracts:
- Plan index query (pagination/sort)
- Membership status query (self-only)

---

## Performance & scaling review (single-tenant)
Hot paths:
- entitlement checks during pricing/checkout/content gating

Rules:
- never do per-request DB scans for entitlements
- precompute/collapse grants into a cached set
- ensure indexes for user grant lookups
- use cache stampede protection (Phase 29)

---

## Tests (minimum, governance-grade)
1) Activation is idempotent:
- webhook replay does not duplicate membership or grants
2) Renewal idempotency:
- two renewal workers racing cannot create two renewal orders
3) Dunning:
- failure transitions to `:past_due`, retries bounded, grace expiry cancels
4) Cancellation:
- cancel_at_period_end prevents new renewals
5) Entitlement revocation:
- cancellation (or policy-driven refund cancel) revokes grants or ends validity

---

## Acceptance criteria
- Membership plans can be created/admin-managed.
- A customer can purchase a membership and become `:active`.
- Entitlements appear immediately after payment success and remain valid until period end.
- Renewals are Oban-driven and replay-safe; no duplicate charges/orders.
- Failed renewals result in deterministic `:past_due` and bounded retries.
- On cancellation/grace expiry, entitlements stop being valid (revoked or expired).
- Performance: entitlement checks are cached and do not cause N+1 DB calls.

---

## Governance impact
No global law changes required if you follow existing rules:
- side effects quarantine
- webhook verify + enqueue
- post-commit notifications
- performance review on hot paths

However, you SHOULD:
- add membership/grants resources to the policy matrix (if not already)
- add governance tests for membership idempotency and entitlement revocation
