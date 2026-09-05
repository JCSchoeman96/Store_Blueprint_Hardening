# Lifecycle Registry Gap Assessment

## 1. Purpose

Lifecycle completeness matters because extraction boundaries depend on knowing which record owns a state, which code is allowed to change it, and which effects are produced by that change. A resource can have a status column without having an authoritative lifecycle if other code can write the column directly or if retries are handled outside the recorded state.

This document records the current executable behavior for the lifecycle concepts identified as missing or incomplete during the S0-02 review. It is an assessment of the implementation, not a replacement state-machine design. Where governance documentation describes a stronger rule than the code enforces, the difference is recorded as drift.

Missing lifecycle boundaries create extraction risk in two ways. First, an extracted domain cannot safely own a state if callers can bypass its transition rules. Second, a downstream domain cannot be separated from an upstream domain when the upstream module performs its writes, retries, and notifications directly.

## 2. InventoryReservation Lifecycle Gap

### Current behavior

The resource is `Store.Orders.InventoryReservation` in `lib/store/orders/inventory_reservation.ex`. Its table is `inventory_reservations`, created by `priv/repo/migrations/20260224201500_phase_11_inventory_reservations.exs`.

The resource declares:

- `state` with type `Store.Orders.Types.InventoryReservationState`, default `:active`.
- States `:active`, `:consumed`, `:expired`, and `:cancelled`.
- An `AshStateMachine` with `:active` as the initial state and these transitions:
  - `mark_consumed`: `:active` to `:consumed`.
  - `mark_expired`: `:active` to `:expired`.
  - `mark_cancelled`: `:active` to `:cancelled`.
- `expires_at`, `consumed_at`, `expired_at`, `cancelled_at`, and `version` fields.
- Unique identities for `(order_id, variant_id)` and `reservation_key`.
- Database indexes for order/state, variant/state, and state/expiry.

The declared resource actions use `Store.Support.Governance.TransitionState` and set the corresponding lifecycle timestamp. The action definitions are in `lib/store/orders/inventory_reservation.ex:77-85` and `:132-172`.

The executable reservation service does not use those transition actions for its normal state writes. `lib/store/orders/inventory_reservations.ex` contains the following paths:

- `reserve_inventory_for_checkout/3` runs a checkout transaction and uses a SQL CTE to lock inventory rows, update counters, and insert `inventory_reservations` rows with state `active` (`:42-95`, `:772-863`). This insertion bypasses the Ash create action.
- The private `update_reservation/2` helper writes reservation attributes with `Repo.update_all`, increments `version`, and reloads the row (`:624-637`). It does not call `mark_consumed`, `mark_expired`, or `mark_cancelled`, and it does not include an expected prior version or `state == :active` predicate.
- Desired quantity `0` changes an active reservation to `cancelled` (`:310-327`).
- Release changes an active reservation to `cancelled` after decrementing inventory counters (`:420-435`).
- Consumption changes an active reservation to `consumed` after decrementing reserved units and incrementing sold units (`:469-490`). An already-consumed reservation returns a no-op result on replay.
- Expiry locks eligible rows with `FOR UPDATE SKIP LOCKED`, updates inventory counters, and changes the reservation to `expired` through the same raw update helper (`:518-584`).
- `update_inventory_counters/3` also uses `Repo.update_all` (`:590-622`), but those updates target `inventory_items` counters rather than the reservation state.

A repository search found no application call sites for the resource actions `mark_consumed`, `mark_expired`, or `mark_cancelled` outside the resource definition. The service-level writes are therefore the effective state authority in the current implementation.

### Affected workflows

| Workflow | Current implementation | Current transaction and worker behavior |
|---|---|---|
| Checkout | `Store.Checkout.Domain` finalization calls `Store.Orders.reserve_inventory_for_checkout` from `lib/store/checkout/domain.ex:749-772`. | Reservation insertion and inventory counter changes are inside the checkout finalization transaction. |
| Reservation expiry | `Store.Workers.ExpireInventoryReservationsWorker` calls `Store.Orders.expire_reservations/1`. | The service finds active, expired rows and uses row locks, including `FOR UPDATE SKIP LOCKED`, before releasing units and writing `expired`. |
| Consumption | Payment success calls `Store.Orders.consume_reservations_for_order` from `lib/store/payments/interlocks.ex:587-601`. | Consumption runs inside the payment-success database transaction and is guarded by active/terminal checks in the service. |
| Release | Pending provider-setup cleanup and failed renewal handling call `Store.Orders.release_reservations_for_order`. | The service releases held units and writes `cancelled`; replay handling is implemented at the service level. |

