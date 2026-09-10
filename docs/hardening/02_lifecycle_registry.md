# Store_Blueprint Subscription Commerce Lifecycle Registry

This is the S0-02 lifecycle registry for the subscription-commerce vertical slice. It records executable behavior found in the repository as inspected on 2026-08-27. Source code is the authority. Governance and phase documents are evidence of stated rules only; disagreements are recorded as drift.

The registry is descriptive. It does not define a target state machine, change application behavior, or imply that a declared action is used in production. A transition is listed as implemented only where the resource or an observed domain path provides the evidence.

## 1. Purpose

Lifecycle modeling makes the boundaries between catalog sellability, purchase state, payment evidence, subscription periods, and access explicit before extraction or hardening work begins. This document is the canonical inventory for the current Subscription Commerce V1 slice:

```text
Product -> Variant -> SubscriptionPlan -> Cart -> CheckoutDraft/Order
  -> PaymentIntent/provider receipt -> paid Order -> Subscription
  -> EntitlementGrant -> RenewalAttempt/dunning
```

The registry records:

- state values and the locations that define them;
- executable transition actions and their guards;
- durable and asynchronous side effects;
- terminal and replay behavior;
- concurrency protections and unprotected races; and
- tests that demonstrate, or fail to demonstrate, the behavior.

Future extraction decisions depend on separating these observed lifecycle contracts from intended architecture. A resource declaration, migration constraint, governance statement, and runtime facade can describe different parts of the system; this registry does not silently reconcile them.

Evidence conventions used below:

- “Observed” means the behavior is visible in source code or a test.
- “Declared” means a type, action, migration, or policy exposes the value, but a runtime transition was not found.
- “Not found” means repository search did not locate evidence; it is not proof that behavior is impossible outside the inspected scope.
- “Terminal under exposed transitions” means no outgoing state transition was found. It does not mean the database prevents every non-state update.

# 2. Lifecycle Summary Table

Coverage levels are qualitative assessments of the test artifacts found, not line-coverage measurements.

| Resource | Domain | Lifecycle Exists | State Location | Test Coverage |
|---|---|---|---|---|
| Product | `Store.Catalog` | Yes | `Product.status` and publication timestamps | Moderate: catalog lifecycle and public visibility tests |
| Variant | `Store.Catalog` | Yes | `Variant.status` | Moderate: active completeness, archive/reactivation, signature and availability tests |
| SubscriptionPlan | `Store.Subscriptions` | Yes | `SubscriptionPlan.status`; attachment uses `VariantSubscriptionPlan.active` | Limited: plan validation/attachment tests; no focused retirement effect test |
| Cart | `Store.Carts` | Yes | `Cart.status`, `Cart.version`; `CartItem` has no state | Focused: mutation, merge, uniqueness, stale/version and LiveView tests |
| CheckoutDraft | `Store.Checkout` | Declared, partially executed | `CheckoutDraft.status`; order payment state is separate | Focused checkout tests; no observed draft `consumed`/`expired` transition test |
| Order | `Store.Orders` | Yes | `Order.state`, `Order.version` | High for state-machine and interlock paths; normal payment-failure runtime path is not proven |
| PaymentIntent | `Store.Payments` | Yes | `PaymentIntent.state`, `PaymentIntent.version` | High for local transitions, provider receipts, replay, and setup paths |
| Subscription | `Store.Subscriptions` | Yes | `Subscription.status`; no version field | High for selected activation/renewal/dunning paths; concurrency and term/access gaps remain |
| RenewalAttempt | `Store.Subscriptions` | Yes | `RenewalAttempt.status`; claim uses `updated_at` compare-and-set | High for uniqueness, worker replay, and renewal reconciliation |
| EntitlementGrant | `Store.Entitlements` | Yes | `EntitlementGrant.status` plus validity/revocation timestamps | High for grant upsert, validity, revocation, cache invalidation, and refund coupling |

The principal source files are [`lib/store/catalog/product.ex`](../../lib/store/catalog/product.ex), [`lib/store/catalog/variant.ex`](../../lib/store/catalog/variant.ex), [`lib/store/subscriptions/subscription_plan.ex`](../../lib/store/subscriptions/subscription_plan.ex), [`lib/store/carts/cart.ex`](../../lib/store/carts/cart.ex), [`lib/store/checkout/checkout_draft.ex`](../../lib/store/checkout/checkout_draft.ex), [`lib/store/orders/order.ex`](../../lib/store/orders/order.ex), [`lib/store/payments/payment_intent.ex`](../../lib/store/payments/payment_intent.ex), [`lib/store/subscriptions/subscription.ex`](../../lib/store/subscriptions/subscription.ex), [`lib/store/subscriptions/renewal_attempt.ex`](../../lib/store/subscriptions/renewal_attempt.ex), and [`lib/store/entitlements/entitlement_grant.ex`](../../lib/store/entitlements/entitlement_grant.ex).

## 3. Product Lifecycle

### States

`Store.Catalog.Product` uses `Store.Catalog.Types.ProductStatus` with these values:

- `draft`
- `published`
- `archived`

The database column is `products.status`. `published_at` and `archived_at` are additional timestamps, not states. Public catalog queries require `status == :published` and a non-null `published_at`.

### Transitions

| Action | From | To | Guard | Side Effects | Tests |
|---|---|---|---|---|---|
| `create_draft` | none | `draft` | Admin or super-admin policy; required product and base-variant arguments. The action forces `status: :draft` and `published_at: nil`. | Generates `default_variant_id`; an `after_action` creates an active base `Variant` and its `InventoryItem`; normalizes fields. The exact cross-resource transaction boundary is not established by the action source. | [`catalog_phase_19_test.exs`](../../test/store/governance/catalog_phase_19_test.exs) and catalog facade tests |
| `update_draft` | `draft` | `draft` | `require_current_state/2` allows only current `draft`; admin/super-admin policy. | Updates accepted product fields and normalizes them. No version field or state-transition helper is used. | [`catalog_phase_19_test.exs`](../../test/store/governance/catalog_phase_19_test.exs) |
| `publish` | `draft` | `published` | Current status must be `draft`; admin/super-admin policy. | Sets `published_at` to current UTC time and clears `archived_at`. The catalog facade clears product-list, availability, and stock caches after success. | [`catalog_phase_19_test.exs`](../../test/store/governance/catalog_phase_19_test.exs) |
| `unpublish` | `published` | `draft` | Current status must be `published`; admin/super-admin policy. | Clears `published_at`. The catalog facade clears product-list, availability, and stock caches after success. | [`catalog_phase_19_test.exs`](../../test/store/governance/catalog_phase_19_test.exs) |
| `archive` | `draft` or `published` | `archived` | Current status must be `draft` or `published`; admin/super-admin policy. | Sets `archived_at` to current UTC time. The catalog facade clears product-list, availability, and stock caches after success. | [`catalog_phase_19_test.exs`](../../test/store/governance/catalog_phase_19_test.exs) |

The Product actions do not use `Store.Support.Governance.TransitionState`. Repeating `publish`, `unpublish`, or `archive` from a state not listed above returns a validation error rather than a replay no-op. No product version or optimistic-lock field was found.

### Terminal States

`archived` is terminal under the exposed Product transition actions: `publish`, `unpublish`, and `update_draft` do not accept it. The source does not label it terminal and does not add a database terminal constraint. Existing variants, plans, carts, orders, or subscriptions are not automatically transitioned by Product archival in the Product resource.

### Extraction Classification

- Reusable commerce behavior: publication visibility predicates, draft/published/archive action shape, publication timestamps, product-to-variant relationship, and public/admin policy split.
- Store-specific behavior: automatic base variant and inventory creation, catalog cache invalidation, product-kind coupling, and the application’s category/image/availability projections.

Performance and security evidence: Product state is persisted in PostgreSQL. Product-list data uses Cachex/Redis and availability/stock data uses ETS; the catalog facade invalidates those layers after mutation and emits catalog invalidation behavior. There is no Product PubSub transition event in the resource. Public reads are deliberately open but only return published products; mutation actions require admin or super-admin policy.

## 4. Variant Lifecycle

### States

`Store.Catalog.Variant` uses `Store.Catalog.Types.VariantStatus`:

- `active`
- `archived`

The database column is `variants.status`. Public variant reads filter to `active`. Variant sellability also depends on its Product being `published` with a non-null `published_at`, required option selections being complete, and inventory checks at cart/checkout time.

### Transitions

