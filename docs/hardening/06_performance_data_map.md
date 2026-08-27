# Store Blueprint Commerce Performance Data Map

Status: S0-06 discovery record<br>
Date: 2026-08-27<br>
Scope: documentation-only architecture discovery

This map records the performance shape that exists in the implementation today. The
resource actions, domain facades, migrations, workers, and cache modules are the source
of truth. The governance documents are used for comparison and terminology, not as
evidence that an unimplemented design exists.

No caching, Redis, database query, index, schema, or infrastructure change is made by
this document. “Candidate” and “risk” entries below are observations to validate with
production cardinalities, `EXPLAIN`, telemetry, and load tests before any hardening work.

## 1. Purpose

The performance goal for the commerce engine is predictable latency at the web boundary
while preserving database authority for money, inventory, payment transitions,
subscription periods, and access grants. The current code already separates several
read projections and asynchronous side effects, but the boundaries are not uniform:

- public catalog reads have Cachex, ETS, and Redis-backed paths;
- carts, checkout, orders, payment transitions, and inventory reservations remain
  primary-database workflows;
- entitlement checks are high-frequency reads over durable grants with a per-user
  Cachex projection;
- payment and renewal flows combine local state transitions with provider calls and
  Oban retries;
- several administrative, reconciliation, and fan-out paths still perform repeated
  reads or per-record work.

The commerce-specific risks are shared mutable rows, hot inventory variants, payment
webhook bursts, external provider latency, retry amplification, stale access data, and
unbounded growth of operational records. An extraction cannot safely put a boundary
around a domain until it knows which data that domain owns, which values are derived,
which reads can tolerate staleness, and which writes must serialize.

This is a code-derived baseline, not a benchmark. The implementation exposes
`RepoStats` and telemetry on several hot paths, but this discovery pass does not claim
production p95/p99 latency or 100k-user capacity without runtime measurements.

## 2. Data Classification Model

The classification describes access pressure and correctness sensitivity, not a storage
retention policy.

### Hot Data

Hot data is touched on storefront requests, active-cart mutations, checkout, payment
webhooks, access checks, or due-work ticks. It is usually small, mutable, and sensitive
to stale reads or lock contention.

- active carts and cart items;
- published product projections and availability hints;
- checkout drafts, payable orders, payment intents, webhook receipts in flight;
- inventory counters and active reservations;
- active subscription rows that are due or past due;
- active entitlement sets used for authorization;
- Oban jobs and outbox rows awaiting side effects.

### Warm Data

Warm data is requested regularly but is less latency-critical than a mutation or access
decision. It includes recent orders, subscription dashboards, recent renewal attempts,
shipping/tax configuration, fulfillment state, and recent customer-facing history.

Warm data can often use bounded pagination and read projections, but it remains backed by
Postgres when it is used to make a business decision.

### Cold Data

Cold data is historical or operational evidence that is rarely on a customer request
path: completed order and payment history, old renewal attempts, processed provider
events, purged webhook evidence, audit records, and closed metric buckets.

Cold data still has retention, privacy, and audit requirements. “Cold” does not mean it
can be deleted or treated as cacheable without a policy.

## 3. Domain Data Map

| Domain | Data | Authority | Read Frequency | Write Frequency | Classification |
|---|---|---|---|---|---|
| Catalog | `products`, `variants`, options, option values, images, digital links | `Store.Catalog` resources and Postgres; public projections are derived | Very high for browse/detail; lower for admin | Low-to-moderate admin/catalog changes | Hot read projection; warm source records |
| Cart | `carts`, `cart_items` | `Store.Carts.Facade` and Postgres | Very high for active shoppers; usually once per cart view/mutation | High while a cart is active | Hot |
| Checkout | `checkout_drafts`, checkout key/version, shipping quote evidence | `Store.Checkout` plus the associated `orders` row | High during checkout; repeated across steps | High during checkout steps; low after completion | Hot while active; cold after expiry/history |
| Orders | `orders`, `order_line_items`, `order_adjustments` | `Store.Orders` and Postgres; line/adjustment snapshots are durable pricing evidence | High for checkout, confirmation, customer history, and operations | Several writes through checkout/payment/fulfillment | Hot while payable; warm after payment; cold historically |
| Payments | `payment_intents`, `payment_attempts`, `payment_applications`, `refunds`, `refund_attempts`, provider events, webhook receipts | Postgres owns local lifecycle, idempotency, and applied transitions; the provider owns remote payment outcome; `Store.Payments` reconciles the two | High for intent creation and webhook bursts; lower for history/reconciliation | High around payment attempts, webhooks, refunds, and state transitions | Hot in flight; warm/cold after settlement |
| Subscriptions | `subscriptions`, `subscription_items`, plans, stored payment methods, `renewal_attempts` | `Store.Subscriptions` and Postgres; provider is external charge authority | User/admin reads are warm; due tick and active renewal rows are hot | Low per subscription, but bursty at renewal and dunning time | Hot for due/past-due rows; warm otherwise |
| Entitlements | `entitlement_grants` and per-user `EntitlementSet` | Durable grants in `Store.Entitlements`; `EntitlementSet` is a derived read projection | Very high when access-controlled pages or downloads are requested | Low-to-moderate, concentrated after subscription/payment changes | Hot |
| Inventory | `inventory_items`, `inventory_reservations` | `Store.Orders` reservation logic and Postgres row locks/counters | High for cart prechecks and checkout; expiry/consume work is periodic | High for popular variants and every checkout/payment outcome | Hot |
| Fulfillment and digital side effects | `fulfillment_orders`, `shipments`, `fulfillment_items`, `download_grants`, `email_outboxes` | Respective domain facades, durable rows, and Oban | Warm customer/operations reads; hot while a job is pending | Bursty after payment and during retries | Hot queue state; warm/cold evidence |