The current source of truth for reservation state and quantities is PostgreSQL. `Store.Catalog.StockFastPath` uses ETS with a default five-second TTL for availability prechecks, and `Store.Catalog.AvailabilityCache` uses ETS with a default 300-second TTL for product availability. Reservation mutations invalidate the variant fast path and product availability cache in `lib/store/orders/inventory_reservations.ex:966-1009`. No Redis use was found in the reservation mutation path. Expiry is worker-driven through Oban; cache invalidation is performed after the service operation returns successfully.

### Gap and extraction impact

The current state vocabulary and intended transition set are explicit in the resource, and the inventory governance tests cover quantity effects, replay behavior, expiry, consumption, release, and a forbidden expired-to-consumed case (`test/store/governance/inventory_reservations_test.exs`). The authority is incomplete because normal checkout, consumption, release, and expiry paths bypass the declared transition actions. The incremented version field does not by itself provide optimistic concurrency protection because the raw update does not compare the prior version.

The inventory reservation lifecycle is therefore `NOT READY` as an extraction boundary. The gap is an authority gap, not an absence of state names or tests.

### Extraction requirement

An extraction gate must identify one authoritative transition surface for reservation state and must account for the existing SQL insertion and `Repo.update_all` paths before reservation behavior is treated as reusable. The gate must preserve the observed terminal semantics, quantity semantics, row-lock behavior, and cache invalidation behavior as facts to be verified during future work.

## 3. Payment Evidence Lifecycle Gaps

The records in this section are all persisted in PostgreSQL. The payment webhook and refund workers run in Oban queues, but no cache was found around the evidence records. The current evidence model mixes formal state-like fields, immutable event records, and outcome records without one consistent lifecycle authority.

### WebhookReceipt

#### Current behavior

`Store.Payments.WebhookReceipt` is defined in `lib/store/payments/webhook_receipt.ex` and persists to `webhook_receipts`. It has two independent status fields:

- `verification_status`, a string defaulting to `"verified"`.
- `processing_status`, a string defaulting to `"new"`.

The database checks in `priv/repo/migrations/20260303120000_phase_21_checkout_payment_integration_mvp.exs:101-145` constrain verification to `verified` or `rejected` and processing to `new`, `processing`, `processed`, or `failed`. The resource has actions named `mark_processing`, `mark_processed`, `mark_failed`, and `purge_evidence` (`lib/store/payments/webhook_receipt.ex:154-171`), but it does not declare an `AshStateMachine` or use `TransitionState` for these updates.

The controller path verifies the raw body and headers, builds a receipt, persists it, and enqueues one worker (`lib/store_web/controllers/webhook_controller.ex:79-176`). Invalid signatures are rejected before the normal receipt-ingest path, while accepted receipts are inserted with verified/new statuses. The receipt has unique identities for `idempotency_key` and `(provider, provider_event_id)` (`lib/store/payments/webhook_receipt.ex:100-103`). A duplicate receipt insert is treated as an existing receipt and does not enqueue a second job in the controller.

`Store.Payments.Facade.mark_processing/1` returns the existing receipt unchanged when it is already `processed`; otherwise it writes `processing` (`lib/store/payments/facade.ex:180-187`). There is no current-state transition graph or compare-and-swap guard. `mark_terminal_status/2` writes `processed` for success/discard and `failed` for errors (`:189-224`). The processing worker has ten Oban attempts (`lib/store/workers/process_webhook_receipt_worker.ex`), and failed receipts can be re-entered into processing.

#### Idempotency, retry, and extraction impact

The current implementation has receipt-ingest idempotency through database identities and controller-level duplicate handling. It does not establish a complete receipt lifecycle authority: the allowed processing transitions are implicit in facade conditionals and database checks, and concurrent workers have no receipt-version compare-and-swap in the inspected path. Evidence purge is a separate mutation that clears `raw_body` and `headers` while retaining the payload hash and purge timestamp.

The extraction impact is `PARTIAL`. The durable ingress record and retry worker exist, but lifecycle legality, concurrent claiming, verification/processing relationship, and replay semantics are not represented by an explicit state machine.

