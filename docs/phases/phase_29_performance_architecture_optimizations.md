# Phase 29 — Performance Architecture & Optimizations (Authoritative)

This phase defines **performance laws** for the single-tenant Store Blueprint.  
Single-tenant does **not** mean “low traffic” — flash sales, launches, and influencer traffic spikes still create enterprise-class load.

This doc is **not** a “later polish” checklist. It is a **design constraint** that must inform every phase implementation.

> Companion governance law: `docs/governance/performance_scaling.md` (short “musts”).  
> This phase doc expands the *how*, the budgets, and the concrete hot-path rules.

---

## 1) Performance budgets (non‑negotiable)

**User-facing (p95 unless noted)**
- Shop listing (cached): **< 200ms**
- Product detail (cached): **< 150ms**
- Add to cart / update qty: **< 150ms**
- Cart render (cached summary + DB fallback): **< 200ms**
- Checkout step transitions (address/shipping/payment selection): **< 300ms**
- Checkout overall p99: **< 5s** (includes payment redirect + return; excludes provider processing time)

**Back-office**
- Admin CRUD screens p95: **< 400ms**
- Fulfillment status update p95: **< 300ms**

**System-facing**
- Webhook controller p95: **< 100ms** (verify signature + enqueue only)
- Webhook worker “apply” p95: **< 300ms** (interlock transitions; no outbound HTTP)
- Email send worker: async, bounded retries; target **< 2s** per send attempt
- Digital grant issuance worker p95: **< 300ms**

**Database**
- No hot-path query should exceed **50ms** median on a warmed DB.
- Any query routinely > **200ms** is a **defect**, not “expected under load”.

---

## 2) Hot path map (what must stay fast)

These paths define the system’s performance ceiling:

1. **Catalog browse**: `/shop` (pagination + filter + sort)
2. **Product detail**: `/shop/:slug`
3. **Cart operations**: add/update/remove + cart summary
4. **Checkout**: cart → order creation → shipping quote selection → payment intent → redirect
5. **Payment webhook**: signature verify → receipt persist (optional) → enqueue → apply-once transition
6. **Post-payment fan-out**: receipt email, fulfillment creation, digital grants, subscription activation
7. **Admin**: catalog publish/unpublish; shipping rule updates; fulfillment operations

Every phase implementation must explicitly answer:
- Which of these hot paths does it touch?
- What is the cache plan?
- What indexes are required?
- What is the replay/idempotency plan?
- What is the “stampede protection” plan?

---

## 3) Architectural laws (performance)

### 3.1 Web is an adapter (performance + correctness)
- `lib/store_web/**` must not implement query logic, dynamic loads, or relationship decisions.
- Web transforms params → **typed query contract structs**, calls **domain read surfaces**, renders results.
- This prevents “query drift” and “N+1 by accident” across screens.

### 3.2 Read surfaces must declare a “query contract”
For each read surface (public/user/admin/api), define:
- allowed filters (finite, vetted)
- allowed sorts (finite, vetted)
- required pagination style (offset or keyset)
- allowed loads (explicit list)
- required indexes
- caching rule (hot/warm/cold; TTL; invalidation triggers)

**No screen is allowed to invent its own read semantics.**

### 3.3 No request-path heavy work
- No outbound HTTP in request path (except provider redirect *initiation*).
- No email sends in request path.
- No digital asset URL signing in request path unless it is already grant-authorized and cheap.
- Heavy fan-out work always goes to **Oban**.

### 3.4 No “DB as cache”
- Do not “solve performance” by adding more writes or denormalized tables prematurely.
- Use caching and correct indexing first.
- If you do add aggregates/materialized views later, treat them as governed artifacts with refresh strategy.

---

## 4) Caching architecture (Hot / Warm / Cold)

### 4.1 Hot cache (ETS / Cachex) — for sub-200ms UX
Use for:
- shop listing pages (page N + filter hash)
- product detail read models
- shipping rule compiled form (if small) and quote results for common routes
- price book “display” fragments (not pricing engine output if that’s governed elsewhere)

