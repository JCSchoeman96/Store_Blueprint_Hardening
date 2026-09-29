# Store_Blueprint Subscription Commerce Current State

This is the S0-01 read-only baseline for the subscription-commerce slice. It records the repository as inspected on 2026-08-26. The implementation is the authority for current behavior. Governance and phase documents are included as evidence and are called out where they differ from the code.

The document does not prescribe a target design, fixes, refactors, or extraction work. “Coverage level” is a qualitative assessment of test artifacts found in the repository, not a line-coverage measurement.

## 1. Repository Context

The README is the default Phoenix starter README. The source tree implements the `:store` OTP application: a Phoenix storefront and account/admin application backed by Ash resources and PostgreSQL, with cart, checkout, payment, subscription, entitlement, fulfillment, digital, pricing, shipping, and communications surfaces.

The declared stack is:

- Elixir `1.19` with Erlang/OTP `28.3` and Elixir `1.19.5-otp-28` in [`.tool-versions`](../../.tool-versions).
- Phoenix `~> 1.8.3`, Phoenix LiveView `~> 1.1.0`, Ecto SQL `~> 3.13`, Postgrex, and Bandit.
- Ash `~> 3.0`, AshPostgres `~> 2.0`, AshStateMachine `~> 0.2.12`, AshJsonApi `~> 1.5`, and AshAuthentication.
- Oban `~> 2.0` for background work and cron ticks.
- Cachex, Redix, Swoosh, Req, Finch, Sentry, and PostgreSQL.
- Tailwind `4.1.12` and esbuild `0.25.4` for assets.

These versions and dependencies are declared in [`mix.exs`](../../mix.exs) and the asset versions are in [`config/config.exs`](../../config/config.exs).

The architectural style is mixed rather than purely resource-oriented:

- Ash resources define most domain data, actions, policies, state machines, identities, and PostgreSQL mappings.
- Domain modules expose facades and orchestration entrypoints.
- Checkout, orders, payments, and subscriptions also contain direct Ecto queries, transactions, row locks, and SQL helpers. Ash and Ecto are therefore both present in the domain path.
- Phoenix LiveViews and controllers call domain facades for the scoped flows. The web routes are in [`StoreWeb.Router`](../../lib/store_web/router.ex).
- The configured Ash domains are Accounts, Admin, Catalog, Carts, Comms, Digital, Checkout, Orders, Payments, Subscriptions, Entitlements, Fulfillment, Shipping, Pricing, and Tools.

The application supervisor starts both `Store.Repo` and `Store.DirectRepo`, Oban, Phoenix PubSub, entitlement/catalog/shipping cache processes, the provider task supervisor, Finch, and endpoint processes in [`Store.Application`](../../lib/store/application.ex). There is no tenant routing or marketplace model in the inspected subscription-commerce path.

## 2. Subscription Commerce Scope

The implemented vertical slice is:

```text
published Product
  -> active Variant
  -> active VariantSubscriptionPlan / SubscriptionPlan
  -> Cart / CartItem
  -> CheckoutDraft / Order snapshots
  -> PaymentIntent
  -> verified provider receipt
  -> paid Order
  -> Subscription
  -> EntitlementGrant, when the plan has an entitlement
  -> Oban renewal attempt / virtual renewal Order / PaymentIntent
  -> past_due, retry, expiration, or paid renewal reconciliation
```

The customer-facing “Product → Purchase Intent → Payment → Subscription → Access” stages exist in these locations:

| Stage | Current implementation |
|---|---|
| Product and Variant | `Store.Catalog.Product`, `Store.Catalog.Variant`, and the catalog facade. A product must be published and a variant active to be sellable. |
| Subscription Plan | `Store.Subscriptions.SubscriptionPlan` plus `Store.Subscriptions.VariantSubscriptionPlan`. A variant can have multiple active plan attachments. |
| Cart | `Store.Carts.Cart` and `Store.Carts.CartItem`. Subscription lines carry an optional `subscription_plan_id`; the cart facade resolves or validates the plan. |
| Checkout | `Store.Checkout.start_from_cart/3`, `set_shipping/3`, and `finalize_totals/3`. Checkout creates an order and draft, then writes immutable price/tax/shipping snapshots and inventory reservations. |
| Purchase Intent | `Store.Payments.create_intent_for_order/3` and the payment interlocks. The local `PaymentIntent` is created/reused before the provider request. |
| Payment | Provider checkout/setup requests and verified webhook processing. `Store.Payments.Interlocks.apply_payment_success_once/2` is the paid-side-effect boundary. |
| Subscription | `EnsureSubscriptionsForPaidOrderWorker` calls `Store.Subscriptions.Facade.create_subscriptions_from_paid_order_for_system/1` after a paid order. The creation path requires an authenticated order user. |
| Access | `Store.Entitlements.EntitlementGrant` is issued from subscription creation and synchronized after a paid renewal. Cached `EntitlementSet` evaluation is used by entitlement-aware LiveViews. |
| Renewal and Dunning | `RunDueSubscriptionRenewalsWorker` enqueues per-subscription jobs. The subscription facade creates `RenewalAttempt`, renewal order, and payment intent records, performs merchant-managed off-session charging, and marks subscriptions `past_due` or `expired` on failure conditions. |

The repository has a subscription-purchase feature gate. `config/config.exs` sets `expose_purchase?: false`; `config/test.exs` enables Stripe but does not globally turn on subscription purchase. The subscription-only tests explicitly cover the disabled flag. Thus the subscription path exists in code but is not exposed by the default application configuration.

Initial subscription activation is not performed by a return URL. The return and cancel LiveView actions are read-only and display the latest order state. A subscription is created only from the paid-order worker path.

## 3. Domain Inventory

| Domain | Modules | Purpose | Evidence |
|---|---|---|---|
| Catalog | `Store.Catalog`, `Catalog.Facade`, Product, Variant, option, image, category, and inventory resources | Published products, active variants, variant-option completeness, SKU/price/currency, and stock availability | [`lib/store/catalog/domain.ex`](../../lib/store/catalog/domain.ex), [`lib/store/catalog/facade.ex`](../../lib/store/catalog/facade.ex) |
| Cart | `Store.Carts`, `Carts.Facade`, cart inputs and query contracts | Active guest/user carts, subscription-plan selection, quantity changes, merge, and cart-version concurrency | [`lib/store/carts/domain.ex`](../../lib/store/carts/domain.ex), [`lib/store/carts/facade.ex`](../../lib/store/carts/facade.ex) |
| Checkout | `Store.Checkout`, `Checkout.Domain`, `CheckoutDraft`, typed checkout inputs | Cart-version checkout identity, order creation, shipping evidence, total finalization, snapshot writing, and reservation orchestration | [`lib/store/checkout/domain.ex`](../../lib/store/checkout/domain.ex), [`lib/store/checkout/checkout_draft.ex`](../../lib/store/checkout/checkout_draft.ex) |
| Orders | `Store.Orders`, `Orders.Facade`, snapshot writers, inventory-reservation services | Order identity/state, immutable line and adjustment evidence, inventory holds, payment apply-once evidence, and refund adjustments | [`lib/store/orders/domain.ex`](../../lib/store/orders/domain.ex), [`lib/store/orders/facade.ex`](../../lib/store/orders/facade.ex) |
| Payments | `Store.Payments`, `Payments.Facade`, `Interlocks`, `Refunds`, provider resolver/task/adapters | Local payment lifecycle, provider references, receipt/event/attempt evidence, payment success application, and refunds | [`lib/store/payments/domain.ex`](../../lib/store/payments/domain.ex), [`lib/store/payments/interlocks.ex`](../../lib/store/payments/interlocks.ex) |
| Subscriptions | `Store.Subscriptions`, `Subscriptions.Facade`, `Scheduler`, subscription resources | Plan/variant contract, stored payment methods, activation, cancellation, boundary changes, renewal attempts, merchant-managed renewal, and dunning | [`lib/store/subscriptions/domain.ex`](../../lib/store/subscriptions/domain.ex), [`lib/store/subscriptions/facade.ex`](../../lib/store/subscriptions/facade.ex) |
| Entitlements | `Store.Entitlements`, `Entitlements.Facade`, `Entitlements.Cache`, `EntitlementSet` | Subscription-derived access grants, validity evaluation, cache fill, and post-write invalidation | [`lib/store/entitlements/domain.ex`](../../lib/store/entitlements/domain.ex), [`lib/store/entitlements/facade.ex`](../../lib/store/entitlements/facade.ex), [`lib/store/entitlements/cache.ex`](../../lib/store/entitlements/cache.ex) |
| Supporting Pricing and Shipping | `Store.Pricing`, `Store.Shipping` | Money/tax/shipping quote inputs used by checkout and physical subscription renewal | [`lib/store/pricing/facade.ex`](../../lib/store/pricing/facade.ex), [`lib/store/shipping/domain.ex`](../../lib/store/shipping/domain.ex) |
| Workers | `Store.Workers.*`, plus the Digital paid-order worker | Receipt processing, paid-order follow-up, renewal fan-out/processing/reconciliation, inventory expiry, provider-setup recovery, reminders, email delivery, and evidence purge | [`lib/store/workers`](../../lib/store/workers) |
| Support infrastructure | `Store.Support.AshNotifications`, `Governance`, `ID`, `Errors`, `RateLimit`, `Redis`, telemetry, HTTP client | Post-commit notifications, transition/idempotency helpers, UUID/order references, stable errors, rate limiting, Redis/cache access, telemetry, and provider HTTP execution | [`lib/store/support`](../../lib/store/support) |

