# Store Blueprint Commerce Security Model

This is the S0-07 security discovery record for the implementation as inspected on 2026-08-27. The code and migrations are the source of truth. Governance documents are cited as comparison context and are not treated as evidence that a control exists in the current application.

This document is documentation only. It does not add authorization, change a policy, introduce tenancy, or alter application behaviour.

## 1. Purpose

Extraction will move trust boundaries as well as modules. A commerce engine cannot be extracted safely by preserving only successful request flows. The extracted boundary must preserve who may see a record, who may change a state, which external event is authoritative, and which retries are harmless.

The high-value security risks in this codebase are concentrated around:

- user-owned orders, subscriptions, entitlements, carts, and digital downloads;
- admin and support access to operational and payment records;
- provider-controlled payment results and webhook evidence;
- worker paths that use system context to perform lifecycle transitions;
- inventory reservations, renewal state, stored payment methods, and refund state;
- the fact that the current application is single-tenant and has no database tenant boundary.

The main extraction rule supported by the current code is therefore: preserve the domain facade, Ash resource policy, ownership filter, and durable idempotency evidence as one security unit. Splitting those pieces would make the visible route boundary stronger than the actual state boundary.

## 2. Security boundary overview

| Boundary | Protected resource | Enforcement |
|---|---|---|
| User and browser | User identity, authenticated account pages, own orders, subscriptions, entitlements, downloads, and cart access | AshAuthentication actor loading, signed session cookie, CSRF, `LiveUserAuth`, user-scoped Ash read actions, and facade ownership checks. Guest cart and checkout access also use a cart token. |
| Admin and support | Catalog operations, inventory visibility, order operations, payment evidence, subscription operations, digital operations, and support views | Database-backed `RoleAssignment` records read by `Store.Admin.Authorization`, admin route checks, LiveView checks, and resource policies. `super_admin` and `admin` are the principal mutation roles. `support` is read-only or limited on the inspected commerce resources. |
| Payment provider | Provider credentials, provider identifiers, provider status, amount, currency, and webhook events | Provider adapter boundary. Stripe validates the raw body and `stripe-signature` with an HMAC and a five-minute timestamp tolerance. Provider responses are normalized before domain processing. |
| Worker and system actor | Payment reconciliation, refund finalization, inventory transitions, subscription activation and renewal, entitlement issue/revoke, digital grant issuance, and evidence retention | Oban workers call domain facades with `system?: true`. Resource policies allow selected system actions. Database identities, row locks, state transitions, and apply-once records provide the durable guards. |
| Database | Durable commercial state, ownership columns, provider evidence, and replay anchors | PostgreSQL foreign keys where declared, UUIDv7 primary keys, unique indexes, check constraints, state/version fields, and indexed ownership or event keys. No PostgreSQL row-level security or tenant policy was found in the inspected migrations. |

The application has more than one enforcement layer. Route checks are a coarse boundary, while Ash policies and domain-level ownership checks are the effective state boundary. A route being under `/admin` or an actor being present is not, by itself, proof of access to a particular record.

## 3. Authentication model

### Identity model

`Store.Accounts.User` is an Ash resource backed by `users`. It has a UUIDv7 primary key, a case-insensitive unique email, an optional hashed password, and `confirmed_at`. The email and password fields are sensitive in the resource definition, while `confirmed_at` is not public.

Password authentication uses the email identity and `hashed_password`. New users go through the confirmation add-on. Google OAuth uses `Store.Accounts.UserIdentity` for the provider identity and the `register_with_google` upsert action. The identity table has a unique `(strategy, uid)` index and a foreign key to `users`; its `user_id` column is not declared non-null in the migration.

`User.get_by_subject` uses `AshAuthentication.Preparations.FilterBySubject`. The user resource bypasses policy only for AshAuthentication interactions. Ordinary user reads are restricted by `id == actor.id`.

### Sessions and tokens

- AshAuthentication tokens are enabled and use `Store.Accounts.Token`.
- Tokens are signed with the runtime `:token_signing_secret`, require token presence for authentication, and are stored in the `tokens` table because `store_all_tokens?(true)` is configured.
- The browser pipeline fetches the session, loads the current user from session, and sets the actor. The API pipeline loads the actor from a bearer token.
- `AuthController.success/4` stores the authenticated user and token in the session. Sign-out revokes session tokens before clearing the session.
- The Phoenix session is a signed cookie named `_store_key`; the endpoint explicitly notes that it is readable but not encrypted. It uses `SameSite=Lax`; `secure` is enabled from production configuration and is false in the general development/test configuration.
- CSRF protection is in the browser pipeline. Security headers include `nosniff`, a strict-origin referrer policy, and `SAMEORIGIN`. CSP is configuration-driven and is not enabled by default in the inspected base configuration.

