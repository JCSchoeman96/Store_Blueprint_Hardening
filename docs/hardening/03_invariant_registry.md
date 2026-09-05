# Store_Blueprint Subscription Commerce Invariant Registry

# 1. Purpose

This registry records the business, data, security, lifecycle, and concurrency rules that are observable in the current Subscription Commerce V1 implementation. An invariant is a condition that the implementation currently preserves, or a condition that the commerce flow depends on but for which the inspected implementation does not provide complete protection.

This is a current-state record. Executable code, database constraints, and tests are the primary evidence. Governance documents are compared with executable behaviour, but they do not override it. `FACT` marks a guarantee or behaviour found in source, schema, or tests. `GAP` marks protection that was not found in the inspected scope. A gap statement means that no reliable enforcement was found; it does not claim that every possible code path in the repository has been exhaustively disproven.

The registry exists because a subscription-commerce extraction cannot preserve correctness if money, ownership, state, payment evidence, retries, or access grants have implicit ownership. Future hardening and extraction work use these entries as the correctness baseline. This document does not redesign the implementation or prescribe a fix.

Primary evidence includes:

- Domain resources and facades under `lib/store/catalog/`, `lib/store/carts/`, `lib/store/checkout/`, `lib/store/orders/`, `lib/store/payments/`, `lib/store/subscriptions/`, and `lib/store/entitlements/`.
- Persistence definitions and constraints under `priv/repo/migrations/`.
- Lifecycle, replay, concurrency, policy, pricing, snapshot, and performance tests under `test/store/` and `test/store_web/`.
- Governance comparisons in `docs/governance/state_machines.md`, `idempotency.md`, `inventory_reservations.md`, `checkout_interlocks.md`, `payment_provider_contract.md`, `pricing_determinism.md`, `immutable_snapshots.md`, `performance_scaling.md`, and `policy_matrix.md`.

# 2. Invariant Summary

| Invariant | Domain | Enforcement Location | Test Evidence | Extraction Status |
|---|---|---|---|---|
| Monetary values are represented as integer minor units with a currency value. | Pricing, catalog, orders, payments, subscriptions | `Store.Pricing.Contract`, pricing evaluator, resource attributes and database checks | `test/store/governance/pricing_determinism_test.exs` | PARTIAL |
| A pricing evaluation is deterministic for the same inputs and evaluation time. | Pricing | `Store.Pricing.Evaluator`, binary UUID ordering, explicit `as_of` | `test/store/governance/pricing_determinism_test.exs` | READY |
| Order line and adjustment snapshots are append-only evidence. | Orders | `Store.Orders.OrderLineItem`, `OrderAdjustment`, `SnapshotWriter` | `test/store/governance/immutable_snapshots_test.exs` | READY |
| An active cart is owned by one authenticated user or bearer guest token, and an authenticated user has at most one active cart. | Carts | `Store.Carts.Facade`, cart policies, partial unique indexes | `test/store/carts/facade_test.exs` | PARTIAL |
| Cart changes advance a version and checkout reads an exact active cart version. | Carts, checkout | `Store.Carts.Facade` row locks and compare-and-set update; `Store.Checkout.Domain` exact-version lock | `test/store/carts/facade_test.exs`, `test/store/checkout/domain_test.exs` | PARTIAL |
| A checkout key and cart/version pair identify one checkout draft and one initial order linkage. | Checkout | Unique `checkout_drafts` and `orders` indexes; checkout conflict handling | `test/store/checkout/domain_test.exs` | PARTIAL |
| A payment success must match the finalized order amount and currency before the paid interlock runs. | Payments, orders | `Store.Payments.Interlocks` canonical receipt validation | `test/store/governance/checkout_interlocks_test.exs`, payment webhook tests | READY |
| A payment intent has an explicit state graph and a version-locked transition path; the database limits submitted/requires-action intents per order. | Payments | `Store.Payments.PaymentIntent`, `TransitionState`, partial in-flight index | `test/store/governance/state_machines_test.exs`, payment tests | READY |
| Webhook and provider evidence has durable uniqueness, but processing is not a compare-and-set lifecycle claim. | Payments | `WebhookReceipt` and `ProviderEvent` identities; `Store.Payments.Facade` processing functions | `test/store/governance/idempotency_transitions_test.exs`, webhook worker tests | NOT READY |
| Paid side effects are guarded by one durable order-level `PaymentApplication`. | Payments, orders, inventory, subscriptions, entitlements | `Store.Payments.Interlocks.apply_payment_success_once/2` and `PaymentApplication` unique key | `test/store/governance/checkout_interlocks_test.exs`, webhook replay tests | PARTIAL |
| One order/variant inventory reservation exists and reservation counters are updated under row locks. | Inventory, orders | `InventoryReservation` identities, `InventoryReservations` SQL locks and counter checks | `test/store/governance/inventory_reservations_test.exs` | PARTIAL |
| Subscription creation is unique by source order line and is initiated only after a paid order/payment path. | Subscriptions, payments, orders | `Store.Subscriptions.Facade`, subscription source identity | `test/store/subscriptions/facade_test.exs`, `checkout_subscription_only_test.exs` | PARTIAL |
| A renewal key is unique per subscription and billing period, and the worker claims pending work with a SQL compare-and-set. | Subscriptions | `RenewalAttempt` unique identity; `Store.Subscriptions.Facade` renewal claim; Oban worker uniqueness | `test/store/subscriptions/replay_concurrency_test.exs` | PARTIAL |
| Stored renewal price and currency are carried on the subscription and pending plan changes are promoted on paid renewal. | Subscriptions, pricing | Subscription fields and renewal reconciliation | `test/store/subscriptions/facade_test.exs` | PARTIAL |
| Effective entitlement access is derived from active, unrevoked, unexpired grants. | Entitlements | `Store.Entitlements.Cache` and `Store.Entitlements.Facade` | `test/store/entitlements/facade_test.exs` | PARTIAL |
| Subscription entitlement grants are unique and cache invalidation is emitted after grant changes. | Entitlements, subscriptions | Grant identity, Cachex invalidation, PubSub broadcast | `test/store/entitlements/facade_test.exs` | PARTIAL |
| Formal state-machine transitions reject forbidden state movement and replay the same state without a version bump. | Orders, payments, refunds, inventory | `Store.Support.Governance.TransitionState`, AshStateMachine resources | `test/store/governance/state_machines_test.exs`, `idempotency_transitions_test.exs` | PARTIAL |
| Webhook controllers verify provider input and enqueue system processing; return/cancel routes do not establish payment proof. | Payments, web boundary | `WebhookController`, `PaymentCallbackController`, provider adapters, rate-limit plug | webhook controller and payment callback tests | PARTIAL |

# 3. Money and Pricing Invariants

## Integer money and explicit currency

**FACT:** The pricing contract uses integer minor-unit fields for quantities, unit prices, line totals, discounts, tax, shipping, and grand totals. Catalog variants and subscription plans store `price_minor` or `amount_minor` together with a currency value. Orders, payment intents, subscription renewal fields, and payment/refund evidence use integer amount fields and currency fields.

The enforcement locations are `lib/store/pricing/contract.ex`, `lib/store/pricing/evaluator.ex`, `lib/store/catalog/variant.ex`, `lib/store/subscriptions/subscription_plan.ex`, `lib/store/orders/order.ex`, `lib/store/payments/payment_intent.ex`, `lib/store/payments/refund.ex`, and the corresponding migrations in `priv/repo/migrations/`. Resource validations reject negative monetary values in the inspected catalog, plan, order, payment, and refund paths. The evaluator rejects non-integer or negative line inputs.

**FACT:** Checkout resolves the cart to one currency and returns a mixed-currency error when the variant and plan inputs do not agree. The payment interlock compares the canonical provider amount and currency with the finalized order `grand_total_minor` and `currency_code` before applying payment success.