The subscription facade is the largest scoped orchestration module. It reads and writes subscriptions, plans, variants, orders, payment intents, stored payment methods, renewal attempts, shipping, pricing/tax, entitlements, and comms. Checkout and payment interlocks have similar cross-domain responsibilities.

## 4. Resource Inventory

All scoped Ash resources use UUIDv7 primary keys through `uuid_v7_primary_key/1`. Money is represented in integer minor-unit fields plus currency fields. The resource declarations below are the current Ash actions and policy shape; migration evidence is summarized after the tables.

### Catalog resources

| Resource / table | Lifecycle and important columns | Relationships and important actions | Policies, indexes, and locking |
|---|---|---|---|
| `Store.Catalog.Product` / `products` | `status`: `draft`, `published`, `archived`; `product_kind`: `simple` or `subscription`; `slug`, title, publication timestamps, category, and required `default_variant_id`. | Belongs to Category and default Variant; has variants, options, and images. Public reads require published status; admin create/update, publish, unpublish, and archive actions exist. | Public read is open; admin/support reads and admin/super-admin writes are policy-gated. Unique slug; indexes on category, status, published_at, `(status, published_at)`, and product_kind. No version field. |
| `Store.Catalog.Variant` / `variants` | `status`: `active` or `archived`; SKU, currency, `price_minor`, optional compare-at price, weight, default flag, and binary option-selection signature. | Belongs to Product and optional ProductImage; has option selections. Create/update/archive and product-scoped variant reads exist. | Public reads are active-only; admin/support read and admin/super-admin writes. Unique SKU, unique default variant per product, and product/image indexes. No version field. |
| `Store.Catalog.ProductOption` / `product_options` | Product option name/slug and position data; no separate state machine. | Belongs to Product and has ProductOptionValues. Admin CRUD and public option reads support variant selection. | Product/slug identity and product indexes are declared; admin mutations are policy-gated. No version field. |
| `Store.Catalog.ProductOptionValue` / `product_option_values` | Option value label/slug/position data; no separate state machine. | Belongs to ProductOption and Product; referenced by VariantOptionSelection. | Option/slug identity and option indexes; admin mutations, public selection reads. No version field. |
| `Store.Catalog.VariantOptionSelection` / `variant_option_selections` | Variant-to-option-value join; derived product id; no lifecycle state. | Belongs to Variant, ProductOption, and ProductOptionValue. System/admin create/update/destroy actions enforce selection consistency. | Unique variant/option identity; reads support public sellability checks. No version field. |
| `Store.Catalog.InventoryItem` / `inventory_items` | `stock_on_hand`, `reserved_count`, `allow_oversell`, and `version`; no enum lifecycle. | One inventory item per Variant. Count-setting/adjustment actions are consumed by reservation code. | Unique variant identity and allow-oversell index. Reservation paths lock inventory rows and update counters; the resource has a version field but the reservation service is the stronger observed concurrency boundary. |
| `Store.Catalog.Category` / `catalog_categories` and `Store.Catalog.ProductImage` / `product_images` | Category has `is_active`; image has URL/alt/position; neither participates in subscription state. | Category is a product grouping; ProductImage belongs to Product and is used by variants. | Category slug and image product/position uniqueness/indexes are in [`phase_19_catalog_simple_products.exs`](../../priv/repo/migrations/20260302193000_phase_19_catalog_simple_products.exs). |

### Cart and checkout resources

| Resource / table | Lifecycle and important columns | Relationships and important actions | Policies, indexes, and locking |
|---|---|---|---|
| `Store.Carts.Cart` / `carts` | `status`: `active` or `abandoned`; token, optional user, `merged_into_cart_id`, and integer `version` starting at 1. | Has CartItems and optional self-relation for merge. The facade gets/creates active carts, increments version on mutations, merges guest carts, and marks the guest cart abandoned. | User/token reads are active-cart scoped; admin/support can read; system/admin mutations. Active token and active user are partial unique indexes plus user/status/merge indexes. The facade locks rows with `FOR UPDATE` and applies a version predicate on updates. |
| `Store.Carts.CartItem` / `cart_items` | Quantity 1–99; `variant_id`; optional `subscription_plan_id`. | Belongs to Cart, Variant, and optional SubscriptionPlan. The cart facade adds, updates, removes, resolves sellability, and invokes membership duplicate guards. | System/admin resource mutations; reads are system/admin at the resource layer while the facade supplies user/cart access. Unique `(cart_id, variant_id, subscription_plan_id)` identity, with final partial plan/no-plan uniqueness from the Phase 26 migration. No version field. |
| `Store.Checkout.CheckoutDraft` / `checkout_drafts` | `status` enum declares `open`, `consumed`, `expired`; `checkout_key`, `cart_version`, optional user and order ids. Current creation path writes `open`. | Belongs to Cart and optional Order. `create`, `attach_order`, and `get_by_checkout_key` actions exist. | Reads support matching user plus system/admin/support policies; creation/attachment are system/admin. Unique checkout key, cart/version, and order id plus cart/user/status/order indexes. No version field. No code path changing status to consumed or expired was found in the scoped search. |

### Order resources

| Resource / table | Lifecycle and important columns | Relationships and important actions | Policies, indexes, and locking |
|---|---|---|---|
| `Store.Orders.Order` / `orders` | `state`: `pending_payment`, `pending_provider_setup`, `paid`, `payment_failed`, `cancelled`, `refunded`; order_ref, checkout_key, optional user, minor-unit totals/currency, finalization timestamp, shipping/tax evidence, provider-setup timestamp, and `version`. | Has line items, adjustments, reservations, payment applications, and refund adjustments. Actions include begin checkout, provider setup begin/refresh/ready, mark paid/failed/refunded, cancel, snapshot/detail writes, and finalize totals. | User reads are self-filtered; admin/support reads; system/admin transitions, with refund step-up in policy. Unique order_ref and checkout_key; state, user keyset, currency, totals, shipping, tax, and provider-setup indexes. `TransitionState` uses the default version optimistic lock for order transitions; domain code also locks orders in checkout/payment paths. |
| `Store.Orders.OrderLineItem` / `order_line_items` | Immutable price/product/variant snapshot: line number, currency, quantity, unit/line/net/tax minor units, SKU/title, variant id, and subscription plan id/key/interval snapshots. | Belongs to Order. Only create and read actions are exposed. | Customer reads are restricted through visible order ids; admin/support/system access is policy-controlled. Unique order/line number plus order, tax, variant, and subscription-plan indexes. No update/destroy action and no version field. |
| `Store.Orders.OrderAdjustment` / `order_adjustments` | Immutable sequence/currency/kind/amount/reason/source/precedence evidence. | Belongs to Order; create/read only. | Unique order/sequence and order index; customer visibility follows order ownership, with system/admin creation. |
| `Store.Orders.PaymentApplication` / `payment_applications` | `application_key` and applied timestamp record the apply-once boundary. | Belongs to Order and PaymentIntent; `apply_once` is an upsert with no mutable upsert fields. | Unique application key, order/payment indexes; system-only creation and admin/support reads. No update/destroy action. |
| `Store.Orders.InventoryReservation` / `inventory_reservations` | `state`: `active`, `consumed`, `expired`, `cancelled`; order/variant/reservation key, quantity, expiry timestamps, and `version`. | Belongs to Order and Variant. `mark_consumed`, `mark_expired`, `mark_cancelled`, and quantity/create actions are used by `InventoryReservations`. | System/admin mutations and admin/support reads. Unique order/variant and reservation key, order/state, variant/state, and state/expiry indexes. Transition actions use the default version lock; service code also uses row locks and `SKIP LOCKED` for sweeps. |
| `Store.Orders.RefundAdjustment` / `refund_adjustments` | Immutable negative refund evidence with currency, kind, amount, reason. | Belongs to Order and Refund; create/read only. | Unique refund id plus order/refund indexes; customer visibility follows order ownership and system/admin creates. |

### Payment resources