Ownership is intentionally split between durable facts and projections. For example,
`StockFastPath`, `AvailabilityCache`, `ProductListCache`, and the entitlement cache do
not own inventory, catalog, or access truth. They can only accelerate reads whose
authoritative records remain in Postgres.

## 4. Database Performance Review

### 4.1 Tables and relationships observed in migrations

The migration set creates the following commerce and supporting tables. Oban’s own
tables are created through `Oban.Migrations.up/0` in the side-effects migration.

- Catalog: `products`, `variants`, `product_options`, `product_option_values`,
  `variant_option_selections`, `product_images`, `catalog_categories`,
  `product_digital_links`, `digital_assets`.
- Cart and checkout: `carts`, `cart_items`, `checkout_drafts`.
- Order and pricing: `orders`, `order_line_items`, `order_adjustments`, `coupons`,
  `promotions`, `tax_rates`, `shipping_zones`, `shipping_methods`, `shipping_rates`.
- Inventory and fulfillment: `inventory_items`, `inventory_reservations`,
  `fulfillment_orders`, `fulfillment_items`, `shipments`.
- Payments: `payment_intents`, `payment_attempts`, `payment_applications`, `refunds`,
  `refund_attempts`, `refund_adjustments`, `provider_events`, `webhook_receipts`,
  `stored_payment_methods`.
- Subscription and access: `subscription_plans`, `variant_subscription_plans`,
  `subscriptions`, `subscription_items`, `renewal_attempts`, `entitlement_grants`.
- Side effects and operations: `email_outboxes`, `audit_logs`, `ops_metric_buckets`,
  `site_settings`, `users`, `user_identities`, `role_assignments`, `tokens`, and
  `tool_lead_submissions`.

The main relationship paths are:

```text
products -> variants -> inventory_items
products -> product_options -> product_option_values
variants -> variant_option_selections -> product_option_values

carts -> cart_items -> variants
checkout_drafts -> orders -> order_line_items / order_adjustments
orders -> payment_intents -> payment_attempts / payment_applications / refunds
orders -> inventory_reservations / fulfillment_orders / email_outboxes / download_grants

users -> subscriptions -> subscription_items / renewal_attempts / entitlement_grants
subscription_plans -> subscriptions and variant_subscription_plans
provider_events and webhook_receipts -> payment/refund processing
```

Foreign-key delete behavior is part of the pressure profile. Cart items and product
variant-dependent records are removed or restricted according to lifecycle rules;
orders retain line and pricing snapshots, while payment, fulfillment, download, and
subscription records refer back to order or user identity. The migration definitions,
rather than this summary, must be consulted before changing a delete or retention rule.

### 4.2 Constraints and query-critical columns

The migrations enforce several important correctness boundaries:

- UUIDv7 primary keys are used for the commerce resources.
- Monetary values are integer minor units with currency columns and non-negative/check
  constraints on totals, quantities, stock, rates, and adjustments.
- `order_ref`, checkout keys, provider event identities, payment provider references,
  renewal keys, entitlement source identities, inventory variant identity, and email
  idempotency keys have uniqueness constraints where the workflow requires them.
- Cart, order, payment intent, inventory item, reservation, and related resources carry
  version or timestamp-based optimistic-concurrency fields used by their actions.
- Partial uniqueness protects one active cart per token/user, one checkout draft per
  cart version, one in-flight provider reference where applicable, and one renewal
  attempt per subscription and renewal key.

The most important existing index families are:

| Workload | Existing index/constraint evidence | Critical columns |
|---|---|---|
| Public catalog | Product slug uniqueness; category/status/publish indexes; `(status, published_at)` hot-path index; variant product/status/selection indexes | `products.status`, `published_at`, `slug`, `category_id`; `variants.product_id`, `status`, `price_minor` |
| Cart lookup | Partial unique active token and user indexes; cart-item cart/variant/plan indexes and partial uniqueness | `carts.token`, `carts.user_id`, `carts.status`; `cart_items.cart_id`, `variant_id`, `subscription_plan_id` |
| Checkout reuse | Unique `checkout_key`; unique cart/version draft identity; draft order index; order checkout key | `checkout_drafts.checkout_key`, `cart_id`, `cart_version`, `order_id`; `orders.checkout_key` |
| Orders | Unique `order_ref`; user and state keyset indexes added in Phase 29; state, setup, shipping/tax indexes | `orders.user_id`, `state`, `inserted_at`, `id`, `provider_setup_started_at` |
| Inventory | Unique inventory row per variant; active reservation expiry/state indexes; reservation key and order/variant uniqueness | `inventory_items.variant_id`, `reserved_count`; `inventory_reservations.variant_id`, `state`, `expires_at`, `reservation_key` |
| Payment | Unique provider/event, attempt, application, refund idempotency, and provider reference identities; provider/status lookup indexes | `provider_events.provider/event_id`; `payment_intents.order_id`, `provider_payment_id`, `provider_session_id`; `webhook_receipts.provider_event_id`, `processing_status` |
| Subscriptions | User/status and plan indexes; partial active-due and past-due tick indexes; renewal-key uniqueness | `subscriptions.status`, `next_renewal_at`, `next_retry_at`, `cancel_at_period_end`, `retry_suppressed_at`; `renewal_attempts.subscription_id`, `renewal_key` |
| Entitlements | User/kind/scope/status, source, and validity indexes; source identity uniqueness | `entitlement_grants.user_id`, `status`, `kind`, `scope_key`, `valid_to_at`, `source_id` |
| Side effects | Email idempotency/unique template identities and state/time indexes; fulfillment state/time indexes | `email_outboxes.state`, `inserted_at`, `template_kind`; `fulfillment_orders.state`, `inserted_at` |

