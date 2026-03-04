# Route Inventory

Purpose: define the canonical public URL surface for QA and search indexing, and separate it from auth/internal routes.

Source of truth used for this inventory:
- `mix phx.routes` (captured on 2026-03-03)
- `lib/store_web/router.ex`

Reference excerpt from `mix phx.routes` (auth/public slice):
- `GET /sign-in        AshAuthentication.Phoenix.SignInLive :sign_in`
- `GET /forgot-password AshAuthentication.Phoenix.SignInLive :reset`
- `GET /register       AshAuthentication.Phoenix.SignInLive :register`
- `GET /password-reset/:token AshAuthentication.Phoenix.ResetLive :reset`
- `GET /confirm-new-user/:token AshAuthentication.Phoenix.ConfirmLive :confirm`

## Public routes (indexable)

| Method | Path | Surface | Canonical | Notes |
|---|---|---|---|---|
| GET | `/` | Controller (`StoreWeb.PageController :home`) | Yes | Home page; included in sitemap. |
| GET | `/shop` | LiveView (`StoreWeb.ShopLive.Index :index`) | Yes | Catalog storefront list route for simple products. |
| GET | `/shop/:slug` | LiveView (`StoreWeb.ShopLive.Show :show`) | Yes | Catalog storefront product detail by slug. |
| GET | `/cart` | LiveView (`StoreWeb.CartLive :index`) | Yes | Cart management route (guest + user). |
| GET | `/checkout` | LiveView (`StoreWeb.CheckoutLive.Placeholder :index`) | Yes | Phase 21 checkout flow by `checkout_key` (shipping, totals finalization, payment handoff). |
| GET | `/checkout/return` | LiveView (`StoreWeb.CheckoutLive.Placeholder :return`) | Yes | Payment return route, read-only status view by `checkout_key`; never marks paid. |
| GET | `/checkout/cancel` | LiveView (`StoreWeb.CheckoutLive.Placeholder :cancel`) | Yes | Payment cancel route, read-only status view by `checkout_key`; never mutates payment/order state. |

## Planned public routes

| Method | Path | Surface | Canonical | Notes |
|---|---|---|---|---|
| GET | `/products` | LiveView alias (optional future) | No | Optional compatibility alias; must redirect to `/shop` when enabled. |

## Public routes (not for sitemap / not indexable)

| Method | Path | Surface | Canonical | Notes |
|---|---|---|---|---|
| GET | `/sign-in` | LiveView (`AshAuthentication.Phoenix.SignInLive :sign_in`) | Yes | Auth/session route; exclude from sitemap. |
| GET | `/register` | LiveView (`AshAuthentication.Phoenix.SignInLive :register`) | Yes | Auth/session route; exclude from sitemap. |
| GET | `/forgot-password` | LiveView (`AshAuthentication.Phoenix.SignInLive :reset`) | Yes | Auth/session route; exclude from sitemap. |
| GET | `/password-reset/:token` | LiveView (`AshAuthentication.Phoenix.ResetLive :reset`) | Yes | Tokenized auth flow; exclude from sitemap. |
| GET | `/confirm-new-user/:token` | LiveView (`AshAuthentication.Phoenix.ConfirmLive :confirm`) | Yes | Tokenized auth flow; exclude from sitemap. |
| GET | `/sign-out` | Controller (`StoreWeb.AuthController :sign_out`) | Yes | Session action route; exclude from sitemap. |

## Authenticated user routes