| Resource / table | Lifecycle and important columns | Relationships and important actions | Policies, indexes, and locking |
|---|---|---|---|
| `Store.Payments.PaymentIntent` / `payment_intents` | `state`: `created`, `submitted`, `requires_action`, `succeeded`, `failed`, `cancelled`; amount received minor units, currency, provider, purpose (`order_checkout` or `subscription_payment_method_update`), optional order/subscription, provider references, payment-intent key, and `version`. | Local intent creation/reuse, provider-reference hydration, submit, requires-action, success, failure, and cancel actions. | System/admin mutations and admin/support reads. Unique payment-intent key; provider payment/session partial unique indexes; order, state, purpose, subscription, provider-reference indexes. Transition actions use the default version lock. A partial unique in-flight-order index is present in [`phase_14_checkout_interlocks.exs`](../../priv/repo/migrations/20260225190004_phase_14_checkout_interlocks.exs). |
| `Store.Payments.PaymentAttempt` / `payment_attempts` | Immutable provider-event interaction evidence: provider/event ids, attempt key, outcome, payload hash, and attempted timestamp. | Belongs to PaymentIntent; `record` upsert and reads. | Unique provider event key and attempt key, payment-intent/attempted indexes; system-only recording and admin/support reads. No version field. |
| `Store.Payments.ProviderEvent` / `provider_events` | Dedupe evidence: provider/event id/key, event type, hashes, and received timestamp. | `ingest` upsert and reads. | Unique provider/event identity plus provider-event-key/received indexes; system-only ingest and admin read. No version field. |
| `Store.Payments.WebhookReceipt` / `webhook_receipts` | Receipt-first evidence: provider/idempotency key, raw body/headers, payload hash, verification status (`verified`/`rejected`), processing status (`new`/`processing`/`processed`/`failed`), event metadata, error fields, timestamps, and evidence purge timestamp. | `ingest`, processing-status actions, and evidence purge. | Unique idempotency key and provider/event identity plus provider, received, verification, processing, event, and purge indexes. System-only ingest/process/purge and admin read. No version field. |
| `Store.Payments.Refund` / `refunds` | `state`: `requested`, `submitted`, `succeeded`, `failed`, `cancelled`; provider, amount/currency/reason/scope, line-item ids, idempotency key, timestamps, and `version`. | Belongs to Order and PaymentIntent. Request and transition actions are orchestrated by `Refunds`. | Admin/support reads; request requires system or admin/super-admin role with a recent step-up; system transitions. Unique idempotency/provider refund identity and order/payment/state/provider indexes. Transition actions use the default version lock. |
| `Store.Payments.RefundAttempt` / `refund_attempts` | Immutable provider refund-event evidence with provider/event keys, outcome, refund ref, error data, hash, sequence, and timestamp. | Belongs to Refund; record/read. | Unique refund/sequence and provider event key plus refund/event/time indexes; system recording and admin/support reads. No version field. |

### Subscription resources

| Resource / table | Lifecycle and important columns | Relationships and important actions | Policies, indexes, and locking |
|---|---|---|---|
| `Store.Subscriptions.SubscriptionPlan` / `subscription_plans` | `status`: `active` or `archived`; interval unit day/month/year, interval count, integer amount/currency, trial, anchor mode/day, billing timezone, term mode/cycles/end, access-on-past-due/cancel policy fields, grace days, retry count/schedule, and entitlement kind/scope. | Has VariantSubscriptionPlan attachments. Public active reads; admin/system create/update/archive/activate. | Unique plan key and status/interval/key indexes. Validation exists for anchor, term, retry schedule, and entitlement pairing. No version field. |
| `Store.Subscriptions.VariantSubscriptionPlan` / `variant_subscription_plans` | `active` boolean; no separate state machine. | Belongs Variant and SubscriptionPlan; list active, attach/upsert, and active-toggle actions. | Unique variant/plan pair; variant, plan, and active indexes. System/admin writes; public active reads and admin reads. No version field. Multiple active plans per variant are allowed after [`phase_27_allow_multiple_active_variant_plans.exs`](../../priv/repo/migrations/20260308173000_phase_27_allow_multiple_active_variant_plans.exs). |
| `Store.Subscriptions.Subscription` / `subscriptions` | `status`: `pending`, `active`, `past_due`, `canceled`, `expired`; provider/billing mode, current/next period timestamps, cancel/dunning fields, provider customer/billing refs, quantity, renewal amount/currency, membership key, pending boundary-change values, and source order/order-line ids. | Belongs current and pending plan/variant, stored payment method; has SubscriptionItems. Actions activate, mark past due, cancel now/period-end, extend period, queue change, expire, and set provider billing reference. | Customer reads are self-scoped; admin/support reads; user cancellation/change actions; system/admin lifecycle actions. Unique source order line and provider subscription ref; user/status, due/retry, plan, variant, pending-change, membership, and stored-method indexes. The resource has no version field, and all `TransitionState` calls explicitly set `lock_attribute: nil`. |
| `Store.Subscriptions.SubscriptionItem` / `subscription_items` | Quantity and immutable plan/amount/currency/interval snapshots plus source order-line id. | Belongs Subscription and Variant. Create-from-order-line upsert and read actions. | Unique source order line; subscription, variant, and source-line indexes; system create and system/admin reads. No version field. |
| `Store.Subscriptions.StoredPaymentMethod` / `stored_payment_methods` | Provider/customer/payment-method references, user, status (`active`, `inactive`, `revoked`), and optional fingerprint. | Has subscriptions. Create/reuse and status actions; payment-method setup success updates it. | Unique provider/customer/payment-method tuple and user/status/provider/status indexes. User reads are self-scoped; system/admin writes. No version field. |
| `Store.Subscriptions.RenewalAttempt` / `renewal_attempts` | Period start/end, deterministic renewal key, `status`: `pending`, `processing`, `succeeded`, `failed`, optional order/payment-intent ids, failure details, and attempt number. | Belongs Subscription. Create/reuse plus processing/succeeded/failed actions. | Unique subscription/renewal key, subscription/inserted/status indexes. System/admin writes and system/admin/support reads. Claiming uses a raw SQL `updated_at` compare-and-set rather than a version column. |

### Entitlement and communications resources

| Resource / table | Lifecycle and important columns | Relationships and important actions | Policies, indexes, and locking |
|---|---|---|---|
| `Store.Entitlements.EntitlementGrant` / `entitlement_grants` | `status`: `active`, `revoked`, `expired`; user, kind (`membership_access`, `digital_library`, `discount_tier`), scope key, source kind/id, valid-from/to, and revocation fields. | Subscription is the source used by the current subscription facade. `issue` upserts and `revoke`/`expire` update. | User reads are filter-scoped; system/admin issue/revoke/expire. Unique user/kind/scope/source and user/kind/scope/status, source, and valid-to indexes. No version field. |
| `Store.Comms.EmailOutbox` / `email_outboxes` | `state`: `pending`, `processing`, `sent`, `failed`; template, recipient/message, idempotency key, provider, attempt/error/timestamps. Subscription-related templates are renewal reminder, payment authentication required, and access ended. | Optional Order, Refund, or Subscription references. Enqueue, sent, failed, retry-pending, delivery, reclaim, and admin read surfaces exist. | Unique idempotency key and order/state/template/refund/subscription indexes. System-only enqueue/update/delivery; admin/support read. No version field. Delivery uses an Oban worker and provider adapters. |

### Database and locking evidence

The relevant schema is assembled across the phase migrations rather than one subscription migration:

- Core state-machine tables, `orders`, and `payment_intents` with version columns originate in [`20260222160727_phase_04_state_machines.exs`](../../priv/repo/migrations/20260222160727_phase_04_state_machines.exs). Provider events originate in the same migration; webhook receipts and uniqueness are in [`20260222162948_phase_05_uniqueness.exs`](../../priv/repo/migrations/20260222162948_phase_05_uniqueness.exs).
- Inventory reservations and refund records/version columns are in [`20260224201500_phase_11_inventory_reservations.exs`](../../priv/repo/migrations/20260224201500_phase_11_inventory_reservations.exs) and [`20260225093000_phase_12_refund_semantics.exs`](../../priv/repo/migrations/20260225093000_phase_12_refund_semantics.exs).
- Catalog and variant tables are in [`phase_19_catalog_simple_products.exs`](../../priv/repo/migrations/20260302193000_phase_19_catalog_simple_products.exs); carts and checkout drafts are in [`phase_20_carts_checkout_drafts.exs`](../../priv/repo/migrations/20260302194911_phase_20_carts_checkout_drafts.exs).
- Checkout/payment fields, provider references, in-flight payment uniqueness, webhook statuses, and email outbox tables are in the Phase 21 migrations and [`phase_14_checkout_interlocks.exs`](../../priv/repo/migrations/20260225190004_phase_14_checkout_interlocks.exs).
- Subscription plans, variant attachments, subscription contracts, subscription items, renewal attempts, and entitlement grants are in [`phase_26_simple_subscriptions.exs`](../../priv/repo/migrations/20260303230000_phase_26_simple_subscriptions.exs), extended by the Phase 26 stored-payment-method and provider-hardening migrations.
- Locked renewal pricing/provider references, payment-intent setup purpose, multiple active variant plans, physical renewal guards, membership comms, webhook evidence retention, hot-path indexes, and pending-provider-setup state are in the Phase 27–31 migrations listed in [`priv/repo/migrations`](../../priv/repo/migrations).

Foreign keys make the following coupling durable: variants depend on products; cart items depend on carts and variants; checkout drafts depend on carts and optionally orders; subscription records depend on users, plans, variants, source orders/order lines, and optionally stored payment methods; renewal attempts point to subscriptions and optionally renewal orders/payment intents; entitlement source ids are subscription-backed in the database; and subscription email outbox rows point to subscriptions. Delete behavior varies by relationship, including cascade for cart items and some dependent records, nilification for checkout/order or stored-payment-method references, and restrict behavior for source evidence.

## 5. Lifecycle Inventory

The following are the lifecycle enums and transition/action paths found in the scoped implementation. “Not a dedicated state machine” means the resource has a state field and actions or facade writes, but does not use `AshStateMachine` for that field.