**GAP:** The pricing contract requires an explicit currency value but the evaluator itself validates a non-empty currency string rather than independently proving a complete ISO-4217 code. Resource fields commonly constrain the value to three characters. The effective guarantee therefore depends on the resource and checkout validation path used.

If this invariant breaks, totals, provider charges, refunds, or renewal charges can represent different monetary values. Existing tests include deterministic pricing, integer arithmetic, currency handling, refund amount validation, and checkout/payment interlock checks in `test/store/governance/pricing_determinism_test.exs`, `test/store/governance/checkout_interlocks_test.exs`, and payment/refund tests.

## Deterministic pricing

**FACT:** `Store.Pricing.Evaluator` is a pure evaluator. It sorts lines by binary UUID/id and line number, applies eligibility at an explicit `as_of` time, caps discounts at the subtotal, and allocates proportional discounts with integer division and deterministic remainder assignment. It does not read or write the database.

The persisted pricing domain obtains current catalog, promotion, coupon, tax, and shipping inputs and passes them into the evaluator. The checkout domain stores the resulting evidence rather than relying on a later recomputation for the order payment check.

The invariant is protected by evaluator tests for ordering, tie breaks, discount allocation, time windows, and repeatability. This is the clearest reusable portion of the pricing behaviour and is classified `READY` in the summary.

## Historical price and snapshot behaviour

**FACT:** `Store.Orders.SnapshotWriter` creates order line and adjustment evidence with product, variant, SKU, title, subscription-plan, unit-price, currency, quantity, tax, and discount values. `OrderLineItem` and `OrderAdjustment` expose create/read actions and have no update or destroy actions. Their database identities prevent duplicate line numbers or adjustment sequence numbers within an order.

**FACT:** Checkout writes a priced snapshot once and records `totals_finalized_at`. A repeated finalization loads the existing snapshot path rather than recalculating the same order from changed catalog data. Tests in `test/store/governance/immutable_snapshots_test.exs` and checkout domain tests protect this behaviour.

**GAP:** The stronger invariant that every order total is immutable immediately after the order reaches `paid` is not fully demonstrated by the resource. The `Order` resource still exposes generic shipping, tax/shipping snapshot, and `finalize_checkout_totals` update actions. No paid-state guard was found in the inspected definitions for every mutable order field. The immutable evidence rows are protected; the immutability of all `Order` columns after payment is not.

## Renewal pricing

**FACT:** A subscription stores `renewal_amount_minor` and `renewal_currency`. Renewal processing uses those stored fields, while a queued plan or variant change stores pending amount and currency fields. A successful paid renewal promotes pending pricing once and clears the pending fields. `test/store/subscriptions/facade_test.exs` covers this promotion.

**FACT:** A subscription plan itself has mutable commercial attributes through its update action. Existing subscription records are not rewritten by the inspected plan/archive paths. The subscription facade checks that the current plan, variant, product, and active variant-plan attachment remain usable for renewal, and it can suppress retries when the current sellable configuration is unavailable.

**GAP:** There is no catalog-wide immutable price-version object in the inspected scope. The current renewal guarantee comes from copying the amount onto `Subscription`, not from immutable `SubscriptionPlan` history. A plan mutation and a subscription renewal therefore have separate data ownership, and the exact effect depends on whether the subscription has a stored renewal amount and whether a pending change is present.

# 4. Product and Catalog Invariants

## Product availability

**FACT:** `Store.Catalog.Product` stores `draft`, `published`, and `archived` status values. Its public read path filters to `published` products with a non-null `published_at`. The product action helpers require `draft` for publish, `published` for unpublish, and `draft` or `published` for archive. Publish sets `published_at`; unpublish clears it; archive sets `archived_at`.

**FACT:** `Store.Checkout.Domain.ensure_published_sellables!/1` and `Store.Carts.Facade` independently require a published product with a publication timestamp before adding or pricing a sellable. Catalog public-read policies and the checkout/cart checks provide two enforcement points.

**GAP:** Product status uses custom validations and update changes rather than an AshStateMachine with a version field. The inspected product action helpers enforce their allowed source states, but the lifecycle is not represented by the common transition authority used by orders and payments.

## Variant validity and availability

**FACT:** `Store.Catalog.Variant` stores `active` and `archived` status values. Active variants require a valid product relationship, valid non-negative price/currency, required option selections, and a unique selection signature within a product when options are used. SKU is unique. An archive action sets the status to archived and synchronizes the selection signature.

Checkout and cart validation require an active variant and a published product. The public catalog read path also filters variants to active status. The variant resource validates that an optional image belongs to the same product.

**GAP:** Variant status and update actions do not use the formal AshStateMachine/optimistic-locking path. The inspected source does not provide a single common transition authority for active-to-archived movement.

## Subscription plan association

**FACT:** `Store.Subscriptions.SubscriptionPlan` stores `active` and `archived` status values through `PlanStatus`, validates interval, anchor, term, retry, and entitlement configuration, and exposes activate/archive actions. Its key is unique. `Store.Subscriptions.VariantSubscriptionPlan` links a variant to a plan and has an `active` boolean.

The database has a unique `(variant_id, subscription_plan_id)` relationship. The later `20260308173000_phase_27_allow_multiple_active_variant_plans.exs` migration drops the earlier unique active-variant index, so more than one active plan can be attached to a variant. Checkout requires a current active plan and active variant-plan association when a plan is selected; when more than one active plan is available, the checkout domain rejects an omitted explicit plan id.

**GAP:** Plan update accepts status and commercial fields without the common transition authority or an optimistic version check. Plan retirement does not delete existing subscription records in the inspected code. Existing subscriptions retain their plan and copied renewal pricing, but renewal availability is checked against the current active plan/variant/product relationship. The result is that plan retirement can leave a subscription record present while preventing or suppressing a future renewal.

## Catalog changes and existing commercial records

**FACT:** No inspected product, variant, or plan archive/unpublish action rewrites historical order line snapshots. No source path was found that rewrites existing subscription rows when a catalog record is archived. Existing order evidence and subscription renewal fields therefore remain separate from current catalog status.

This is a data-preservation invariant for historical orders, not a guarantee that every existing subscription remains renewable. Renewal uses current sellability checks in `Store.Subscriptions.Facade`, so availability and historical-price behaviour are separate rules.

# 5. Cart Invariants

## Ownership and active-cart uniqueness

**FACT:** `Store.Carts.Cart` stores an optional `user_id`, a bearer `token`, `active` or `abandoned` status, and a positive `version`. The database has a partial unique index for one active cart per non-null user and one active cart per token. The cart has a self-reference for a merged cart.

`Store.Carts.Facade.get_cart_for_user/2` uses the authenticated actor id for a signed-in user and the supplied cart token for a guest. The facade verifies that the token belongs to the cart it returns. Cart policies limit authenticated reads to the actor’s cart and permit the system/admin mutation paths used by the facade.

**GAP:** A guest token is a bearer credential. The inspected cart flow does not show a second guest identity or ownership factor. A caller holding the token can access the corresponding guest cart within the current policy model.

## Item validity and duplicate prevention

**FACT:** Cart item quantity is constrained to one through 99. The database prevents duplicate `(cart_id, variant_id)` rows for a non-plan item and duplicate `(cart_id, variant_id, subscription_plan_id)` rows for a planned item. The facade merges a repeated add into the existing item and caps the resulting quantity at the configured maximum rather than inserting a second row.

The facade checks variant activity, product publication, required options, and plan compatibility before creating or updating an item. A cart item’s variant foreign key is restrictive; deleting a referenced variant is not silently allowed by the database.

**GAP:** Add, update, and remove do not use a caller-provided operation idempotency key. Retrying an add request can increase the existing quantity up to the cap. The row is not duplicated, but repeated intent is not necessarily a no-op.