### Authentication flow and route boundary

Public storefront, sign-in, registration, and checkout pages use optional authentication where the flow permits guests. Account, order, subscription, and download pages use required authentication. The API v1 pipeline requires a bearer actor. The `/admin` LiveView scope first requires an actor and then permits `super_admin`, `admin`, or `support`; `AdminLive` itself narrows the dashboard to `super_admin` and `admin`, while individual admin screens perform their own role checks.

The browser pipeline also installs `EnsureCartToken`. It reads a signed `cart_token` cookie, creates a UUIDv7 token when needed, and mirrors it into the session and assigns. The current plug falls back to the raw request cookie when no valid signed cookie value is available. The token therefore behaves as a bearer-like guest capability and is not an identity proof.

The code consumes `step_up_at_mono_usec` from the session and passes it into action context. The refund, provider-setting, pricing, and selected operational policies compare it to the current monotonic time. No in-repository step-up or reauthentication producer was found during this inspection. The consumer and governance contract exist, but the end-to-end origin of the claim is outside the inspected implementation boundary.

Primary sources: [`User`](../../lib/store/accounts/user.ex), [`Token`](../../lib/store/accounts/token.ex), [`UserIdentity`](../../lib/store/accounts/user_identity.ex), [`Endpoint`](../../lib/store_web/endpoint.ex), [`Router`](../../lib/store_web/router.ex), [`AuthController`](../../lib/store_web/auth_controller.ex), and [`LiveUserAuth`](../../lib/store_web/live_user_auth.ex).

## 4. Authorization model

Ash resources use `Ash.Policy.Authorizer` unless stated otherwise. Roles are not stored on the user row. `Store.Admin.Authorization` reads `RoleAssignment` rows by `user_id`; the resource allows the role names `super_admin`, `admin`, `editor`, `support`, and `customer` as data, but the commerce policy checks inspected here primarily use `super_admin`, `admin`, and `support`. `editor` and `customer` do not receive a general admin capability from these policies.

The policy matrix below summarizes current resource and facade behavior. “System” means a trusted worker or domain path carrying `context[:system?] == true`, not an ordinary authenticated user.

