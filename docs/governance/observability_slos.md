# Observability & SLOs (Authoritative)

**Status:** Governance law (mandatory operational baseline)  
**Last updated:** 2026-02-27

This document defines the **minimum observability standard** for the Store Blueprint.  
Enterprise-grade means the system is not only correct, but **operable**: when something breaks, you can see it quickly, explain it, and fix it.

Scope:
- Storefront (catalog/product reads)
- Cart and checkout
- Payments (webhooks + workers)
- Email outbox + delivery
- Shipping quote + fulfillment
- Digital downloads
- Subscriptions (renewals, dunning, reminders)

Complements:
- `docs/governance/performance_scaling.md`
- `docs/governance/payment_provider_contract.md`
- `docs/governance/payment_provider_capabilities.md`
- `docs/governance/enforcement_gates.md`

---

## 1) Core law: no silent failures

### Required outcomes
Every critical workflow MUST emit:
- a log trail (PII-safe),
- a metric counter for success/failure,
- and timing telemetry for p95/p99 monitoring.

### Forbidden
- swallowing exceptions without logging an internal error code
- logging secrets or raw PII payloads
- background work without a queue metric/backlog age metric

---

## 2) SLOs (minimum budgets)

SLOs are targets. Alerts trigger when they are consistently violated.

### Storefront SLOs
- Product list (`/shop`) p95 < **200ms**, p99 < **500ms**
- Product detail (`/shop/:slug`) p95 < **150ms**, p99 < **400ms**
- Error rate (5xx) < **0.1%** rolling 10 min

### Cart SLOs
- Add/update/remove item p95 < **150ms**, p99 < **350ms**
- Cart view p95 < **150ms**, p99 < **350ms**
- Error rate (5xx) < **0.1%** rolling 10 min

### Checkout SLOs
- Begin checkout (cart → checkout snapshot) p95 < **300ms**, p99 < **800ms**
- Create payment intent p95 < **800ms**, p99 < **2s**
- Checkout end-to-end p99 < **5s** (excluding customer time on provider page)

### Payments/webhooks SLOs
- Webhook controller verify+enqueue p95 < **80ms**, p99 < **200ms**
- Webhook worker process receipt p95 < **300ms**, p99 < **1s**
- Receipt backlog age p95 < **60s**, p99 < **5 min**
- Signature failure spikes must alert (see Alerts)

### Email SLOs (Comms outbox)
- Receipt email enqueued within **30s** of paid
- Outbox backlog age p95 < **5 min**, p99 < **30 min**
- Delivery failure rate < **1%** rolling 1 hour (provider-dependent)

### Shipping quote SLOs
- Quote calculation p95 < **200ms**, p99 < **500ms**
- Quote cache hit rate target: **> 80%** on peak traffic (if caching enabled)

### Digital download SLOs
- Grant check + signed URL issuance p95 < **150ms**, p99 < **350ms**
- Denied/expired grant attempts tracked (security signal)

### Subscriptions SLOs (if enabled)
- Renewal tick runtime p95 < **1s**, p99 < **5s**
- Renewal backlog age p95 < **15 min**, p99 < **2 hours**
- Past-due ratio monitored (see Alerts)

---

## 3) Telemetry (required events)

Use `:telemetry.execute/3` (or equivalent) with consistent naming.

### Storefront
- `[:store, :catalog, :product_list]` — duration, result_count, cache=hit/miss
- `[:store, :catalog, :product_detail]` — duration, cache=hit/miss

### Cart/Checkout
- `[:store, :carts, :get]` — duration, actor_scope=guest/user, result=hit/miss
- `[:store, :carts, :mutate]` — action=add/remove/update/merge/convert, duration, success?
- `[:store, :carts, :merge]` — duration, source=guest_token, outcome=merged/noop
- `[:store, :checkout, :start_from_cart]` — duration, totals_hash
- `[:store, :checkout, :create_payment_intent]` — provider, duration, success?

### Payments
- `[:store, :payments, :webhook_received]` — provider, event_type, verified?
- `[:store, :payments, :webhook_enqueued]` — provider, event_type
- `[:store, :payments, :webhook_processed]` — provider, event_type, outcome=ok/duplicate/failed
- `[:store, :payments, :interlock_apply_payment_success_once]` — duration, replay=true/false