### ProviderEvent

#### Current behavior

`Store.Payments.ProviderEvent` is defined in `lib/store/payments/provider_event.ex` and persists to `provider_events`. It contains provider and event identity, event type, payload hash, and receipt-time data, but no state, status, version, or transition actions. Its only resource action is `ingest`, which upserts by the provider event identity (`lib/store/payments/provider_event.ex:56-90`). The migration `priv/repo/migrations/20260222160727_phase_04_state_machines.exs:11-41` creates the table and unique `(provider, provider_event_id)` identity. The actual resource and migration do not contain the `receipt_id` field described as recommended in `docs/governance/idempotency.md:38-56`.

`Store.Payments.Interlocks.ingest_provider_event/2` calls the create action and returns the provider event key (`lib/store/payments/interlocks.ex:465-487`). The caller does not branch on whether the upsert inserted a new record or reused an existing record. Payment and refund processing therefore continue to attempt `PaymentAttempt`/`RefundAttempt` recording and downstream application after a duplicate provider event is found.

#### Idempotency, retry, and extraction impact

The current implementation makes the event record insert idempotent through unique database identity. It does not make the worker a no-op at the ProviderEvent boundary. Downstream payment application has a separate `PaymentApplication` key and terminal-state checks, so ordinary payment replay can be safe without ProviderEvent itself suppressing the rest of the pipeline. That is different from the governance rule that a duplicate ProviderEvent worker must perform no transitions or side effects.

ProviderEvent has no lifecycle to retry or transition. Its extraction impact is `NOT READY` as a complete evidence boundary because event identity is persisted without explicit duplicate disposition, receipt lineage, or a worker-level no-op contract.

### PaymentAttempt

#### Current behavior

`Store.Payments.PaymentAttempt` is defined in `lib/store/payments/payment_attempt.ex` and persists to `payment_attempts`. It belongs to `PaymentIntent` and records provider event identity, an `attempt_key`, an `outcome` string, payload hash, and attempt time. It has no state field, version field, Ash state machine, or update actions. Its `record` create action uses unique `provider_event_key` and `attempt_key` identities (`lib/store/payments/payment_attempt.ex:54-86`). The corresponding database constraints and indexes are in `priv/repo/migrations/20260225190004_phase_14_checkout_interlocks.exs:28-72`.

The payment interlock records an outcome of `succeeded`, `failed`, or `ignored` after canonical provider status handling and before applying the canonical receipt (`lib/store/payments/interlocks.ex:490-520`). A repeated attempt key reuses the existing evidence record rather than representing a processing state transition.

#### Idempotency, retry, and extraction impact

The unique attempt identity makes evidence creation idempotent for the same provider event/payment intent/event type. The record is immutable after creation in the resource. It does not distinguish evidence recording from downstream application success, and it has no explicit processing, retry, or suppression lifecycle. A worker retry can therefore reuse the evidence row while re-entering the downstream interlock.

A repository search found no dedicated test file or direct `PaymentAttempt` test reference under `test/`; the record is covered only indirectly by webhook worker execution. Its extraction impact is `PARTIAL` for immutable evidence and `NOT READY` if it is intended to represent a payment-attempt lifecycle.

### StoredPaymentMethod

#### Current behavior

`Store.Subscriptions.StoredPaymentMethod` is defined in `lib/store/subscriptions/stored_payment_method.ex` and persists to `stored_payment_methods`. Its status type is `Store.Subscriptions.Types.StoredPaymentMethodStatus`, with values `active`, `inactive`, and `revoked` (`lib/store/subscriptions/types/stored_payment_method_status.ex:1-6`). The migration `priv/repo/migrations/20260304110000_phase_26_stored_payment_methods.exs:7-89` enforces those values and the unique provider/customer/payment-method identity.

The resource has `create_or_reuse`, `mark_active`, `mark_inactive`, and `mark_revoked` actions (`lib/store/subscriptions/stored_payment_method.ex:78-110`). It does not declare an `AshStateMachine`, use `TransitionState`, or perform a version-checked update. `create_or_reuse` can update the existing row's status and fingerprint while reusing the identity. A search found no application call sites for the three mark actions; the paid subscription setup path calls `create_or_reuse` with `active`.