| Resource | States discovered | Transition locations | Documented elsewhere | Tests found |
|---|---|---|---|---|
| Product | `draft`, `published`, `archived` | `Store.Catalog.Product` publish, unpublish, archive, and draft actions | Phase 19 catalog docs and catalog governance | [`catalog_phase_19_test.exs`](../../test/store/governance/catalog_phase_19_test.exs), [`facade_public_product_test.exs`](../../test/store/catalog/facade_public_product_test.exs) |
| Variant | `active`, `archived` | `Store.Catalog.Variant.archive`; active-only public reads | Phase 25 catalog/variant docs | [`catalog_phase_25_test.exs`](../../test/store/governance/catalog_phase_25_test.exs) |
| Cart | `active`, `abandoned` | `Carts.Facade` marks a merged guest cart abandoned; active cart reads/mutations are facade-scoped | Phase 20 docs | [`facade_test.exs`](../../test/store/carts/facade_test.exs) |
| CheckoutDraft | Declared `open`, `consumed`, `expired`; observed creation is `open` | `CheckoutDraft.create`, `attach_order`, and checkout facade reads; no scoped status transition to consumed/expired was found | Phase 20 docs describe the enum, but governance does not define a transition table | Checkout draft linkage/auth tests in [`domain_test.exs`](../../test/store/checkout/domain_test.exs) |
| Order | `pending_payment`, `pending_provider_setup`, `paid`, `payment_failed`, `cancelled`, `refunded` | `Store.Orders.Order` AshStateMachine transitions; provider-setup sweep cancels stale setup orders; payment success marks paid; refund worker can mark fully refunded | [`state_machines.md`](../governance/state_machines.md) omits `pending_provider_setup` and `payment_failed` | [`state_machines_test.exs`](../../test/store/governance/state_machines_test.exs), pending-provider-setup worker tests |
| PaymentIntent | `created`, `submitted`, `requires_action`, `succeeded`, `failed`, `cancelled` | `Store.Payments.PaymentIntent` transitions applied by payment interlocks and setup/renewal paths | [`state_machines.md`](../governance/state_machines.md) omits `requires_action` | State-machine, provider-task, webhook worker, and create-intent tests |
| Refund | `requested`, `submitted`, `succeeded`, `failed`, `cancelled` | `Store.Payments.Refund` transitions; refund request creates local evidence; refund worker applies provider result | [`refund_semantics.md`](../governance/refund_semantics.md), payment provider contract | Refund worker, refund semantics, and post-commit tests |
| InventoryReservation | `active`, `consumed`, `expired`, `cancelled` | `InventoryReservation` transitions and `Orders.InventoryReservations` transaction/sweep services | [`inventory_reservations.md`](../governance/inventory_reservations.md) | [`inventory_reservations_test.exs`](../../test/store/governance/inventory_reservations_test.exs), expiry worker tests |
| SubscriptionPlan | `active`, `archived` | `activate` and `archive` actions | Phase 26/27 subscription docs | Subscription fixture and subscription facade tests |
| Subscription | `pending`, `active`, `past_due`, `canceled`, `expired` | `Subscription` AshStateMachine transitions; subscription facade handles activation, dunning, cancellation, renewal extension, and expiry | Subscription governance describes cadence/terms/access/dunning but the stated lifecycle is not identical to this enum | [`facade_test.exs`](../../test/store/subscriptions/facade_test.exs), scheduler, replay, policy, and worker tests |
| RenewalAttempt | `pending`, `processing`, `succeeded`, `failed` | Create/reuse, SQL claim, and status actions in subscription facade/resource | Subscription scheduling governance | Uniqueness, replay/concurrency, facade, and worker tests |
| StoredPaymentMethod | `active`, `inactive`, `revoked` | Resource status actions; setup-success path creates/reuses active records | Phase 26 enterprise addendum | [`stored_payment_method_test.exs`](../../test/store/subscriptions/stored_payment_method_test.exs), setup webhook worker test |
| EntitlementGrant | `active`, `revoked`, `expired` | Issue upsert; revoke on cancel-now/grace expiry/refund-related paths; validity also expires at read time | Subscription scheduling/access governance | [`facade_test.exs`](../../test/store/entitlements/facade_test.exs), refund revocation tests |
| EmailOutbox | `pending`, `processing`, `sent`, `failed` | Comms facade enqueue, delivery worker claim/finish, retry/reclaim worker | Comms/outbox and subscription scheduling docs | Comms and worker tests |

Two implementation/documentation differences are material to this inventory:

1. The governance state-machine document lists only four order states and five payment-intent states. The resources and tests currently implement the extra provider-setup, payment-failed, and requires-action states above.
2. The subscription plan stores term and access-policy fields, but repository search found no use of `term_mode`, `term_cycles`, `term_end_at`, `access_on_past_due`, or `access_on_cancel` outside plan definitions/validation and type declarations. The observed renewal and access behavior is therefore driven by the subscription facade’s fixed paths, not by all of those stored policy fields.

## 6. Subscription Flow

### Initial purchase

| Step | Responsible module | Transaction boundary and side effects | Worker involvement |
|---|---|---|---|
| 1. Customer selects a published product variant and, for a subscription product, a plan | `Store.Catalog.Facade`, `StoreWeb.ShopLive.Show` | Public catalog reads use product/variant/plan data and cache paths. The selected plan is carried as typed cart input. | None. |
| 2. Cart line is created or updated | `Store.Carts.Facade`, `CartItemInput` | Cart mutation runs in a `Repo.transaction`, locks cart/items with `FOR UPDATE`, validates product publication, variant activity, required option selections, and plan attachment, performs a best-effort stock precheck, and bumps cart version when changed. Membership plans pass through a duplicate-purchase guard. | None. |
| 3. Checkout starts | `Store.Checkout.start_from_cart/3` | A `Repo.transaction` locks active cart and items, requires a non-empty cart, revalidates catalog sellability and plan selection, derives currency and checkout idempotency, invokes `Orders.begin_checkout`, and creates/reuses a `CheckoutDraft`. At this point the order exists, but checkout tests show no price snapshot or inventory hold yet. | None. |
| 4. Shipping and totals are finalized | `Store.Checkout.set_shipping/3`, `finalize_totals/3`, Pricing, Shipping, Orders | Shipping quote selection validates a generated quote hash/method. Finalization runs in a transaction locking cart, cart items, and order; it revalidates sellability and currency, writes immutable line snapshots, evaluates tax/shipping, writes tax/shipping evidence, finalizes minor-unit totals, and reserves inventory. Subscription-only carts skip shipping/tax selection. | None. |
| 5. Local payment intent is created/reused | `Store.Payments.create_intent_for_order/3`, `Payments.Interlocks` | Requires finalized totals and a payable order. The payment-intent identity is deterministic and an in-flight order uniqueness guard prevents a second active intent. The local intent is created before the provider request. | Provider calls run through `Store.Payments.ProviderTask`, outside an open database transaction as covered by provider fault-isolation tests. |
| 6. Provider checkout or setup is requested | `Store.Payments.ensure_provider_setup`, Stripe adapter | The order can transition to `pending_provider_setup` while the provider request is in progress. Stripe creates a Checkout Session for a payment or setup-mode Checkout Session for a zero-total subscription cart; subscription lines request future off-session payment-method use. Provider references are saved, the local intent is submitted, and the order returns to `pending_payment`. | `ExpirePendingProviderSetupOrdersWorker` recovers locally completable records and cancels/release reservations for stale records. |
| 7. Provider sends a result | Webhook or callback controller, provider adapter | The controller rate-limits the route, uses captured raw body and headers, verifies and normalizes, stores a verified `WebhookReceipt`, and returns accepted. It does not transition order/payment/subscription state. | Exactly one processing worker is enqueued for a new receipt. Refund event types route to the refund worker; other events route to the payment worker. |
| 8. Payment result is reconciled | `ProcessWebhookReceiptWorker`, `Payments.Facade`, `Payments.Interlocks` | Worker re-reads receipt, checks verified status/provider enabled, normalizes the raw payload, resolves the local payment intent by provider session/payment id or local metadata id, validates amount/currency against the finalized order for normal payment intents, upserts ProviderEvent and PaymentAttempt evidence, then applies the canonical result. | Payment success uses `apply_payment_success_once`: a transaction inserts `PaymentApplication` with `ON CONFLICT DO NOTHING`, marks local intent succeeded, marks order paid, and consumes reservations. Failure/requires-action update the local intent; renewal reservations are released on failure paths. |
| 9. Subscription is activated after payment | `EnsureSubscriptionsForPaidOrderWorker`, `Subscriptions.Facade` | After commit, payment interlocks enqueue the subscription worker when paid order lines contain subscription plan snapshots. The worker transaction upserts any stored payment method, creates/reuses one Subscription and SubscriptionItem per source order line, and returns notifications for post-commit delivery. | `EnsureSubscriptionsForPaidOrderWorker`, queue `:subscriptions`, max attempts 10, unique forever by worker/args. |
| 10. Access is granted | `Entitlements.Facade`, `EntitlementGrant`, entitlement-aware LiveViews | Subscription creation returns entitlement pairs; grant issue occurs after the subscription transaction. Grant validity uses the subscription current period end. Cache invalidation deletes the local cache and broadcasts over PubSub after the grant write. Grant errors in the post-commit issuance loop are counted as skipped by the current facade. | No separate entitlement worker in this path. |

### Renewal and dunning