| Domain | Read permissions | Write permissions | Admin permissions | Policy location |
|---|---|---|---|---|
| Catalog | Published products, active variants, and active categories have public read actions. Admin and support can read primary catalog resources. Product images, options, option values, and variant selections have broad `always()` read policies. | Product, variant, category, image, and option mutations are generally `super_admin`/`admin`; selected system paths create subordinate records. | `super_admin` and `admin` manage catalog lifecycle. `support` is read-only on the principal catalog resources. | [`product.ex`](../../lib/store/catalog/product.ex), [`variant.ex`](../../lib/store/catalog/variant.ex), [`category.ex`](../../lib/store/catalog/category.ex), [`product_image.ex`](../../lib/store/catalog/product_image.ex), [`product_option.ex`](../../lib/store/catalog/product_option.ex), [`product_option_value.ex`](../../lib/store/catalog/product_option_value.ex), [`variant_option_selection.ex`](../../lib/store/catalog/variant_option_selection.ex) |
| Orders | A user can read own orders through `read_for_user`, `get_for_user`, and `get_for_user_by_ref`, filtered by `user_id == actor.id`. Admin/support receive broad reads. Child line items and adjustments use parent-order visibility preparation; inventory reservations and payment applications are admin/support reads. | Order creation, checkout start, payment and snapshot transitions are system or `super_admin`/`admin`. Cancellation includes `support`. Refund completion is system or role plus recent step-up. Customers have no ordinary order mutation action. | `super_admin`/`admin` can perform lifecycle and snapshot operations; support can cancel and inspect the operational records allowed by the resource policies. | [`order.ex`](../../lib/store/orders/order.ex), [`order_line_item.ex`](../../lib/store/orders/order_line_item.ex), [`order_adjustment.ex`](../../lib/store/orders/order_adjustment.ex), [`refund_adjustment.ex`](../../lib/store/orders/refund_adjustment.ex), [`inventory_reservation.ex`](../../lib/store/orders/inventory_reservation.ex), [`payment_application.ex`](../../lib/store/orders/payment_application.ex) |
| Payments | Payment intents, attempts, refunds, and refund attempts are readable by `super_admin`, `admin`, and `support`. Provider events and webhook receipts are restricted to `super_admin` and `admin`. No customer payment-intent read action exists in the resource. | Intent creation, provider-reference writes, submission, and payment state transitions are system or `super_admin`/`admin`. Refund request is system or `super_admin`/`admin` with recent step-up; refund transitions, provider-event ingest, receipt ingest, and attempt records are system-only. | Admins inspect payment evidence and request refunds. Refund request also validates payment/order/currency/amount/scope and locks the payment intent. Support can read many payment records but cannot request or transition refunds. | [`payment_intent.ex`](../../lib/store/payments/payment_intent.ex), [`payment_attempt.ex`](../../lib/store/payments/payment_attempt.ex), [`provider_event.ex`](../../lib/store/payments/provider_event.ex), [`webhook_receipt.ex`](../../lib/store/payments/webhook_receipt.ex), [`refund.ex`](../../lib/store/payments/refund.ex), [`refund_attempt.ex`](../../lib/store/payments/refund_attempt.ex), [`refunds.ex`](../../lib/store/payments/refunds.ex) |
| Subscriptions | A customer reads only subscriptions whose `user_id` matches the actor through `read_for_user` and `get_for_user`. Admin/support/system have broad subscription and operational-record reads. Public users can read active subscription plans through public actions. | A customer may cancel their own subscription now or at period end and queue their own plan/variant change. Creation, activation, dunning transitions, period extension, expiry, provider billing-reference changes, and renewal records are system or `super_admin`/`admin`. | `super_admin`/`admin` can read and manage any subscription. `support` can inspect subscription records but is not allowed to mutate them. | [`subscription.ex`](../../lib/store/subscriptions/subscription.ex), [`subscription_plan.ex`](../../lib/store/subscriptions/subscription_plan.ex), [`subscription_item.ex`](../../lib/store/subscriptions/subscription_item.ex), [`renewal_attempt.ex`](../../lib/store/subscriptions/renewal_attempt.ex), [`stored_payment_method.ex`](../../lib/store/subscriptions/stored_payment_method.ex), [`variant_subscription_plan.ex`](../../lib/store/subscriptions/variant_subscription_plan.ex) |
| Entitlements | A user reads only own grants through the `read_for_user` filter. Admin/support/system can read grants broadly. The entitlement facade separately builds an effective set for a specific user. | Issue, revoke, and expiry paths are system or `super_admin`/`admin` as defined by the resource/facade. Support cannot mutate grants. Digital download grants are issued by system paths; user reads are actor-scoped and admin/support reads are broad. | Admins can inspect and revoke entitlement or download-grant records through the allowed domain surfaces. Effective access also depends on status, revocation, validity time, and cache state. | [`entitlement_grant.ex`](../../lib/store/entitlements/entitlement_grant.ex), [`facade.ex`](../../lib/store/entitlements/facade.ex), [`download_grant.ex`](../../lib/store/digital/download_grant.ex), [`digital/facade.ex`](../../lib/store/digital/facade.ex) |
| Inventory | Inventory items and order reservations are not customer-readable. Admin/support can read inventory and reservation state. | Inventory counts and reservation lifecycle are system or `super_admin`/`admin`; reservations are created, consumed, expired, or cancelled through order/payment domain paths. | `super_admin`/`admin` can change stock and reservation state. Support has read access but no mutation path in the inspected policies. | [`inventory_item.ex`](../../lib/store/catalog/inventory_item.ex), [`inventory_reservation.ex`](../../lib/store/orders/inventory_reservation.ex), [`inventory_reservations.ex`](../../lib/store/orders/inventory_reservations.ex) |

### Policy composition and current gaps

- Role checks query `RoleAssignment` through `Store.Admin.Authorization`. There is no user-row role field that can be used as a second, independent authority.
- Row visibility is sometimes expressed as Ash filter policy, as with user orders, user subscriptions, user entitlements, and user download grants. Other child resources rely on a preparation that first finds visible parent order IDs.
- The cart facade and checkout domain perform ownership checks around direct repository work. A `CartItem` has no independent owner policy, so its parent-cart lookup is the security boundary.
- Several domain and worker paths use `authorize?: false` together with `system?: true`. This is intentional for trusted internal orchestration, but it means extraction must prevent ordinary callers from reaching those paths or manufacturing the system context.
- Resource fields that contain provider references and a provider client secret are marked public in `PaymentIntent`, and provider identifiers are public on several subscription and stored-payment-method resources. The current customer-facing read surfaces are narrower than those resource attributes, but an extracted generic serializer or API must not infer public exposure from the attribute flags alone.
- `ProductImage`, product option, option value, and variant-selection primary reads use `always()` rather than the published/active filters used by storefront actions. The storefront facade chooses constrained public actions, but a direct generic resource surface could expose records outside that storefront visibility rule.