| Action | From | To | Guard | Side Effects | Tests |
|---|---|---|---|---|---|
| `create` / `create_for_product` | none | `active` or `archived` | Admin/super-admin policy; compare-at price, image ownership, active option completeness, and active signature uniqueness validators. `create_for_product` also requires an internal forced id. | Normalizes SKU/currency/title and synchronizes the option-selection signature. `create_for_product` is used by Product base-variant creation. | [`catalog_phase_25_test.exs`](../../test/store/governance/catalog_phase_25_test.exs) |
| `update` | `active` or `archived` | `active` or `archived` | Admin/super-admin policy; validators run against the resulting status. There is no current-state transition guard. | Can change status and variant fields; synchronizes selection signature. Re-activating an archived variant is directly exercised by tests. | [`catalog_phase_25_test.exs`](../../test/store/governance/catalog_phase_25_test.exs) |
| `archive` | `active` or `archived` | `archived` | Admin/super-admin policy only. The action has no current-state guard. | Sets status to `archived` and synchronizes the selection signature. The catalog facade invalidates product/availability/stock caches. | [`catalog_phase_25_test.exs`](../../test/store/governance/catalog_phase_25_test.exs) |

`archive` is therefore repeatable as a write rather than an explicit replay no-op, and generic `update` can restore `active` if the active validators pass. There is no separate `activate` action and no Variant version field.

### Terminal States

There is no terminal Variant state in the executable actions. `archived` is excluded from public sellability, but `update` can set it back to `active`. `destroy` also exists, subject to foreign-key constraints; the catalog facade reports blocking constraints for product default, cart-item, and subscription-item references.

### Extraction Classification

- Reusable commerce behavior: variant identity, integer minor-unit price/currency, active/archive visibility, option-completeness/signature validation, and Product relationship.
- Store-specific behavior: inventory linkage, option-resolution projections, stock fast path, cache invalidation, and the application’s delete-blocking relationship set.

Performance and security evidence: variants are PostgreSQL rows. Catalog detail/availability reads can use Cachex/ETS/Redis through the catalog surfaces; Variant writes invalidate product and stock-related caches in the facade. No Variant transition PubSub event was found. Active-state creation/update/archive require admin or super-admin policy; checkout rechecks Product and Variant status before pricing.

## 5. Subscription Plan Lifecycle

### States

`Store.Subscriptions.SubscriptionPlan` uses `Store.Subscriptions.Types.PlanStatus`:

- `active`
- `archived`

The database column is `subscription_plans.status`. A separate `Store.Subscriptions.VariantSubscriptionPlan` record has boolean `active`/`inactive` attachment state; it is not a state machine and is not the same as plan status.

Plan attributes that affect later lifecycle work include `interval_unit`, `interval_count`, `currency`, `amount_minor`, trial/anchor fields, billing timezone, term fields, access policy fields, grace days, retry limits/schedule, and entitlement kind/scope. The plan resource validates these fields on create/update. `Store.Subscriptions.Scheduler` uses cadence/anchor/timezone/grace/retry values; the observed subscription path does not consume the term or access policy fields described below.

### Transitions

| Action | From | To | Guard | Side Effects | Tests |
|---|---|---|---|---|---|
| `create` | none | `active` or `archived` | System or admin/super-admin policy; anchor, term, retry-schedule, and entitlement validators. Default status is `active`. | Normalizes key/name/currency/timezone/scope and retry schedule. | [`subscriptions_phase_26_test.exs`](../../test/store/governance/subscriptions_phase_26_test.exs), subscription facade tests |
| `update` | `active` or `archived` | `active` or `archived` | System or admin/super-admin policy; no current-state guard. Pricing, cadence, term, access, dunning, entitlement, and status fields are accepted. | Can edit plan price and lifecycle fields in place. Existing Subscription rows retain their stored renewal amount/currency unless a pending change or renewal reconciliation updates them. | Plan validation and subscription facade tests; no focused archive-price effect test found |
| `archive` | `active` or `archived` | `archived` | System or admin/super-admin policy; no current-state guard. | Sets `status: :archived`. It does not cascade to VariantSubscriptionPlan attachments or Subscription rows. | No focused retirement transition test found |
| `activate` | `active` or `archived` | `active` | System or admin/super-admin policy; no current-state guard. | Sets `status: :active`. | No focused replay/activation test found |
| `attach` / `set_active` on `VariantSubscriptionPlan` | none or existing attachment | `active` or inactive boolean | System or admin/super-admin policy; unique `(variant_id, subscription_plan_id)`. | `attach` upserts the relationship and `set_active` changes only the attachment boolean. | [`subscriptions_uniqueness_test.exs`](../../test/store/governance/subscriptions_uniqueness_test.exs), subscription facade/checkout tests |

The system reads used by checkout and subscription option resolution filter `VariantSubscriptionPlan.active == true`. The observed queries in [`lib/store/subscriptions/facade.ex`](../../lib/store/subscriptions/facade.ex) load the attached plan but do not also filter `SubscriptionPlan.status == :active`. Therefore the source does not prove that archiving a plan excludes it from every system-side option or renewal read when its attachment remains active. Public plan reads do filter to active. This is a lifecycle distinction, not a correction.

### Terminal States

Neither plan state is terminal. `archived` can be changed back to `active` by `activate` or generic `update`. No action automatically retires existing subscriptions when a plan is archived. Existing subscriptions keep their plan id, variant id, renewal amount, and renewal currency. Renewal uses the current plan record and active variant-plan attachment when building the effective contract, so plan archival effects are not uniform across public reads, checkout option reads, and renewal reads.

### Extraction Classification

- Reusable commerce behavior: cadence/anchor/term/dunning data model, active attachment model, integer pricing, deterministic scheduler inputs, and entitlement configuration.
- Store-specific behavior: default `Africa/Johannesburg` timezone, membership entitlement keys, provider selection, checkout plan-resolution queries, and the current coupling to physical renewal/shipping.

Performance and security evidence: plan and attachment state are PostgreSQL data with status/relationship indexes. No plan cache or invalidation path was found in the plan resource; catalog/product cache invalidation does not establish plan-cache invalidation. Public plan reads are active-only. Plan mutation and attachment mutation require system or admin/super-admin policy.

## 6. Cart Lifecycle

`Store.Carts.Cart` is a small state-bearing resource, while `Store.Carts.CartItem` is a quantity/relationship record with no lifecycle state.

### States and operations

`Cart.status` values are:

- `active`
- `abandoned`

Creation always writes `active`. `Store.Carts.Facade.get_cart_for_user/2` finds an active cart by authenticated user id or guest token and creates one if absent. An authenticated cart receives a generated token; a guest cart uses the supplied token. `Cart.version` starts at `1`.

The observed operations are:

| Operation | Current behavior | Guard and side effects | Tests |
|---|---|---|---|
| Create/load | Finds the first active cart by user or token, or inserts an active cart. Unique conflicts are re-read. | Token validation; user/token ownership is enforced by facade lookup and resource policy. PostgreSQL source of truth. | [`carts/facade_test.exs`](../../test/store/carts/facade_test.exs) |
| Add item | Locks the active cart and items, checks active Product/Variant sellability, checks membership duplicate rules, inserts or merges `CartItem`, and caps quantity at 99. | Transaction and `FOR UPDATE` locks. Best-effort ETS stock precheck; checkout reservation is authoritative. Cart version increments only when data changes. | [`carts/facade_test.exs`](../../test/store/carts/facade_test.exs), catalog Phase 25 tests |
| Update quantity | Locks cart/item, rechecks variant sellability, updates quantity, and increments Cart version on change. Same quantity is a no-op. | Quantity input validation; database row lock and version bump. | [`carts/facade_test.exs`](../../test/store/carts/facade_test.exs) |
| Remove item | Locks cart and matching item, deletes the item, and increments version on change. | Active cart/token ownership and `FOR UPDATE`; no cart-item state is retained after deletion. | [`carts/facade_test.exs`](../../test/store/carts/facade_test.exs) |
| Guest merge | Locks guest token cart and user active cart; merges items in binary UUID order; caps quantities; marks guest cart `abandoned`, records `merged_into_cart_id`, and increments versions when changed. | User id/token validation, row locks, unique active-cart indexes, version predicate on guest abandonment, and repeat merge no-op. | [`carts/facade_test.exs`](../../test/store/carts/facade_test.exs), lock-order tests |

### Expiration, Conversion, and Abandonment

No `expires_at` field, cart-expiration action, or cart-expiration worker was found. The only observed write to `status: :abandoned` is guest-cart merge. There is no normal abandoned-cart transition for inactivity.

Checkout does not convert or consume the Cart. It takes the current cart version, creates or reuses a `CheckoutDraft` and Order, and leaves the Cart active. The Cart is therefore not a completed-order lifecycle record. A Cart can remain active after its Order is paid unless another operation changes it.

### Stale Version Behavior and Concurrency Notes