The primary migration evidence is [`priv/repo/migrations/`](../../priv/repo/migrations/),
especially the hot-path additions in
[`phase 29`](../../priv/repo/migrations/20260310113000_phase_29_hot_path_indexes_and_keyset_pagination.exs)
and the renewal guards in
[`phase 27 physical renewal guards`](../../priv/repo/migrations/20260308193000_phase_27_physical_renewal_guards.exs).

### 4.3 Candidate index and query-shape gaps

These are observed pressure points, not approved schema changes:

- Public catalog search applies `ILIKE`-style title/subtitle predicates. No dedicated
  text-search index is visible in the inspected migrations. A broad search can therefore
  scan a large published set even when status/publish filtering is indexed.
- The admin catalog list reads records and then applies some filters, sorting, and
  pagination in Elixir. The query can grow with the catalog rather than the page size.
- Subscription list code loads plans and filters some plan-key behavior after the
  subscription read. The user/status indexes help the first predicate, but the final
  result size and offset behavior still need measurement.
- The entitlement projection reads all active grants for a user and evaluates validity
  windows while building the set. The user/status leading index helps, but per-user
  grant cardinality can make cold reads expensive.
- Cart item mutation locks search by cart, variant, and optional subscription plan.
  The uniqueness constraints protect the identity, but the full lock query should be
  checked against its partial/composite index coverage with `EXPLAIN`.
- Refund calculations read order/payment refund history and fold remaining amounts in
  memory. The current refund indexes are primarily single-column; a composite plan for
  the actual state/order/payment predicates would require measured evidence.
- Webhook evidence cleanup combines retention time and evidence-purged state. Separate
  time/state indexes exist in the migration history, but cleanup selectivity under large
  receipt volume is not measured.

No missing index is declared from schema inspection alone. The next evidence required
for any index decision is representative row counts, query plans, selectivity, lock
waits, and write amplification.

### 4.4 Query amplification and database pressure

Observed query shapes likely to create pressure are:

- catalog detail cache misses: product/images plus option, option-value, and variant/
  inventory/selection reads, then in-memory grouping; subscription products add plan
  option reads;
- cart view with items: cart, cart items, batched variants, and batched products. This
  avoids an item-by-item detail query on the normal view path, but cart merge performs
  per-item locking and upsert work;
- checkout start/finalize: cart and item locks, batched catalog/plan reads, draft/order
  reuse, snapshot writes, tax/shipping reads, and inventory reservation work;
- payment webhook processing: several alternative payment-intent lookups followed by
  provider-event and attempt idempotency writes, order validation, and a success
  transaction;
- inventory consume/release/expiry: variant-ordered locks plus per-reservation updates;
- entitlement revocation: reads all grants for a subscription and updates grants one at
  a time;
- renewal processing: one due scan followed by multiple reads and writes per
  subscription, plus optional physical inventory, shipping, and tax work.

The code captures query counts and database timings through
[`RepoStats`](../../lib/store/support/telemetry/repo_stats.ex) on catalog detail, cart,
checkout, and payment entry points. Those counters are the right measurement boundary;
this document does not invent fixed query counts for branches with different cache
state or line counts.

### 4.5 Transaction boundaries

| Transaction boundary | Work inside or adjacent to it | Performance consequence |
|---|---|---|
| Cart mutation | Lock active cart and target item, perform sellability/stock checks, write item and cart version, reload the cart view | Short, frequent row locks; hot users and duplicate submissions contend on one cart row |
| Checkout start | Lock cart and all cart items, validate catalog/plan state, reuse/create order and draft | Lock duration includes several reads and creates; cart version/draft uniqueness provides duplicate safety |
| Checkout finalization | Lock cart/items/order, revalidate catalog and pricing, write immutable snapshots, reserve inventory, write tax/shipping totals | Correctness is strong, but it concentrates work and locks at the checkout boundary |
| Inventory reservation | Checkout uses one SQL CTE with ordered `FOR UPDATE` inventory locks; generic paths use per-variant transactions | Ordered locks reduce deadlock risk; popular variants serialize by design |
| Payment success application | Unique application insert, payment intent/order transitions, reservation consumption, notification collection | One durable transition prevents duplicate settlement; downstream fan-out is post-commit |
| Refund request | Lock payment intent, calculate remaining refundable amount, lock/reuse idempotent refund state | Refunds for one payment serialize; historical refund scans add read pressure |
| Renewal attempt | Claim attempt with compare-and-set update; prepare order/reservation and local intent, then provider charge and later reconciliation | Attempt uniqueness and optimistic claim prevent duplicate work; provider latency must not be hidden in a long DB lock |
| Expiry sweep | Select bounded expired reservations, use `SKIP LOCKED`, lock inventory rows, decrement and terminalize reservations | Bounded batches protect the queue, while popular variants can still collide with checkout |