## 5. Ownership model

The requested ownership chain is transitive rather than uniformly represented by a direct foreign key.

| Object | Owner or authority | Customer read rule | Customer mutation rule |
|---|---|---|---|
| User | The authenticated Ash actor identified by `users.id` | The user resource permits ordinary reads only for the actor's own id | Password, confirmation, and OAuth flows are owned by AshAuthentication. No general customer role-assignment mutation exists. |
| Cart | `carts.user_id` for an authenticated cart; `carts.token` for a guest cart. `user_id` is nullable. | Authenticated lookup is by actor id. Guest lookup is by the cart token. The cart resource also permits an active token in the action context. | Customers mutate through `Store.Carts.Facade` after the parent cart is found by actor/token. Cart items have no independent customer policy. Auth merges the guest token into the user's active cart. |
| Order | `orders.user_id` when the order is associated with an account; nil for guest checkout. | Authenticated order reads are filtered to the actor. Guest checkout access is checked by the checkout domain using the checkout key plus the cart-token relationship. | Customer order writes are not exposed as ordinary actions. System/admin paths create and transition orders; support can cancel under the order policy. |
| Payment | No direct customer owner column on `payment_intents`. Ownership is inherited from `order_id` or `subscription_id` when present. Provider event and webhook receipt records are operational evidence, not customer-owned records. | No customer payment-intent resource read action. Admin/support reads are role-gated. Checkout uses the domain facade rather than exposing the payment record as a generic customer read. | Customer checkout can request payment intent creation through the checkout/payment facade, but the resource action runs under a system path. Provider state changes are worker-only after verified evidence. |
| Subscription | `subscriptions.user_id`, a non-null foreign key to `users`. Source order and source line item are also non-null foreign keys. | `read_for_user` and `get_for_user` filter by actor user id. | The owner can cancel and queue a plan/variant change for their own subscription. Creation, activation, renewal, expiry, and provider-reference changes are system/admin operations. |
| Entitlement | `entitlement_grants.user_id`, a non-null foreign key to `users`; the source id points to the subscription. | `read_for_user` filters by actor user id. The cached effective set is keyed by user id and checks active, non-revoked, non-expired grants. | Issue/revoke/expire are system/admin operations. Customers cannot directly edit grants. |
| Digital download grant | `download_grants.actor_user_id`, a non-null foreign key to `users`, with order, line-item, and asset foreign keys. | The facade requires actor id equality with `actor_user_id` and a live grant. It generates a short-lived signed URL only after that check. | Issued by the paid-order worker; revoked by system/admin paths; expiry is system-managed. |

The current ownership flow is:

```text
User
  -> Cart (account id or guest bearer token)
  -> Order (account id or guest checkout relationship)
  -> Payment (transitive order/subscription linkage)
  -> Subscription (non-null user id)
  -> Entitlement (non-null user id and subscription source)
```

### Ownership gaps relevant to extraction

- Guest carts and guest checkout are bearer-capability flows. A cart token or checkout key is not equivalent to an authenticated user identity.
- `carts.user_id`, `orders.user_id`, and `checkout_drafts.user_id` are plain nullable UUID columns in the inspected migrations rather than foreign keys. `orders.user_id` is indexed, but database referential integrity does not enforce the association.
- `payment_intents.order_id` is nullable and was created as a plain UUID column. The later `subscription_id` field has a foreign key, but payment ownership remains transitive and split across nullable relationships.
- Role assignments have a `user_id` column but the inspected admin migration does not declare a user foreign key. `assigned_by` is also not a database foreign key.
- Order ownership and cart-token ownership are enforced in Ash filters or facade code, not by PostgreSQL row-level security. A direct repository path or a generic extracted read API must preserve those checks.
- The current cache key for effective entitlements is `user:<user_id>`. It is safe for the current single-tenant shape only because there is no tenant dimension. Reusing it in a shared extracted or multi-tenant cache would create a key-collision boundary.

## 6. Payment trust boundary

```text
Client
  -> Application checkout and payment facade
  -> Payment provider
  -> Signed webhook or provider callback
  -> Receipt and provider-event evidence
  -> Worker reconciliation
  -> Commerce state
```

### Trust decisions