`Cart.version` is used by mutation bumps, checkout draft identity, checkout reload, and guest-merge updates. The facade locks the cart before mutation and uses `WHERE id = ... AND version = ...` for observed compare-and-set updates. A failed compare-and-set returns `STALE_RECORD`. Checkout uses the cart version as a snapshot and returns `STALE_RECORD` when the active cart/version no longer exists.

There is no Cart cache and no Cart mutation PubSub/broadcast observed. PostgreSQL is the source of truth. ETS stock data is only a precheck and is invalidated by inventory/catalog paths; it does not replace checkout reservation locks. Cart mutation and merge do not enqueue workers.

Security evidence: Cart reads are active-user or active-token scoped; resource writes are system/admin only, with the facade supplying the user-facing ownership boundary. User-controlled token, variant id, plan id, and quantity are normalized through typed inputs before the facade re-reads current records.

### Terminal States

`abandoned` is terminal under the observed Cart facade operations: no normal reload returns it as active, and no reactivation operation was found. The resource’s generic `update` action accepts `status`, so the resource declaration itself does not make this terminal. The effective application behavior is therefore “merged carts are no longer active,” not a fully closed state machine.

## 7. Checkout Lifecycle

### Draft states

`Store.Checkout.CheckoutDraft.status` declares:

- `open`
- `consumed`
- `expired`

The draft row is in `checkout_drafts`. The resource exposes `create`, `attach_order`, `get_by_checkout_key`, and read actions. The observed creation path writes `open`; no scoped code path was found that writes `consumed` or `expired`, and no draft transition actions exist.

Payment waiting and completion states are held by the related Order, not by CheckoutDraft:

- `Order.pending_payment` is the normal waiting state.
- `Order.pending_provider_setup` covers local/provider-reference setup and recovery.
- `Order.paid`, `Order.payment_failed`, or `Order.cancelled` describe the related Order outcome.

The `get_draft_for_user/2` response maps `status` from the checkout summary’s Order state, while the underlying `CheckoutDraft.status` remains the separate draft value. This means a checkout-facing response can expose an Order state under a field named `status` without changing the draft row.

### Transitions and operations

| Action/operation | From | To | Guard | Side Effects | Tests |
|---|---|---|---|---|---|
| `start_from_cart/3` | no draft | draft `open`; Order `pending_payment` | Active cart, non-empty items, published Product/active Variant, resolvable active attachment, one currency, membership duplicate checks, and typed start input. | One PostgreSQL transaction locks cart/items, calls `Store.Orders.begin_checkout/2`, and inserts or reuses the draft. Order checkout key and `(cart_id, cart_version)` identities make repeats return `duplicate?`. Notifications are sent after commit. | [`checkout/domain_test.exs`](../../test/store/checkout/domain_test.exs), checkout interlock/governance tests, LiveView tests |
| `start_from_cart/3` provider setup handoff | draft remains `open`; Order `pending_payment` -> `pending_provider_setup` -> `pending_payment` | Order-only transition | Local PaymentIntent is created/reused, provider reference is absent, and provider setup is requested. | `Store.Payments.create_intent_for_order/3` begins provider setup, calls provider outside the local state transaction, stores provider refs, submits the local PaymentIntent, and returns Order to `pending_payment`. Recovery worker repeats local reconciliation for recoverable setup rows. | [`expire_pending_provider_setup_orders_worker_test.exs`](../../test/store/workers/expire_pending_provider_setup_orders_worker_test.exs), payment/provider tests |
| `set_shipping/3` | draft `open` | draft `open` | User/system checkout access; server-generated quote options; submitted selected method/hash must match the current quote. | Reads/quotes shipping, stores address/method/quote evidence on the Order. Shipping quote uses Cachex -> Redis -> rule/database path. No draft status transition. | [`checkout/domain_test.exs`](../../test/store/checkout/domain_test.exs), LiveView checkout tests |
| `finalize_totals/3` | draft `open` | draft `open` | Cart/version still matches; current sellability, plan, currency, pricing, shipping/tax evidence, and inventory are valid. | Transaction locks cart/items/order, writes immutable line/adjustment snapshots, reserves inventory, writes tax/shipping evidence, and sets `Order.totals_finalized_at`. Repeated finalization returns the existing finalized result. | checkout domain, immutable snapshot, interlock, and performance tests |
| Payment completion | draft remains observed as `open` | related Order `paid` | Verified provider receipt, matching finalized amount/currency, payable Order state, and apply-once boundary. | Payment worker updates PaymentIntent/Order and reservations, then enqueues downstream workers. No CheckoutDraft consumption was found. | webhook controller/worker and payment interlock tests |
| Cancellation | draft remains `open` | related Order `cancelled` | Order cancellation action permits only `pending_payment` or `pending_provider_setup`; system/admin/support policy as defined by Order. | Clears provider-setup timestamp and releases reservations through the order facade where used. No draft status update. | state-machine and pending-provider-setup tests |
| Expiration | draft remains `open` | related Order `cancelled` for stale provider setup | `provider_setup_started_at` exceeds sweep TTL; worker recovery is attempted first. | `ExpirePendingProviderSetupOrdersWorker` reconciles recoverable provider setup, then `Store.Orders.sweep_stale_pending_provider_setup/2` locks rows, releases reservations, cancels stale Orders, and emits notifications/PubSub. No draft expiration write. | [`expire_pending_provider_setup_orders_worker_test.exs`](../../test/store/workers/expire_pending_provider_setup_orders_worker_test.exs), LiveView expired-checkout test |

### Transaction, idempotency, and replay behavior

Checkout start and total finalization use explicit `Repo.transaction/1` blocks with row locks. Order creation is keyed by checkout key; draft creation is keyed by checkout key and cart version. Unique conflicts are re-read and resolved as duplicates. Total finalization checks `totals_finalized_at` and snapshot/reservation identities to make repeat calls return existing evidence.

The browser return/cancel routes read checkout/order state only. They do not prove payment, mark an Order paid, cancel a PaymentIntent, or create a Subscription. Provider state enters the domain through the verified receipt worker path.

### Terminal States

There is no executable CheckoutDraft terminal transition. `consumed` and `expired` are declared enum values without an observed writer in this scope. Related Order states can be terminal, but the draft row does not follow them.

Performance and security evidence: PostgreSQL is the checkout source of truth; Cart and Order locks protect high-velocity writes. Shipping quotes use Cachex/Redis with application TTLs, and stored quote evidence is rechecked. No CheckoutDraft cache or PubSub state channel was found. Checkout accepts user-controlled cart tokens, checkout keys, variant/plan selections, quantities, addresses, and quote selection, but current catalog/order data is re-read and server-side quote evidence is required. Provider calls are outside the web controller and payment boundary.

## 8. Order Lifecycle

### Current executable states

`Store.Orders.Types.OrderState` and the `orders.state` database check constraint define:

- `pending_payment`
- `pending_provider_setup`
- `paid`
- `payment_failed`
- `cancelled`
- `refunded`

`Order.version` starts at 1 and is the default optimistic-lock attribute for `TransitionState`.

### Transitions

| Action | From | To | Guard | Side Effects | Tests |
|---|---|---|---|---|---|
| `begin_checkout` | none | `pending_payment` | Checkout key/order identity and typed order input; Order resource policy is system/admin. | Generates an `order_ref` when absent; upserts by unique checkout key. Checkout supplies line-item contract inputs in its surrounding transaction. | [`state_machines_test.exs`](../../test/store/governance/state_machines_test.exs), checkout tests |
| `begin_provider_setup` | `pending_payment` | `pending_provider_setup` | System/provider-setup flow; Order transition table permits this source. | Sets `provider_setup_started_at` and applies version lock; order notification/PubSub is emitted by payment domain on success. | [`state_machines_test.exs`](../../test/store/governance/state_machines_test.exs), pending-provider-setup worker tests |
| `refresh_provider_setup` | `pending_provider_setup` | `pending_provider_setup` | System setup-recovery/request path; no state transition helper, only timestamp update. | Refreshes `provider_setup_started_at`; payment domain emits a provider-setup-refreshed state notification. | pending-provider-setup tests |
| `provider_setup_ready` | `pending_provider_setup` | `pending_payment` | System path after local provider reference reconciliation. | Clears `provider_setup_started_at`, increments version through transition helper, and emits an order state notification. | [`state_machines_test.exs`](../../test/store/governance/state_machines_test.exs), payment domain tests |
| `mark_paid` | `pending_payment` or `pending_provider_setup` | `paid` | Verified provider success plus payable Order state; system action. | Clears provider-setup timestamp; payment interlock inserts `PaymentApplication` with `ON CONFLICT DO NOTHING`, marks PaymentIntent succeeded, marks Order paid, consumes reservations, notifies/broadcasts, and enqueues fulfillment, digital grants, subscriptions, and order receipt after commit. | state-machine, payment interlock, webhook, worker, and integration tests |
| `mark_payment_failed` | `pending_payment` or `pending_provider_setup` | `payment_failed` | System/admin action exists in resource policy. | Clears provider-setup timestamp. A scoped search found no normal provider-failure call site invoking this Order action; normal payment failure updates PaymentIntent and renewal state instead. | [`state_machines_test.exs`](../../test/store/governance/state_machines_test.exs); no normal failure integration proof found |
| `cancel` | `pending_payment` or `pending_provider_setup` | `cancelled` | System/admin/support capability as enforced by facade/resource policy; current state must be payable/setup. | Clears provider-setup timestamp; stale provider-setup sweep releases reservations before/with cancellation. | state-machine and pending-provider-setup tests |
| `mark_refunded` | `paid` | `refunded` | Successful refund finalization and remaining refundable amount reaches zero; system action. | Refund callback creates immutable `RefundAdjustment`; full refund changes Order to refunded, while partial refund leaves Order paid. Digital revocation may be applied for digital lines. | [`refund_semantics_test.exs`](../../test/store/governance/refund_semantics_test.exs), refund worker/digital revocation tests |

