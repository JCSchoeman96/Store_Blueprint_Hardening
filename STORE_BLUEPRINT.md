# Store Blueprint — Ash 3.x + PETAL (Single-Tenant)
**Reusable base for single-site ecommerce + content projects (Phoenix LiveView + Ash 3.x).**

This blueprint is explicitly **single-tenant**:
- One site owner (super_admin) selling their own products to customers
- No organization scoping, no tenant routing, no marketplace/multi-vendor semantics

Anything marked MUST/SHALL is a hard requirement.

---

## 0) Constitutional Laws (NON-NEGOTIABLE)

### 0.1 Naming conventions
- **snake_case**: DB tables, DB columns, JSON keys, Ash attributes/actions, function names, file paths.
- **SCREAMING_SNAKE_CASE**: stable error codes (registry).

### 0.2 Primary keys
- **MUST** use **UUIDv7** stored as Postgres `uuid` (16 bytes).

### 0.3 Deterministic UUID Binary Sort Law (MANDATORY)
Whenever hashing/signing over a list of UUIDs, using UUIDs for apportionment tie-breaks, or ordering lock acquisition over multiple IDs:

1. Normalize UUIDs to raw **16-byte** binary form  
2. Sort by **unsigned lexicographic byte order** (ascending)  
3. Use that order as the canonical basis

**BAN:** UUIDs MUST NOT be sorted/compared as strings for crypto/tie-break/lock ordering logic.  
Any clause like “lexicographically smallest UUID” MUST be redefined to this binary sort.

### 0.4 Lock Ordering Law (MANDATORY)
Whenever acquiring locks over **multiple records** (DB row locks, distributed locks, or GenServer/ETS ownership), the lock acquisition order MUST be:

1) Convert each UUID to raw 16-byte  
2) Sort ascending by unsigned lexicographic byte order  
3) Acquire locks in that order

**Rationale:** prevents deadlocks and makes concurrency deterministic under load.

### 0.5 Polyglot ID Surface Policy
- Internal identifiers: **UUIDv7** (native).
- External/API/logs/webhooks: **prefixed resource ids** at boundaries (e.g., `ord_<uuid>`, `prd_<uuid>`, `pay_<uuid>`).
- Customer-facing: **order_ref** (Crockford Base32 + check digit), **separate** from external prefixed ids.

### 0.6 Customer-facing order_ref (Crockford)
**Default:** 9 total chars (8 payload + 1 check).  
**Allowed for small deployments:** 7 total (6+1).  
**6 total (5+1): opt-in only**, collision-prone and support-hostile.

**Collision reality check (birthday bound):**
- 6 total (payload=5): space = 32^5 ≈ 33,554,432  
  - ~1% chance of ≥1 collision by ~821 orders  
  - ~50% chance by ~6,820 orders
- 7 total (payload=6): space = 32^6 ≈ 1,073,741,824
- 9 total (payload=8): space = 32^8 ≈ 1,099,511,627,776

**MUST:**
- uppercase Crockford alphabet (no I/L/O/U)
- DB unique index on `orders.order_ref`
- retry-on-conflict generation

---

## 1) Blueprint pack model

### 1.1 Kernel (ALWAYS)
**Goal:** identity + governance + laws; the part you can trust across clients.

Includes:
- Repo, config, baseline telemetry/logging
- Laws + utilities
  - UUIDv7 helpers
  - binary UUID sort + lock ordering helpers
  - prefixed IDs
  - order_ref generator/validator
  - error code registry + canonical error envelope
  - outbound HTTP wrapper (Req)
- CI gates (`mix check`, `mix check.ci`) and enforcement checks
- Memory, GC, and runtime resource safety review contract
- Web skeleton: endpoint/router/layouts/components/base plugs
- Auth wiring (AshAuthenticationPhoenix routing patterns)

### 1.2 Packs (DEFAULT)
- Accounts/Auth
- Admin (RBAC + Audit)
- Content (posts/categories/tags)
- Ecommerce (catalog + pricing + orders + payments)

> Multi-tenant is intentionally out-of-scope for this blueprint. If you ever need it, treat it as a separate blueprint, not a “quick patch”.

---

## 2) Recommended project layout (single tenant)

```
lib/store/
  application.ex
  repo.ex

  support/
    id/
      uuid_v7.ex
      binary_uuid_sort.ex
      lock_order.ex
      prefixed_id.ex
      order_ref.ex
    errors/
      error_codes.ex
      error.ex
    http/
      req_client.ex
    security/
      crypto.ex
      rate_limit.ex
      step_up.ex
    governance/
      audit_redaction.ex
      idempotency.ex
      transitions.ex
      retention.ex
    performance/ (optional pack)
      cache_policy.ex
      redis_keys.ex
      pubsub_topics.ex

  accounts/
    domain.ex
    user.ex
    user_security_event.ex
    policies.ex

  admin/
    domain.ex
    role_assignment.ex
    audit_log.ex
    policies.ex
    site_setting.ex (optional, for provider config etc.)

  content/
    domain.ex
    post.ex
    category.ex
    tag.ex
    joins.ex
    policies.ex

  catalog/
    domain.ex
    product.ex
    product_variant.ex
    category.ex
    joins.ex
    inventory_item.ex
    policies.ex

  pricing/
    domain.ex
    price_book.ex
    price_entry.ex
    promotion.ex
    coupon.ex
    discount_application.ex
    policies.ex

  orders/
    domain.ex
    order.ex
    order_line_item.ex
    order_adjustment.ex
    policies.ex

  payments/
    domain.ex
    payment_intent.ex
    payment_attempt.ex
    webhook_receipt.ex
    provider_event.ex
    providers/
      provider.ex
      stub.ex
    policies.ex

lib/store_web/
  endpoint.ex
  router.ex
  plugs/
    fetch_actor.ex
    require_role.ex
    require_step_up.ex
  controllers/
    webhook_controller.ex
    api/...
  live/
    storefront/...
    admin/...
  components/
  layouts/

priv/repo/migrations/
test/
docs/
  governance/
  agent_notes/
  phases/
```