- The client is untrusted for payment proof. Return and cancel routes are read-only and do not mark an order paid, refunded, or confirmed. Query parameters from those routes are not used as payment evidence.
- The application is trusted to calculate and persist checkout snapshots, integer minor-unit amounts, currency, local order ids, and idempotency keys. It creates provider intent payloads and redirects but does not treat a client redirect as settlement.
- The provider is the external payment authority only through a verified event or a provider response handled by the provider boundary. A provider-shaped body without a valid signature is not trusted.
- The webhook controller verifies the raw body and headers, normalizes the payload to a canonical receipt, persists evidence, and enqueues. It does not perform commerce state transitions or outbound provider calls.
- The worker is trusted to reconcile verified evidence. It validates provider, event identity, local references, amount, currency, intent purpose, and applicable order/subscription state before applying transitions.

### Payment validation points

1. Provider selection is normalized and must be enabled. The provider resolver fails closed for unknown or disabled providers.
2. The Stripe adapter checks `stripe-signature`, parses the timestamp and `v1` signatures, applies a 300-second tolerance, computes HMAC-SHA256 over `timestamp.raw_body`, uses secure comparison, and only then decodes JSON.
3. Canonical normalization extracts provider event id/type, provider session/payment references, local intent metadata, amount, currency, and status.
4. The receipt uses an idempotency key from the canonical provider value or `provider:event_id`; the raw body hash is persisted.
5. Payment interlocks deduplicate provider events and payment applications, check local linkage and amount/currency, and apply state transitions through system domain actions.
6. Refund requests require an admin or super-admin role plus recent step-up unless they are system calls. They require a succeeded payment intent, a paid order, matching order and currency, a positive amount within remaining refundable value, and a locked payment-intent row.
7. Refund completion is driven by verified provider refund events. The local refund evidence, provider event key, refund attempt, refund adjustment, order threshold, and digital revocation paths are replay-aware.

The provider adapter behavior declares capabilities for checkout, refunds, tokenization, renewals, and webhooks. Stripe implements the inspected paths. PayFast, Paystack, Peach Payments, and Yoco contain scaffold or “not implemented yet” paths for important operations. Capability declarations and enabled-provider configuration are therefore not proof that a provider is safe to extract or operationally complete.

## 7. Webhook security

### Signature validation

`StoreWeb.WebhookController` and `StoreWeb.PaymentCallbackController` require the exact raw body captured by the endpoint body reader. They pass raw body plus headers to the provider adapter before JSON normalization. The Stripe adapter rejects missing or invalid signatures, missing secrets, stale timestamps, failed HMAC comparison, and invalid JSON. The raw body is retained in the receipt for evidence until the retention worker purges it.

The controller accepts the provider only after normalization, persists a `WebhookReceipt` through the system facade, and returns `202 Accepted` with the receipt id. It does not mark payment state or make an outbound HTTP request.

### Duplicate and replay handling

- `WebhookReceipt.ingest` is an upsert on `idempotency_key` and returns a skipped-upsert result for duplicates.
- The preferred key is the canonical provider idempotency key; otherwise the controller uses `provider:event_id`. The receipt also has a unique `(provider, provider_event_id)` identity when an event id is present.
- Duplicate receipts do not enqueue a second job. New receipts enqueue one normal or refund worker, and the Oban job is unique over worker and args for 24 hours including completed jobs.
- Workers load the receipt through a system-only action. Payment processing records `ProviderEvent` and `PaymentAttempt` evidence, while refund processing records `ProviderEvent` and `RefundAttempt` evidence with unique provider event keys.
- State transitions are performed by system domain paths and are intended to be replay-safe. Receipt status is tracked as `new`, `processing`, `processed`, or `failed`.
- `PurgeWebhookReceiptEvidenceWorker` runs as an operational job and, by default, replaces the raw body with `[PURGED]` and clears headers after the configured 30-day retention period. The event identity and processing metadata remain.

### Current webhook risks

- Rate limiting is keyed by remote IP, with a default of 120 requests per 60 seconds. The in-app limiter allows the request when its backend returns an error, so a rate-limit backend failure is fail-open.
- The limiter is configured for ETS by default in the base configuration and can use Redis at runtime. ETS is per node, so it is not a global protection boundary in a multi-node deployment.
- The normal webhook controller dispatches refund event types to the refund worker. The payment callback controller always enqueues the normal payment worker. These two ingress paths do not have identical event dispatch behavior.
- An accepted receipt can still fail later in Oban or the worker. The database receipt is the durable evidence, but operational retry, queue lag, and failure monitoring remain part of the security boundary.
- The current provider adapter set is not uniformly implemented. Extracting a provider-agnostic webhook contract from the capability map would overstate the protection actually supplied by non-Stripe adapters.