`TransitionState` treats a request whose current state already equals the target as a success/no-op before consulting the transition table. Thus replaying `mark_paid`, `mark_payment_failed`, `cancel`, or `mark_refunded` at the target state does not bump `version`. Other forbidden source/target pairs return `INVALID_STATE_TRANSITION`; a stale version returns the normalized stale-record error.

### Refund supporting lifecycle

Refund state is separate from Order state. `Store.Payments.Refund` uses:

- `requested`
- `submitted`
- `succeeded`
- `failed`
- `cancelled`

The allowed transitions are `requested -> submitted`, `requested|submitted -> succeeded`, `requested|submitted -> failed`, and `requested|submitted -> cancelled`. Refunds have their own `version` lock, idempotency key, provider-ref identity, and admin/super-admin step-up requirement for requests. The current provider adapters do not expose outbound refund creation; completion is driven by an inbound refund event. `Order.refunded` is reached only when the refund total exhausts the refundable amount.

### Terminal States

Under the exposed state transitions:

- `paid` can still move to `refunded`.
- `pending_payment` and `pending_provider_setup` can move to `paid`, `payment_failed`, or `cancelled`.
- `payment_failed`, `cancelled`, and `refunded` have no outgoing transition other than same-target replay no-op behavior.

The database does not express a separate terminal marker. Non-state evidence updates remain possible through the resource/domain actions where accepted.

### Governance Drift

[`docs/governance/state_machines.md`](../governance/state_machines.md) is explicitly authoritative for Orders and Payments, but it does not match the executable Order resource.

| Documented state/transition | Actual state/transition | Impact | Recommended future correction |
|---|---|---|---|
| Order states: `pending_payment`, `paid`, `cancelled`, `refunded` | Code and migration also expose `pending_provider_setup` and `payment_failed`. | Consumers reading governance alone can reject valid setup/failure states or misclassify pending orders. | Update the governance lifecycle table to the executable state set after a separate lifecycle decision. |
| Governance says `pending_payment -> paid` is the payment success path | Code allows `pending_payment` and `pending_provider_setup -> paid`. | Provider setup recovery and payment completion are not represented in the documented transition graph. | Record the provider-setup branch and its recovery policy. |
| Governance says every lifecycle write uses optimistic locking | Order does use `version`; this statement does not cover the Subscription resource, which explicitly disables its lock, and generic non-state evidence updates vary by action. | A repository-wide assumption about locking is false for part of this vertical slice. | Reconcile the rule with each resource’s executable locking strategy. |

This drift is recorded, not corrected, in this task.

Performance and security evidence: Order, snapshots, PaymentApplication, and reservations are PostgreSQL source-of-truth rows. Order/payment success has no read cache; state indexes, unique identities, `version`, row locks, and apply-once SQL protect the hot path. Payment success emits Order PubSub/state notifications and enqueues downstream Oban jobs after commit. Order lifecycle mutations are system/admin controlled; customer reads are self-scoped, and refund request uses a recent step-up for admin/super-admin.

## 9. PaymentIntent Lifecycle

### States

`Store.Payments.PaymentIntent` uses `Store.Payments.Types.PaymentIntentState` and `payment_intents.state`:

- `created`
- `submitted`
- `requires_action`
- `succeeded`
- `failed`
- `cancelled`

The resource starts in `created` and has `version` optimistic locking. Canonical provider receipts additionally carry `:unknown`, but `unknown` is not a PaymentIntent state.

### Transitions

| Transition | Provider trigger | Domain action | Idempotency behavior | Replay handling | Terminal status |
|---|---|---|---|---|---|
| `created -> submitted` | Local provider intent/reference creation or renewal off-session request reaches local submission. | `PaymentIntent.submit` through `Store.Payments`/subscription renewal facade. | `payment_intent_key` create-or-reuse identity; renewal uses `renewal:<renewal_key>`. | `maybe_submit_payment_intent` accepts already `submitted`, `requires_action`, or `succeeded`; other states fail closed. Transition helper same-target replay is a no-op. | No |
| `submitted -> requires_action` | Stripe `payment_intent.requires_action` or `payment_intent.requires_confirmation`; renewal response may return `requires_action`. | `mark_requires_action`. | Provider event, PaymentAttempt, and ProviderEvent identities dedupe receipt processing. | Already `requires_action` is a no-op; renewal reservation is released and the Subscription is put past due for authentication-required responses. | No |
| `submitted -> succeeded` or `requires_action -> succeeded` | Verified canonical `succeeded`: Stripe checkout/session completion, `payment_intent.succeeded`, `charge.succeeded`, or setup-intent success. | `mark_succeeded`; for order intents, `apply_payment_success_once`; for setup-purpose intents, stored-payment-method handler. | PaymentApplication `paid_apply:order:<id>` uses SQL `ON CONFLICT DO NOTHING`; provider event/attempt and receipt identities dedupe inputs. | Already succeeded is a no-op. A normal order success applies Order/reservation/subscription side effects only at the apply-once boundary. | Yes |
| `submitted -> failed` or `requires_action -> failed` | Verified canonical failure such as Stripe payment failure, charge failure, setup failure, or a synchronous renewal decline. | `mark_failed`; renewal path also releases reservations and records RenewalAttempt/Subscription dunning state. | Receipt/provider-event/payment-attempt identities; local state action is replay-safe for already failed. | `maybe_mark_payment_intent_failed` returns no-op for `failed` and no-op for states outside failed-transitionable states. Normal initial-payment failure does not call Order `mark_payment_failed` in the observed path. | Yes |
| `created|submitted|requires_action -> cancelled` | Stripe `setup_intent.canceled` is normalized as failure but special-cased to local cancellation; explicit system/admin cancel action is also present. | `cancel`. | Already cancelled is a no-op in canonical processing. | No transition from succeeded/failed; same-target replay is no-op. | Yes |

### Provider and webhook handling

The implemented provider is Stripe. Its adapter verifies the raw body and `stripe-signature`, normalizes provider payloads into `CanonicalReceipt`, and maps event types in [`lib/store/payments/providers/stripe.ex`](../../lib/store/payments/providers/stripe.ex). PayFast, Paystack, Yoco, and Peach Payments are resolver-known but operational methods return not-implemented/disabled errors; their capability maps do not prove lifecycle support.

The controller boundary is:

```text
raw body + headers
  -> provider signature verification and canonical normalization
  -> verified WebhookReceipt ingest/upsert
  -> one Oban processing job for a new receipt
  -> worker/facade state transition
```

`WebhookReceipt` itself has string fields `verification_status` (`verified`/other observed values) and `processing_status` (`new`, `processing`, `processed`, `failed`). Receipt ingestion is unique by idempotency key and provider/event identity; processing marks `processing`, treats `ok`/discard as `processed`, and marks errors `failed`. `ProcessWebhookReceiptWorker` retries up to 10 times. The main webhook route selects `ProcessRefundWebhookReceiptWorker` for refund-like event names; the payment callback route always enqueues `ProcessWebhookReceiptWorker`.

### Terminal status and financial guards

`succeeded`, `failed`, and `cancelled` are terminal under the PaymentIntent transition table. The payment worker requires a verified receipt, resolves a local intent through provider/session/payment/local ids, verifies the provider and canonical target, and for normal order payment checks receipt amount and currency against finalized Order totals. Payment state transitions and setup-method updates require system context or admin policy; browser return/cancel routes are read-only.