---

## 3) Single-tenant invariants (this is where drift usually starts)

### 3.1 Global uniqueness constraints (MUST)
Since there is no tenant scoping, these MUST be globally unique:
- `accounts_users.email`
- `catalog_products.slug`
- `content_posts.slug`
- `catalog_product_variants.sku`
- `pricing_coupons.code` (normalized canonical storage)
- `orders.order_ref`
- `payments_provider_events.(provider, provider_event_id)`
- `payments_webhook_receipts.idempotency_key`

### 3.2 Actor model (MUST)
- Actor is the authenticated user (or nil).
- Policies MUST scope customer access by `user_id` (own data only).
- No tenant context exists; do not add tenant_id columns.

---

## 4) Hardened governance (P0): what prevents blueprint rot
These governance documents are **authoritative**:
- `docs/governance/state_machines.md`
- `docs/governance/policy_matrix.md`
- `docs/governance/idempotency.md`
- `docs/governance/audit_and_pii.md`
- `docs/governance/retention.md`
- `docs/governance/step_up.md`
- `docs/governance/enforcement_gates.md`
- `docs/governance/error_codes.md`
- `docs/governance/outbound_http.md`
- `docs/governance/side_effects_quarantine.md`
- `docs/governance/immutable_snapshots.md`
- `docs/governance/pricing_determinism.md`
- `docs/governance/inventory_reservations.md`
- `docs/governance/refund_semantics.md`
- `docs/governance/tax_shipping.md`
- `docs/governance/checkout_interlocks.md`
- `docs/governance/performance_scaling.md` (required short-form performance and runtime review companion)

The detailed performance and runtime safety authority is
`docs/phases/phase_29_performance_architecture_optimizations.md`.

---

## 5) Payments & Webhooks (receipt-first + idempotent) — REQUIRED

### 5.1 Required pipeline (MUST)
1) Controller receives webhook  
2) Controller computes `idempotency_key` and stores **WebhookReceipt FIRST**  
3) Controller enqueues Oban job with receipt id  
4) Oban worker verifies signature, normalizes ProviderEvent, applies transitions exactly once

### 5.2 Forbidden behaviors (MUST NOT)
- MUST NOT apply business side-effects in the controller
- MUST NOT trust client totals
- MUST NOT perform long network calls in controller

---

## 6) Data correctness rules

### 6.1 Money
- Store money as integer minor units + currency code
- Orders store snapshotted totals; historical totals MUST NOT change

### 6.2 Concurrency
- All lifecycle transitions MUST use optimistic locking
- All multi-record lock acquisition MUST follow Lock Ordering Law

---

## 7) Required tests (P0 minimum)
- ID laws: binary UUID sort + lock ordering + prefixed IDs + order_ref mutation tests
- State machines: Orders + PaymentIntent transition tables enforced + replay NOOP
- Audit guarantees: AuditLog has no update/destroy actions; PII rules enforced in tests
- Step-up: sensitive actions return STEP_UP_REQUIRED unless within window
- Webhook idempotency: duplicate receipt/event produces one durable side effect
- Enforcement gate: Repo usage in web fails CI
- Single-tenant uniqueness: key unique indexes exist (migration tests or schema tests)
- Policy matrix: pinned authorization tests fail CI on drift
- Error codes: registry pinned and tested
- Outbound HTTP: no raw Req usage gate enforced
- Side effects: quarantine gates enforced (no HTTP/Oban enqueue in web except allowlist)
- Immutable snapshots: order lines/adjustments cannot be updated or deleted
- Pricing determinism: stacking/rounding/allocation pinned and test-gated
- Inventory reservations: no-oversell model pinned and concurrency/idempotency test-gated
- Refund semantics: idempotent, step-up protected, and interlocked with order/payment state machines
- Tax & shipping: deterministic selection/calculation with pinned rounding and evidence snapshots
- Checkout interlocks: begin_checkout/payment_intent idempotency and paid side-effects exactly-once
- Memory, GC & runtime resource safety: bounded processes, heaps, mailboxes, caches, queues, subscriptions, and cleanup verified at baseline, peak, and post-load cooldown when load, soak, or performance testing is relevant

---

## 8) References (documentation anchors)
- Ash: https://hexdocs.pm/ash/
- Ash Postgres: https://hexdocs.pm/ash_postgres/
- AshAuthenticationPhoenix: https://hexdocs.pm/ash_authentication_phoenix/liveview.html
- AshStateMachine: https://hexdocs.pm/ash_state_machine/
- Credo: https://hexdocs.pm/credo/
- Req releases: https://github.com/wojtekmach/req/releases
- Bandit PhoenixAdapter: https://hexdocs.pm/bandit/Bandit.PhoenixAdapter.html
- Oban: https://hexdocs.pm/oban/
