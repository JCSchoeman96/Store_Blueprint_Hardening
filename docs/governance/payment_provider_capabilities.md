# Payment Provider Capabilities & Selection Matrix (Authoritative)

**Status:** Governance law (provider integrations MUST declare capabilities)  
**Last updated:** 2026-02-27

This document prevents “feature lies” by requiring every payment provider integration to declare what it can and cannot do.

It standardizes:
- capability flags (one-time, refunds, tokenization, renewals, verification style)
- UI/flow gating rules (what must be disabled when a capability is missing)
- verification posture (offline HMAC vs remote verify)
- subscription posture (merchant-initiated charges vs provider-managed subscriptions)
- operational and security expectations per provider

Applies to providers supported by this blueprint, including:
- Paystack
- PayFast
- Yoco
- Peach Payments
- Stripe
- PayPal

> Provider capabilities can change.  
> Always confirm current upstream docs before enabling a capability in production.

---

## 1) The core law: capabilities must be explicit

### Required: provider capability declaration
Every provider adapter MUST expose a static capability map, e.g.:

- `supports_one_time_checkout?`
- `supports_refunds?`
- `supports_partial_refunds?`
- `supports_tokenization?`
- `supports_merchant_initiated_charges?` (needed for “our engine does renewals”)
- `supports_provider_managed_subscriptions?` (provider runs schedule; we react to events)
- `webhook_verification_mode`:
  - `:offline_hmac` (verify locally from headers + raw body)
  - `:remote_verify` (requires outbound HTTP to provider verify endpoint)
  - `:ip_allowlist_plus_signature` (signature + IP checks as defense-in-depth)
- `supports_webhooks?`
- `supports_disputes_or_chargebacks?` (optional)
- `supports_payouts?` (optional)

### Enforcement rule
- If a capability is missing, the corresponding product/UX features MUST be disabled.
- Do not “fallback silently.” If subscriptions are enabled but tokenization is not supported, subscription purchase must be rejected with an explicit error.

---

## 2) Subscription styles (choose intentionally)

Subscriptions can be implemented in two fundamentally different ways:

### A) Merchant-managed renewal engine (blueprint default)
We schedule renewals (Oban), create renewal Orders, create PaymentIntents, and charge a stored billing reference.

**Requires:**
- `supports_tokenization? == true`
- `supports_merchant_initiated_charges? == true`

Pros:
- consistent behavior across providers that support tokenization
- our domain remains the truth for periods, grace, dunning

Cons:
- not possible with providers that don’t allow merchant-initiated charging

### B) Provider-managed subscriptions
Provider manages the billing schedule and charges the customer. We subscribe to provider events.

**Requires:**
- `supports_provider_managed_subscriptions? == true`
- strong webhook event model

Pros:
- provider handles payment method updates and some retry logic
- less custom billing work

Cons:
- more provider-specific concepts and events
- harder to keep “one internal subscription model” identical across providers

**Blueprint stance:** Prefer merchant-managed renewals when possible. Provider-managed subscriptions are an explicit opt-in.

---

## 3) Webhook verification modes (and where they run)

This blueprint’s payment contract says:
- controller verifies signature and enqueues only
- worker applies state transitions

But verification differs by provider:

### `:offline_hmac`
- Controller verifies signature locally (pure computation).
- Worker assumes verified receipts and proceeds.

### `:remote_verify`
- Controller does cheap screening (required headers present) + persists receipt + enqueues.
- Worker performs outbound verification call **before** applying any state.
- If remote verify fails → mark receipt failed, do not apply transitions.

This stays consistent with side-effect quarantine because outbound IO occurs in the worker.

### `:ip_allowlist_plus_signature`
- Controller verifies signature locally.
- Controller MAY enforce IP allowlist as defense-in-depth, but must not rely on it alone.

---

## 4) Provider matrix (initial baseline)

This is a conservative baseline to prevent overpromising. Confirm current provider docs before enabling.