Performance and security evidence: PaymentIntent, receipt, ProviderEvent, PaymentAttempt, and PaymentApplication are PostgreSQL source-of-truth records. No payment-state cache was found. Unique keys and indexed provider/order/state columns support lookup; webhook processing is Oban-only after controller receipt persistence. Payment success emits Order state notifications and enqueues subscriptions, digital grants, fulfillment, and receipt email after commit. Webhook ingress is rate-limited and signature-verified against provider-controlled raw input. Provider-controlled ids, amounts, currency, metadata, and event types are replay-sensitive and are not trusted without canonical target and total checks.

## 10. Subscription Lifecycle

This is the highest-priority lifecycle in the slice. The resource is [`Store.Subscriptions.Subscription`](../../lib/store/subscriptions/subscription.ex); orchestration is concentrated in [`Store.Subscriptions.Facade`](../../lib/store/subscriptions/facade.ex), with scheduling helpers in [`Store.Subscriptions.Scheduler`](../../lib/store/subscriptions/scheduler.ex).

### States

`Store.Subscriptions.Types.SubscriptionStatus` and `subscriptions.status` define:

- `pending`
- `active`
- `past_due`
- `canceled`
- `expired`

The resource declares an AshStateMachine with `pending` as its initial state. The actual paid-order creation path accepts `status: :active` in `create_from_order_line`, so initial activation normally creates an active Subscription directly rather than persisting `pending` first.

The Subscription has no `version` attribute. Every observed state transition passes `lock_attribute: nil` to `TransitionState`. `TransitionState` still makes a same-target state request a no-op, but the Subscription transition itself does not use optimistic locking.

### Transitions

| Transition | Guard | Trigger | Side Effects | Retry Safe | Concurrency Risk |
|---|---|---|---|---|---|
| Create from paid initial order: none -> `active` | Paid Order, authenticated `order.user_id`, subscription line snapshot, succeeded PaymentIntent, enabled provider/capabilities, and unique source OrderLineItem. | `EnsureSubscriptionsForPaidOrderWorker` calls `create_subscriptions_from_paid_order_for_system/1`. | Transaction upserts StoredPaymentMethod, creates Subscription and SubscriptionItem, sends post-commit notifications, then issues EntitlementGrant after the transaction. | Yes for source-line identity; repeat returns skipped and does not issue a second grant because grant issue is unique. | No Subscription version lock; entitlement issue is after the subscription transaction, so cancellation/retry can overlap with downstream grant issue. |
| `pending -> active` (`activate_now`) | Ash transition allows `pending` or `past_due`; system/admin policy. Action clears past-due/dunning fields and accepts period fields. | Explicit resource/facade activation path; no initial paid-order call site using this action was found. | Sets active and clears `past_due_since_at`, billing reason, retry/suppression fields. | Same-target no-op at state layer; no version lock. | Concurrent dunning/cancellation can write the same Subscription without optimistic locking. |
| `active -> past_due` (`mark_past_due_transition`) | System context; state machine permits only active. | Renewal payment failure, missing payment method/provider, catalog/attachment/inventory/shipping blocker, or authentication-required response. | Sets `past_due_since_at` if absent, billing reason, dunning count, `next_retry_at`; hard blockers set `retry_suppressed_at`. When a `RenewalAttempt` exists it is marked failed; reservations are released when a payment intent has been created. | Same-target state replay is a no-op for the state change, but accepted failure metadata can still be updated. Dunning count/retry values are not protected by a Subscription version. | Renewal vs cancellation, duplicate failure workers, webhook vs local response, and simultaneous failure paths can race. |
| `past_due -> active` (`extend_period`) | Paid renewal Order, matching RenewalAttempt, succeeded PaymentIntent, reconcilable attempt, effective active plan/variant attachment, and matching order/attempt ids. | `ReconcilePaidSubscriptionRenewalWorker` after payment success apply-once. | Advances period, applies pending plan/variant/amount/currency, clears pending changes and dunning fields, syncs entitlement, then marks attempt succeeded. | Yes: already-succeeded attempt returns noop; PaymentApplication and unique attempt keys prevent duplicate paid extensions. | Reconciliation does not use a Subscription version; cancellation or another reconciliation can interleave with the period update. |
| `active -> active` (`extend_period`) | Same paid-renewal guards as above. | Successful renewal from an active subscription. | Same period/contract/entitlement effects as past-due recovery. | Yes through RenewalAttempt/PaymentApplication identities. | Same no-lock Subscription risk. |
| `active -> canceled` (`cancel_now_transition`) | User owns Subscription or admin/system policy; facade capability permits active/past_due, resource transition also permits pending. | Customer/admin cancel-now. | Sets `canceled_at`/`ended_at`, clears renewal/retry fields and period-end flag, revokes all subscription grants, and enqueues membership access-ended email when applicable. | Same-target state replay is no-op, but no version lock. Repeated grant revocation is effectively no-op per grant errors/count behavior. | Renewal can have already claimed an attempt or created a provider charge while cancel-now runs; no broad race test found. |
| `past_due -> canceled` (`cancel_now_transition`) | Same cancellation actor guard. | Customer/admin cancel-now during dunning. | Same immediate revocation and renewal suppression effects. | State replay no-op; grant revoke scans current grants. | Dunning worker can update past-due fields concurrently; no Subscription lock. |
| `pending -> canceled` (`cancel_now_transition`) | Resource state table permits it; facade action capabilities do not expose cancel-now for pending in its current capability map. | Direct system/admin resource use is possible; user facade is more restrictive. | Sets cancellation timestamps and clears retry fields. | Same-target no-op; no version lock. | Difference between resource transition table and facade capabilities is an ownership/behavior boundary. |
| `active -> expired` (`mark_expired_transition`) | System path when grace/retry exhaustion is reached; state machine permits active or past_due. | Expiry helper or retry exhaustion. | Sets ended timestamp, clears renewal/retry fields, revokes subscription grants, and enqueues membership access-ended email. | No version lock; repeated expiration from expired is not an allowed transition, though same-target helper behavior depends on action invocation. | Expiry vs paid webhook reconciliation can race; no focused test found. |
| `past_due -> expired` (`mark_expired_transition`) | `past_due_since_at` plus plan grace window reached, or dunning attempt count exceeds plan max. | Renewal worker/tick. | Same grant revocation and access-ended effects. | Renewal due query excludes retry-suppressed subscriptions; expiry is deterministic when the worker observes the grace boundary. | No Subscription lock; worker only acts on a current read. |
| Queue plan change | No Subscription state change. Facade permits active/past_due and validates target plan/variant attachment. | User/admin plan or variant change facade. | Stores pending ids, pending renewal amount/currency, and `change_effective_at`; a past-due hard suppression can be cleared and an immediate retry enqueued. | Same pending contract is treated as a no-op; update has no version lock. | Queue change vs renewal effective-contract read can race. |
| Payment-method recovery | No Subscription state change unless it schedules retry. | Verified setup-purpose PaymentIntent success. | Creates/reuses active StoredPaymentMethod, sets provider refs, clears billing failure metadata, and may enqueue immediate renewal retry for past_due. | Setup PaymentIntent and stored-method identity are reusable; update path is transaction-wrapped. | Stored-method update and renewal charge can overlap; Subscription reference write has no version lock. |

### Renewal and dunning behavior

`Subscription.read_due_for_system` selects:

- `active` rows with `next_renewal_at <= now`; or
- `past_due` rows with no `retry_suppressed_at` and a null/due `next_retry_at`,

and excludes `cancel_at_period_end == true`.

`Scheduler.initial_period/2` starts a period from the creation time. `next_period/2` advances day/month/year cadence with anchor and timezone behavior. `renewal_key/2` is `sub:<subscription_id>:end:<period_end_iso8601>`. `Scheduler.next_retry_at/3` reads plan retry schedule but clamps every retry offset to at least 24 hours, so the plan default `[0, 24, 72]` does not produce an immediate retry in the current implementation. Grace expiry is `past_due_since_at + grace_period_days`.

The worker path is:

```text
RunDueSubscriptionRenewalsWorker
  -> ProcessSubscriptionRenewalWorker
  -> RenewalAttempt claim
  -> renewal Order + PaymentIntent + optional inventory reservation
  -> Stripe off-session charge
  -> verified payment receipt / apply-once Order payment
  -> ReconcilePaidSubscriptionRenewalWorker
  -> extend Subscription + sync EntitlementGrant
```