Notifications are collected on transactional Ash paths and emitted after commit where
the implementation uses the post-commit wrapper. That keeps observers from running while
the transaction is holding business rows.

## 5. Checkout Performance Path

```text
User action
  -> cart view or mutation
  -> start checkout
  -> set shipping
  -> finalize totals and reserve inventory
  -> create/reuse payment intent
  -> provider redirect or client confirmation

Database operations
  -> active cart/item reads and locks
  -> batched variant/product/plan reads
  -> checkout draft/order reuse or creation
  -> immutable line/adjustment snapshots
  -> tax/shipping reads and order totals
  -> inventory counter/reservation transaction

External calls
  -> payment provider setup through the provider task boundary
  -> no outbound HTTP call is visible in the inspected local shipping quote path

Workers
  -> payment webhook receipt processor
  -> fulfillment, digital grants, subscription activation/reconciliation, email
```

### 5.1 User actions and database operations

`Store.Carts.Facade` first resolves the active cart by token/user and then, for a view
with items, loads cart items plus batched variants and products. Mutations use a database
transaction, lock the cart and relevant item, perform an ETS stock precheck, update the
item and cart version, and reload the resulting view. The ETS check is advisory; the
checkout reservation is authoritative.

`Store.Checkout.Domain.start_from_cart/3` locks the active cart and all cart items,
validates that the catalog is still sellable, resolves subscription plan attachments,
and reuses or creates a draft/order using checkout-key and cart-version uniqueness.

`set_shipping/3` reads checkout context, computes server-side quote options, selects a
server-generated quote, and persists the address/method/evidence to the order. The
inspected implementation uses the local `Store.Shipping` facade; there is no observed
outbound HTTP call in this step.

`finalize_totals/3` locks the cart, cart items, and order again, revalidates the catalog
and subscription selections, writes the priced snapshot, reserves inventory, reads tax
rates where needed, evaluates tax/shipping in memory, persists adjustment/snapshot data,
and finalizes order totals. The branch for subscription-only lines avoids physical
shipping work.

### 5.2 Bottlenecks, races, and scaling concerns

- Several reads and validations occur while checkout rows are locked. The boundary is
  correct but should be measured for lock duration and pool occupancy.
- Cart mutations serialize on one cart row. This is acceptable for normal use but can be
  visible with rapid multi-tab updates or automated clients.
- Inventory prechecks can be stale. The ordered reservation CTE and inventory row locks
  are the final oversell guard; a cached positive precheck cannot reserve stock.
- Checkout draft/order creation is protected by checkout-key, cart-version, and order
  uniqueness, but duplicate callers still perform competing reads and conflict recovery.
- Payment provider setup adds external latency after local checkout state is prepared.
  Provider calls and retries must not be counted as database capacity.
- A paid webhook can fan out fulfillment, digital, subscription, and email jobs. The
  request/worker split protects the user request but transfers pressure to Oban queues.

### 5.3 Checkout performance review

- Hot/warm/cold: active cart, draft, payable order, and reservation are hot; completed
  order snapshots become warm and then cold history.
- Source of truth: Postgres cart/order/snapshot/reservation rows; catalog and stock
  caches are projections or hints only.
- Cacheability: public catalog inputs and stock hints are cacheable; mutable cart,
  checkout, price snapshot, and reservation decisions are not safely replaced by a
  general cache.
- Invalidation: catalog mutations clear product projections; inventory reservation,
  consume, release, and expiry clear local stock/availability hints. Durable checkout
  state is read directly.
- At 100k concurrent users: public catalog traffic can be absorbed partly by existing
  caches, but personalized cart/checkout traffic concentrates on the primary database,
  connection pool, cart rows, order rows, and popular inventory rows. Capacity is not
  demonstrated without a concurrent checkout/load test.

## 6. Payment Performance Path

### 6.1 Webhook processing

The payment return/cancel path is read-only and is not a payment proof. The durable
payment path is the webhook flow:

1. The controller verifies the raw body and headers, normalizes a canonical receipt,
   persists the receipt when configured, and enqueues one processing job.
2. `ProcessWebhookReceiptWorker` fetches the receipt and calls the payment facade.
3. The interlock layer decodes and normalizes the provider payload, locates the local
   payment intent by the available provider/session/local references, hydrates provider
   references when needed, and validates the canonical amount/currency against the order.
4. It upserts `provider_events` and `payment_attempts` through their identities before
   applying the canonical state transition.
5. A successful payment uses the unique payment-application key, transitions the payment
   intent and order, consumes reservations, and emits post-commit notifications/fan-out
   jobs. Duplicate deliveries return the already-applied result and do not repeat the
   settlement fan-out.

A webhook can therefore perform several alternative reads before it reaches the
`provider_events`/attempt idempotency anchors. A code-derived successful path commonly
has multiple intent lookups, an order read, two idempotency writes, and transition writes;
the exact count depends on which provider reference is present and whether records are
already hydrated.

### 6.2 Reconciliation, retries, and idempotency

- `ExpirePendingProviderSetupOrdersWorker` runs every minute and performs a bounded
  provider-setup recovery/sweep with a default batch size of 200.