| Step | Responsible module | Transaction boundary and side effects | Worker involvement |
|---|---|---|---|
| 11. Due subscriptions are selected | `Subscription.read_due_for_system`, `Subscriptions.Facade`, `RunDueSubscriptionRenewalsWorker` | PostgreSQL is queried by active `next_renewal_at` or retryable past-due `next_retry_at`, excluding `cancel_at_period_end` and retry-suppressed subscriptions. Due jobs carry a deterministic renewal key and UUID-derived jitter. | Oban cron runs the tick every five minutes. The tick is unique for 55 seconds and enqueues per-subscription jobs, each unique forever by worker/args. |
| 12. Renewal attempt is claimed | `Subscriptions.Facade` and `RenewalAttempt` | `RenewalAttempt` is create/reuse by `(subscription_id, renewal_key)`. A raw SQL `updated_at` compare-and-set changes pending/failed rows into the claimed path. | `ProcessSubscriptionRenewalWorker`, queue `:subscriptions`, max attempts 5. |
| 13. Renewal contract and order are built | `Subscriptions.Facade`, Orders, Catalog, Pricing, Shipping | The facade resolves pending plan/variant changes, checks active variant-plan attachment and catalog availability, takes stored renewal amount/currency snapshots, and creates/reuses a virtual renewal Order through `Orders.begin_checkout`. Physical variants use the prior paid order shipping profile, a live quote, surge checks, tax evaluation, and inventory reservation. Subscription-only renewals write a virtual order snapshot and zero shipping. | No provider request occurs until the local renewal order and PaymentIntent exist. |
| 14. Off-session charge is requested | `Store.Payments.create_or_reuse_payment_intent`, `Store.Payments.Providers.Stripe` | The renewal PaymentIntent key is derived from `renewal_key`; it is submitted locally, then Stripe receives an off-session PaymentIntent request with customer/payment-method references and renewal metadata. A synchronous Stripe success does not advance the local subscription period. | The provider call runs in the subscription worker through the provider boundary. |
| 15. Renewal outcome is reconciled | Payment webhook worker and `ReconcilePaidSubscriptionRenewalWorker` | Provider webhook applies payment success to the renewal order with the same apply-once interlock. A paid renewal order is recognized through `RenewalAttempt` and enqueues reconciliation. Reconciliation verifies the paid order/attempt, promotes pending plan/variant/price data, extends the period once, syncs entitlement validity, and marks the attempt succeeded. | `ReconcilePaidSubscriptionRenewalWorker`, queue `:subscriptions`, max attempts 5, unique forever by worker/args. |
| 16. Failure enters dunning | `Subscriptions.Facade` | Missing/invalid stored payment method, disabled provider, unavailable variant/plan, missing shipping evidence, shipping unavailability/surge, inventory failure, provider failure, or authentication-required outcomes update `billing_status_reason`, attempt counts, retry timestamps, and `past_due`/`expired` status. Hard physical blockers set `retry_suppressed_at`; retry exhaustion expires and revokes entitlement. | Payment-authentication-required and access-ended messages use the comms outbox. Hourly reminder worker covers active membership renewal reminders at 7/3/1-day offsets. |

The current initial payment failure path marks the local `PaymentIntent` failed. The `Order.mark_payment_failed` transition exists and is tested directly, but no scoped call site invoking it was found outside the resource/type/provider declarations. A pending provider-setup order is instead handled by provider-setup recovery/stale sweep paths.

## 7. Payment Integration Inventory

### Implemented

| Provider | Current behavior | Evidence |
|---|---|---|
| Stripe | The only provider with working create-intent/setup-intent, Checkout Session, off-session charge, webhook signature verification, and canonical receipt normalization paths. It supports Stripe metadata lookup for local intent/renewal identifiers. The adapter invokes the shared request client for Stripe HTTP calls and uses provider idempotency keys. | [`lib/store/payments/providers/stripe.ex`](../../lib/store/payments/providers/stripe.ex), [`stripe_subscriptions_test.exs`](../../test/store/payments/providers/stripe_subscriptions_test.exs) |

Stripe webhook verification uses the raw body, `stripe-signature` timestamp and v1 HMAC, a default 300-second tolerance, and constant-time signature comparison. Normalization maps checkout/session, payment-intent, charge, and setup-intent event types into `CanonicalReceipt` statuses. Amount and currency are rechecked against the finalized order for normal payment intents.

### Placeholder / scaffold

| Provider | Declared capability envelope | Actual adapter behavior |
|---|---|---|
| PayFast | One-time, refunds, tokenization, and merchant-initiated charges declared; no provider-managed subscriptions; IP allowlist plus signature verification mode declared. | `create_intent`, `charge_off_session`, `verify_webhook`, and `normalize_webhook` return explicit not-implemented/disabled errors. |
| Paystack | One-time, refunds, and partial refunds declared; tokenization and merchant/provider-managed recurring declared false. | All operational adapter methods return explicit not-implemented/disabled errors. |
| Yoco | One-time and refunds declared; recurring/tokenization/merchant charge support declared false. | All operational adapter methods return explicit not-implemented/disabled errors. |
| Peach Payments | One-time, refunds, partial refunds, tokenization, and merchant-initiated charges declared; provider-managed subscriptions declared false. | All operational adapter methods return explicit not-implemented/disabled errors. |

The resolver knows Stripe, PayFast, Paystack, Yoco, and Peach Payments, normalizes aliases, and fails closed for unknown providers. Capability maps are declarative; the four non-Stripe providers have scaffold tests that assert recurring operations fail closed.

### Webhook handling and idempotency

The routes are `POST /api/webhooks/:provider` and `POST /api/payments/:provider/callback`. Both controllers:

- enforce the webhook rate-limit scope;
- capture raw body bytes and request headers;
- reject unknown providers and verification/payload failures;
- call provider verify/normalize code;
- persist a verified `WebhookReceipt` with raw evidence, event metadata, payload hash, and an idempotency key;
- enqueue one Oban worker for a new receipt; and
- return an accepted response without domain transitions or outbound payment calls.

Receipt uniqueness is by idempotency key and provider/event identity. ProviderEvent, PaymentAttempt, PaymentApplication, renewal-attempt, source-order-line, refund, and outbox identities provide additional replay boundaries. Oban uniqueness is configured on receipt worker arguments and renewal worker arguments.

### Payment lifecycle and refunds

The local payment lifecycle is `created -> submitted -> succeeded|failed|requires_action`, with cancellation from created/submitted/requires-action. Setup intents use `purpose: :subscription_payment_method_update` and on success call the subscription stored-payment-method handler.

Refunds are partially implemented internally. `Store.Payments.Refunds.request_refund/2` validates provider selection, order/payment linkage, currency, refundable remaining amount, line scope, and an idempotency key under a locked transaction. Request authorization requires system context or admin/super-admin plus a recent 15-minute step-up. A successful provider refund event is processed by `ProcessRefundWebhookReceiptWorker`, creates a RefundAdjustment, marks the local refund succeeded, marks the Order refunded only when the remaining refundable amount reaches zero, and invokes digital revocation where applicable.

There is no `create_refund` callback in [`Store.Payments.Providers.Behaviour`](../../lib/store/payments/providers/behavior.ex), and no outbound provider refund request was found in the provider adapters. The current refund path creates local requested evidence and depends on an inbound refund event for completion. The Stripe capability map says refunds are supported, but that declaration is not an implemented outbound refund operation.

## 8. Subscription Engine Inventory

### Contract and plan model

`SubscriptionPlan` stores cadence, anchor, timezone, term, access, dunning, entitlement kind, and integer minor-unit amount. `VariantSubscriptionPlan` binds a plan to a variant and permits multiple active plans per variant. Cart and checkout require an explicit plan when more than one active attachment exists; an attached active plan is rechecked during renewal.

`Subscription` stores one contract per paid subscription order line. It snapshots the source order/line, variant, plan, quantity, renewal amount/currency, period timestamps, membership key, provider references, pending boundary changes, and dunning fields. `SubscriptionItem` stores a second source-line/plan snapshot.

### Renewal system

`Store.Subscriptions.Scheduler` is a pure helper for period start/end, daily/monthly/yearly cadence, every-N intervals, start-anniversary or fixed-day anchors, timezone conversion, end-of-month clamping, grace expiry, retry timestamps, renewal keys, and deterministic UUID-derived jitter.

The current schedule is Oban-only:

- `RunDueSubscriptionRenewalsWorker` runs from the Oban cron configuration every five minutes.
- `ProcessSubscriptionRenewalWorker` processes one due subscription.
- `ReconcilePaidSubscriptionRenewalWorker` advances a paid renewal after the payment webhook apply-once path.
- `EnqueueMembershipRenewalRemindersWorker` runs hourly and scans active membership subscriptions for 7-, 3-, and 1-day reminder windows.

`renewal_key` is `sub:<subscription_id>:end:<period_end_iso8601>`. The database uniqueness key is `(subscription_id, renewal_key)`. Renewal job uniqueness includes the subscription id and renewal key. The current facade intentionally does not advance a subscription on a synchronous off-session provider response; it waits for verified payment-event application and reconciliation.

### Dunning and expiration