Missing payment method, disabled provider, unavailable variant/attachment, inventory failure, missing physical shipping profile, shipping unavailability, or a shipping cost surge move the Subscription toward `past_due`. Hard reasons such as `VARIANT_UNAVAILABLE`, `VARIANT_PLAN_UNAVAILABLE`, `SHIPPING_PROFILE_MISSING`, `SHIPPING_UNAVAILABLE`, and `SHIPPING_COST_SURGE` set retry suppression. Retry exhaustion or grace expiry uses `expired` in code.

### Cancellation and plan changes

`cancel_at_period_end` only sets a boolean flag. It does not change `status`, `canceled_at`, or `ended_at`; due selection excludes the row, and no scoped worker was found that performs a period-boundary status transition. The Subscription can therefore remain `active` after its period/entitlement validity ends. `cancel_now` performs the actual `canceled` state transition and immediate grant revocation.

Plan and variant changes are queued as pending ids and price/currency snapshots and are promoted at successful renewal reconciliation. There is no observed proration path. The current contract is based on the pending plan/variant pair at the renewal boundary.

`term_mode`, `term_cycles`, `term_end_at`, `access_on_past_due`, and `access_on_cancel` are stored/validated on SubscriptionPlan but are not copied to Subscription and were not found in the observed renewal/access transition code. The executable lifecycle therefore uses grace/expiration and grant validity independently of those declared policy values.

### Terminal States

`canceled` and `expired` have no outgoing transitions in the Subscription state machine. `pending`, `active`, and `past_due` have the outgoing transitions listed above. `cancel_at_period_end: true` is not a state and does not create a terminal status.

### Security and performance evidence

Subscription lifecycle writes are system-context actions or admin/user facade actions with ownership checks. Initial activation requires an authenticated user even though the order/checkout model can represent guests. Renewal is system/Oban-only. Provider customer/payment-method refs are used only after verified setup/payment flows. Membership duplicate checks use user id and membership key.

Subscription, RenewalAttempt, Order, PaymentIntent, and EntitlementGrant are persisted in PostgreSQL. Due scans use subscription status/time indexes and bounded limits. No Subscription or RenewalAttempt cache was found; Redis use in this path is telemetry/warm infrastructure, not subscription state. Oban workers provide async scheduling, uniqueness, retry, and post-webhook reconciliation. Paid renewal reconciliation invalidates the Entitlement Cachex key and broadcasts the user entitlement topic. Subscription transition telemetry records renewal/dunning outcomes; no transition-level PubSub event for every Subscription state was found.

## 11. RenewalAttempt Lifecycle

### States and transitions

`Store.Subscriptions.RenewalAttempt` uses `Store.Subscriptions.Types.RenewalAttemptStatus`:

- `pending`
- `processing`
- `succeeded`
- `failed`

The `renewal_attempts.status` database check constraint matches these four values. There is no `suppressed` state. Suppression is represented on Subscription by `retry_suppressed_at`.

| Operation | From | To | Guard/trigger | Side Effects and retry behavior |
|---|---|---|---|---|
| `create_or_reuse` | none | `pending` | One Subscription and deterministic `renewal_key` for a billing period; unique `(subscription_id, renewal_key)`. | Upsert has no mutable fields and returns skipped existing rows. Duplicate due ticks reuse the same attempt. |
| `claim_renewal_attempt` | `pending` or `failed` | operationally claimed; status is set later by `mark_processing` | Raw SQL compare-and-set requires matching `updated_at` and status in `pending`/`failed`. | One concurrent caller wins; others receive `already_claimed` and return noop. Claim itself changes `updated_at` but not status. |
| `mark_processing` | pending/failed operational record | `processing` | System renewal path after renewal Order/PaymentIntent association. | Stores Order and PaymentIntent ids. It can be called again by current renewal orchestration; no version field exists. |
| `mark_failed` | processing or prior attempt | `failed` | Renewal charge/setup/contract/fulfillment error. | Stores failure code/message and increments `attempt_no`. The helper ignores update errors. Failed attempts can be claimed again by the CAS path. |
| `mark_succeeded` | processing/failed operational record | `succeeded` | Paid renewal Order, matching attempt/payment, successful reconciliation. | Clears failure fields and stores Order/PaymentIntent ids. Reconcile returns noop if the attempt is already succeeded. |

### Duplicate prevention and workers

`RunDueSubscriptionRenewalsWorker` is unique for 55 seconds by worker/queue and enqueues per-subscription `ProcessSubscriptionRenewalWorker` jobs unique by worker/args. The process worker has max five attempts. `RenewalAttempt` uniqueness is the durable period-level guard; its claim compare-and-set is the observed concurrency guard. `ReconcilePaidSubscriptionRenewalWorker` is unique by worker/args and also checks attempt/order/payment identity.

Tests include [`subscriptions_uniqueness_test.exs`](../../test/store/governance/subscriptions_uniqueness_test.exs), [`replay_concurrency_test.exs`](../../test/store/subscriptions/replay_concurrency_test.exs), renewal facade tests, and [`subscriptions_run_due_renewals_worker_test.exs`](../../test/store/workers/subscriptions_run_due_renewals_worker_test.exs). No separate suppression-state test exists because suppression is not a RenewalAttempt state.

Performance and security evidence: RenewalAttempt rows and indexes are PostgreSQL-backed; no cache or PubSub state cache is used. Due queries are bounded by a limit of up to 500; worker fan-out is Oban. Renewal keys and worker args are replay-sensitive system inputs and are validated against the current Subscription period before processing.

## 12. Entitlement Lifecycle

### States and transitions

`Store.Entitlements.EntitlementGrant` uses `Store.Entitlements.Types.EntitlementStatus`:

- `active`
- `revoked`
- `expired`

The database column is `entitlement_grants.status`; `valid_from_at`, `valid_to_at`, `revoked_at`, and `revoked_reason` carry additional access evidence. There is no AshStateMachine declaration.

| Operation | From | To | Guard/trigger | Side Effects | Tests |
|---|---|---|---|---|---|
| `issue` | none or existing unique grant | `active` | System subscription path; plan must provide entitlement kind and scope; unique `(user_id, kind, scope_key, source_kind, source_id)`. | Upserts active status and validity window; invalidates local user cache and broadcasts entitlement invalidation after write. Initial issue is invoked after the Subscription transaction. | [`entitlements/facade_test.exs`](../../test/store/entitlements/facade_test.exs), subscription facade/uniqueness tests |
| `revoke` | active or any loaded grant | `revoked` | System or admin policy; subscription source scan for cancellation/expiration/refund coupling. | Sets status and `revoked_at` if absent, records reason, invalidates local cache and broadcasts per user when changes are found. | entitlement facade, subscription grace/cancel, refund digital revocation tests |
| `expire` | any row through explicit resource action | `expired` | Resource action accepts no arguments and is system/admin policy; no current-state guard was found. | Sets status expired. Direct facade call to this action was not found in the main subscription path; time validity also expires access at read time. | Entitlement tests exercise expiration/validity behavior; no broad transition test found |
| Validity evaluation | row remains `active` | access denied at evaluation time | `EntitlementSet.effective_grants/2` requires active status, `valid_from_at <= now`, `valid_to_at` nil or in future, and nil `revoked_at`. | No database state write is required for time expiry. | entitlement facade tests |

### Subscription dependency and access evaluation

Subscription creation issues a grant only when the plan has `entitlement_kind` and `entitlement_scope_key`. `valid_to_at` is set to the Subscription current-period end. Successful renewal upserts the grant with the renewed validity. Cancel-now and grace-expired Subscription paths revoke all grants whose source is the Subscription. Refund handling has a separate line-scoped Digital coupling; the main grant revoke path is subscription-source based.

Access reads are served by `Entitlements.Facade.entitlement_set_for_user/1`. `Entitlements.Cache` uses Cachex with a 60-second TTL, 30-second expiration interval, lazy expiration, and a per-user key `user:<user_id>`. Cache misses read active grants from PostgreSQL and build effective scopes. Issue/revoke paths delete the local key and broadcast `{:entitlements_invalidated, ...}` on `store:entitlements:<user_id>` after the durable write. Subscription/account LiveViews consume this invalidation path. No Redis entitlement cache was found.

### Terminal States

`revoked` and `expired` are terminal in the observed access meaning: `effective_grants/2` excludes them. The resource actions do not enforce a formal state graph; `issue` is an upsert that can write `active` on an existing unique row, so the database/resource declaration does not make revocation irreversible. Time expiry can deny access while the row’s status remains `active` until an explicit revoke/expire write occurs.

### Security and performance evidence

Grant writes are system or admin/super-admin policy actions; user reads are self-filtered. The trust boundary is Subscription/plan data becoming access authority. Cache invalidation is explicit on grant issue/revoke, but the after-transaction initial issue means a paid Order can exist before a grant exists. The cache’s TTL gives a bounded stale-read window if an invalidation fails; no stampede lock beyond Cachex fetch behavior was found. Grant reads use user/kind/scope/status and validity indexes.