**TTL baseline:** 30–300 seconds for catalog pages, 10–60 seconds for carts (if cached), 30–300 seconds for shipping compiled rules.

**Stampede protection (MUST):**
- single-flight / request coalescing per key
- soft TTL + background refresh where possible
- avoid “cache miss = everyone hits DB at once”

### 4.2 Warm cache (Redis) — for shared caches across nodes
Single-tenant still benefits if you run multiple nodes or need persistence across deploys.

Use for:
- webhook dedupe keys (24–72 hours)
- shipping rules cache (30–120 minutes)
- price book display cache (30–120 minutes)
- “inventory availability hints” (short TTL; durability still in DB)

**Key conventions:** as in governance doc: `prod:store:<namespace>:...`  
**Never** embed PII in keys.

### 4.3 Cold (Postgres) — the source of truth
The DB holds durable truth:
- orders, payment intents, refunds
- inventory reservations (if using DB truth)
- cart state (if persisted)
- grants/subscriptions
- outbox records

**The goal is not “avoid DB”** — it is “avoid *avoidable* DB” and “keep DB queries indexed and small”.

---

## 5) Indexing rules (MUST for enterprise)

### 5.1 Catalog (Products / Variants)
Required patterns:
- `products.slug` unique
- `products.status` + `published_at` composite (for browse ordering)
- `products.category_id` index (if categories)
- `variants.sku` unique (if SKU)
- `variants.product_id` index
- `inventory_items.sellable_id` unique + index

Avoid:
- filtering by non-indexed text fields
- ordering by fields without indexes on large tables

### 5.2 Carts
- `carts.cart_token` unique (guest cart)
- `carts.user_id` index (user cart)
- `cart_items.cart_id` index
- `cart_items` unique `(cart_id, sellable_id)` (or `(cart_id, variant_id)`)

### 5.3 Orders
- `orders.order_ref` unique
- `orders.user_id, inserted_at` composite (user order history)
- `orders.status, inserted_at` composite (admin dashboards)
- `order_line_items.order_id, line_no` unique (you already have)

### 5.4 Payments / Refunds
- `payment_intents.provider_ref` unique (or provider + ref)
- `payment_intents.order_id` index
- `refunds.payment_intent_id` index
- `refunds.idempotency_key` unique per intent (if modeled)

### 5.5 Shipping / Fulfillment
- shipping rules: index by `zone_id`, `method_id`, and any “active window” fields
- fulfillment: `fulfillment_orders.order_id` unique; `status, inserted_at` index

### 5.6 Digital
- `download_grants` unique `(order_line_item_id, asset_id)`
- `download_grants.user_id` index (or order_id)
- `download_grants.expires_at` index (for cleanup)

### 5.7 Subscriptions
- `subscriptions.user_id, status` composite
- `renewal_attempts.subscription_id, renewal_key` unique
- `renewal_attempts.status, inserted_at` index (ops visibility)

---

## 6) LiveView performance rules (PETAL-compatible)

### 6.1 Lists must stream
- Shop listing, admin tables, order lists should use streaming patterns.
- Avoid assigning huge lists to socket assigns repeatedly.
- Prefer stable ids and incremental updates (stream insert/delete).

### 6.2 Debounce user input
- Search/filter changes must be debounced and server-side.
- Do not trigger DB queries on every keystroke.

### 6.3 Pagination must be explicit
- Public lists: offset pagination is acceptable for MVP, but guard with indexes.
- Admin lists: consider keyset if tables become large.
- Never “load all and paginate in memory”.

### 6.4 Loads must be purposeful
- Each screen defines exact relationship loads.
- “Load everything” is banned.
- The domain read surface owns `load` decisions, not the LiveView.

---

## 7) Ash-specific performance guidance

### 7.1 Prefer resource read actions + code interfaces
- Each read action can set defaults: sorting, filtering constraints, pagination policy.
- Keep “shape” stable: return read models that screens expect.

### 7.2 Prevent accidental N+1
- Use explicit `load` lists in read surfaces.
- Avoid per-row queries in render functions.
- If you need derived fields, consider:
  - calculated fields (but watch DB cost)
  - aggregates (with indexes)
  - precomputed snapshots (if immutable)