Initial subscription creation persists the stored payment method in the subscription creation transaction (`lib/store/subscriptions/facade.ex:1136-1145`, `:1867-1895`). Renewal reads require a matching active stored payment method and return `PAYMENT_METHOD_REQUIRED` when it is absent or not active (`lib/store/subscriptions/facade.ex:2094-2146`). The `subscriptions.stored_payment_method_id` foreign key references `stored_payment_methods` with `nilify` behavior in the stored-payment-method migration, so the database relationship is shared between stored payment method and subscription behavior.

#### Idempotency, retry, and extraction impact

The provider/customer/payment-method identity makes `create_or_reuse` repeatable. The existing test `test/store/subscriptions/stored_payment_method_test.exs:10-60` proves same-identity reuse and status update, but it does not prove a transition graph, forbidden transitions, or concurrent status updates. Status actions have no explicit guard, and no status lifecycle is recorded for retry or revocation reasons.

The extraction impact is `NOT READY` as a lifecycle boundary. The current record is reusable as a stored payment reference only after its ownership, status authority, and provider-reference trust boundary are made explicit in future work.

### RefundAttempt

#### Current behavior

`Store.Payments.RefundAttempt` is defined in `lib/store/payments/refund_attempt.ex` and persists to `refund_attempts`. It belongs to `Refund` and records provider event identity, refund identity, `provider_refund_id`, an `outcome` string, error data, payload hash, `sequence_no`, and attempt time. It has no state field, version field, Ash state machine, or update actions. Its `record` action is create-only. Database uniqueness is enforced for `(refund_id, sequence_no)` and `provider_event_key` by `priv/repo/migrations/20260225093000_phase_12_refund_semantics.exs:79-129`.

The refund webhook path first checks for an existing attempt by provider event key, computes `MAX(sequence_no) + 1` for a new attempt, and creates the record (`lib/store/payments/refunds.ex:353-417`). A refund worker replay therefore reuses a prior attempt when the provider event key is found. The lookup, maximum-sequence calculation, and create are separate operations in the inspected path; no enclosing transaction is present in that helper.

#### Idempotency, retry, and extraction impact

The unique provider-event identity and explicit lookup provide replay handling for the same event, and the refund worker has ten Oban attempts (`lib/store/workers/process_refund_webhook_receipt_worker.ex`). The evidence row itself has no processing/retry/suppression state. Concurrent new provider events for the same refund can independently calculate the same next sequence number before the database uniqueness constraint is applied.

The existing refund worker test checks that a replay leaves one `RefundAttempt` (`test/store/workers/process_refund_webhook_receipt_worker_test.exs:81-86`), but there is no dedicated lifecycle or concurrency test for the evidence record. Its extraction impact is `PARTIAL` for append-only refund evidence and `NOT READY` if sequence allocation and retry status are part of the extracted refund boundary.

## 4. Payment Side Effect Boundary

### Current flow

The current payment-success path is:

```text
Payment success
    ->
Payment interlock
    ->
Order
    ->
Inventory
    ->
Subscription
    ->
Entitlement
    ->
Notifications
```

The arrows represent the following executable behavior:

1. **Payment success ingress.** `lib/store_web/controllers/webhook_controller.ex` verifies the raw provider body and headers, persists a `WebhookReceipt`, and enqueues one `ProcessWebhookReceiptWorker`. The worker calls the payment facade/interlock with a system actor. Provider-controlled payload data is normalized before domain application.
2. **Payment interlock.** `Store.Payments.Interlocks.process_payment_webhook_receipt/2` verifies the receipt/provider, decodes and normalizes the payload, fetches the `PaymentIntent`, validates its target, ingests a `ProviderEvent`, records a `PaymentAttempt`, and applies the canonical receipt (`lib/store/payments/interlocks.ex:55-74`).
3. **Order and inventory.** `apply_payment_success_once/2` runs `run_apply_payment_success_once/2` in a PostgreSQL transaction (`lib/store/payments/interlocks.ex:77-109`, `:587-601`). The transaction inserts a `PaymentApplication` with `ON CONFLICT DO NOTHING`, transitions a submitted or action-required `PaymentIntent` to succeeded, transitions an eligible order to paid, and consumes order reservations. The `PaymentApplication` key is `paid_apply:order:<order_id>` (`:612-635`).
4. **Post-commit fan-out.** After the payment transaction, the interlock sends Ash notifications, broadcasts an order state change over `Store.PubSub`, and enqueues fulfillment, digital-grant, subscription, and order-receipt work (`:91-109`). The payment interlock directly calls `Store.Orders`, `Store.Digital`, `Store.Fulfillment`, and `Store.Subscriptions` surfaces.
5. **Subscription.** `Store.Workers.EnsureSubscriptionsForPaidOrderWorker` calls `Store.Subscriptions.Facade.create_subscriptions_from_paid_order_for_system/1`. The facade checks that the order is paid, contains subscription lines, has a succeeded payment intent, and is not a renewal order (`lib/store/subscriptions/facade.ex:1063-1109`). It creates active subscription records in a separate subscription transaction and persists a stored payment method when provider references are present (`:1136-1145`, `:1802-1895`).
6. **Entitlement.** After the subscription transaction commits, the subscription facade calls `Store.Entitlements.Facade.issue_subscription_entitlement_for_system/2` for plans with entitlement configuration (`lib/store/subscriptions/facade.ex:1112-1129`, `:1933-1977`). This is not part of the payment-success or subscription-creation database transaction.
7. **Notifications and access invalidation.** Payment application sends post-commit Ash notifications and an order PubSub broadcast. Subscription and entitlement paths issue their own post-commit notifications, access-ended emails, and cache invalidations. The entitlement cache invalidation broadcasts `{:entitlements_invalidated, ...}` on a per-user PubSub topic (`lib/store/entitlements/cache.ex:51-77`).

### Current behavior, extraction concern, and future boundary requirement

| Classification | Finding |
|---|---|
| Current behavior | Order payment application, payment-intent/order transitions, and inventory consumption are transactionally grouped. Subscription creation and entitlement issuance are asynchronous follow-on operations. `PaymentApplication` provides an order-level once-only ledger. Post-commit notifications and Oban fan-out occur after the transaction. |
| Extraction concern | `Store.Payments.Interlocks` is a procedural cross-domain coordinator. It directly invokes order, inventory, digital, fulfillment, and subscription behavior. The current implementation does not persist a standalone `payment_succeeded` event that downstream domains consume. Later enqueue failures are logged by the relevant helper and do not roll back the already-committed payment transaction. The ProviderEvent duplicate is also not a worker-level no-op before this fan-out. |
| Future boundary requirement | An extraction gate must name the owning domain and durable handoff/retry contract for each payment-success consequence. The gate must distinguish transaction-owned effects from post-commit and worker-owned effects and preserve the existing once-only payment application and replay behavior. This is a boundary requirement, not a claim that a different event mechanism currently exists. |

### Persistence, cache, and worker facts

- Payment evidence, payment application, order state, and reservation state are PostgreSQL-backed. No ETS, Cachex, or Redis cache was found in the payment evidence/interlock path.
- Webhook and refund processing use Oban workers with configured retry attempts. Oban job uniqueness is applied by the webhook controllers for receipt enqueueing; the downstream ProviderEvent record does not itself stop a duplicate worker.
- Order state changes are broadcast through Phoenix PubSub, but the broadcast is not the durable handoff for subscription or entitlement creation.
- Reservation inventory uses the ETS caches described in section 2 and invalidates them from reservation mutation paths.

## 5. Subscription / Entitlement Boundary

### Current behavior

Subscription-to-entitlement behavior is implemented by direct calls from `Store.Subscriptions.Facade` to `Store.Entitlements.Facade`:

- Initial paid-order subscription creation collects subscription/plan pairs and, after the subscription transaction commits, calls `maybe_issue_entitlement/2` (`lib/store/subscriptions/facade.ex:1112-1129`, `:1933-1977`).
- Renewal reconciliation calls `maybe_sync_entitlement/2` after extending the subscription period (`lib/store/subscriptions/facade.ex:1363-1390`, `:1944-1953`).
- Immediate cancellation calls `revoke_subscription_entitlements_for_system/2` directly after the subscription cancellation transition (`lib/store/subscriptions/facade.ex:1986-2006`).
- Past-due grace expiry marks the subscription expired and then directly revokes subscription entitlements (`lib/store/subscriptions/facade.ex:3056-3101`).