## 13. Cross-Domain Lifecycle Events

The following are observed cross-domain effects. They are not a proposed event model.

| Event or operation | Current sequence and responsible modules | Transaction/worker boundary | Current source of truth, cache, invalidation, and PubSub |
|---|---|---|---|
| Sellable subscription purchase selection | Published Product/active Variant reads in `Store.Catalog`; active attachment/plan resolution and membership duplicate checks in `Store.Subscriptions.Facade`; Cart mutation in `Store.Carts.Facade`. | Cart item add/update uses PostgreSQL transaction/locks; no worker. | Product/Variant/attachment/plan rows are PostgreSQL. Catalog has Cachex/Redis/ETS reads and invalidates on catalog mutations; Cart has no cache/PubSub. Stock ETS is a precheck only. |
| Checkout starts | `Store.Checkout.start_from_cart/3` locks cart/items, calls `Store.Orders.begin_checkout`, creates/reuses `CheckoutDraft`, and returns checkout key/order ref. | One checkout-start `Repo.transaction/1`; post-commit Ash notifications. | Cart, draft, Order, and line/snapshot data are PostgreSQL. Draft/order are not cached; shipping quote cache is not used until shipping selection. |
| Totals finalized | `Store.Checkout.finalize_totals/3` revalidates catalog/plan/pricing, writes OrderLineItem/adjustment snapshots, reserves inventory, and finalizes Order totals. | Explicit transaction locks Cart/Items/Order; reservation code has lock ordering and unique keys. | PostgreSQL snapshots/reservations are authoritative. Shipping quote Cachex -> Redis -> source and quote evidence are rechecked; no checkout PubSub. |
| PaymentIntent submitted | `Store.Payments.Facade.create_intent_for_order/3` creates/reuses local PaymentIntent, begins Order provider setup, calls Stripe/provider boundary, stores refs, submits local intent, and returns Order to pending payment. | Provider HTTP is outside the local state transition transaction; provider-setup recovery is Oban. | PaymentIntent/Order/provider refs are PostgreSQL; no payment cache/PubSub state cache. Webhook receipt is persisted before worker processing. |
| Payment succeeded | Verified provider receipt -> `WebhookReceipt` -> `ProviderEvent`/`PaymentAttempt` -> `PaymentIntent` success. Normal order path calls `Interlocks.apply_payment_success_once/2`. | `PaymentApplication`/PI/Order/reservation changes are in one transaction; notifications and downstream Oban jobs occur after commit. | PostgreSQL payment/order/reservation evidence. No payment cache. Order state notification/PubSub, plus `EnsureSubscriptionsForPaidOrderWorker`, Digital, Fulfillment, and receipt email jobs. |
| Initial Subscription activation | `EnsureSubscriptionsForPaidOrderWorker` -> `SubscriptionsFacade.create_subscriptions_from_paid_order_for_system/1`. | Stored method/Subscription/SubscriptionItem transaction; post-commit notifications; Entitlement issue occurs after that transaction. | Subscription and stored method are PostgreSQL; no Subscription cache/PubSub state cache. Entitlement issue invalidates Cachex and broadcasts user topic. |
| Entitlement granted | `EntitlementsFacade.issue_subscription_entitlement_for_system/2` upserts plan-configured grant. | Called after Subscription transaction in initial path; renewal sync occurs during reconciliation path. | EntitlementGrant is PostgreSQL; Cachex per-user key deleted and entitlement PubSub broadcast emitted after write. |
| Renewal due | Oban cron `RunDueSubscriptionRenewalsWorker` reads bounded due subscriptions and enqueues jittered `ProcessSubscriptionRenewalWorker`. | Oban scheduling/fan-out; no inline controller path. | Subscription status/time rows and indexes are PostgreSQL. No Subscription cache; Oban uniqueness and RenewalAttempt identity protect duplicates. |
| Renewal charge | `Subscriptions.Facade` creates/reuses RenewalAttempt, virtual renewal Order, PaymentIntent, optional physical reservation/shipping evidence, then invokes Stripe off-session charge. | Renewal Order/PaymentIntent creation and reservation writes are domain transactions/actions; provider HTTP is outside the local DB transaction. | PostgreSQL renewal/Order/PI/reservation evidence. No renewal cache; reservation and payment failure paths invalidate stock/availability caches through inventory services. |
| Renewal payment succeeded | Webhook applies PaymentIntent/Order once, then enqueues `ReconcilePaidSubscriptionRenewalWorker`. | Reconciliation validates paid Order/attempt, extends Subscription, syncs Entitlement, and marks attempt succeeded. | PostgreSQL is source of truth. Entitlement Cachex key invalidated and user PubSub broadcast; no Subscription cache. |
| Renewal failure/dunning | Synchronous or webhook failure marks PaymentIntent failed/requires action, releases renewal reservation, marks RenewalAttempt failed, and marks Subscription past due or suppressed. | Worker retry and Oban max attempts; payment receipt still finishes through receipt worker. | PostgreSQL PI/attempt/subscription/reservation rows. No payment/subscription cache; authentication-required path enqueues Comms email. |
| Grace expiration | Due renewal worker calls `mark_expired_transition` when grace is reached or retry count is exhausted. | Oban worker/system facade; revoke/email follow state update. | Subscription and grants are PostgreSQL; grant cache invalidated and entitlement PubSub emitted; membership access-ended email is queued. |
| Cancel now | User/admin subscription facade calls `cancel_now_transition`, then entitlement revoke and membership email. | Subscription write is separate from grant revoke; no cross-domain transaction was found. | Subscription/Grant PostgreSQL rows, Entitlement Cachex invalidation/PubSub. No cancellation worker. |
| Refund confirmed | Refund webhook worker finalizes Refund, creates RefundAdjustment, possibly marks Order refunded and applies Digital revocation. | Refund receipt processing is Oban; refund/order/adjustment effects are not one universal resource transaction in the worker source. | Refund/Order/Adjustment PostgreSQL; no payment cache. Digital grant/download state has its own worker/coupling; no Subscription entitlement transition was found for refund. |

The most significant observed cross-domain boundary is payment success. It is the point at which Order, PaymentIntent, inventory reservations, subscriptions, entitlements, fulfillment/digital work, PubSub notifications, and email workers become coupled. A failure after the paid transaction can leave a paid Order before every downstream action has completed.

## 14. Concurrency and Race Analysis

This section records possible races and current protections. “Missing evidence” means no focused proof was found; it is not a code change recommendation.