## Version and stale checkout protection

**FACT:** Cart mutations lock the cart and relevant item rows in Postgres, then increment the cart version using an id-plus-current-version predicate. A failed compare-and-set returns a stale-record error. Merge locks the guest and user carts, merges items, marks the guest cart abandoned, and uses a version predicate.

Checkout locks an active cart at an exact requested version and rejects a changed version with `STALE_RECORD`. This prevents a checkout from silently pricing a newer cart than the caller selected. The relevant protections are in `lib/store/carts/facade.ex`, `lib/store/checkout/domain.ex`, and `priv/repo/migrations/20260302194911_phase_20_carts_checkout_drafts.exs`.

**GAP:** `Cart` has no AshStateMachine. Its `abandoned` status is written by the merge path with a direct `Repo.update_all` rather than through a lifecycle transition action. The schema has no `expired` cart state, and no cart-expiration worker or transition was found in the scoped configuration.

## Cart persistence and cache behaviour

Postgres is the cart and cart-item source of truth. Cart reads and mutations do not use a cart cache. The stock precheck uses `Store.Catalog.StockFastPath`, an ETS cache with a short configured TTL and database fallback; it is a precheck and does not replace the locked inventory reservation transaction. Cart mutations do not publish a cart cache invalidation event. No Redis cart state path was found.

Cart concurrency tests cover version increments, no-op behaviour, guest/user merge, and duplicate membership-plan item rules in `test/store/carts/facade_test.exs`. The checkout test suite covers idempotent same-version starts, concurrent starts, and stale/sellability cases.

# 6. Checkout Invariants

## Checkout identity

**FACT:** `Store.Checkout.CheckoutDraft` stores `checkout_key`, `cart_id`, `cart_version`, optional `user_id`, `order_id`, and `open`, `consumed`, or `expired` status. The database has unique indexes on `checkout_key` and `(cart_id, cart_version)`. Orders also carry a unique checkout key.

`Store.Checkout.Domain.start_from_cart/2` locks the active cart and items, validates sellability, creates or reuses the draft/order linkage, and handles uniqueness conflicts by loading the existing checkout. The implementation therefore gives a repeated start for the same logical key/version an idempotent outcome.

**GAP:** The current uniqueness is per checkout key and cart version. A cart version change can produce a new checkout key/version and a new order. The inspected code does not prove the stronger rule that one cart over its entire lifetime can produce only one commercial outcome.

## Draft lifecycle

**FACT:** The database accepts `open`, `consumed`, and `expired` checkout-draft values. The resource defines create, attach-order, and lookup actions.

**GAP:** In the scoped checkout implementation, draft creation writes `open`, and no transition action or writer for `consumed` or `expired` was found. There is no formal state machine, no version field, and no evidence in the inspected paths that payment completion consumes the draft or that a worker expires it. The schema lifecycle is therefore broader than the executable transition surface.

## Transaction and mutation boundary

**FACT:** Checkout start runs in a transaction that locks the cart and items and creates or reuses the draft/order. Priced snapshot and reservation creation runs in a separate transaction that locks the exact cart version, cart items, order, and inventory rows. Snapshot writing, order total finalization, and reservation creation are coordinated in the checkout domain.

Checkout may create/link the checkout draft and order, write order price/tax/shipping evidence and totals, and reserve inventory. It reads and validates catalog and subscription-plan data. The web layer routes through domain facades; payment return/cancel handling is read-only and does not mark an order paid or confirmed.

**GAP:** The initial checkout transaction can create the draft/order linkage before a priced snapshot or reservation exists. This is covered as an explicit current behaviour in `test/store/checkout/domain_test.exs`. The later finalization is the authority for price evidence and inventory reservation, so an `open` draft/order may exist without a completed commercial snapshot.

## Checkout retry and stale-state protection

**FACT:** Unique checkout identities, cart row locks, exact cart-version checks, and idempotent finalization protect the main retry paths. A quote option uses a server-generated quote hash and method validation; tampering with the client-supplied selection is rejected by the checkout domain.

**GAP:** There is no explicit checkout-draft transition claim or completion token. Replay safety is provided by database identities and existing order/snapshot checks rather than a complete draft state machine. Test evidence covers same-version starts, concurrent starts, idempotent finalization, quote tampering, guest/user access, unpublished sellables, and membership eligibility, but not a consumed/expired draft transition because no executable transition was found.

## Checkout data and cache behaviour

Checkout commercial truth is stored in Postgres. The flow uses row locks and indexed uniqueness rather than a checkout cache. Catalog availability and stock fast paths may supply read prechecks; the final reservation uses locked database inventory. No Redis checkout-state cache or PubSub checkout mutation path was found.

# 7. Order Invariants

## Order states and transition authority

**FACT:** `Store.Orders.Order` stores the following executable states:

- `pending_payment`
- `pending_provider_setup`
- `paid`
- `payment_failed`
- `cancelled`
- `refunded`

The AshStateMachine transitions are:

| Transition action | Allowed source | Destination |
|---|---|---|
| `begin_provider_setup` | `pending_payment` | `pending_provider_setup` |
| `provider_setup_ready` | `pending_provider_setup` | `pending_payment` |
| `mark_paid` | `pending_payment`, `pending_provider_setup` | `paid` |
| `mark_payment_failed` | `pending_payment`, `pending_provider_setup` | `payment_failed` |
| `cancel` | `pending_payment`, `pending_provider_setup` | `cancelled` |
| `mark_refunded` | `paid` | `refunded` |

The transition actions use `Store.Support.Governance.TransitionState`, which checks the current state and uses the `version` field for optimistic locking. Same-state replay is treated as a no-op by the helper. Forbidden movement returns the invalid-state error path. The resource and transition tests are in `lib/store/orders/order.ex`, `lib/store/support/governance/transition_state.ex`, and `test/store/governance/state_machines_test.exs`.

## Commercial history and totals

**FACT:** The order stores `currency_code`, item subtotal, shipping total, grand total, and `totals_finalized_at`. Checkout writes line-level product, variant, plan, quantity, and price snapshots through `Store.Orders.SnapshotWriter`. `PaymentApplication` provides a unique order-level paid-application key.

**FACT:** Order line items and adjustments are create/read-only evidence. Refunds add `RefundAdjustment` evidence rather than changing historical order lines. Refund request validation checks amount and currency against payment/order evidence, and the order reaches `refunded` after the refund flow determines that the refundable remainder is exhausted.

**GAP:** The `Order` resource itself has update actions for shipping and totals and the inspected actions do not all require a non-paid source state. The current implementation protects line and adjustment history more strongly than it protects every order column after payment. “Immutable commercial history” is therefore true for the snapshot evidence, but not proven as a blanket rule for the mutable order record.

## Payment relationship

An order can have payment intents, and the payment-intent migration indexes order references and restricts the active in-flight path to one submitted or requires-action intent per order. The payment interlock only marks an order paid after a matching payment intent reaches succeeded and a unique `PaymentApplication` is inserted or observed.

## Governance Drift

| Documented state | Actual executable state | Impact |
|---|---|---|
| `docs/governance/state_machines.md` lists `pending_payment`, `paid`, `cancelled`, and `refunded`. | `OrderState` also contains `pending_provider_setup` and `payment_failed`. | Consumers that use the governance list as exhaustive can reject or fail to model real provider-setup and payment-failure paths. |
| Governance describes the order paid/refunded progression as the primary lifecycle. | The resource permits `pending_provider_setup -> pending_payment`, payment failure from both pending states, and paid from both pending states. | Extraction must preserve the provider-setup and failure branches; simplifying the graph would change current behaviour. |
| Governance requires lifecycle writes to use optimistic locking. | The `Order` formal transitions use a version field, but other order update actions and several other lifecycle resources do not use the same authority. | The rule is not a repository-wide guarantee even where the order state machine itself satisfies it. |