| Method | Path | Surface | Canonical | Notes |
|---|---|---|---|---|
| GET | `/account` | LiveView (`StoreWeb.AccountLive :index`) | Yes | Authenticated only. |
| GET | `/account/orders/:order_ref` | LiveView (`StoreWeb.Orders.ShowLive :show`) | Yes | Authenticated only. |
| GET | `/account/subscriptions` | LiveView (`StoreWeb.SubscriptionsLive.Index :index`) | Yes | Authenticated subscriptions overview. |
| GET | `/account/subscriptions/:id` | LiveView (`StoreWeb.SubscriptionsLive.Show :show`) | Yes | Authenticated subscription detail. |
| GET | `/account/downloads` | LiveView (`StoreWeb.Digital.DownloadsLive :index`) | Yes | Authenticated digital grant listing. |
| GET | `/account/downloads/:grant_id/request` | Controller (`StoreWeb.DigitalDownloadController :create`) | Yes | Authenticated signed URL issuance + external redirect. |
| GET | `/admin` | LiveView (`StoreWeb.AdminLive :index`) | Yes | Restricted role surface; never index. |
| GET | `/admin/subscriptions` | LiveView (`StoreWeb.Admin.Subscriptions.IndexLive :index`) | Yes | Restricted subscription operations surface; never index. |
| GET | `/admin/subscriptions/:id` | LiveView (`StoreWeb.Admin.Subscriptions.ShowLive :show`) | Yes | Restricted subscription detail surface; never index. |
| GET | `/admin/products` | LiveView (`StoreWeb.Admin.Products.IndexLive :index`) | Yes | Restricted role surface; never index. |
| GET | `/admin/products/new` | LiveView (`StoreWeb.Admin.Products.IndexLive :new`) | Yes | Restricted role surface; never index. |
| GET | `/admin/products/:id/edit` | LiveView (`StoreWeb.Admin.Products.IndexLive :edit`) | Yes | Restricted role surface; never index. |
| GET | `/admin/digital-assets` | LiveView (`StoreWeb.Admin.DigitalAssets.IndexLive :index`) | Yes | Restricted role surface; never index. |
| GET | `/admin/digital-assets/new` | LiveView (`StoreWeb.Admin.DigitalAssets.IndexLive :new`) | Yes | Restricted role surface; never index. |
| GET | `/admin/digital-assets/:id/edit` | LiveView (`StoreWeb.Admin.DigitalAssets.IndexLive :edit`) | Yes | Restricted role surface; never index. |
| GET | `/admin/product-digital-links` | LiveView (`StoreWeb.Admin.ProductDigitalLinks.IndexLive :index`) | Yes | Restricted role surface; never index. |
| GET | `/admin/product-digital-links/new` | LiveView (`StoreWeb.Admin.ProductDigitalLinks.IndexLive :new`) | Yes | Restricted role surface; never index. |
| GET | `/admin/product-digital-links/:id/edit` | LiveView (`StoreWeb.Admin.ProductDigitalLinks.IndexLive :edit`) | Yes | Restricted role surface; never index. |
| GET | `/admin/shipping-methods` | LiveView (`StoreWeb.Admin.ShippingMethods.IndexLive :index`) | Yes | Restricted role surface; never index. |
| GET | `/admin/shipping-methods/new` | LiveView (`StoreWeb.Admin.ShippingMethods.IndexLive :new`) | Yes | Restricted role surface; never index. |
| GET | `/admin/shipping-methods/:id/edit` | LiveView (`StoreWeb.Admin.ShippingMethods.IndexLive :edit`) | Yes | Restricted role surface; never index. |
| GET | `/admin/shipping-zones` | LiveView (`StoreWeb.Admin.ShippingZones.IndexLive :index`) | Yes | Restricted role surface; never index. |
| GET | `/admin/shipping-zones/new` | LiveView (`StoreWeb.Admin.ShippingZones.IndexLive :new`) | Yes | Restricted role surface; never index. |
| GET | `/admin/shipping-zones/:id/edit` | LiveView (`StoreWeb.Admin.ShippingZones.IndexLive :edit`) | Yes | Restricted role surface; never index. |
| GET | `/admin/shipping-rates` | LiveView (`StoreWeb.Admin.ShippingRates.IndexLive :index`) | Yes | Restricted role surface; never index. |
| GET | `/admin/shipping-rates/new` | LiveView (`StoreWeb.Admin.ShippingRates.IndexLive :new`) | Yes | Restricted role surface; never index. |
| GET | `/admin/shipping-rates/:id/edit` | LiveView (`StoreWeb.Admin.ShippingRates.IndexLive :edit`) | Yes | Restricted role surface; never index. |
| GET | `/admin/tax-rates` | LiveView (`StoreWeb.Admin.TaxRates.IndexLive :index`) | Yes | Restricted role surface; never index. |
| GET | `/admin/tax-rates/new` | LiveView (`StoreWeb.Admin.TaxRates.IndexLive :new`) | Yes | Restricted role surface; never index. |
| GET | `/admin/tax-rates/:id/edit` | LiveView (`StoreWeb.Admin.TaxRates.IndexLive :edit`) | Yes | Restricted role surface; never index. |
| GET | `/admin/email-outbox` | LiveView (`StoreWeb.Admin.EmailOutbox.IndexLive :index`) | Yes | Restricted role surface; never index. |

