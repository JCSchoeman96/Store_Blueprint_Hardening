# Route Inventory

Purpose: define the canonical public URL surface for QA and search indexing, and separate it from auth/internal routes.

Source of truth used for this inventory:
- `mix phx.routes` (captured on 2026-03-02)
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
| GET | `/admin` | LiveView (`StoreWeb.AdminLive :index`) | Yes | Restricted role surface; never index. |
| GET | `/admin/shipping-zones` | LiveView (`StoreWeb.Admin.ShippingZones.IndexLive :index`) | Yes | Restricted role surface; never index. |
| GET | `/admin/shipping-zones/new` | LiveView (`StoreWeb.Admin.ShippingZones.IndexLive :new`) | Yes | Restricted role surface; never index. |
| GET | `/admin/shipping-zones/:id/edit` | LiveView (`StoreWeb.Admin.ShippingZones.IndexLive :edit`) | Yes | Restricted role surface; never index. |
| GET | `/admin/shipping-rates` | LiveView (`StoreWeb.Admin.ShippingRates.IndexLive :index`) | Yes | Restricted role surface; never index. |
| GET | `/admin/shipping-rates/new` | LiveView (`StoreWeb.Admin.ShippingRates.IndexLive :new`) | Yes | Restricted role surface; never index. |
| GET | `/admin/shipping-rates/:id/edit` | LiveView (`StoreWeb.Admin.ShippingRates.IndexLive :edit`) | Yes | Restricted role surface; never index. |
| GET | `/admin/tax-rates` | LiveView (`StoreWeb.Admin.TaxRates.IndexLive :index`) | Yes | Restricted role surface; never index. |
| GET | `/admin/tax-rates/new` | LiveView (`StoreWeb.Admin.TaxRates.IndexLive :new`) | Yes | Restricted role surface; never index. |
| GET | `/admin/tax-rates/:id/edit` | LiveView (`StoreWeb.Admin.TaxRates.IndexLive :edit`) | Yes | Restricted role surface; never index. |

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

- `/shop` -> `/products`
- `/catalog` -> `/products`

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
- `/admin/shipping-zones`
- `/admin/shipping-rates`
- `/admin/tax-rates`

When catalog/checkout routes exist, extend this smoke pass to:
- `/products`
- `/cart`
- `/checkout`
- legal routes (for example `/terms`, `/privacy`)