- Payment and refund webhook workers have up to 10 Oban attempts. Their worker modules
  do not declare argument-level uniqueness; replay safety is supplied by webhook/provider
  identities, payment attempts, refund identities, and the payment application key.
- The payment-intent create/reuse path uses a deterministic key and database uniqueness;
  an additional partial in-flight order constraint prevents two active intents for the
  same order.
- Provider calls are external and may be retried independently of local database
  transitions. Local “pending setup” and “requires action” states are the recovery
  anchors.
- Webhook raw bodies and headers are retained as evidence and later purged by a bounded,
  unique operations worker. This is both a storage-growth and sensitive-data concern.

### 6.3 Payment performance review

- Hot/warm/cold: payment intents, in-flight attempts, webhook receipts, and pending
  provider setup are hot; settled payment/refund evidence is warm, then cold.
- Source of truth: the external provider is authoritative for the remote result; local
  Postgres is authoritative for the local state machine, idempotency, order application,
  and reservation consumption.
- Cacheability: payment proof, intent state, order totals, provider references, and
  refund balances must not be replaced by a cache. Read-only operational dashboards may
  use derived projections, but no such cache is the current authority.
- Invalidation: no payment-state cache is used; durable transitions and unique keys make
  replays safe. Post-commit notifications and jobs are the invalidation/fan-out boundary
  for downstream projections.
- At 100k concurrent users: ordinary browsing is not the main pressure; provider bursts
  and webhook delivery are. A burst can saturate the webhooks queue, primary DB pool,
  payment/order row locks, and post-commit queues even if catalog reads remain cached.

## 7. Subscription Renewal Performance

### 7.1 Scheduling and batch shape

The configured cron runs `RunDueSubscriptionRenewalsWorker` every five minutes. The
worker reads at most 100 due subscriptions by default, with an allowed limit up to 500,
loads each plan, and enqueues one `ProcessSubscriptionRenewalWorker` per due row. Each
job receives a deterministic jitter of up to one hour. The tick worker is unique for 55
seconds; the per-subscription worker is unique for its arguments for the lifetime of the
job.

The due read action selects:

- active subscriptions with `next_renewal_at <= now`;
- past-due subscriptions with no retry suppression and a missing or due `next_retry_at`;
- rows where `cancel_at_period_end` is false;
- ascending `next_renewal_at` and UUID tie-break order with the configured limit.

The partial active-due and past-due indexes in the Phase 27 migration align with these
predicates. The facade also exposes a synchronous due-renewal runner that processes the
selected list directly; the configured worker path fans out jobs instead.

### 7.2 Per-renewal work and retry risks

For each subscription, the facade:

1. Reads the subscription and plan, checks due state/grace expiry, computes the next
   period, and derives `renewal_key = subscription + period end`.
2. Creates or reuses one `renewal_attempt` using the unique subscription/renewal key,
   then claims pending/failed work with an optimistic `updated_at` compare-and-set.
3. Resolves the effective plan and variant. A physical renewal also reads the prior
   shipping profile, quotes shipping, reads tax rates, and reserves inventory; a
   subscription-only renewal writes a virtual pricing snapshot.
4. Reuses or creates a renewal order, writes snapshots/totals, creates or reuses a
   deterministic payment intent, and marks the attempt processing.
5. Calls the provider for an off-session charge. It persists provider references. Failure
   or authentication-required responses release renewal inventory and update payment/
   subscription state; a successful remote result is reconciled through the payment and
   subscription paths.
6. Reconciliation advances the period, clears pending changes/dunning state, syncs the
   entitlement, and marks the attempt succeeded. Retry schedules use plan configuration,
   defaulting to 24/72/120 hours, while grace expiry can end the subscription and revoke
   entitlements.

The retry design limits one period to one durable renewal key, but it still creates
multiple DB operations and potentially one external provider call per subscription.
Failure bursts can create a retry wave, especially when many plans share the same billing
anchor. Jitter spreads the configured tick’s fan-out; it does not remove queue, provider,
or inventory capacity limits.

### 7.3 Renewal performance review

- Hot/warm/cold: due active/past-due subscription rows, renewal attempts in progress,
  renewal orders, and reserved inventory are hot; subscription history and old attempts
  are warm/cold.
- Source of truth: Postgres subscription/attempt/order/payment/reservation rows plus the
  provider’s remote charge result. Scheduler functions are pure derivation, not storage.
- Cacheability: plan/configuration reads may be candidates for bounded read caching, but
  due rows, attempt status, period boundaries, payment methods, and inventory decisions
  must be read from durable state.
- Invalidation: renewal success updates the subscription period and entitlement; failure
  updates dunning/retry fields; reservation release/consume clears local stock hints.
  No general subscription-state cache is present.
- At 100k concurrent users: renewal volume is usually lower than browse traffic but can
  form a time-based burst. A shared billing anchor can overload the subscription queue,
  payment provider, primary DB, and popular-variant locks. Current batch limits and
  jitter provide bounded work admission, not a capacity guarantee.

## 8. Entitlement Read Performance

`Store.Entitlements.Facade.entitlement_set_for_user/1` is the high-read access surface.
On a local Cachex miss, it reads all active `entitlement_grants` for the user, sorts by
recency, builds an in-memory effective set, and assigns a 60-second expiry. `Cachex.fetch`
provides per-key fetch behavior on the node. The cache key is user-scoped; it is not a
second source of entitlement truth.