# 8. Payment Invariants

## PaymentIntent

### Identity and amount consistency

**FACT:** `Store.Payments.PaymentIntent` stores `created`, `submitted`, `requires_action`, `succeeded`, `failed`, or `cancelled` state, a version, provider references, amount/currency, purpose, and optional order/subscription references. The domain computes a deterministic payment-intent key from order, amount, currency, and provider. The resource has a unique payment-intent key, partial uniqueness for provider payment/session references, and an index that prevents more than one in-flight `submitted` or `requires_action` intent for an order.

`Store.Payments.Interlocks` preflights existing in-flight/succeeded intents and creates or reuses an intent. Payment success validation uses the finalized order amount and currency rather than trusting a client return parameter or an unverified provider amount.

### State transitions

| Transition | Allowed source | Destination | Protection |
|---|---|---|---|
| `submit` | `created` | `submitted` | `TransitionState` and payment-intent version |
| `mark_requires_action` | `submitted` | `requires_action` | `TransitionState` and payment-intent version |
| `mark_succeeded` | `submitted`, `requires_action` | `succeeded` | `TransitionState`, provider reconciliation, order amount/currency check |
| `mark_failed` | `submitted`, `requires_action` | `failed` | `TransitionState` and payment-intent version |
| `cancel` | `created`, `submitted`, `requires_action` | `cancelled` | `TransitionState` and payment-intent version |

There are no transitions out of `succeeded`, `failed`, or `cancelled` in the state machine. The payment-intent resource, state types, interlock, and tests provide the executable evidence. Same-state replay is handled by the transition helper; provider retries also pass through the interlock.

**FACT:** Provider adapter output is normalized before it reaches the state transition. Provider adapters are restricted to payload construction, signature verification, and normalization. The webhook controller and worker perform the domain transition through the payments surface.

**GAP:** A payment intent has a formal state machine, but the broader payment evidence lifecycle is not formalized. Payment success also invokes an order-level interlock and downstream jobs, so payment-intent state alone is not the complete paid-outcome invariant.

### Governance Drift

`docs/governance/state_machines.md` lists PaymentIntent states as `created`, `submitted`, `succeeded`, `failed`, and `cancelled`. The executable `PaymentIntentState` also contains `requires_action`, and `mark_succeeded`, `mark_failed`, and `cancel` explicitly accept that state. An extraction based only on the governance list would omit the provider authentication branch.

## WebhookReceipt

### Evidence identity and verification

**FACT:** `Store.Payments.WebhookReceipt` stores raw body and headers, provider, idempotency key, payload hash, verification status, processing status, provider event id, event type, processing timestamps, error fields, and evidence purge time. Its identities include the idempotency key and provider/provider-event identity. The `ingest` action is an upsert and returns metadata identifying a skipped duplicate.

The webhook and payment callback controllers verify the raw body and headers with the provider adapter, normalize the receipt input, persist the receipt, and use the duplicate result to avoid enqueueing a second processing job. The processing worker runs with a system context. The receipt purge worker replaces raw evidence after the configured retention period and emits an audit-log entry for the purge path.

### Processing lifecycle and replay

Observed processing values are `new`, `processing`, `processed`, and `failed`; verification is stored separately. The resource has no AshStateMachine, version attribute, or transition-level compare-and-set. `Store.Payments.Facade.mark_processing/1` returns an already-processed receipt unchanged, but otherwise updates a receipt to processing without checking that the prior processing status is exactly `new`.

**FACT:** A processed receipt is not processed again by the normal worker entry point. Failed receipts remain evidence with error details and can enter the processing path again.

**GAP:** Two workers can load the same non-processed receipt and both enter `mark_processing` because the inspected claim has no status predicate or version CAS. Receipt uniqueness prevents duplicate evidence rows, but it does not by itself serialize processing. Tests cover duplicate ingest and worker replay paths; no test proving concurrent receipt claim exclusion was found.

## ProviderEvent

**FACT:** `Store.Payments.ProviderEvent` is an immutable create/upsert evidence resource. It stores provider event id/key, type, payload hashes, and receipt time. The database/resource identity is `(provider, provider_event_id)`. `provider_event_key` has an index but is not a unique identity in the resource shown. There is no state, version, receipt foreign key, or update action.

Duplicate ingestion returns a skipped upsert and the idempotency tests prove that the provider/event identity does not create a second row. Provider event ordering is not represented by a sequence or ordering field, and no ordering assumption was found in the interlock.

**GAP:** `Store.Payments.Interlocks.ingest_provider_event/2` returns the provider-event result/key, but the payment application path proceeds to record a payment attempt and apply the payment outcome without using a duplicate provider-event result as an explicit no-op boundary. Thus the database preserves one ProviderEvent row, while the inspected code does not prove that every duplicate ProviderEvent worker invocation stops before downstream work. The governance idempotency document requires that duplicate ProviderEvent handling be a no-op, which is a documented/executable mismatch.

The actual resource has no `receipt_id` relationship, although `docs/governance/idempotency.md` and `payment_provider_contract.md` describe receipt lineage as a recommended or expected part of the evidence model. This weakens traceability between the verified delivery and normalized provider event.

## PaymentAttempt

**FACT:** `Store.Payments.PaymentAttempt` is immutable interaction evidence rather than a lifecycle state machine. It stores payment intent, provider/event keys, an attempt key, outcome, payload hash, and attempted time. It has unique provider-event-key and attempt-key identities and a create/upsert `record` action with empty upsert fields.

The payment interlock records an attempt before applying the canonical receipt. Uniqueness prevents an identical attempt key from creating a second evidence row. The resource has no processing, retry, or terminal state and no version field.

**GAP:** No dedicated PaymentAttempt test file or direct `PaymentAttempt` test reference was found in the inspected test tree. Existing webhook/payment tests exercise the enclosing flow indirectly, but they do not prove a complete attempt lifecycle, retry policy, or duplicate-provider-event boundary.

## StoredPaymentMethod

**FACT:** `Store.Subscriptions.StoredPaymentMethod` stores active, inactive, or revoked status, provider/customer/payment-method references, fingerprint, and user ownership. Provider/customer/payment-method identity is unique, and lookup indexes include user/status and provider/status. `create_or_reuse` upserts the reference; mark-active, mark-inactive, and mark-revoked actions update the status.

Renewal processing requires an active stored payment method. An absent or non-active method produces the payment-method-required failure path and moves the subscription into dunning handling. `test/store/subscriptions/stored_payment_method_test.exs` covers reuse and status persistence.

**GAP:** Stored payment-method status is not an AshStateMachine and has no version/CAS guard. The inspected mark actions do not encode a transition graph or prove that a revoked method cannot later be marked active by an authorized system action. Provider token values are stored as references; the inspected code does not store raw card credentials.

## Refund and RefundAttempt

**FACT:** `Store.Payments.Refund` has a formal state machine with `requested`, `submitted`, `succeeded`, `failed`, and `cancelled` states. The refund service locks the payment intent while validating the request, checks positive amount and currency, computes refundable remaining value from captured/payment and refund evidence, and uses the request idempotency fingerprint.

Refund provider events are stored in `RefundAttempt`. The resource is create-only and stores refund, provider/event keys, optional provider refund id, outcome, error details, payload hash, timestamp, and sequence number. `(refund_id, sequence_no)` and provider-event-key identities prevent exact duplicate attempt evidence. A successful refund appends a `RefundAdjustment`; the order is moved to `refunded` when no refundable remainder remains. The refund flow can also enqueue digital revocation for relevant products.