### Refunds
- `[:store, :payments, :refund_requested]` — provider, amount_minor, success?
- `[:store, :payments, :refund_webhook_processed]` — provider, outcome

### Comms (EmailOutbox)
- `[:store, :comms, :outbox_insert]` — type, duration, unique=true/false
- `[:store, :comms, :delivery_attempt]` — provider, template, outcome, duration

### Shipping/Fulfillment
- `[:store, :shipping, :quote]` — cache=hit/miss, duration
- `[:store, :fulfillment, :transition]` — state_from, state_to, duration

### Digital
- `[:store, :digital, :grant_issued]` — asset_id, order_id
- `[:store, :digital, :signed_url]` — duration, outcome=ok/denied/expired

### Subscriptions (if enabled)
- `[:store, :subscriptions, :tick]` — due_count, duration
- `[:store, :subscriptions, :renewal_attempt]` — renewal_key, outcome
- `[:store, :subscriptions, :dunning]` — status, attempt_no

---

## 4) Logging (PII-safe, structured)

### Required log fields
- `request_id`
- `actor_id` (never email/phone)
- `order_id` and/or `order_ref`
- `provider`
- `provider_event_id`
- `error_code` (internal code)
- `duration_ms`

### PII rules (non-negotiable)
Never log:
- full addresses, emails, phone numbers
- raw webhook payloads (unless explicitly enabled with short retention + redaction)
- secrets (API keys, webhook secrets)

---

## 5) Metrics (minimum counters & gauges)

### Counters
- `store_http_requests_total{route,status}`
- `store_http_errors_total{route,error_code}`
- `store_webhooks_total{provider,event_type,verified}`
- `store_webhooks_failed_total{provider,reason}`
- `store_outbox_enqueued_total{type}`
- `store_outbox_delivery_total{provider,outcome}`
- `store_subscriptions_renewal_total{outcome}`

### Gauges
- `store_webhook_backlog_age_seconds`
- `store_outbox_backlog_age_seconds`
- `store_renewal_backlog_age_seconds`
- `store_cache_hit_ratio{surface}`

---

## 6) Alerts (minimum set)

### Payments
- Signature failures spike:
  - `store_webhooks_failed_total{reason=signature_invalid}` above threshold in 5 min
- Receipt backlog age:
  - p99 > 5 min
- Worker failure rate:
  - failures > 1% in 10 min

### Checkout
- checkout error rate > 1% rolling 10 min
- payment intent creation p99 > 2s sustained

### Email
- outbox backlog age p99 > 30 min
- delivery failure rate > 5% rolling 1 hour

### Subscriptions (if enabled)
- renewal backlog age p99 > 2 hours
- past-due ratio above configured % for > 1 day

### Security signals
- spike in denied/expired digital downloads
- repeated invalid webhook signatures

---

## 7) Dashboards (minimum)
Dashboards must show:
- p95/p99 latency: shop/cart/checkout
- webhook throughput + backlog age
- outbox throughput + backlog age
- payment success vs fail trends
- refund volume trends
- subscription renewal success/fail (if enabled)
- cache hit ratios (storefront/shipping/entitlements)

---

## 8) Incident playbooks (minimum)

### Webhooks not processing
1) Check backlog age gauge
2) Check worker failures + error codes
3) Validate signature secret configuration
4) Validate Oban queues running
5) Safe to retry: receipts are deduped by `provider_event_id`

### Customers not receiving emails
1) Check outbox backlog age
2) Check delivery outcomes
3) Confirm provider credentials in runtime config
4) Resend: must reuse outbox idempotency key (no duplicates)

### Slow checkout
1) Confirm DB query counts / slow query logs
2) Confirm cache hit ratio for pricing/shipping
3) Confirm no N+1 loads in read surfaces
4) Confirm provider latency (intent creation)

---

## 9) “Enterprise-ready” verification
Before calling a store enterprise-ready:
- Telemetry exists for all implemented hot paths
- Alerts configured for backlog + failure spikes
- Dashboards exist for webhook/outbox/renewal queues
- PII logging rules reviewed and enforced

---

## 10) Implementation note
- Telemetry emission belongs in domain facades and workers.
- Keep event names stable across clones so dashboards/alerts are reusable.