| Lifecycle/race | Existing protections | Missing protection or uncertainty | Tests |
|---|---|---|---|
| Cart mutation vs checkout start | Cart/item `FOR UPDATE`, active-cart predicates, Cart version, checkout draft/order unique identities, checkout revalidation. | No single test was found covering every add/remove operation racing with checkout finalization and verifying the user-visible retry contract. | Cart facade, checkout domain, checkout interlock tests |
| Guest cart merge vs user cart creation/merge | User/guest cart row locks, active user/token unique indexes, deterministic binary UUID item ordering, version predicate on guest abandonment, repeat merge noop. | Merge creates/reloads on uniqueness conflict; broad multi-cart stress beyond focused tests is not evident. | Cart facade and lock-order tests |
| Duplicate checkout start | Transaction locks cart/items; unique `(cart_id, cart_version)`, unique checkout key, Order `begin_checkout` upsert. | CheckoutDraft status is not used to gate a second start; it relies on order/draft identity and related Order state. | checkout domain/interlock and LiveView tests |
| Provider setup request vs request crash/retry | Order `pending_provider_setup`, provider refs, PaymentIntent create/reuse, local reconciliation, stale setup recovery worker, Order version. | Provider HTTP and local state are separate boundaries; exact external provider outcome after process loss can require recovery evidence not available locally. | provider fault-isolation, provider task, pending setup worker tests |
| Duplicate payment webhook vs retry worker | Receipt idempotency, ProviderEvent/PaymentAttempt identities, PaymentApplication SQL `ON CONFLICT`, PI/Order version locks, Oban uniqueness. | Callback route sends refund-like events to the general payment worker rather than the refund worker; the effect for non-Stripe/generic callback payloads is not proven. | webhook controller/worker, idempotency, Stripe tests |
| Payment success vs Order cancellation | `maybe_mark_order_paid` permits only pending/setup states; Order transition/version rejects invalid/stale updates. | A provider can report success after local cancellation; the resulting financial reconciliation/error behavior is not a complete end-to-end contract in the tests. | state-machine and webhook tests; no full race test found |
| Renewal tick duplication | Unique `(subscription_id, renewal_key)`, Oban unique worker args, RenewalAttempt `updated_at` CAS claim, bounded due query. | Subscription itself is not locked while a due row is selected and processed. | [`replay_concurrency_test.exs`](../../test/store/subscriptions/replay_concurrency_test.exs), renewal worker tests |
| Renewal vs cancel-now | Due selection excludes canceled/period-end rows when read; cancel clears next renewal fields. | No Subscription version/row lock; a worker that already read an active Subscription can continue creating a renewal while cancellation commits. No broad race test found. | Focused renewal/cancel tests are distributed; no direct race proof found |
| Renewal vs plan/variant change | Effective contract reads pending ids and validates active attachment/catalog before charge; reconciliation promotes pending values only after paid renewal. | Queue and renewal reads/writes use no Subscription version; pending contract can be changed while a charge is in flight. | plan/variant change tests and renewal reconciliation tests |
| Renewal payment success vs grace expiry | Paid Order and RenewalAttempt matching checks; attempt already succeeded returns noop; expiry requires current observed grace boundary. | No Subscription lock or compare-and-set around expiry vs reconciliation; no direct race test found. | grace expiry and replay tests, but not this race |
| Renewal payment failure vs webhook success | Payment/ProviderEvent/PaymentApplication identities prevent duplicate Order payment application; renewal reconciliation requires paid Order and matching attempt. | Subscription past-due metadata and paid extension are separate writes with no Subscription version; ordering under concurrent failure/success is not fully proven. | renewal worker, webhook, and replay tests |
| Entitlement issue vs revoke | Unique source grant identity, upsert, cache invalidation after writes, Subscription source scan. | Initial issue is after Subscription transaction; no common lock/transaction covers Subscription cancellation and grant issue, and no grant/revoke race test was found. | entitlement uniqueness/cache and subscription grace/cancel tests |
| Entitlement cache vs grant mutation | Local Cachex delete and per-user PubSub invalidation after grant issue/revoke; 60-second TTL; Cachex fetch coalescing. | A failed invalidation/broadcast can leave a stale local value until TTL; no distributed cache invalidation was found because there is no Redis entitlement cache. | entitlement facade/cache tests |
| Product/Variant archival vs checkout/renewal read | Checkout revalidates published/active catalog; renewal validates active Variant/Product and active attachment. | No Product/Variant version lock; reads can cross an admin mutation boundary. Plan status is not consistently filtered in system option/renewal reads. | catalog lifecycle/availability and renewal unavailable-variant tests |

High-velocity persistence/cache/worker summary:

- Cart mutations are PostgreSQL lock/version operations. There is no Cart cache or Cart PubSub; ETS stock prechecks are invalidated but are not authoritative.
- Payment events are PostgreSQL receipt/evidence/state operations. There is no payment-state cache; controllers persist receipts and enqueue workers, and apply-once/order notifications happen after durable transaction work.
- Renewal is PostgreSQL due/attempt/order/payment state plus Oban fan-out and retry. There is no Subscription cache or transition PubSub cache; entitlement invalidation is the downstream cache effect.
- Entitlement changes are PostgreSQL grant writes plus Cachex delete and user PubSub invalidation. Access evaluation can still use a cached set for up to the configured TTL if invalidation fails.

Elevated-trust transitions include Product/Plan/Variant administration, Order cancellation/refund, PaymentIntent reconciliation, Subscription system activation/renewal/expiration, and Entitlement issue/revoke. Resource policies and system contexts are the current enforcement. The repository has policy-matrix tests and selected step-up tests; a general audit record for every privileged lifecycle transition was not found.

## 15. Lifecycle Extraction Readiness

These classifications describe the current lifecycle boundary, coupling, and evidence quality. They are not target architecture recommendations.

| Lifecycle | Classification | Why |
|---|---|---|
| Product | PARTIAL | Publication actions, visibility predicates, policies, cache invalidation, and tests are clear. No versioning exists, base variant/inventory creation is coupled to Product, and catalog sellability continues into cart/checkout/inventory. |
| Cart | PARTIAL | Cart state, item operations, ownership, merge, unique indexes, row locks, version behavior, and tests are identifiable. Cart mutation directly invokes catalog and membership policy, has no explicit expiration/conversion lifecycle, and has application-specific token/guest semantics. |
| Checkout | NOT READY | Checkout owns cart snapshotting, plan resolution, pricing, shipping/tax, Order creation, reservations, provider setup handoff, and direct SQL/lock orchestration. CheckoutDraft declares unexecuted states and the draft/order lifecycle is split across resources. |
| Order | PARTIAL | The state machine, version lock, snapshot resources, payment apply-once boundary, reservation integration, policy shape, and tests are explicit. The executable state set drifts from governance, payment/subscription/fulfillment/digital effects are coupled, and normal payment failure does not use the declared failure transition in the observed path. |
| Payment | NOT READY | Receipt-first processing, Stripe normalization, idempotency, version locks, and webhook tests are substantial. Four configured providers are scaffold-only, refund outbound behavior is absent, callback routing differs from the webhook route, and payment success coordinates several downstream domains. |
| Subscription | NOT READY | Activation, stored payment methods, renewal, dunning, plan/variant changes, physical shipping, inventory, payments, entitlements, comms, and worker orchestration are concentrated in a large facade. Subscription transitions lack optimistic locking, term/access fields are dormant in observed code, period-end cancellation is incomplete, and provider/membership/application assumptions are embedded. |
| Entitlement | PARTIAL | Grant identity, validity evaluation, system/admin policy, Cachex single-flight caching, PubSub invalidation, and focused tests form a recognizable access boundary. The initial issue is post-transaction, row status can remain active after time validity ends, and the implementation is coupled to Subscription-derived scopes and application LiveViews. |

The registry therefore establishes current lifecycle truth for later hardening work without treating declared but unused states, governance rules, or provider capability maps as executable behavior.

### Evidence consulted

Primary implementation evidence:

- Catalog: [`lib/store/catalog/product.ex`](../../lib/store/catalog/product.ex), [`variant.ex`](../../lib/store/catalog/variant.ex), [`facade.ex`](../../lib/store/catalog/facade.ex), and status types.
- Cart/checkout: [`lib/store/carts`](../../lib/store/carts), [`lib/store/checkout`](../../lib/store/checkout), and checkout inputs/facades.
- Orders/payments: [`lib/store/orders/order.ex`](../../lib/store/orders/order.ex), [`lib/store/orders/domain.ex`](../../lib/store/orders/domain.ex), [`lib/store/payments/payment_intent.ex`](../../lib/store/payments/payment_intent.ex), [`lib/store/payments/interlocks.ex`](../../lib/store/payments/interlocks.ex), [`lib/store/payments/facade.ex`](../../lib/store/payments/facade.ex), refund resources, provider adapters, and webhook controllers.
- Subscriptions/entitlements: [`lib/store/subscriptions/subscription.ex`](../../lib/store/subscriptions/subscription.ex), [`facade.ex`](../../lib/store/subscriptions/facade.ex), [`scheduler.ex`](../../lib/store/subscriptions/scheduler.ex), RenewalAttempt, StoredPaymentMethod, and [`lib/store/entitlements`](../../lib/store/entitlements).
- Workers: [`lib/store/workers`](../../lib/store/workers), especially paid-order subscription creation, webhook processing, provider-setup expiry/recovery, renewal fan-out/processing/reconciliation, and evidence purge.

Database evidence came from the Phase 19/20/21/26/27/27A migrations under [`priv/repo/migrations`](../../priv/repo/migrations), including state check constraints, foreign keys, unique identities, partial in-flight payment indexes, renewal uniqueness, subscription due/retry indexes, and entitlement lookup indexes.

Test evidence came from [`test/store/governance/state_machines_test.exs`](../../test/store/governance/state_machines_test.exs), catalog/cart/checkout/payment/subscription/entitlement suites, webhook and renewal worker suites, [`test/store/subscriptions/replay_concurrency_test.exs`](../../test/store/subscriptions/replay_concurrency_test.exs), and related LiveView/integration tests.

Governance comparison used [`docs/governance/state_machines.md`](../governance/state_machines.md), [`subscription_scheduling_terms.md`](../governance/subscription_scheduling_terms.md), [`checkout_interlocks.md`](../governance/checkout_interlocks.md), [`idempotency.md`](../governance/idempotency.md), [`refund_semantics.md`](../governance/refund_semantics.md), [`payment_provider_contract.md`](../governance/payment_provider_contract.md), [`policy_matrix.md`](../governance/policy_matrix.md), and [`performance_scaling.md`](../governance/performance_scaling.md).