**GAP:** RefundAttempt sequence allocation uses the current maximum plus one in the refund service. Concurrent independent attempts can calculate the same next sequence number; the unique constraint is the observed database protection, and no explicit sequence allocation CAS or retry path was found. RefundAttempt has no state lifecycle of its own, so provider submission/retry history is represented as append-only outcome rows rather than enforced transitions.

## Payment side-effect application

**FACT:** The current paid interlock is `Store.Payments.Interlocks.apply_payment_success_once/2`. Inside a Postgres transaction it inserts the unique order-level `PaymentApplication`, transitions the payment intent to succeeded, transitions the order to paid, and consumes order inventory reservations. After commit it publishes/queues fulfillment, digital grants, subscription creation or renewal reconciliation, and the order receipt. The payment interlock also emits payment telemetry.

This means Postgres records payment/order/inventory truth, while Oban jobs and post-commit notifications carry downstream effects. There is no durable `payment_succeeded` event resource in the inspected path. Downstream behaviour is invoked procedurally from the payment module through domain facades.

**GAP:** The durable `PaymentApplication` prevents repeat order-level application, but the `ProviderEvent` duplicate result is not the equivalent top-level gate. Post-commit enqueue failures are logged by the interlock path and do not roll back the already-committed payment/order/inventory transaction. The current implementation therefore has a strong financial interlock and a broader, procedural downstream boundary.

# 9. Subscription Invariants

## Creation

**FACT:** `Store.Subscriptions.Subscription` has a unique source order-line identity. `Store.Subscriptions.Facade` verifies that the source order is paid, the payment intent is succeeded, the source line has a valid subscription plan/variant, and the request is not a renewal order before creating the subscription. Repeating creation for the same source line reuses the existing record. The initial subscription worker is enqueued from the payment-success interlock.

The subscription resource state machine declares `pending` as its default initial state, but the creation facade’s `create_subscription_record` path creates a subscription with `active` status after the paid checks. This is executable current behaviour and is an invariant gap between resource default and creation orchestration.

Entitlement issuance happens after the subscription transaction. If initial entitlement issuance returns an error, the creation path records the outcome as skipped rather than failing the already-created subscription. This can leave a paid active subscription without its expected grant.

## States and lifecycle transitions

The executable status values are:

- `pending`
- `active`
- `past_due`
- `canceled`
- `expired`

The state-machine transitions are:

| Transition | Allowed source | Destination | Current meaning |
|---|---|---|---|
| `activate_now` | `pending`, `past_due` | `active` | Activates or recovers the subscription and clears dunning fields. |
| `mark_past_due_transition` | `active` | `past_due` | Starts payment-failure/dunning status. |
| `cancel_now_transition` | `pending`, `active`, `past_due` | `canceled` | Immediate cancellation, with end/cancellation timestamps and renewal suppression. |
| `mark_expired_transition` | `active`, `past_due` | `expired` | Ends the subscription after the expiry/grace path. |
| `extend_period` | `active`, `past_due` | `active` | Records a successful renewal; active-to-active is a valid transition. |

There is no `canceled -> active`, `expired -> active`, or `canceled -> pending` transition. In the current state machine, `canceled` and `expired` are terminal. `cancel_at_period_end` is a boolean update action, not a status transition. The due-renewal query excludes subscriptions with that flag, but no inspected worker explicitly transitions the record to `canceled` at the period boundary.

**GAP:** Subscription transitions pass `lock_attribute: nil` to `TransitionState`. The subscription status graph is explicit, but its state transitions do not use the optimistic-locking version strategy used by Order, PaymentIntent, Refund, and InventoryReservation. The resource also exposes generic field updates for dunning, pending plan changes, and period fields.

## Activation, cancellation, failure, recovery, and expiry

**FACT:** A payment-success worker creates the initial active subscription after a paid order. Renewal payment failure records a failed RenewalAttempt and moves an active subscription to `past_due`; missing payment methods, disabled providers, hard shipping/cost blockers, and other mapped reasons can suppress retries. A successful paid renewal calls `extend_period` and can recover `past_due` to `active`.

Immediate cancellation calls the cancellation transition, clears renewal scheduling fields, and invokes entitlement revocation. Grace expiry calls the expired transition and invokes entitlement revocation. The current state machine makes cancellation terminal even though the field name is `canceled` and no resume action exists.

**GAP:** Cancellation and expiry call entitlement revocation outside the subscription transition and do not fail the subscription operation when the revocation result is ignored. The subscription state can therefore commit while the access-side effect is unsuccessful or unconfirmed.

## Renewal

**FACT:** Renewals are scheduled by `Store.Subscriptions.Scheduler` and `ProcessSubscriptionRenewalWorker`, with a five-minute cron schedule in application configuration. Due selection uses indexed subscription status/next-renewal fields and excludes canceled-at-period-end records and suppressed dunning records.

`RenewalAttempt` stores `pending`, `processing`, `succeeded`, or `failed` status, subscription, renewal key, period dates, order/payment references, attempt number, failure data, and timestamps. The database identity `(subscription_id, renewal_key)` prevents duplicate logical attempts. The facade claims work with a SQL compare-and-set on status and `updated_at`; only one caller receiving one updated row proceeds from the claim. Oban also applies worker uniqueness for the subscription/period job.

Renewal creates a virtual renewal order and payment intent, reserves inventory for physical renewals, and charges off-session through a stored payment method. A successful provider response waits for webhook reconciliation before extending the subscription. Synchronous payment failure releases the reservation and marks the attempt/subscription failure path. Retryable failures schedule the next attempt; hard failures set retry suppression. The scheduler and facade emit renewal/dunning telemetry.

**FACT:** Renewal uses the subscription’s stored renewal amount/currency and promotes pending plan/variant/pricing only after the paid renewal reconciliation. `test/store/subscriptions/replay_concurrency_test.exs` proves concurrent renewal ticks create one attempt, do not advance the period twice, and leave one processing attempt.

**GAP:** `RenewalAttempt` itself has no state machine or version field. The initial claim is guarded by SQL CAS, but subsequent `mark_processing`, `mark_succeeded`, and `mark_failed` actions are generic updates. The inspected code does not demonstrate a single lock spanning renewal versus cancellation, plan change, and payment webhook reconciliation. Those races remain extraction risks even though duplicate attempt creation is protected.

## Plan, variant, and stored payment method changes

**FACT:** Subscription plan or variant changes are stored as pending fields with pending amount/currency and effective timing. Renewal reconciliation promotes them once after paid renewal. A subscription can store a new stored-payment-method relationship/reference used by later renewal attempts.

**GAP:** The current plan/variant change path is a subscription-field update rather than a separate lifecycle resource or versioned command. It can race with renewal reads because the subscription has no optimistic-lock field in the transition configuration. Stored-payment-method status changes have the same non-formal lifecycle property described in the payment section.

## Subscription data and cache behaviour

Subscription and renewal state are stored in Postgres. Renewal due selection uses indexed queries, and Oban owns scheduling/retry execution. No subscription state cache or Redis billing-state cache was found. Subscription transitions do not publish a subscription cache invalidation event in the inspected path.

The related entitlement cache is updated separately after grant/revoke operations. This creates a cross-domain consistency interval between a committed subscription status change and the cache-backed access decision.

# 10. InventoryReservation Invariants

## Reservation identity and quantity

**FACT:** `Store.Orders.InventoryReservation` stores order, variant, reservation key, non-negative quantity, expiry, terminal timestamps, state, and version. The resource identities prevent more than one reservation for an order/variant pair and prevent reuse of a reservation key. The database checks non-negative quantity and has state/expiry indexes.

Checkout reservation uses a Postgres transaction and a CTE that locks the relevant inventory rows, updates reserved counters, and inserts active reservations. Requests are sorted by binary UUID order. The normal reservation path locks `InventoryItem` and an existing reservation row before calculating the desired quantity delta. This protects stock and reserved-count arithmetic under simultaneous reservations.