Past-due processing increments `dunning_attempt_count`, records a string billing reason, computes `next_retry_at` from the plan schedule, and can set `retry_suppressed_at` for hard blockers. Grace expiration calls the `expired` subscription transition, revokes all subscription-source entitlement grants, and enqueues membership access-ended email. Retry exhaustion also calls the expiry path.

The stored plan fields `max_retry_attempts`, `retry_schedule_hours`, and `grace_period_days` are used. The current `Scheduler.next_retry_at/3` clamps a configured retry offset to at least 24 hours, so a plan default containing `0` does not produce an immediate retry in this implementation.

The stored `term_mode`, `term_cycles`, and `term_end_at` fields are validated on plan create/update but are not copied to Subscription and are not referenced by the observed period-extension or due-renewal code. The stored `access_on_past_due` and `access_on_cancel` fields are likewise not referenced outside plan declarations/validation. This is current behavior, not a statement about intended semantics.

### Stored payment methods and plan changes

Stripe setup-intent success creates or reuses `StoredPaymentMethod`, links it to a subscription, stores provider customer/payment-method references, clears billing failure metadata, and can make a past-due subscription immediately retryable. Renewal requires an active stored payment method whose provider matches the subscription provider.

Plan and variant changes are queued for the next period boundary through pending ids, amount/currency values, and `change_effective_at`. Renewal resolves the pending pair and applies it only during paid renewal reconciliation. There is no proration path in the inspected code.

### Cancellation

Customer/admin facade calls expose cancel-now and cancel-at-period-end. Cancel-now transitions to `canceled`, clears renewal/retry fields, revokes subscription entitlements, and enqueues membership access-ended email. Cancel-at-period-end only sets `cancel_at_period_end: true`; the due query excludes that subscription from further renewal processing. No scoped worker was found that transitions such a subscription to `canceled` at the period boundary. Its entitlement validity can expire at `valid_to_at` while the Subscription row remains active with the flag set.

### Reusable versus application-specific

Strong reusable components already present are:

- deterministic `Scheduler` period/renewal-key calculations;
- `RenewalAttempt` uniqueness and claim logic;
- virtual renewal orders using the common order/payment interlocks;
- stored payment-method identity and setup-intent flow;
- post-commit notification and Oban outbox patterns;
- plan/variant boundary-change snapshots; and
- entitlement grant upsert/revocation/cache invalidation.

Application-specific assumptions embedded in the engine include the `membership_key` duplicate-purchase guard, a required authenticated user for subscription creation, Stripe Checkout/SetupIntent semantics, merchant-managed billing as the selected mode, South African default billing timezone, physical-renewal dependence on the prior order’s shipping profile, shipping-cost surge thresholds, and membership-specific email templates.

Provider-managed subscription mode is represented in the `BillingMode` type and capability map, but `provider_managed_mode_enabled?: false` is the configured default and no provider-managed subscription creation/update orchestration was found. With the default flag off, a provider supporting both modes is selected as merchant-managed.

## 9. Entitlement Inventory

`Store.Entitlements.EntitlementGrant` is the durable access record. The current grant kinds are `membership_access`, `digital_library`, and `discount_tier`; the database source relationship and subscription facade use subscription source ids for this slice.

Creation and invalidation behavior:

- After paid initial subscription creation, the subscription facade issues a grant when the plan has an entitlement kind and scope. `valid_from_at` is the issue time and `valid_to_at` is the subscription current-period end.
- After successful renewal reconciliation, the grant is upserted with the renewed validity window.
- Cancel-now and grace-expired subscription paths revoke all grants sourced by the subscription.
- Entitlement reads use `EntitlementSet.effective_grants/2`, which requires active status, a valid current time window, and no revocation timestamp. Expired validity is therefore rejected at read time even if the row remains active.
- Refund-related digital revocation is a direct coupling from Payments to Digital; it is line-scoped in the tested refund path. Digital `DownloadGrant` is outside the main inventory here.

Access evaluation and caching:

- `Entitlements.Facade.entitlement_set_for_user/1` reads active grants for one user and caches the resulting set.
- The Cachex cache key is `user:<user_id>` with a 60-second TTL, 30-second expiration interval, and single-flight fallback behavior.
- Issue/revoke paths delete the local cache and broadcast a per-user PubSub invalidation after the durable write. Entitlement-aware account/subscription LiveViews subscribe and refresh or display membership-expired UI.
- No Redis entitlement cache was found. Redis is used by the catalog/shipping warm caches, rate limiting, and telemetry aggregates described below.

The current dependency chain is Subscription → SubscriptionPlan entitlement fields → EntitlementGrant → Cachex/PubSub → LiveView access refresh. There is no separate entitlement scheduler; expiry is represented by validity evaluation and explicit subscription revoke/expire paths.

## 10. Existing Performance Architecture

The implementation has the layered architecture described in [`performance_scaling.md`](../governance/performance_scaling.md), but only some domains use each layer.

| Layer | Current implementation | Observed TTL/invalidation |
|---|---|---|
| Hot: ETS / Cachex | Catalog product-list Cachex, catalog availability ETS, stock fast-path ETS, shipping quote Cachex, entitlement Cachex, and ETS rate limiting when configured. | Product list hot TTL 2 minutes; shipping quote hot TTL 45 seconds; availability default TTL 300 seconds; stock fast path default TTL 5 seconds; entitlement TTL 60 seconds. Catalog/shipping cache clear plus PubSub invalidation is present. Inventory mutations invalidate stock and product availability. Entitlement writes delete the local key and broadcast the user topic. |
| Warm: Redis | Product-list and shipping-quote caches use Redis term values as warm storage; Redis also stores high-velocity telemetry counters/windows/queue helpers. Optional Redis rate limiting uses the configured Redix client. | Product-list warm TTL 1,800 seconds; shipping quote warm TTL 900 seconds. Cache mutation clears the local Cachex layer, deletes the Redis prefix, then broadcasts invalidation. Telemetry counter/window TTLs are in [`RedisAggregates`](../../lib/store/support/telemetry/redis_aggregates.ex). There is no Redis subscription or entitlement data cache. |
| Cold: PostgreSQL | `Store.Repo` AshPostgres and direct `Ecto` queries are the source of truth for products, plans, carts, orders, payment evidence, subscriptions, renewal attempts, grants, and outbox records. | Durable writes are the invalidation source. Checkout/payment/renewal paths query current rows and use row locks/unique constraints where observed. |

### Per-flow performance record

| Data flow | Source of truth | Cache layer | Database access pattern | Invalidation behavior |
|---|---|---|---|---|
| Product/variant/plan storefront reads | PostgreSQL catalog, variant, and plan rows | Product-list Cachex → Redis → PostgreSQL; availability/stock ETS on relevant paths | Product list uses a bounded query and product-list key; product detail uses bounded/batched option/variant/plan loads. | Catalog mutations clear availability/stock and product-list caches, then broadcast product-list invalidation. |
| Cart reads and mutations | `carts` and `cart_items` | Stock fast-path ETS only for best-effort precheck; cart itself is not cached | Cart facade batches item/variant/product reads, locks writes, and uses cart version predicates. | Cart version changes are durable; stock mutation invalidates stock/availability caches. |
| Checkout | Cart/order/draft/snapshot/reservation rows | Shipping quote Cachex → Redis → PostgreSQL/rules source; no order/cart cache observed | Start and finalize use transactions with cart/item/order locks. Snapshot writes are create-only or update evidence actions; reservations use deterministic lock ordering and SQL. | Catalog/price/shipping mutations invalidate their respective caches. Stored shipping quote evidence is used to revalidate client selections. |
| Initial payment/webhook | PaymentIntent, WebhookReceipt, ProviderEvent, PaymentAttempt, Order, PaymentApplication | No payment-state cache observed | Receipt persistence and worker processing use unique identities; apply-once uses a transaction and SQL `ON CONFLICT`. Provider HTTP is outside the DB transaction. | Receipt evidence is purged by scheduled worker after the configured retention; durable payment/order state is not cache-invalidated because reads query PostgreSQL. |
| Subscription activation/access | Subscription, SubscriptionItem, StoredPaymentMethod, EntitlementGrant | Entitlement Cachex only | Paid-order worker uses a transaction for stored method/subscription records; entitlement issue follows that transaction. | Entitlement issue/revoke clears local Cachex and broadcasts PubSub. Grant validity is checked against the clock on cache hits. |
| Renewal/dunning | Subscription, plan, RenewalAttempt, renewal Order/PaymentIntent, provider receipts | No subscription/renewal data cache observed; Redis is telemetry only | Due read is bounded and indexed; per-subscription processing reads and writes current rows, creates virtual snapshots, may quote shipping, and uses inventory/order/payment idempotency. | Subscription and attempt state are durable. Entitlement sync invalidates the per-user entitlement cache after paid renewal. |
| Email/outbox | EmailOutbox and Oban jobs | No email cache observed | Outbox is unique by idempotency key; delivery/reclaim uses SQL claim/retry state and provider adapter calls. | State changes are durable; Oban uniqueness and outbox identity reduce duplicate delivery. |

Relevant observed indexes include published product composites, cart/user/token uniqueness, checkout cart/version and order uniqueness, payment intent provider/session/in-flight uniqueness, order keyset indexes, subscription due/retry partial indexes, renewal attempt uniqueness/inserted indexes, entitlement user/source/valid-to indexes, and outbox state/template/subscription indexes. Query-count and stage timing telemetry exists in catalog, checkout, payment ingress, subscription, comms, and Redis aggregate paths. Subscription performance tests assert bounded due-job, entitlement, and detail reads; they do not establish a production query budget.