## 8. Subscription security

### Creation and activation

Subscriptions are created from a paid order by `EnsureSubscriptionsForPaidOrderWorker` and the subscription facade. The source order line is unique, the user must be present, and the payment must be succeeded. Activation and initial entitlement issue occur after payment success in worker/domain paths, not from a customer return URL.

The subscription has a non-null user foreign key, source order and line-item foreign keys, unique source-line identity, and a unique provider subscription reference when present. Customer reads are filtered to their own user id. Admin reads are broad and role-gated.

### Cancellation and changes

The owner can request cancellation now, cancellation at period end, or queue a plan/variant change for their own subscription. `super_admin` and `admin` can perform those operations for any subscription. Support can read subscription records but is not allowed by the resource policies to perform those mutations.

Renewal discovery and processing are Oban-only. Due subscriptions are read through a system action, renewal work is keyed by a period-specific `renewal_key`, and `RenewalAttempt` has a unique `(subscription_id, renewal_key)` identity. Renewal, dunning, expiry, period extension, and payment reconciliation run as system worker paths.

Payment method update starts from an owner or admin subscription facade, uses a provider setup intent, and stores provider references after verified setup success. The subscription policy permits `set_provider_billing_reference` to system or admin, but no separate step-up condition is present on that action. Stored payment methods have an owner filter for ordinary reads plus broad system/admin/support reads; their provider references are public attributes in the resource definition.

### Subscription-specific gaps

- The worker is a high-authority actor. Its correctness depends on the queue boundary, unique renewal key, provider verification, and resource state guards rather than on an interactive user session.
- The subscription resource has broad public attributes for provider references and billing state. Generic serializers must not turn those fields into customer API exposure.
- Admin provider-reference mutation is role-gated but is not step-up-gated in the subscription resource.
- The code contains explicit renewal uniqueness and worker replay handling, but no database tenant or account boundary exists around a subscription.

## 9. Entitlement security

Entitlements represent access control rather than merely commerce history. `EntitlementGrant` belongs to a user and subscription, has active/revoked/expired status, validity timestamps, a revocation timestamp/reason, and a unique user/scope/source identity.

The ordinary user read action filters by `user_id == actor.id`. System, admin, and support can read broadly. Issue and mutation paths are controlled by system or admin policy. Subscription workers issue grants after a successful paid subscription path; subscription expiry, cancellation, refund policy, and other system paths can revoke them.

The entitlement facade builds an effective set from active grants, then applies revocation and validity-time checks. It caches the set in Cachex under a key containing the user id, with a 60-second TTL. Writes invalidate the local cache and broadcast a Phoenix PubSub invalidation after the durable write. Authenticated LiveViews subscribe to the user-specific invalidation topic.

Digital access is separately represented by `DownloadGrant`. The grant has a non-null user foreign key, order/line/asset foreign keys, active/revoked/expired status, expiration, download counters, and a unique order-line/asset identity. The digital facade checks the actor id, grant state, expiry, per-grant rate limit, active asset, and signed-URL host before issuing a short-lived URL. Paid-order grant issuance and refund revocation are worker/system paths.

Current access-control risks are the split between Ash filter policy, manual facade filters, cached effective sets, and LiveView invalidation. A cache hit can remain stale for up to 60 seconds if invalidation is delayed or missed. A signed URL that has already been issued can remain usable until its short TTL expires; later grant revocation does not retroactively invalidate the URL unless the storage provider applies an independent check.

## 10. Admin security

### Roles and route access

`RoleAssignment` is the role authority. It enforces unique `(user_id, role)`, allows bootstrap/system reads and writes, and restricts ordinary role assignment creation to `super_admin`. Role assignment actions are audited. The bootstrap task creates the initial `super_admin` assignment using bootstrap/system context.

The `/admin` route is actor-required and accepts `super_admin`, `admin`, or `support`. The dashboard itself requires `super_admin` or `admin`. Individual screens gate according to their operation: catalog, pricing, shipping, tax, and digital configuration generally require `super_admin` or `admin`; subscriptions, fulfillment, and email-outbox screens can expose support read or limited operational access. Resource policies remain the final data/action boundary.

### Privileged workflows

- Catalog publish, unpublish, archive, product/variant/option changes, and inventory count changes.
- Order cancellation, checkout snapshot writes, payment state reconciliation, and fulfillment operations.
- Payment evidence inspection and refund request. Refunds require admin/super-admin plus a recent 15-minute step-up unless system context is used.
- Provider configuration through `SiteSetting` is admin/super-admin and step-up-gated. Runtime provider secrets are loaded from environment configuration rather than stored as ordinary site settings.
- Subscription cancellation for another user, provider billing-reference changes, activation, expiry, renewal, and dunning transitions.
- Entitlement and download-grant inspection, issue, revocation, expiry, and refund-triggered access changes.
- Webhook evidence inspection, evidence retention purge, and worker-driven state transitions.