`Store.Entitlements.EntitlementGrant` persists to `entitlement_grants` and has status values `active`, `revoked`, and `expired` (`lib/store/entitlements/entitlement_grant.ex`, `lib/store/entitlements/types/entitlement_status.ex:1-8`). It does not declare an Ash state machine. `issue` upserts the unique `(user_id, kind, scope_key, source_kind, source_id)` grant identity and sets active validity; `revoke` and `expire` are update actions without current-state guards or version checks. The table has a foreign key from `source_id` to subscriptions for subscription grants in `priv/repo/migrations/20260303230000_phase_26_simple_subscriptions.exs:574-671`.

Access decisions occur in `Store.Entitlements.Facade.entitlement_set_for_user/1`. It reads active grants through `Store.Entitlements.Cache`, and `Store.Entitlements.Types.EntitlementSet` further considers `status`, `revoked_at`, and `valid_to_at` when calculating effective grants (`lib/store/entitlements/facade.ex:37-46`, `:153-174`). The hot cache is Cachex with a 60-second TTL, a 30-second expiration sweep, local deletion, and per-user PubSub invalidation (`lib/store/entitlements/cache.ex:1-77`). No Redis cache was found for entitlement access.

### Coupling and failure behavior

The subscription facade owns knowledge of entitlement configuration and invokes entitlement writes directly. Entitlement issuance is after the subscription transaction, so an active subscription can exist before its grant is present. In the initial creation path, `maybe_issue_entitlement/2` converts an issuance error into `:skipped`; the subscription result can therefore report a created subscription without a grant. Renewal synchronization returns an error when issuance fails. Cancellation and expiry call revocation while ignoring the revocation result. These are different failure contracts for the same subscription-to-access relationship.

The entitlement database foreign key, direct facade calls, shared subscription source identifiers, and access-cache invalidation make the coupling observable in both persistence and runtime behavior. The grant cache can also serve a previously computed entitlement set until invalidation or TTL expiry, although the effective-grant calculation checks validity fields.

The subscription-to-entitlement boundary is `NOT READY` for extraction. The current implementation has identifiable facades and a cache contract, but subscription state changes and entitlement effects are coupled procedurally, with no explicit durable boundary or uniform outcome contract.

### Extraction requirement

An extraction gate must make the subscription-to-entitlement dependency, grant creation/revocation outcome, cache invalidation, and failure/retry ownership explicit. The gate must preserve the current distinction between subscription persistence, entitlement persistence, and access evaluation rather than treating a subscription row as proof that access exists.

## 6. Lifecycle Authority Violations

### Current findings

| Area | Verified current behavior | Authority or extraction impact |
|---|---|---|
| InventoryReservation | Resource transitions exist, but `Store.Orders.InventoryReservations` inserts rows with SQL and writes state through `Repo.update_all`. | The declared state machine is not the only state-writing authority. Terminal semantics are enforced by service queries/tests rather than by every state write. |
| WebhookReceipt | Processing actions write string statuses without `AshStateMachine`, `TransitionState`, or a version compare. | Database vocabulary is constrained, but transition legality and concurrent claiming are implicit. |
| ProviderEvent | The resource is append-only evidence with no state. Duplicate upsert information is not used to stop the worker. | Evidence identity exists without a complete duplicate disposition or receipt-to-event lineage. |
| PaymentAttempt | The resource records an outcome once and has no update/lifecycle actions. | An outcome record is not a processing/retry state machine and does not prove downstream payment application. |
| StoredPaymentMethod | Status actions exist without a state machine or guarded/versioned transitions; `create_or_reuse` can change status. | The active/inactive/revoked lifecycle has no single explicit transition graph. |
| RefundAttempt | The record is create-only evidence; the refund service performs find, sequence allocation, and create in separate operations. | Replay is partly protected, but attempt ordering and retry state are not authoritative under concurrency. |
| EntitlementGrant | `issue`, `revoke`, and `expire` update status without a state machine or version guard. | Access lifecycle authority is distributed across the grant resource and subscription facade. |
| Payment side effects | The payment interlock directly calls several downstream domain surfaces and enqueues their workers after commit. | Payment success consequences are procedurally coupled rather than represented by an independently durable downstream boundary. |

### Governance drift

The following differences were verified between governance documentation and executable code:

| Documented rule | Actual implementation | Impact |
|---|---|---|
| `docs/governance/inventory_reservations.md:69-88` defines active-to-terminal transitions and no further terminal transitions. | The resource declares those transitions, but normal reservation writes use direct SQL/`Repo.update_all` and do not invoke the transition actions. | Governance terminal semantics are not enforced by the declared resource API on all paths. |
| `docs/governance/idempotency.md:33-36` says a duplicate ProviderEvent worker must no-op with no transitions or side effects. | `Store.Payments.Interlocks` continues to record/reuse attempt evidence and apply the canonical receipt after the ProviderEvent upsert path, without branching on duplicate status. | Duplicate suppression occurs later, partly through `PaymentApplication` and terminal checks, rather than at the ProviderEvent boundary. |
| `docs/governance/idempotency.md:48-56` lists `ProviderEvent.receipt_id` as recommended lineage data. | `ProviderEvent` and its migration have no `receipt_id` relationship or column. | The normalized event cannot be joined to its originating receipt through the documented foreign key. |
| `docs/governance/payment_provider_contract.md:75-88` describes verification and processing status fields as a durable receipt lifecycle. | `WebhookReceipt` has the status fields and database checks, but no formal transition graph or concurrent processing claim guard. | The vocabulary exists, while lifecycle authority and replay/concurrency semantics remain implicit. |
| `docs/governance/state_machines.md` specifies explicit Order and PaymentIntent transitions. | Those resources use transition actions in the payment interlock, while the evidence, stored-payment-method, entitlement, and reservation service paths do not consistently use equivalent transition authority. | Lifecycle governance coverage differs between adjacent resources in the same payment/subscription flow. |

### Trust and replay-sensitive operations

The webhook controller is the provider trust boundary: it receives provider-controlled headers/body data, verifies the signature, and enqueues the receipt. The worker runs with system authority and performs payment/reconciliation transitions. Evidence resource policies restrict ingest and lifecycle writes to system actors, while refund request authorization and step-up checks are handled in `lib/store/payments/refunds.ex:555-590`. Payment success, refund reconciliation, inventory consumption, stored payment method status, subscription cancellation/expiry, and entitlement issue/revoke are replay-sensitive or privileged operations. The current implementation has tests for several replay paths, but no test establishes that all state writes pass through one authoritative lifecycle API.

## 7. Required Future Gates

These are extraction gates derived from the verified gaps. They are not implementation changes in this task.

1. **Reservation state authority gate.** Every lifecycle-bearing reservation write must be attributable to an explicit transition authority, including checkout SQL insertion, consumption, release, expiry, and desired-quantity cancellation. Any remaining direct SQL or `Repo.update_all` path must be accounted for before extraction.
2. **Terminal-state gate.** Inventory terminal behavior must be proven for the actual write paths, including replay and forbidden transitions, rather than inferred only from the declared `AshStateMachine`.
3. **Payment evidence classification gate.** `WebhookReceipt`, `ProviderEvent`, `PaymentAttempt`, `RefundAttempt`, and `StoredPaymentMethod` must each be classified as either immutable evidence or a stateful lifecycle, with the classification reflected in explicit states, transitions, guards, retry behavior, and tests.
4. **Duplicate evidence gate.** Receipt and provider-event duplicate behavior must be explicit at the worker boundary. The extraction record must distinguish receipt insert reuse, ProviderEvent reuse, downstream idempotency, and actual no-op behavior.
5. **Evidence lineage gate.** The relationship between an inbound receipt and its normalized provider event must be traceable in the persisted model or the absence of that relationship must be an accepted, documented boundary decision.
6. **Payment side-effect gate.** Each payment-success consequence must have a named owning domain, a durable handoff or retry contract, and a documented transaction boundary. The gate must account for order, inventory, subscription, entitlement, notification, fulfillment, and digital side effects without treating the current procedural calls as independent boundaries.
7. **Subscription-access gate.** Subscription creation, renewal, cancellation, expiry, entitlement grant/revocation, access evaluation, and cache invalidation must have an explicit dependency and failure contract. Subscription persistence must not be treated as implicit proof of entitlement persistence.
8. **Concurrency evidence gate.** Tests must cover the actual race-sensitive paths identified here: reservation state writes, duplicate webhook/provider-event workers, refund-attempt sequence allocation, stored-payment-method status changes, subscription renewal versus cancellation, and entitlement issue versus revoke.
9. **Privileged-transition gate.** Extraction evidence must identify the actor or system authority for payment reconciliation, refund transitions, inventory terminal changes, stored payment method changes, subscription cancellation/expiry, and manual entitlement changes, including replay behavior at each trust boundary.