## 11. Existing Security Controls

### Trust boundaries and sensitive inputs

| Boundary | Inputs | Current control |
|---|---|---|
| Browser/customer → LiveView/domain | Cart token, checkout key, variant/plan ids, quantities, shipping fields, quote hash/method, subscription action ids, return/cancel query parameters | Typed params/input structs normalize and validate fields. Cart and checkout facades re-read current catalog/order data. Cart token and user identity are used for cart/draft access. Return/cancel pages do not apply payment state or trust query parameters as payment proof. |
| Provider → webhook/callback controller | Provider route value, raw body bytes, headers, provider event ids, amounts/currencies, provider metadata | Provider is normalized against a known-provider allowlist. Signature verification uses exact raw body and headers. A verified receipt is persisted before worker processing. Payment worker validates canonical target and normal payment amount/currency against the finalized order. |
| Worker/system → domain state | Oban args, receipt ids, provider results, renewal keys, payment-method refs | Workers call domain facades/system-context actions. Ash policies gate system actions. Unique database identities, apply-once rows, renewal keys, and Oban uniqueness make replay-sensitive operations durable. |
| Admin/support → privileged records | Product, order, payment, refund, subscription, entitlement, outbox reads/actions | Ash policies check roles. Support is generally read-only for subscription/payment lifecycle actions. Refund request requires a recent step-up for admin/super-admin. |
| Application → external providers/email | Stripe credentials, provider customer/payment-method refs, raw provider response | Credentials are read from runtime configuration. Provider calls are wrapped by `ProviderTask`/Finch. Email is routed through Comms outbox and Oban. Logger parameter filtering includes token, secret, payment method, address, phone, and email keys. |

### Authorization and policy controls

Ash policies are present on the scoped resources. Customer reads are self-scoped for orders, subscriptions, grants, stored methods, carts, and checkout-related surfaces; public catalog and active plan reads are explicitly open. Admin/super-admin/support roles receive varying read access. System-context actions handle payment success, subscription activation/renewal, entitlement changes, receipt processing, inventory reservations, and outbox delivery.

The current policy matrix and implementation are compared by [`subscriptions_policy_matrix_test.exs`](../../test/store/governance/subscriptions_policy_matrix_test.exs), [`policy_matrix_test.exs`](../../test/store/governance/policy_matrix_test.exs), and the resource policies. Web query-discipline and no-direct-Ash/Repo gates are represented in [`mix.exs`](../../mix.exs) and governance tests.

### Replay-sensitive operations

The replay-sensitive set is: payment intent create/reuse, provider setup recovery, webhook receipt ingest, provider-event and payment-attempt recording, payment success/order-paid/reservation consumption, refund request and callback finalization, initial subscription creation, setup-intent stored-method update, renewal attempt/order/payment-intent creation, paid renewal reconciliation, entitlement issue/revoke, and email enqueue/delivery.

The current controls are database uniqueness, row locks, optimistic-lock version fields on several non-subscription state resources, raw SQL compare-and-set for renewal attempts, post-commit notifications, and worker uniqueness. Subscription transition actions currently opt out of `TransitionState` optimistic locking, which is documented as a risk below.

### Rate limiting, secrets, and audit evidence

- Webhook/callback requests use `RequestRateLimit` with configured limits. The default config selects ETS; runtime and test configuration can select Redis. Admin and signed-download limits are also configured.
- Provider keys/secrets are runtime environment configuration. Test configuration uses test-only values. `config/runtime.exs` parses provider and Redis configuration.
- `WebhookReceipt` stores raw body and headers, retains a SHA-256 hash, and has an Oban purge worker. The configured operations retention is 30 days; purge overwrites raw body and headers and records an `AuditLog` action through the payments facade.
- `Store.Admin.AuditLog` was found for webhook evidence purge. The scoped search did not find a general audit call on every payment or subscription transition, despite governance tests/docs requiring broader audit coverage.
- No separate security scanner workflow was found. CI runs dependency audit, Credo, compile and source-denylist governance gates, tests, performance smoke, and Dialyzer as described in Section 12.

## 12. Test Coverage Inventory

Coverage levels below describe the breadth of relevant test artifacts found, not measured code coverage.

| Area | Existing Tests | Coverage Level | Gaps |
|---|---|---|---|
| Catalog/product/variant | [`facade_public_product_test.exs`](../../test/store/catalog/facade_public_product_test.exs), [`availability_cache_test.exs`](../../test/store/catalog/availability_cache_test.exs), catalog Phase 19/25 governance tests | Moderate | Public reads, cache behavior, bounded plan-option reads, and availability races are covered. Full product-to-paid-subscription integration is not in one test. |
| Cart and plan selection | [`carts/facade_test.exs`](../../test/store/carts/facade_test.exs), [`checkout_subscription_only_test.exs`](../../test/store/subscriptions/checkout_subscription_only_test.exs) | High for focused invariants | Membership duplicate guards, cart merge/version, feature-off behavior, and subscription-only checkout are covered. Broader mixed-cart and all plan attachment permutations are distributed across tests rather than one end-to-end scenario. |
| Checkout | [`checkout/domain_test.exs`](../../test/store/checkout/domain_test.exs), checkout interlock/governance tests | High for core interlocks | Start idempotency/concurrency, snapshot/hold idempotency, quote tamper, guest/user authorization, and unavailable inventory are covered. Provider-to-subscription flow is tested through separate worker suites. |
| Orders and snapshots | [`orders/facade_pagination_test.exs`](../../test/store/orders/facade_pagination_test.exs), immutable snapshot, state-machine, inventory-reservation, and pending-provider-setup tests | Moderate | Snapshot immutability, pagination, reservation and provider-setup sweeps are covered. The runtime use of `Order.payment_failed` is not covered by an end-to-end payment failure test. |
| Initial payment intent | [`create_intent_for_order_test.exs`](../../test/store/payments/create_intent_for_order_test.exs), provider task/fault-isolation tests | High for local boundary behavior | Finalized totals, idempotency, guest digital restriction, provider selection/disablement, timeout/error/crash, and local recovery are covered. There is no live provider integration in the repository test suite. |
| Webhooks and payment workers | [`webhook_controller_test.exs`](../../test/store_web/controllers/webhook_controller_test.exs), payment/refund worker tests, provider resolver and Stripe tests | High for Stripe receipt/replay path | Raw bytes, signatures, duplicate receipts, routing, disabled providers, success, setup success, renewal reservation release, and refund threshold are covered. Non-Stripe adapters are scaffold-only, and refund normalization is generic worker parsing rather than provider adapter normalization. |
| Refunds | [`refunds_digital_revocation_test.exs`](../../test/store/payments/refunds_digital_revocation_test.exs), refund semantics/governance and refund worker tests | Moderate | Internal bounds, line-scoped digital revocation, refund callback replay, and full-refund threshold are covered. No outbound provider refund operation exists to test. |
| Subscription activation | [`subscriptions/facade_test.exs`](../../test/store/subscriptions/facade_test.exs), [`subscriptions_ensure_for_paid_order_worker_test.exs`](../../test/store/workers/subscriptions_ensure_for_paid_order_worker_test.exs) | High for isolated activation | Replay-safe source-line creation, stored method linkage, provider selection, and entitlement issuance are covered. Guest paid subscription behavior is not exercised as a complete flow; the facade explicitly rejects it. |
| Renewal and dunning | Subscription facade, scheduler, property, replay-concurrency, performance, and renewal-worker tests | High for implemented merchant-managed path | Due jobs, deterministic jitter, renewal attempt uniqueness, missing method/provider, physical shipping/inventory/surge, synchronous decline, grace expiry, pending pricing, and webhook reconciliation are covered. Term modes/access policy fields and period-end cancellation terminal transition are not covered by focused tests. |
| Entitlements | [`entitlements/facade_test.exs`](../../test/store/entitlements/facade_test.exs), uniqueness and refund revocation tests | High for cache/grant mechanics | Upsert, validity-at-read, cache invalidation/coalescing, revocation, and expiration are covered. Broader entitlement authorization use outside LiveViews is not part of this slice. |
| Concurrency and locking | Cart parallel start/merge, checkout parallel start/finalize, provider fault races, renewal replay concurrency, inventory reservation tests | Moderate to high for selected paths | There are focused race tests. Subscription lifecycle transitions have no version lock and no broad cancellation-vs-renewal race test was found. |
| Security and governance | State machines, policy matrix, idempotency, immutable snapshots, web no-direct-call/query gates, API forward-only, error-code, audit/post-commit tests | High for static governance controls | Static architectural gates and selected policy transitions are covered. CI has no separate security scan, and audit requirements are broader than the observed payment/subscription audit call sites. |
| Performance/query behavior | Subscription performance tests, catalog telemetry/bounded-query tests, perf smoke/chaos tests, CI and nightly smoke workflows | Moderate | Bounded reads, cache layers, due selection, and smoke profiles are covered. Repository tests do not establish production latency or load behavior, and there is no single measured end-to-end subscription checkout benchmark. |

### CI/CD behavior

