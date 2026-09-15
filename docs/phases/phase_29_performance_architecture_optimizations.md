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

## 10) Memory, GC & Runtime Resource Safety (permanent)

Memory, garbage collection, mailbox pressure, and runtime resource lifecycle are
part of the performance and hardening contract. Apply this section to every
runtime-relevant plan, implementation, review, and load or soak test.

### 10.1 Process and state bounds

- **PROCESS LIFETIME:** bound process creation, verify expected termination, and
  ensure Tasks and workers cannot become orphaned.
- **PROCESS MEMORY:** investigate unexplained monotonic heap growth and keep
  long-lived process memory bounded.
- **MAILBOXES:** keep `message_queue_len` bounded under supported load. No
  long-lived consumer may accumulate messages indefinitely.
- **GENSERVERS:** bound in-memory state and prevent unbounded event or history
  accumulation.
- **ETS:** make table ownership explicit, bound table size, and name the owner
  responsible for cleanup or TTL expiry.
- **BINARIES:** inspect large-binary retention and sub-binary retention risks.
- **ATOMS:** do not create atoms dynamically from user-controlled input. Atom
  growth must remain bounded.

### 10.2 Caches and coordination state

- **CACHE:** Cachex and ETS entries need bounded capacity, TTL, and eviction
  where appropriate.
- **REDIS:** queues, leases, metadata, fences, and hot keys need explicit
  bounded retention and cleanup.
- **OBAN:** backlog, retries, dead jobs, uniqueness windows, and cleanup must
  remain bounded.
- **LIVEVIEW:** socket assigns and state must remain bounded. Disconnected
  clients must clean up subscriptions and processes.
- **PUBSUB:** subscriber and process lifetimes must be bounded. Stale
  subscriptions must not accumulate.
- **TIMERS / MONITORS:** prevent timer and monitor accumulation.
- **PORTS / NIFS:** make lifecycle and cleanup explicit wherever used.

### 10.3 GC and leak review

- Monitor minor and full-sweep GC behavior.
- Avoid oversized heaps in hot or long-lived processes.
- Identify GC-driven latency spikes and excessive allocation churn.
- Check for leaks of processes, ETS tables, ports, timers, telemetry handlers,
  subscriptions, workers, and caches.

The review must distinguish these failure modes instead of collapsing them into
"memory usage": memory leak, memory bloat, memory churn or allocation churn, GC
pressure, mailbox pressure, and resource leak.

### 10.4 Permanent invariants

- **PERF-MEM-001:** After a bounded workload and cooldown or expiry period,
  memory, process counts, mailbox depths, ETS/cache state, and transient
  coordination state must converge toward a stable post-load baseline rather
  than increase monotonically across equivalent runs.
- **PERF-GC-001:** Hot and long-lived processes must not require continuously
  expanding heaps or excessive major or full-sweep garbage collection to sustain
  supported throughput.
- **PERF-MBOX-001:** No long-lived process may accumulate an unbounded mailbox
  under supported load.
- **PERF-RESOURCE-001:** Processes, Tasks, timers, ETS tables, telemetry
  handlers, PubSub subscriptions, leases, fences, cache entries, and other
  transient resources must have explicit ownership and bounded cleanup.

### 10.5 Runtime measurement requirement

Relevant performance evidence must include all three windows:

1. **BASELINE BEFORE LOAD**
2. **PEAK LOAD**
3. **POST-LOAD COOLDOWN / DRAIN**

Where feasible, record BEAM total memory, process memory, binary memory, ETS
memory, atom memory, process count, port count, ETS table count, and for hot
processes memory, `heap_size`, `total_heap_size`, `message_queue_len`, and
reductions. Record GC behavior as well. At each window, also record applicable
resource cardinalities such as active Tasks/workers, timer and monitor counts,
ETS entries, Cachex entries and capacity, Redis keys/queues/leases/fences,
Oban ready/retry/scheduled/dead-job/backlog and uniqueness counts, LiveView
sockets/subscriptions, PubSub subscribers, and telemetry handlers.