## Internal / API / webhook routes

| Method | Path | Surface | Canonical | Notes |
|---|---|---|---|---|
| GET | `/api/v1/orders` | JSON:API (`StoreWeb.JsonApiRouter`, `Store.Orders.read_for_user`) | Yes | Customer scoped list read; not indexable. |
| GET | `/api/v1/orders/:id` | JSON:API (`StoreWeb.JsonApiRouter`, `Store.Orders.get_for_user`) | Yes | Customer scoped get read; not indexable. |
| GET | `/api/v1/admin/orders` | JSON:API (`StoreWeb.JsonApiRouter`, `Store.Orders.read_for_admin`) | Yes | Admin/support scoped read; not indexable. |
| GET | `/api/v1/admin/orders/:id` | JSON:API (`StoreWeb.JsonApiRouter`, `Store.Orders.get_for_admin`) | Yes | Admin/support scoped get; not indexable. |
| GET | `/api/v1/admin/payment-intents` | JSON:API (`StoreWeb.JsonApiRouter`, `Store.Payments.PaymentIntent.read_for_admin`) | Yes | Admin/support scoped read; not indexable. |
| GET | `/api/v1/admin/payment-intents/:id` | JSON:API (`StoreWeb.JsonApiRouter`, `Store.Payments.PaymentIntent.get_for_admin`) | Yes | Admin/support scoped get; not indexable. |
| GET | `/api/v1/open_api` | JSON:API Router OpenAPI endpoint | Yes | Admin-only contract endpoint; not indexable. |
| GET | `/api/v1/json_schema` | JSON:API Router JSON Schema endpoint | Yes | Admin-only contract endpoint; not indexable. |
| POST | `/api/webhooks/:provider` | Controller (`StoreWeb.WebhookController :create`) | Yes | Webhook receiver; never index. |
| POST | `/api/payments/:provider/callback` | Controller (`StoreWeb.PaymentCallbackController :create`) | Yes | Payment callback enqueue-only route; never index. |
| * | `/auth/**` | AshAuthentication action endpoints | Yes | Auth internals; never index. |
| GET | `/dev/dashboard*` | LiveDashboard | Yes | Dev-only internal tooling. |
| * | `/dev/mailbox` | Swoosh preview | Yes | Dev-only internal tooling. |
| WS/GET/POST | `/live/*` | LiveView transport | Yes | Framework transport endpoints; never index. |

## Canonical redirects (implemented now)

- None currently implemented.

## Planned canonical redirects (not implemented yet)

- `/products` -> `/shop`
- `/catalog` -> `/shop`

## Sitemap inclusion policy

Include:
- stable, public, user-facing pages.

Exclude:
- auth/session/token routes
- admin/internal tooling
- webhook and API endpoints
- framework transport endpoints

## Manual UX gate (lightweight)

For each phase touching web routes, run a route smoke pass and record tested URLs:
- `/`
- `/sign-in`
- `/register`
- `/account` (auth required behavior)
- `/admin` (authorization behavior)
- `/account/downloads`
- `/admin/shipping-zones`
- `/admin/shipping-rates`
- `/admin/tax-rates`
- `/admin/email-outbox`

When catalog/checkout routes exist, extend this smoke pass to:
- `/shop`
- `/shop/:slug` (sample known slug)
- `/cart`
- `/checkout?checkout_key=<known draft key>`
- legal routes (for example `/terms`, `/privacy`)