[`ci.yml`](../../.github/workflows/ci.yml) runs on pull requests and pushes to `main`. It declares PostgreSQL 16 and Redis 7 services and has separate jobs for:

- `check_static`: strict toolchain setup, database create/migrate, migration-alignment check, dependency audit, `mix check`, and generated-drift check;
- `test_pr_strict`: database setup and `mix test --max-failures 1`;
- required CI performance smoke and chaos smoke jobs using `priv/repo/performance_smoke_test.exs`; and
- required Dialyzer via `mix check.types`.

`mix check` includes format, warnings-as-errors compilation, dependency audit, source-denylist/web-boundary gates, API/GraphQL/surface/doc gates, tests, Credo strict, and docs generation. The workflows do not name a separate SAST, DAST, or security scan job. The dependency audit is the only explicitly named security-oriented CI step.

During this inventory, after fetching the repository's locked dependencies, `mix check` compiled the dependency set and application but exited nonzero in the dependency-audit stage. The audit reported vulnerabilities for locked versions including Phoenix 1.8.3, AshAuthentication 4.13.7, Bandit 1.11.0, Mint 1.7.1, Req 0.5.17, Postgrex 0.22.0, Decimal 2.3.0, and Plug 1.19.1. No dependency or application change was made as part of this inventory, so a passing `mix check` result was not established.

[`nightly-hardening.yml`](../../.github/workflows/nightly-hardening.yml) runs three seeded test suites, focused scheduler/replay/performance tests, a three-iteration replay stress loop, full-stress/provider-incident performance smoke, artifact upload, and nightly Dialyzer. It does not add a separate security job.

## 13. Known Risks And Unknowns

### KNOWN PROBLEMS

- Default configuration has `payments.enabled_providers: []` and `subscription_features.expose_purchase?: false`, so subscription purchase and provider payment are unavailable unless deployment configuration overrides them.
- Stripe is the only operational payment adapter. PayFast, Paystack, Yoco, and Peach Payments expose capability maps but return scaffold errors for operational methods.
- The provider behavior has no outbound `create_refund` operation. Local refunds depend on provider callbacks for completion even though provider capability maps declare refunds.
- Governance [`state_machines.md`](../governance/state_machines.md) does not match the code’s Order and PaymentIntent state enums. It omits `pending_provider_setup`, `payment_failed`, and `requires_action`; subscription states are not covered by that document.
- `Subscription` has no version column and explicitly passes `lock_attribute: nil` to all observed `TransitionState` changes. This differs from the governance requirement that lifecycle writes use optimistic locking.
- `Subscription` stores term/access policy fields, but the renewal/access code found by repository search does not consume those fields. Fixed cycles, fixed end dates, immediate past-due access removal, and configurable cancel access are not represented in the observed orchestration.
- Cancel-at-period-end sets a flag that excludes the subscription from future due selection, but no scoped terminal transition at the period boundary was found. The row can remain `active` after its period and entitlement validity have ended.
- `Order.mark_payment_failed` is a declared and tested transition, but no scoped runtime call site was found for normal provider failure. Current payment failure processing updates the local PaymentIntent; stale provider setup is handled by a separate recovery/sweep path.
- Subscription creation requires `order.user_id` to be present. Checkout drafts and orders support guests, so the data model permits a paid guest subscription order that the activation worker will reject.
- The subscription facade is about 3,300 lines and directly coordinates catalog, pricing, shipping, orders, payments, entitlements, and comms. Checkout and payment interlocks also contain broad orchestration and direct SQL. Ownership is therefore not isolated to one small reusable boundary.
- Physical subscription renewal is tied to the previous paid order’s shipping evidence, live shipping quote, tax rules, variant weight, inventory reservation, and a hard-coded shipping cost surge threshold. That is an application-specific fulfillment assumption in the subscription engine.
- Post-commit subscription entitlement issuance and several downstream Oban enqueue paths log/skip errors rather than making the paid order rollback. Payment durability can therefore precede subscription/access or downstream-job durability.
- Raw Ecto/SQL access and Ash actions coexist in the same domain flows. Locks, resource policies, direct updates, and Ash transitions are not all expressed through one data-access mechanism.

### NEEDS INVESTIGATION

- Which production/runtime environment values enable providers, expose subscription purchase, select billing mode, and configure Redis. The repository contains parsers and defaults, not deployment values.
- Whether the current migration database and generated Ash resource definitions pass `mix ash_postgres.generate_migrations --check` in the intended host toolchain. CI declares this check; local beads tooling did not provide a usable Dolt server and the application toolchain was not used to alter code.
- Whether term and access-policy fields are intentionally dormant or are documentation drift requiring a separate decision record. This inventory does not infer the desired behavior.
- Whether provider-managed Stripe subscriptions are intended to be enabled later. Capability support is declared, but the current flow is merchant-managed off-session charging.
- The exact desired audit scope for payment/subscription transitions. Current code visibly audits webhook evidence purge, while governance requires audit evidence for at least one payment transition and admin mutation.
- Whether all state transitions that use direct SQL or Ash updates have equivalent concurrency guarantees. The broad subscription cancellation, dunning, setup-success, and renewal races have only partial focused coverage.
- Whether the hourly reminder window is operationally sufficient after downtime. Current reminder code scans fixed 7/3/1-day windows and uses outbox idempotency keys; it does not show a catch-up policy for missed windows.
- Whether the generic refund webhook parser is valid for every configured provider. Only Stripe has provider-specific normalization, and the other adapters are scaffolds.
- Whether the current guest checkout/product configuration permits any intended guest subscription purchase, given the activation requirement for an authenticated user.

## 14. Extraction Readiness Snapshot

These classifications describe the current code’s extraction readiness, not a proposed work plan.

| Domain | Classification | Current evidence |
|---|---|---|
| Catalog | PARTIAL | Clear Ash resources, public/admin facade, typed query contracts, product-list/availability/stock caches, and focused tests exist. Catalog still couples sellability to cart/subscription-plan resolution and inventory paths, and variant/product records have no lifecycle version field. |
| Cart | PARTIAL | Cart resources, typed input, facade, locking/version strategy, deterministic merge, and tests are present. Add-to-cart directly invokes catalog stock and subscription membership guards, so cart behavior includes application-specific subscription policy. |
| Checkout | NOT READY | Checkout domain owns a large multi-step orchestration across carts, catalog, plans, pricing, shipping, orders, snapshots, inventory, and payment handoff. It uses direct row locks and SQL as well as Ash actions, and the checkout draft state enum is not fully exercised. |
| Orders | PARTIAL | Order and immutable snapshot resources, explicit state transitions, apply-once/payment application, reservation services, indexes, and tests provide a recognizable boundary. Payment, subscription, fulfillment, digital, comms, and raw SQL side effects are still coupled to the order path. |
| Payments | NOT READY | Receipt-first evidence, interlocks, provider task isolation, Stripe adapter, policies, and tests are substantial. The provider set is mostly scaffold, refund outbound behavior is absent, and payment interlocks enqueue and coordinate subscription/digital/fulfillment/comms effects. |
| Subscriptions | NOT READY | The facade contains the full activation, stored-method, change, cancellation, renewal, dunning, shipping, inventory, payment, entitlement, and comms flow. The resource lacks optimistic locking, term/access fields are dormant, and provider/physical/membership assumptions are embedded. |
| Entitlements | PARTIAL | Grant resource, unique issue, validity-at-read, Cachex single-flight cache, PubSub invalidation, facade, and focused tests form a relatively clear access boundary. The source model is subscription-centric and its invalidation/LiveView behavior is coupled to this application’s membership UX. |

### Evidence consulted

Primary implementation evidence included the scoped files under [`lib/store/catalog`](../../lib/store/catalog), [`lib/store/carts`](../../lib/store/carts), [`lib/store/checkout`](../../lib/store/checkout), [`lib/store/orders`](../../lib/store/orders), [`lib/store/payments`](../../lib/store/payments), [`lib/store/subscriptions`](../../lib/store/subscriptions), [`lib/store/entitlements`](../../lib/store/entitlements), [`lib/store/comms`](../../lib/store/comms), [`lib/store/workers`](../../lib/store/workers), and the relevant LiveViews/controllers under [`lib/store_web`](../../lib/store_web).

Database evidence came from the Phase 4/5/11/12/14/19/20/21/26/27/28/29/31 migrations under [`priv/repo/migrations`](../../priv/repo/migrations). Test evidence came from the scoped suites under [`test/store`](../../test/store), [`test/store_web`](../../test/store_web), and subscription fixtures. CI evidence came from [`ci.yml`](../../.github/workflows/ci.yml) and [`nightly-hardening.yml`](../../.github/workflows/nightly-hardening.yml). Governance comparisons used [`state_machines.md`](../governance/state_machines.md), [`subscription_scheduling_terms.md`](../governance/subscription_scheduling_terms.md), [`payment_provider_contract.md`](../governance/payment_provider_contract.md), [`payment_provider_capabilities.md`](../governance/payment_provider_capabilities.md), [`performance_scaling.md`](../governance/performance_scaling.md), [`idempotency.md`](../governance/idempotency.md), [`policy_matrix.md`](../governance/policy_matrix.md), [`audit_and_pii.md`](../governance/audit_and_pii.md), [`retention.md`](../governance/retention.md), and the Phase 19–29 docs/agent notes.