| Provider        | One-time checkout | Webhooks | Verify mode                  | Refunds | Tokenization | Merchant-managed renewals | Provider-managed subs |
|----------------|-------------------|----------|------------------------------|---------|--------------|---------------------------|-----------------------|
| Paystack       | Yes               | Yes      | Offline HMAC                 | Yes     | Varies       | Varies                    | Varies                |
| PayFast        | Yes               | ITN      | IP allowlist + signature     | Yes     | Yes          | Yes                       | Varies                |
| Yoco           | Yes               | Yes      | Offline HMAC (timestamped)   | Varies  | Limited/No   | No                        | Limited/No            |
| Peach Payments | Yes               | Yes      | Offline signature (+ IP opt) | Yes     | Yes          | Yes                       | Varies                |
| Stripe         | Yes               | Yes      | Offline signature header     | Yes     | Yes          | Yes                       | Yes                   |
| PayPal         | Yes               | Yes      | Remote verify (recommended)  | Yes     | Yes          | Varies                    | Yes                   |

Notes:
- “Varies” means region/product constraints may apply. Do not assume subscription support without verifying upstream docs.
- If a provider’s online gateway does not support recurring billing, enforce that via capability gating.

---

## 5) UI and flow gating rules (non-negotiable)

### If provider lacks `supports_tokenization?`
- Disable:
  - membership subscriptions (Phase 27A)
  - merchant-managed renewals (Phase 26/27)
- If client wants memberships anyway:
  - must use provider-managed subscriptions (if supported), OR
  - choose another provider

### If provider uses `:remote_verify`
- Webhook controller MUST:
  - store receipt as “pending remote verification”
  - enqueue worker
- Worker MUST:
  - remote verify
  - only then apply transitions

### If provider lacks `supports_refunds?`
- Disable admin refund flows for that provider configuration.
- Refund requests must be rejected early with explicit error code.

### If provider does not support partial refunds
- Refund resource must enforce “full only” and reject partial amounts.

---

## 6) Required runtime configuration (per provider)

Every provider config must live in `runtime.exs` and be environment driven.

Common required keys:
- `mode`: `:sandbox | :live`
- `api_key` / `merchant_id` / `client_id` (provider-specific)
- `webhook_secret` (or signing secret / token)
- `timeout_ms`
- `idempotency_prefix` (optional but recommended)

Optional defense-in-depth:
- `allowed_webhook_ips` (list)
- `max_webhook_rate` (rate limiting settings)

---

## 7) Adapter surface contract (what each provider must implement)

### Required functions (conceptual)
- `capabilities/0` → returns capability map
- `build_checkout_session(order_snapshot, opts)` → redirect URL or provider session id
- `verify_webhook(headers, raw_body)` → `{:ok, verified_payload}` or `{:error, reason}`
- `normalize_webhook(verified_payload)` → canonical receipt struct
- `create_refund(refund)` → outbound request (worker only) + idempotency key
- (If tokenization) `build_setup_flow(user, opts)` → allow updating payment method for renewals

### Hard boundary
Provider adapter modules remain pure (no Repo/Ash/Oban). Workers orchestrate side effects.

---

## 8) Governance tests (mandatory once provider is implemented)

For each provider adapter:
1) Capabilities test:
- adapter declares capabilities and they are consistent with enabled flows

2) Verification tests:
- missing/invalid signature rejected
- valid signature accepted

3) Replay safety:
- duplicate provider_event_id does not double-apply paid/refund effects

4) Gating tests:
- subscriptions disabled when tokenization missing
- refunds disabled when refunds missing

---

## 9) Operational guidance: choosing providers per client

### Conservative default (best for enterprise + subscriptions)
- Stripe (if client can use it) OR
- Peach/PayFast (RSA-friendly) with tokenization/recurring enabled

### “Local-only one-time payments”
- Yoco can be fine for one-time checkout, but do not promise renewals unless verified.

### PayPal
- Great for international buyers; expect remote verification flows and more provider-specific nuance.

### Paystack
- Strong in supported regions; verify subscription/tokenization constraints for the client’s country and product.

---

## 10) Decision checklist (must be recorded per client)
Before selecting a provider for a client, record:
- country/region + settlement requirements
- whether subscriptions are required (physical or membership)
- whether tokenization/merchant-initiated charges are required
- webhook verification mode (offline vs remote)
- refund requirements (full vs partial)
- provider downtime posture (grace periods, retry strategy)

Store this in a client implementation note under `docs/agent_notes/`.