### Audit and dangerous-operation observations

`AuditLog` is append-only at the resource level, is created by system paths, and is readable by admin/support roles. The sanitizer limits metadata keys and payload size. Audit hooks exist on role assignment and selected admin/payment mutations. The inspection did not establish that every privileged commerce transition, every worker transition, or every direct repository mutation creates an audit record.

The most dangerous operations are refund initiation, payment state changes, provider-reference writes, inventory adjustments, subscription cancellation/renewal changes, entitlement revocation, and role assignment. Their safety currently depends on the combination of role policy, step-up where present, system-context containment, state/version checks, row locks, unique identities, and post-commit worker behavior.

## 11. Multi-tenant readiness assessment

### Current state

The application is explicitly single-tenant. The inspected code, migrations, routes, caches, and policies contain no `tenant_id`, tenant routing, organization boundary, marketplace boundary, or database RLS policy. User ownership is the only customer data partition, and admin roles can read across all users within the one store.

### Readiness observations

| Area | Current reality | Extraction implication |
|---|---|---|
| Tenant identifiers | None in users, carts, orders, payments, subscriptions, entitlements, inventory, or webhook evidence | A shared extracted service cannot infer a tenant from current records. Tenant identity would be a new architecture concern, not a field to preserve from this implementation. |
| Data boundaries | User filters, guest cart tokens, source relationships, role checks, and domain facades | These are account and capability boundaries, not tenant isolation. They do not prevent one store's admin from seeing another store because another store does not exist. |
| Policy assumptions | Policies use actor id, roles, system context, and sometimes global admin reads | Adding a tenant dimension would require every filter, admin read, system worker, cache key, webhook receipt, and unique identity to be reviewed. Current policies cannot be described as tenant-safe. |
| Database isolation | Foreign keys, unique/check constraints, and indexes; no RLS or tenant predicates | Constraints preserve shape and replay identity, but they do not enforce cross-tenant isolation. |
| Operational identity | Provider, event, renewal, and idempotency keys are not tenant-qualified | Reusing the current keys across stores could collide unless the extracted design deliberately introduces a tenant-scoped identity. |

No tenancy is implemented or proposed by this document.

## 12. Extraction security risks

The classifications below describe readiness of the current behavior as an extraction boundary. They do not approve a redesign or prescribe a hardening change.

### READY

- Password and Google identity flows have explicit AshAuthentication resources and route/session integration.
- Browser and API actor loading are distinct and visible in the router.
- Customer order, subscription, entitlement, and download reads have identified owner filters or facade checks.
- Stripe raw-body signature verification, canonical normalization, receipt persistence, and worker handoff are explicit.
- Payment and refund evidence has durable provider-event/idempotency identities, and refund requests have amount, currency, state, lock, and step-up checks.
- Renewal attempts, paid-order subscription creation, digital grant issuance, and webhook jobs have named worker boundaries and several unique/replay guards.

### PARTIAL

- Authorization is split between Ash policies, parent-order preparations, role queries, and direct facade/repository paths. The extraction boundary must preserve all of them together.
- Guest cart and checkout ownership is a bearer-token capability. The unsigned-cookie fallback and lack of a user identity make token handling a material extraction boundary.
- Admin access is role-gated, but route access, individual LiveView checks, resource policies, and support permissions are not one uniform matrix. Some current resource fields are public even when they contain provider identifiers.
- Step-up is consumed by sensitive checks, but no in-repository producer or reauthentication/MFA flow was found.
- Entitlement access combines database state, manual effective checks, a 60-second per-user cache, PubSub invalidation, and digital grant checks. Stale-cache and post-revocation URL windows remain part of the current model.
- Webhook dedupe and worker replay handling are present, but the two ingress controllers dispatch callback events differently and the IP rate limiter can fail open on backend errors.
- Audit coverage is present for selected operations but was not proven for all privileged lifecycle transitions and direct repository mutations.

### NOT READY