Issuing or revoking a subscription entitlement changes the durable grant and then clears
the local user key and broadcasts a user-specific Phoenix PubSub invalidation. The
effective-grant calculation also checks validity timestamps and revocation state. The
implementation therefore has two stale-read controls: explicit invalidation after a
write and a bounded TTL if an invalidation is missed. Cross-node behavior depends on
each node subscribing to the invalidation topic; there is no Redis entitlement cache in
this path.

### Entitlement performance review

- Hot/warm/cold: access checks are hot; current active grants are warm-to-hot; revoked or
  expired grant history is warm/cold.
- Source of truth: `entitlement_grants` in Postgres. The per-user `EntitlementSet` is a
  derived Cachex value.
- Cacheability: yes, because the projection is user-scoped and read-heavy, provided
  stale access semantics remain bounded and cache failures fall back safely.
- Invalidation: local delete plus PubSub broadcast after a grant issue/revoke path, with
  a 60-second TTL and 30-second lazy expiration interval. A missed message leaves a
  bounded stale window.
- At 100k concurrent users: warm hits can avoid a database read for repeated access
  checks, but cold users and invalidation waves still hit the primary database. Each
  node has local memory and local misses; a single user with many grants increases cold
  read/build cost. Browser caching is unsuitable for this authenticated projection.

The main measured-risk gap is grant cardinality per user and the number of nodes that
receive invalidation traffic. Neither is available from static inspection.

## 9. Inventory Performance

Inventory is the most concurrency-sensitive data flow.

### 9.1 Reservation creation

The authoritative inventory state is `inventory_items.stock_on_hand` and
`reserved_count`, together with active `inventory_reservations`. Checkout aggregates
requested quantities by variant, uses binary UUID ordering for deterministic lock order,
and executes a SQL CTE that locks inventory rows `FOR UPDATE`, checks availability or
`allow_oversell`, updates counters, and inserts reservations. The CTE validates that all
requested quantities were matched before committing.

The generic reservation path uses a transaction with per-variant inventory locks and
existing order/variant reservations. Both paths make the database row lock and durable
counter the oversell guard. `StockFastPath` reads batches of inventory rows into a
five-second ETS hint; it is explicitly a precheck and cannot authorize a reservation.

### 9.2 Expiry and terminal transitions

Reservation consumption and release lock affected inventory rows and reservations in
binary UUID order, decrement counters, and move reservations to terminal states. The
expiry path selects active expired candidates in `expires_at` order with a batch limit of
500, uses `SKIP LOCKED`, then applies counter and state changes. The one-minute Oban
expiry worker is unique for 55 seconds and retries up to 10 times.

After reservation, consumption, release, or expiry, the implementation invalidates local
stock/availability hints. These invalidations are not a distributed inventory authority;
the next authoritative checkout still locks Postgres rows.

### 9.3 Concurrency and overselling risks

- A popular variant creates a single-row lock hotspot. Correctness requires this
  serialization; horizontal web nodes do not remove it.
- `StockFastPath` and product availability may be stale for a few seconds/minutes. The
  safe failure mode is a final reservation rejection or a refreshed read, not trust in
  the hint.
- `allow_oversell` is an explicit business setting represented as effectively infinite
  sellable quantity; it is not an accidental race.
- Checkout reservations, renewal reservations, payment-success consumption, release on
  failed payment, and expiry can contend on the same inventory row. Lock ordering reduces
  deadlocks, while queue capacity and transaction duration determine throughput.
- Expiry is bounded by 500 reservations per sweep. A backlog can keep expired stock
  reserved until later sweeps unless another path releases it.
- Cache invalidation is local for stock/availability paths. Multi-node reads can disagree
  transiently, but authoritative reservation outcomes remain database-serialized.

### Inventory performance review

- Hot/warm/cold: inventory counters and active reservations are hot; terminal
  reservations and historical stock changes are warm/cold.
- Source of truth: Postgres inventory rows and reservation rows under transaction/row
  locks.
- Cacheability: only short-lived read hints/prechecks are suitable. Reservation quantity,
  available stock at commit, and reservation state are not cacheable authorities.
- Invalidation: local `StockFastPath` and product availability invalidation after durable
  changes; TTLs provide a fallback. No cache invalidation can replace the reservation
  transaction.
- At 100k concurrent users: the database hot row for a popular variant, not the web
  process, sets throughput. Cart prechecks may absorb some reads, but checkout, renewal,
  expiry, and consume/release still serialize on the authoritative row. Overselling is
  prevented if all writers continue through the existing reservation boundary.

## 10. Cache Strategy Assessment

The following is an assessment of the mechanisms already visible in the codebase and
the constraints a future extraction would have to preserve. It does not add or change a
cache.