## State and terminal behaviour

The executable reservation states are:

- `active`
- `consumed`
- `expired`
- `cancelled`

The declared AshStateMachine permits `active -> consumed`, `active -> expired`, and `active -> cancelled`. Terminal states have no declared outgoing transition. Consume, release, and expiry services treat already-terminal reservations as no-ops and adjust inventory counters only when the reservation is active. Reservation expiry is scheduled by `ExpireInventoryReservationsWorker` and uses `FOR UPDATE SKIP LOCKED` before decrementing inventory.

The reservation TTL is 15 minutes in the inspected checkout/reservation configuration. Expiry, consume, and release paths invalidate stock and product availability fast paths after database work.

## Lifecycle authority violation

**FACT:** `InventoryReservation` has a formal state machine and version field.

**GAP:** `Store.Orders.InventoryReservations` also has a private `update_reservation/2` path that uses `Repo.update_all`, directly writes the target state and terminal fields, and increments the version. The checkout CTE directly inserts rows with `state = active`. The consume, release, and expiry paths also use raw updates after their own state checks. These operations are serialized by transactions and row locks, but they bypass the Ash transition action and its common transition authority.

The result is that database locking and counter arithmetic are stronger than the lifecycle-authority guarantee. A service-level caller can reach the raw mutation helper without executing the resource transition action’s declared transition graph. This is covered as a known gap in `docs/hardening/02_1_lifecycle_registry_gaps.md`; no implementation change is made here.

## Reservation failure consequences and tests

An incorrect reservation quantity or missing row lock can oversell inventory or leave `reserved_count` inconsistent with active reservation quantities. The current tests cover one-last-unit contention, same-order idempotency, quantity deltas, one-time expiry release, one-time consume, one-time release, and refusal to consume expired reservations in `test/store/governance/inventory_reservations_test.exs`.

Postgres is the inventory and reservation source of truth. ETS `StockFastPath` and `AvailabilityCache` are read caches only. Reservation changes invalidate the affected variant/product cache entries; no Redis reservation authority was found.

# 11. Entitlement Invariants

## Grant identity and states

**FACT:** `Store.Entitlements.EntitlementGrant` stores `active`, `revoked`, or `expired` status, user, kind, scope, source subscription, validity dates, and revocation reason. A database/resource identity makes a grant unique for the user/kind/scope/source combination. The source subscription relationship uses a foreign key with cascade behaviour in the inspected migration.

The resource does not declare an AshStateMachine or version field. `issue` is an upsert that can refresh validity on an existing grant. `revoke_all_for_source` and expiration update grant status through generic updates.

## Creation and dependency on subscriptions

**FACT:** `Store.Entitlements.Facade.issue_subscription_entitlement_for_system/2` requires the subscription plan to provide entitlement kind and scope. It uses the subscription period end as the grant validity boundary, creates/reuses the grant, and invalidates the user’s entitlement cache after a successful write. Initial subscription creation invokes this facade after commit; renewal reconciliation synchronizes entitlement validity after a successful period update.

**FACT:** Immediate cancellation and grace expiry invoke source-grant revocation. Expiry evaluation also treats a grant with a `valid_to` in the past as ineffective, even if the status has not yet been updated to `expired`.

**GAP:** Initial entitlement issuance errors are converted to a skipped result during subscription creation. Cancellation and expiry paths ignore the revoke result. The current implementation therefore does not prove the stronger invariant that every paid/active subscription has a durable active grant or that every canceled/expired subscription has a completed revoke before the operation returns.

## Access evaluation and cache

`Store.Entitlements.Cache` returns effective grants by filtering status, revocation, and validity. It uses Cachex with a 60-second TTL and a 30-second sweep interval, coalesces concurrent misses, and invalidates local entries plus the entitlement PubSub topic after writes. `test/store/entitlements/facade_test.exs` covers upsert/validity refresh, revoke-all, cache evaluation/invalidation, concurrent cache misses, and expiration invalidation.

**FACT:** The entitlement evaluator only returns access evidence represented by effective grants.

**GAP:** The inspected entitlement module does not itself prove that every application access path is gated by this evaluator. The digital-download path has separate `DownloadGrant` controls. No global access-without-grant assertion was found for every possible subscription-protected feature.

## Entitlement consistency and concurrency

Grant uniqueness protects duplicate issue requests, and cache invalidation reduces stale reads after successful writes. There is no grant version/CAS or transaction spanning revoke-all and all grant rows. Revoke-all reads matching grants and updates them individually; an individual update failure is represented in the returned count/error handling rather than atomically rolling back all source grants.

The grant row and subscription remain Postgres truth. Cachex is an access-read optimization and is not a billing or entitlement authority.

# 12. Lifecycle Authority Invariants

## Current protection

**FACT:** The common `Store.Support.Governance.TransitionState` helper checks current state, accepts an already-equal target as a replay/no-op, and delegates allowed transitions to AshStateMachine. With the default configuration it uses an optimistic lock on `version` and maps stale writes to the repository stale-record error. The formal state-machine resources in the scoped slice are Order, PaymentIntent, Refund, InventoryReservation, and Subscription.

**FACT:** Order, PaymentIntent, Refund, and InventoryReservation declare explicit transition graphs and version fields. Tests cover allowed transitions, forbidden transitions, replay/no-op behaviour, and stale-record handling for the governed resources. The subscription graph is explicit but passes `lock_attribute: nil`, so it does not have the same version protection.

**FACT:** Provider adapters do not call `Repo`, Ash actions, or Oban. Webhook controllers verify and normalize provider input, persist a receipt, and enqueue a worker. System workers call domain facades. These boundaries prevent a provider adapter or controller from directly applying an order/subscription transition.

## Governance comparison

The governance documents describe stronger uniform guarantees than the current executable paths provide:

- `docs/governance/state_machines.md` requires lifecycle writes to use optimistic locking. Order, PaymentIntent, Refund, and InventoryReservation formal transitions have version fields, but Subscription transitions set `lock_attribute: nil`, and non-state-machine lifecycle records have no shared version guard.
- `docs/governance/inventory_reservations.md` describes transition-only state changes. `Store.Orders.InventoryReservations` directly updates reservation state with `Repo.update_all` and inserts active state from its checkout CTE.
- `docs/governance/idempotency.md` requires duplicate ProviderEvent processing to be a no-op. The current payment interlock persists one ProviderEvent row but does not use the skipped-upsert result as a complete downstream no-op gate.
- `docs/governance/idempotency.md` and `docs/governance/payment_provider_contract.md` describe receipt lineage for normalized provider evidence. `ProviderEvent` has no `receipt_id` field or foreign key in the current resource/migration.

## Lifecycle-bearing records without formal transition authority

The following resources have lifecycle-like state/status fields but do not declare the common AshStateMachine:

- `Product`: custom current-state validation in publish/unpublish/archive actions.
- `Variant`: active/archive status and custom validation.
- `SubscriptionPlan`: active/archive status and generic update fields.
- `Cart`: active/abandoned status.
- `CheckoutDraft`: open/consumed/expired status, with only open creation observed.
- `WebhookReceipt`: verification and processing statuses.
- `ProviderEvent`: immutable evidence with no state.
- `PaymentAttempt`: immutable outcome evidence with no state.
- `StoredPaymentMethod`: active/inactive/revoked status.
- `RenewalAttempt`: pending/processing/succeeded/failed status.
- `EntitlementGrant`: active/revoked/expired status.

Their values may be constrained by resource types, policies, identities, or generic update actions, but they do not share the same explicit transition graph and lock semantics.

## Confirmed bypasses and hidden side effects

**FACT:** `Store.Orders.InventoryReservations` directly mutates reservation state with `Repo.update_all` and inserts active reservations from a CTE. This bypasses the resource’s declared transition actions.