### 7.3 Pagination strategy
- Use Ash pagination consistently across surfaces.
- Ensure sorting keys are indexed.
- For keyset pagination: ensure stable deterministic ordering.

### 7.4 Bulk operations
- Admin bulk updates must be implemented with caution:
  - apply policy checks
  - batch in bounded chunks
  - avoid long transactions that lock hot tables

---

## 8) Webhook and external-provider performance rules

### 8.1 Webhook controller is a “thin security gate”
- Verify signature in controller (pure computation).
- Optionally persist receipt (small insert).
- Enqueue worker.
- Return quickly.

### 8.2 Dedupe early
- Use provider event id as a dedupe key.
- Store dedupe key in Redis (warm) or DB unique constraint.
- Worker must be replay-safe regardless.

### 8.3 Rate limiting
- Apply rate limits at the edge (Cloudflare/nginx) **and** in-app (Redis ZSET or token bucket).
- Do not allow webhook endpoints to become an amplification vector.

---

## 9) Oban performance rules

### 9.1 Separate queues by workload
- `webhooks_apply` (fast, strict)
- `emails` (retry-friendly)
- `digital_grants` (fast)
- `subscriptions` (scheduled)
- `maintenance` (cleanup)

### 9.2 Unique jobs for replay safety
- webhooks: unique by provider_event_id
- emails: unique by outbox message id
- grants: unique by (order_line_item_id, asset_id)
- renewals: unique by renewal_key

### 9.3 Timeouts and backoff
- Fail fast on permanent errors.
- Backoff on transient provider issues (email, signing).
- Never retry domain state transitions if they already committed; use idempotency anchors.

---

## 10) Measurement & observability (must exist before “enterprise complete”)

### 10.1 Telemetry events (minimum)
Emit telemetry for:
- `catalog.list` duration + result_count + cache_hit
- `catalog.detail` duration + cache_hit
- `cart.mutate` duration + db_queries
- `checkout.start` duration + db_queries
- `shipping.quote` duration + cache_hit
- `webhook.verify` duration
- `webhook.apply` duration + idempotent_replay? boolean
- `email.send` duration + provider response class
- `digital.sign_url` duration
- `subscription.renewal` duration + outcome

### 10.2 Query visibility
- Enable slow query logging in production.
- Track “queries per request” for hot paths.
- Add alerts for p95/p99 breaches.

---

## 11) Load testing & validation plan

Before declaring the blueprint “fully working enterprise ecommerce”:

### 11.1 Scenarios (minimum)
- 500 concurrent users browsing catalog
- 200 concurrent add-to-cart actions
- 50 concurrent checkout starts
- webhook burst: 100 events/min for 10 minutes (simulate provider retries)
- subscription renewal burst (cron window): 1k renewals over 10 minutes (scaled down for your store)

### 11.2 Acceptance thresholds
- No error spikes
- No DB saturation
- Cache hit ratio > 80% for catalog/detail under browse load
- Checkout p99 < 5s
- No oversell (inventory invariants hold)

---

## 12) Performance & Scaling Review template (MANDATORY)

For every new action/surface, fill this in:

- **Surface name**: (e.g., `Store.Catalog.list_public/2`)
- **Hot path touched**: (catalog/detail/cart/checkout/webhook/admin)
- **Data layer**: hot / warm / cold
- **Query shape**: filters, sorts, loads
- **Pagination**: offset/keyset, ordering keys
- **Indexes required**: list them
- **Cache key**: (what identifies the entry)
- **TTL**: (seconds/minutes)
- **Invalidation triggers**: (what changes invalidate)
- **Stampede protection**: (single-flight, soft TTL, prewarm)
- **Side effects**: none / Oban queue name
- **Worst-case behavior**: (cache miss; DB fallback; degradation plan)

---

## Governance impact
No governance docs are modified in this step.  
However, **Phase 29 is authoritative**: future phases must reference it and conform to its budgets and review template.