- Multi-tenant extraction. There is no tenant identifier, tenant-qualified key, tenant route, tenant cache namespace, or database isolation policy.
- Provider-neutral payment extraction. Stripe is implemented; several other adapters expose scaffold behavior or unimplemented verification/normalization/charge paths despite capability declarations.
- Database-enforced ownership for nullable `carts.user_id`, `orders.user_id`, and `checkout_drafts.user_id`, and for the plain UUID `payment_intents.order_id` linkage.
- A generic extracted serializer or public API that relies on Ash `public?` attributes for payment, subscription, stored-payment-method, webhook, or download records.
- A worker boundary that is safe solely because it has a system flag. System contexts and `authorize?: false` must remain unreachable from untrusted inputs and must preserve typed facade validation.

## Performance and security review

### Hot paths

- Catalog browse and detail use product/availability/stock caches. Product caches are public projections, while user entitlement state is separately keyed by user id. An extracted shared cache must not reuse a public cache namespace for user-sensitive values.
- Cart and checkout ownership checks sit on frequent request paths. Cart mutations can use direct repository work after facade lookup, so a missed parent check would be both a performance shortcut and an authorization failure. Cart item work and checkout loads should be measured for per-item query growth.
- Payment webhook ingress is designed as a thin verify, persist, and enqueue path. Duplicate delivery still consumes signature verification and a receipt upsert, but it skips a second job. The webhook and refund queues are bounded at 10 workers in base configuration, so bursts can produce queue lag and increase the time before a payment or revocation is reflected.
- Entitlement checks avoid a database read on every LiveView render through a per-user Cachex set. The 60-second TTL and PubSub invalidation reduce load but create a stale-permission window if invalidation or node delivery fails.
- Role checks read role assignments at authorization time rather than using a documented role cache. This reduces stale-role permission risk but can add database reads to admin hot paths and to repeated policy checks.

### Warm and cold paths

- Warm paths include recent account/order/subscription reads, operational admin tables, webhook receipt processing, and queue retries. Indexes exist for user/status, provider references, event identities, renewal keys, entitlement lookups, and grant expiry.
- Cold paths include audit history, purged webhook evidence, refund history, and operational cleanup. They are less latency-sensitive but carry sensitive evidence and should remain behind role/system policies.
- PostgreSQL is the source of truth for payment, order, inventory, subscription, entitlement, and webhook state. Cache and queue records do not establish authority.

### Query, cache, and queue interactions

- Parent-scoped reads and child-resource preparations can introduce extra queries or N+1 behavior, especially for order lines/adjustments, cart merge, digital grant revocation, and subscription renewal fan-out.
- Current invalidation uses local Cachex plus PubSub for entitlements and catalog projections. There is no tenant component in these keys because the implementation is single-tenant.
- Oban uniqueness protects receipt jobs, renewal jobs, grant issuance, fulfillment, and selected outbox work, but queue capacity and retry behavior still determine how long security state remains stale.
- The inspected code emits webhook, digital signed-URL, catalog cache, and payment-ingress telemetry. Extraction should preserve measurements for authorization outcomes, cache hit/miss and invalidation, queue lag, duplicate/replay outcome, lock waits, and provider verification failures. No production p95/p99, multi-node cache, or webhook-storm result is inferred from static code inspection.

The performance guidance used for comparison is [`performance_scaling.md`](../governance/performance_scaling.md) and [`phase_29_performance_architecture_optimizations.md`](../phases/phase_29_performance_architecture_optimizations.md). Those documents define future measurement and scaling expectations; they are not evidence that the current runtime meets each budget.

## Sources consulted

- [`AGENTS.md`](../../AGENTS.md) and [`docs/agent_rules/phoenix_guidelines.md`](../agent_rules/phoenix_guidelines.md)
- [`phase_02_auth.md`](../phases/phase_02_auth.md), [`phase_03_admin.md`](../phases/phase_03_admin.md), and [`phase_06_policy_matrix.md`](../phases/phase_06_policy_matrix.md)
- [`policy_matrix.md`](../governance/policy_matrix.md), [`payment_provider_contract.md`](../governance/payment_provider_contract.md), [`payment_provider_capabilities.md`](../governance/payment_provider_capabilities.md), [`idempotency.md`](../governance/idempotency.md), [`refund_semantics.md`](../governance/refund_semantics.md), [`step_up.md`](../governance/step_up.md), and [`audit_and_pii.md`](../governance/audit_and_pii.md)
- Authentication resources, router/session plugs, role/policy resources, domain facades, payment provider adapters, webhook controllers/workers, subscription workers, entitlement/digital facades, and PostgreSQL migrations under [`lib`](../../lib) and [`priv/repo/migrations`](../../priv/repo/migrations)
- Relevant authorization, webhook, refund, subscription, entitlement, cart, digital, admin, and performance tests under [`test`](../../test)