Compare equivalent runs after cooldown. The measurements must show whether
memory, process counts, mailbox depths, ETS/cache state, and transient
coordination state converge toward a stable baseline. A peak sample alone cannot
classify a leak or prove safe cleanup.

### 10.6 100k and flash-sale review

Moving contention away from PostgreSQL is insufficient if the replacement creates
one BEAM process per waiter, one timer or monitor per unbounded request,
unbounded Redis state, unbounded ETS or cache state, unbounded Oban jobs, or
unbounded mailboxes.

For every high-concurrency design, answer:

- Where does waiting state live?
- Is it bounded?
- Who cleans it up?
- What happens after cooldown?

### 10.7 TOON Note requirements

For performance or runtime-relevant TOON prompts, the `Note` field must include
these fields as applicable:

- `MEMORY`: bounded process, ETS, cache, and transient resource state
- `GC`: allocation, heap, and major or full-sweep considerations
- `MAILBOX`: bounded long-lived process queues
- `RESOURCE CLEANUP`: owner plus expiry or termination behavior
- `POST-LOAD`: expected convergence after workload cooldown

Retain the existing performance fields: `DATA LAYER`, `INDEXES`, `CACHE`,
`REDIS STRUCTURE`, `TTL`, `INVALIDATION/CLEANUP`, `PUBSUB`, `STORE.REPO
EFFECT`, and `100K STATUS`. Do not force irrelevant memory fields onto prompts
that are purely documentation-only.

## 11) Measurement & observability (must exist before “enterprise complete”)

### 11.1 Telemetry events (minimum)
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

### 11.2 Query visibility
- Enable slow query logging in production.
- Track “queries per request” for hot paths.
- Add alerts for p95/p99 breaches.

---

## 12) Load testing & validation plan

Before declaring the blueprint “fully working enterprise ecommerce”:

### 12.1 Scenarios (minimum)
- 500 concurrent users browsing catalog
- 200 concurrent add-to-cart actions
- 50 concurrent checkout starts
- webhook burst: 100 events/min for 10 minutes (simulate provider retries)
- subscription renewal burst (cron window): 1k renewals over 10 minutes (scaled down for your store)

### 12.2 Acceptance thresholds
- No error spikes
- No DB saturation
- Cache hit ratio > 80% for catalog/detail under browse load
- Checkout p99 < 5s
- No oversell (inventory invariants hold)

---

## 13) Performance & Scaling Review template (MANDATORY)

For every new action/surface, fill this in:

- **Surface name**: (e.g., `Store.Catalog.list_public/2`)
- **Hot path touched**: (catalog/detail/cart/checkout/webhook/admin)
- **DATA LAYER**: hot / warm / cold
- **Query shape**: filters, sorts, loads
- **Pagination**: offset/keyset, ordering keys
- **INDEXES**: list them
- **CACHE**: key and capacity, if applicable
- **REDIS STRUCTURE**: keys, queues, leases, fences, or hot keys, if applicable
- **TTL**: (seconds/minutes)
- **INVALIDATION/CLEANUP**: triggers, owner, and expiry behavior
- **PUBSUB**: topics, subscriber lifecycle, and stale-subscription cleanup
- **STORE.REPO EFFECT**: query, pool, lock, and connection pressure
- **100K STATUS**: boundedness result, risk, or unmeasured status
- **Stampede protection**: (single-flight, soft TTL, prewarm)
- **Side effects**: none / Oban queue name
- **Worst-case behavior**: (cache miss; DB fallback; degradation plan)
- **MEMORY**: bounded process, ETS, cache, and transient resource state, where applicable
- **GC**: allocation, heap, and major or full-sweep considerations, where applicable
- **MAILBOX**: bounded long-lived process queues, where applicable
- **RESOURCE CLEANUP**: owner, expiry, and termination behavior, where applicable
- **POST-LOAD**: expected convergence after workload cooldown, where applicable

---

## Governance impact
`AGENTS.md` is the process authority. Phase 29 is authoritative for the detailed
performance and runtime resource safety methodology. Future phases must conform
to its budgets, invariants, measurement windows, 100k review, and review
template. `docs/governance/performance_scaling.md` is the short mandatory
companion checklist.