**FACT:** Cart merge directly marks the guest cart abandoned with a `Repo.update_all` predicate. Cart has no formal state machine, so this is a direct status mutation rather than a bypass of a declared graph.

**FACT:** Payment success directly coordinates PaymentIntent, Order, InventoryReservation, and durable `PaymentApplication` work in `Store.Payments.Interlocks`, then calls or enqueues fulfillment, digital grants, subscription creation/reconciliation, and order receipt work. Subscription code directly invokes payment, order, entitlement, pricing, shipping, and communications services for renewal and cancellation paths.

**GAP:** The current implementation does not provide one durable domain event boundary between payment success and every downstream domain. Some downstream failures happen after commit and are logged or returned independently. This makes side-effect ownership and replay semantics broader than the payment-intent state transition.

## Consistency after failure

Formal order/payment/refund/inventory transition writes occur through Ash actions and, where used by the interlock, inside database transactions. The paid interlock rolls back its transaction if its transactional transition work fails.

**GAP:** Post-commit jobs and entitlement calls are not part of the same transaction. A committed paid order can therefore coexist temporarily or permanently with an unprocessed downstream subscription, entitlement, fulfillment, digital grant, or receipt job if enqueue/processing fails. The inspected code contains retry workers for several jobs, but no single invariant proves completion of all downstream effects.

# 13. Concurrency Invariants

## Checkout

### Existing protection

- Cart and cart-item rows are locked in checkout start and pricing finalization.
- Cart version updates use an id-plus-version compare-and-set.
- Checkout drafts and orders have unique checkout keys and cart/version identities.
- Inventory reservations use a separate locked transaction and all-or-nothing counter update.
- Checkout quote options are validated against a server-generated quote hash.

### Evidence and remaining risk

`test/store/checkout/domain_test.exs` covers idempotent same-version starts, parallel start outcomes, stale cart rejection, snapshot/reservation idempotency, quote tampering, guest isolation, and sellability. `test/store/carts/facade_test.exs` covers version and merge concurrency behaviour.

**GAP:** Checkout drafts have no claim/version transition. A cart version can create another checkout outcome, and the initial draft/order linkage can exist before priced evidence. Add retries are not operation-key idempotent. The current protection is `PARTIAL`, not a proof of one lifetime-cart commercial outcome.

## Payments

### Existing protection

- Webhook receipt identities prevent duplicate receipt rows.
- Provider/event identities prevent duplicate provider evidence rows.
- PaymentAttempt and RefundAttempt identities preserve duplicate-attempt constraints.
- One in-flight PaymentIntent per order is protected by a partial unique index.
- PaymentIntent and Order transitions use version-locked Ash state-machine actions.
- `PaymentApplication` has a unique application key and is inserted in the paid interlock transaction.
- Webhook input is signature-verified before system processing, and webhook routes have the configured rate-limit plug.

### Evidence and remaining risk

Payment replay, receipt duplicate, provider-event uniqueness, and paid interlock behaviour are covered by governance/payment/webhook tests. `test/store/subscriptions/replay_concurrency_test.exs` also exercises renewal payment reconciliation indirectly.

**GAP:** Webhook processing claim is not a status/version CAS. Duplicate ProviderEvent results do not form an explicit no-op gate in the observed application path. Duplicate downstream enqueue or post-commit processing is protected by a mix of Oban uniqueness and domain idempotency, not by one complete payment-evidence state machine.

## Subscriptions

### Existing protection

- Source order-line uniqueness prevents duplicate initial subscriptions.
- RenewalAttempt `(subscription_id, renewal_key)` uniqueness prevents duplicate logical periods.
- Renewal claim uses a SQL compare-and-set on attempt status and timestamp.
- Process-renewal Oban jobs use worker uniqueness.
- Provider webhook reconciliation waits for payment success before extending the period.
- Stored renewal amount/currency and pending plan-change fields preserve the current renewal quote.
- Retry schedules, dunning count, next retry, and retry suppression are stored durably.

### Evidence and remaining risk

The subscription facade tests cover creation replay, due renewals, missing payment methods, provider failures, pricing promotion, dunning, grace expiry, physical reservation, and retry suppression. The replay concurrency test proves one renewal attempt under concurrent ticks.

**GAP:** Subscription state transitions have `lock_attribute: nil`. Renewal, cancellation, plan change, and payment reconciliation do not share an observed subscription row lock or version guard. RenewalAttempt later status updates are generic. The current tests do not cover renewal-versus-cancellation, renewal-versus-plan-change, or payment-success-versus-expiry races.

## Inventory

### Existing protection

- Inventory rows and reservation rows are locked in variant UUID binary order.
- Reservation and inventory quantity constraints are enforced in resource/schema/database paths.
- Expiry uses `SKIP LOCKED`; terminal replays are no-ops.
- Unique reservation identities and row locks prevent duplicate active holds for the same order/variant.
- Stock fast-path invalidation happens after reservation, consume, release, and expiry operations.

### Evidence and remaining risk

Concurrency tests cover last-unit contention, idempotent reservation, delta quantities, expiry, consume, and release. The row-lock/counter model is the strongest concurrency boundary in the slice.

**GAP:** Reservation state can still be written through raw updates outside the declared Ash transition actions. A lock protects the specific current service paths, but it does not make the lifecycle authority universal. Expiry versus consume/release is tested for terminal no-op behaviour, not every interleaving with checkout and payment success.

## Entitlements

### Existing protection

- Grant uniqueness and upsert prevent duplicate source grants.
- Cache misses are coalesced.
- Successful issue/revoke/expire operations invalidate local and PubSub-distributed cache entries.

### Evidence and remaining risk

Entitlement tests cover grant upsert, revoke, effective validity, concurrent cache misses, and expiry invalidation.

**GAP:** Grant status writes have no version/CAS and revoke-all is not one atomic transaction over all grants. Grant-versus-revoke and subscription-status-versus-grant races are not directly tested. Cache invalidation is a separate operation from subscription transition, so stale access can remain within the cache TTL if invalidation fails or is not invoked.

# 14. Security Invariants

## Trust boundaries and input classes

| Boundary/input | Current protection | Remaining evidence or risk |
|---|---|---|
| User cart token, cart id, item id, quantity, variant/plan choice | Typed cart inputs, cart token ownership lookup, active product/variant/plan checks, quantity constraints, cart and item policies | Guest token is a bearer credential. Add retries are not operation-key idempotent. |
| User checkout key, cart version, shipping/quote choice | Typed checkout inputs, exact cart-version lock, server-generated quote hash/method validation, actor/cart/draft access checks | Checkout draft completion/expiry authority is incomplete. |
| Client payment return/cancel query parameters | Return/cancel routes are read-only; payment proof comes from provider webhook/payment interlock | No client parameter establishes paid/refunded state in the inspected path. |
| Provider raw body, headers, event id, amount, currency, status | Raw signature verification, provider adapter normalization, receipt persistence, provider enablement check, canonical amount/currency/order checks | ProviderEvent duplicate result is not a complete downstream no-op gate. |
| Webhook delivery/replay | Unique WebhookReceipt and ProviderEvent identities, Oban worker, processed status | Receipt processing claim lacks CAS, so concurrent workers can enter processing. |
| Payment/refund transition | System-context domain facade, Ash policies, payment/order/refund transition actions, order amount/refund remaining checks | RefundAttempt sequence allocation has only database uniqueness under concurrency. |
| Admin/support catalog/order/payment reads and mutations | Ash policies, role checks, and step-up requirement for refund/order-refund operations | Evidence is resource/action-specific; non-formal lifecycle resources rely on generic system/admin updates. |
| Manual entitlement or inventory mutation | Resource policies restrict mutation to system/admin paths; subscription facade uses system actor | No common lifecycle transition authority covers all grant/reservation updates. |
| Provider credentials and outbound calls | Provider adapters isolate outbound calls and runtime configuration supplies provider settings; controllers do not call providers directly | The registry does not infer secret rotation or external provider guarantees from configuration alone. |