| Candidate | Suitable? | Why | Invalidation event | Risk |
|---|---|---|---|---|
| ETS | Yes for node-local, short-lived, non-authoritative hints | Already used by `StockFastPath` (5s) and `AvailabilityCache` (300s); very low read overhead | Catalog mutation, inventory reservation/consume/release/expiry, plus TTL cleanup | Per-node divergence, stale hints, public named tables, no cross-node single flight; availability fetch has no explicit single-flight |
| GenServer | Limited; coordination/single-flight only | A process can serialize a bounded key or own a tiny ephemeral state machine, but it is not a durable shared cache | Explicit messages, owner restart, or TTL | One process becomes a bottleneck/failure point; memory is node-local; unsuitable as commerce truth |
| Cachex | Yes for bounded derived projections | Existing product-list and entitlement caches use TTLs; `Cachex.fetch` supplies keyed fetch behavior | Product/catalog mutation clears local and warm entries; entitlement issue/revoke clears local key and broadcasts PubSub | Node-local memory and missed broadcasts; TTL/stampede behavior must be observed; cache failure must not change correctness |
| Redis | Conditional for shared warm, non-sensitive projections | Existing product-list warm tier and operational rate-limit/metric paths show a shared-store use case | Prefix/key deletion, versioned keys, or PubSub after durable changes | Network/serialization/outage dependency, cross-tenant/PII key mistakes, and pressure from mass invalidation; never payment or inventory authority |
| Browser caching | Only for public/static non-sensitive catalog assets | Can reduce repeat public reads when content is safe to expose | Cache-Control expiry, asset/content versioning, or public catalog invalidation policy | Leaks personalized/cart/payment/access data if boundaries are wrong; stale public price/availability can mislead users |

Current cache behavior by data type:

| Data | Current/possible cache posture | Boundary that must remain durable |
|---|---|---|
| Public catalog lists | Cachex hot tier plus Redis warm tier; catalog mutations clear list cache | Product/variant publication, price, and availability records |
| Product detail projections | ETS availability payload and short-lived derived projection | Product, variant, option, image, and inventory records |
| Stock availability | Five-second ETS precheck/batch hint | Inventory reservation CTE and row locks |
| Active entitlements | 60-second per-user Cachex with PubSub invalidation | Entitlement grant status/validity/revocation |
| Cart and checkout | No general authoritative cache observed; a derived display cache would be highly mutable | Cart version, item identity, order snapshot, totals, reservation |
| Payment/order/subscription state | No general state cache observed | Postgres state machine, provider event, attempt, and idempotency records |

## 11. Scalability Risks

| Risk | Evidence in current implementation | Likely consequence |
|---|---|---|
| Thundering herd | Cache misses fall back to catalog/entitlement reads; per-node caches miss independently | Simultaneous cold reads increase primary DB load |
| Cache stampede | Product list uses Cachex fetch semantics, but availability/stock hints use simple get/build/put paths; Redis fallback can also converge on Postgres | Many requests rebuild the same projection or query the same catalog rows |
| Database hotspots | Inventory rows, active cart rows, checkout/order/payment transitions, and refund locks are serialized | Lock waits, pool exhaustion, and rising p99 under popular-product or payment bursts |
| Query amplification | Admin catalog filtering in Elixir; cart merge per-item work; entitlement revocation per grant; renewal/webhook branch reads | Work grows with total records or fan-out rather than request page size |
| Queue overload | Paid payment success fans out to fulfillment, digital, subscription, reconciliation, and email queues; renewal ticks create per-subscription jobs | Oban latency, retry pileups, and delayed customer side effects |
| Provider retry wave | Webhook and off-session provider calls can retry while local state remains pending | Duplicate external calls, webhook bursts, and pressure on payment idempotency rows |
| Time-based renewal burst | Five-minute tick, bounded batches, one-hour jitter, and plan-aligned billing periods | Subscription queue/provider/DB overload when many accounts become due together |
| Distributed stale hints | Stock/availability invalidation is local; entitlement uses PubSub but still has TTL fallback | Nodes can render different hints or briefly serve stale access projections |
| Operational table growth | Raw webhook bodies/headers, provider events, attempts, renewal attempts, outboxes, and audit data accumulate | Larger indexes, slower maintenance, retention/purge workload, and storage cost |
| Invalidation fan-out | Catalog mutation clears broad product-list cache; entitlement changes broadcast by user | A write burst can cause broad cache churn and cold-read bursts |

The 100k-user scenario is therefore asymmetric: cached public reads may scale across web
nodes, while personalized reads, checkout, payment, entitlement cold misses, renewal
jobs, and inventory decisions still converge on a small number of primary database rows
and queues.

## 12. Future Scaling Requirements

These are requirements to carry into later hardening/extraction work, not an
implementation plan for S0-06:

- Establish measured sub-100ms budgets for eligible hot reads and retain the existing
  commerce-specific p95/p99 checkout, webhook, and worker budgets.
- Preserve horizontal scaling without making a node-local cache, process, or web socket
  the source of truth.
- Keep payment, inventory, order, subscription, and entitlement transitions durable and
  idempotent while moving non-critical side effects to bounded asynchronous processing.
- Provide durable event/outbox semantics for post-commit fan-out and replay.
- Validate read-replica suitability only for read-only, lag-tolerant paths; primary reads
  remain required for checkout, payment proof, inventory, and lifecycle decisions.
- Separate analytics and operational aggregation from transactional commerce tables as
  volume justifies it.
- Add representative cardinality, `EXPLAIN`, lock-wait, pool, queue-lag, cache-hit, and
  invalidation telemetry before selecting new indexes or cache tiers.
- Prove behavior under at least 100k concurrent users with browse, cart, checkout,
  webhook, entitlement, inventory, and renewal mix—not only a catalog benchmark.

## Performance Review

The following table answers the required five questions for each major data flow. Query
counts are qualitative because branches vary with cache state, line count, and provider
references; `RepoStats`/telemetry is the measurement boundary.

| Major flow | Hot/warm/cold? | Source of truth | Can it be cached? | Invalidation | 100k-user behavior and query risk |
|---|---|---|---|---|---|
| Catalog browse/detail | Hot read over warm source records | Postgres product/variant/options/images/inventory | Yes for derived public list/detail/availability projections | Catalog mutation clears list/detail/availability; short TTL fallback | Existing cache tiers absorb hits; cold misses perform product graph reads and can herd; public search/admin in-memory filtering are large-query risks |
| Cart view/mutation | Hot | Postgres carts/items plus current catalog/inventory checks | No general authoritative cache; display-only derived data would be volatile | Durable cart version and item writes; no cache authority | Every active user consumes primary reads; mutation locks one cart and may reload all items; merge is per-item |
| Checkout start/finalize | Hot while active | Postgres draft/order/snapshot/reservation; catalog is revalidated | Mutable decision state should not be replaced by cache; public catalog inputs may be cached | Cart/order versioning and durable writes; local stock hints invalidated after reservation | DB pool and row locks dominate; finalization combines reads/writes and inventory serialization; no fixed query count claimed |
| Payment intent/webhook | Hot in flight; warm/cold after settlement | Provider remote outcome plus local payment/order/application records | No payment-proof/state cache | Provider-event, attempt, application, and state-machine idempotency; post-commit fan-out | Webhook bursts create multi-read/multi-write work and queue load; external latency and retry amplification dominate |
| Subscription renewal | Hot for due work; warm history | Subscription/attempt/order/payment/reservation rows plus provider | Plan/config may be candidate; due state and payment method are not cache authority | Renewal key, attempt claim, period/dunning updates, reservation release/consume | Batch 100/500 limits and jitter spread work; shared billing anchors can still overload queue/provider/DB |
| Entitlement access check | Hot | Postgres entitlement grants | Yes, per-user derived set | Local delete, PubSub invalidation, 60s TTL | Warm hits scale better; cold users and invalidation waves hit Postgres; grant cardinality controls cold-read cost |
| Inventory precheck/reservation | Hot | Postgres counters/reservations and row locks | Only ETS short-lived hints/prechecks | Local stock/availability invalidation plus TTL; transaction is final authority | Popular variants serialize on one row; stale hints are tolerable only because CTE reservation rechecks |
| Fulfillment/digital/email fan-out | Hot queue state; warm/cold evidence | Durable fulfillment/grant/outbox rows and Oban job state | No cache for delivery truth; public status views may derive | Unique jobs, outbox state, worker completion/retry | Payment bursts fan out jobs; queue depth/retry policy, not web cache hit rate, controls latency |

## Security Review

Sensitive data observed in the performance paths includes:

- payment intent provider identifiers, client secrets, customer/payment-method references,
  payment attempts, refund data, and provider event payloads;
- webhook raw bodies and headers, including data retained for verification and replay;
- personal data in users, cart/order ownership, email outboxes, and shipping names,
  addresses, postal codes, regions, and phone/contact fields;
- cart tokens and checkout keys, which are bearer-like workflow identifiers;
- subscription, entitlement, and download-grant state, which reveals paid access and
  digital rights;
- digital asset keys and signed-download material, which must not become public cache
  content.

Cache exposure risks are therefore narrower than ordinary catalog caching:

- the ETS tables are node-local and named public tables; their contents and process
  access must be treated as application-internal despite the public table option;
- entitlement cache keys include a user identifier and values contain access decisions;
  they must not be placed in browser caches or shared without user scoping;
- Redis product-list values are public projections, but key namespaces and serialized
  values must not acquire PII or payment state;
- browser caching is limited to public/static content. Cart, checkout, payment,
  subscription, entitlement, download, and personal shipping data must not be cached as
  shared responses;
- provider client secrets, raw webhook evidence, stored payment references, and signed
  URLs are never suitable cache material for performance convenience.

## Evidence Index

Primary implementation evidence:

- [`Store.Catalog`](../../lib/store/catalog/)
- [`Store.Carts.Facade`](../../lib/store/carts/facade.ex)
- [`Store.Checkout.Domain`](../../lib/store/checkout/domain.ex)
- [`Store.Orders inventory reservations`](../../lib/store/orders/inventory_reservations.ex)
- [`Store.Payments domain`](../../lib/store/payments/domain.ex)
- [`Store.Payments interlocks`](../../lib/store/payments/interlocks.ex)
- [`Store.Subscriptions.Facade`](../../lib/store/subscriptions/facade.ex)
- [`Store.Subscriptions.Scheduler`](../../lib/store/subscriptions/scheduler.ex)
- [`Store.Entitlements.Facade`](../../lib/store/entitlements/facade.ex)
- [`Store.Entitlements.Cache`](../../lib/store/entitlements/cache.ex)
- [`Oban workers`](../../lib/store/workers/)
- [`Oban and queue configuration`](../../config/config.exs)

Migration and governance evidence:

- [`All repository migrations`](../../priv/repo/migrations/)
- [`Performance and scaling governance`](../governance/performance_scaling.md)
- [`Phase 29 performance architecture`](../phases/phase_29_performance_architecture_optimizations.md)
- [`Current-state discovery`](00_current_state.md)
- [`Dependency map`](04_dependency_map.md)
- [`Test strategy and current performance evidence`](05_test_strategy.md)

The next responsible step is measurement and validation of the candidate pressure points.
This S0-06 record intentionally stops before implementing any performance improvement.