## Authorization and ownership

**FACT:** Catalog public reads expose published products, active variants, and active plans. Catalog mutations use admin-role policies as defined on the resources, while support is included on relevant catalog read policies. Cart reads are scoped to the actor or guest token. Checkout, order, subscription, payment, refund, and entitlement mutations in the inspected privileged paths use system/admin context or resource policy checks.

**FACT:** Refund initiation is restricted to system or an admin role with the configured step-up window. Marking an order refunded and payment transitions are not ordinary user actions. PaymentAttempt, ProviderEvent, WebhookReceipt lifecycle writes are system-only, with admin/support read policies where defined.

## Webhook verification and rate limiting

The webhook and payment callback controllers attach `StoreWeb.Plugs.RequestRateLimit` with the `webhook` scope. Runtime configuration defaults to 120 requests per 60 seconds and can select the ETS or Redis backend. The controllers verify raw body/headers and enqueue processing; provider modules do not write domain state.

This is a delivery-abuse control, not an idempotency control. A valid replay still reaches the receipt/evidence idempotency paths, and a concurrent receipt claim remains a lifecycle gap.

## Audit evidence

Webhook evidence is retained and later purged by the system facade. The purge path calls `Store.Admin.AuditLog` with `WEBHOOK_EVIDENCE_PURGED`. No equivalent universal audit record was found for every subscription cancellation, manual entitlement change, or reservation terminal transition.

# 15. Performance/Data Integrity Invariants

## Authoritative layers

**FACT:** Postgres is the source of truth for products, variants, plans, carts, checkout drafts, orders, snapshots, payment intents, payment evidence, refunds, stored payment methods, subscriptions, renewal attempts, reservations, inventory counters, and entitlement grants. The inspected billing and access flows do not use Redis or ETS as financial authority.

The current cache layers are:

| Data | Layer and observed TTL | Invalidation/current use |
|---|---|---|
| Variant stock fast path | ETS, default five seconds, database fallback | Variant invalidation after reservation/consume/release/expiry. It is a precheck, not reservation authority. |
| Product availability | ETS, default 300 seconds | Product-scoped invalidation after catalog/inventory effects. |
| Product list projection | Cachex hot cache, two minutes; Redis warm cache, 1,800 seconds | Local clear, Redis prefix deletion, and PubSub invalidation. |
| Entitlement effective-grant reads | Cachex, 60 seconds, 30-second sweep | Local delete and entitlement PubSub broadcast after grant changes. |
| Cart, checkout, order, payment, subscription, renewal, reservation records | No domain-state cache found | Postgres reads, transactions, locks, unique indexes, and workers are current controls. |

Redis support also exists for rate limiting, telemetry aggregation, and the catalog list warm cache. No Redis-backed payment, subscription, renewal, reservation, or entitlement authority was found.

## Query and index protections

The migrations and resource custom indexes cover the main lookup paths: product slug/status/publication, variant SKU/product/status, plan key/status, active variant-plan attachment, active cart user/token, cart items, checkout key/cart version/status, order state/user/ref/checkout/provider-setup, snapshot order/line/sequence, payment-intent state/order/provider references, receipt idempotency/provider-event/processing/purge, provider-event identity, payment/refund attempt identities, subscription status/due/provider/source/stored-method, renewal subscription/status, reservation order/variant/state/expiry, inventory variant, and entitlement source/user/validity.

Checkout and cart facades load related catalog data in batches and use locks for the final mutation. Renewal due selection is indexed by subscription status and next renewal/retry. Entitlement cache coalesces concurrent misses. The checkout and subscription performance tests contain telemetry/query assertions for their exercised paths; they do not convert every global query budget into a database invariant.

## High-frequency data integrity

- Cart writes remain durable in Postgres and use version/CAS plus row locks; the stock ETS value is only an availability precheck.
- Payment evidence and payment application remain durable in Postgres; receipt/provider uniqueness and PaymentApplication protect replay, while worker enqueue and receipt processing are separate concerns.
- Renewals remain durable in Postgres and are scheduled by Oban; worker uniqueness and RenewalAttempt identities protect duplicate work, while subscription status has no version lock.
- Entitlements are durable in Postgres; Cachex only accelerates effective-grant reads and is invalidated by grant operations. Cache invalidation failure can leave stale reads for the configured TTL.

The performance governance document describes a hot/warm/cold model and Redis as an optional warm layer. The executable implementation uses Redis for the catalog list warm cache and optional rate limiting, not as billing authority or a general subscription/entitlement state cache. That difference is recorded here rather than inferred as a future architecture.

# 16. Extraction Classification

| Domain | Classification | Current evidence | Missing protection or boundary |
|---|---|---|---|
| Product | PARTIAL | Published/archive actions have current-state validation; public reads and checkout enforce published availability; catalog data has clear resource ownership. | No common Ash lifecycle state machine/version; multiple active plan attachments are allowed after the phase-27 migration; product-side effects on existing subscription renewability are implicit. |
| Cart | PARTIAL | Ownership checks, unique active-cart indexes, quantity constraints, row locks, version CAS, merge tests, and stale checkout protection exist. | Guest bearer-token model, no formal cart state machine, no operation-key idempotency, and no complete cart expiration lifecycle. |
| Checkout | PARTIAL | Typed facade, unique checkout identities, exact cart-version locks, pricing snapshots, reservation transaction, quote-hash validation, and retry tests exist. | Draft `consumed`/`expired` states have no observed transition authority; one lifetime-cart outcome is not proven. |
| Orders | PARTIAL | Explicit AshStateMachine, version locking, immutable line/adjustment evidence, payment relationship, refund evidence, and governance tests exist. | Governance state list is stale; general order totals/shipping updates are not uniformly frozen after paid; payment side effects extend beyond the order transition. |
| Payments | PARTIAL | PaymentIntent state graph/version, provider verification, unique receipt/provider evidence, amount/currency reconciliation, PaymentApplication, refund checks, and worker paths exist. | Receipt processing lacks CAS; duplicate ProviderEvent is not an explicit no-op gate; PaymentAttempt/RefundAttempt lack lifecycles; downstream fanout is procedural and post-commit. |
| InventoryReservation | PARTIAL | State graph, unique identities, row locks, binary UUID lock ordering, quantity constraints, expiry worker, cache invalidation, and concurrency tests exist. | Raw `Repo.update_all` and CTE paths bypass transition actions, so lifecycle authority is not uniform. |
| Subscriptions | NOT READY | Source-line uniqueness, paid creation checks, explicit status graph, renewal key uniqueness, SQL claim, Oban scheduling, dunning, stored renewal pricing, and replay tests exist. | Creation bypasses the resource default state, transitions disable optimistic locking, renewal/cancel/plan-change races are not comprehensively guarded, and entitlement/payment/order coupling is broad. |
| Entitlements | NOT READY | Durable grant identity, subscription source relationship, effective-status evaluation, Cachex TTL, PubSub invalidation, and grant tests exist. | No formal grant state machine/version, revoke-all is not atomic, subscription-side errors are ignored or swallowed, and the global access boundary is not proven. |

The classifications describe extraction readiness of the current invariants, not the value or quality of individual modules. The reusable portions are the deterministic pricing evaluator, immutable order evidence model, explicit PaymentIntent/Order transition helpers, database-backed reservation arithmetic, and renewal-key uniqueness. The main extraction blockers are incomplete evidence lifecycles, bypassed transition authority, broad payment/subscription fanout, missing subscription locking, and subscription/entitlement consistency gaps.
