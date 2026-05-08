# Production Runbook

## Purpose
- Define the Phase 28 operator contract for go-live, rollback, and incident handling.
- Use release commands only. Do not assume `mix` exists on a production host.

## Release Commands
- Preflight:
  - `bin/store eval "Store.Release.preflight()"`
- Restore audit:
  - `bin/store eval "Store.Release.restore_audit()"`
- Migrations:
  - `bin/store eval "Store.Release.migrate_all()"`

## Go-Live Checklist
- Verify required-always production env vars are present:
  - `DATABASE_URL`
  - `SECRET_KEY_BASE`
  - `SENTRY_DSN`
  - `STORE_TOKEN_SIGNING_SECRET`
  - `STORE_GOOGLE_CLIENT_ID`
  - `STORE_GOOGLE_CLIENT_SECRET`
  - `STORE_GOOGLE_REDIRECT_URI_BASE`
  - `STORE_QUOTE_HASH_SECRET`
- Verify optional vars (runtime defaults exist unless overridden intentionally):
  - `PHX_HOST` (default `example.com`)
  - `PORT` (default `4000`)
  - `STORE_DB_POOL_MODE` (default `session`; set `transaction` when using PgBouncer transaction pooling)
  - `STORE_WEBHOOK_RETENTION_DAYS` (default `30`)
  - `STORE_WEBHOOK_RATE_LIMIT_LIMIT` (default `120`)
  - `STORE_WEBHOOK_RATE_LIMIT_WINDOW_SECONDS` (default `60`)
  - `STORE_ADMIN_RATE_LIMIT_LIMIT` (default `300`)
  - `STORE_ADMIN_RATE_LIMIT_WINDOW_SECONDS` (default `60`)
  - `STORE_TRUSTED_PROXY_PROXIES` only if overriding compile-time trusted proxy defaults
- Verify conditional vars based on deployment mode:
  - `STORE_STRIPE_SECRET_KEY`, `STORE_STRIPE_PUBLISHABLE_KEY`, `STORE_STRIPE_WEBHOOK_SECRET` only when `STORE_PAYMENTS_ENABLED_PROVIDERS` includes `stripe`
  - `RELEASE_COOKIE` only when clustering/distribution is enabled (`DNS_CLUSTER_QUERY` set and multi-node distribution expected)
  - `DNS_CLUSTER_QUERY` can be set directly, or resolved from `RAILWAY_PRIVATE_DOMAIN` / `RAILWAY_PRIVATE_NETWORKING_DOMAIN`
- Run preflight from the release:
  - `bin/store eval "Store.Release.preflight()"`
- Railway deploys must run migrations through the pre-deploy command in `railway.toml`:
  - `bin/store eval "Store.Release.migrate_all()"`
- Do not run migrations manually after traffic has already shifted to the new web containers.
- Confirm health endpoints:
  - `GET /health/live`
  - `GET /health/ready`
- Run smoke flow:
  - browse product
  - add to cart
  - create checkout
  - complete payment
  - verify webhook receipt created
  - verify receipt email sent
  - for digital goods, verify signed URL issuance

## Edge and WAF Requirements
- Trust Cloudflare as a proxy only after the origin rewrites `conn.remote_ip` from `CF-Connecting-IP` / forwarded headers.
- Keep the trusted proxy CIDR list aligned with Cloudflare's published ranges if `STORE_TRUSTED_PROXY_PROXIES` is overridden.
- Do not point the waiting room or app-level rate limits at raw Cloudflare edge IPs.
- Keep Stripe signature verification enabled at the app boundary.
- Also allow Stripe webhook traffic at the edge or reverse proxy using Stripe’s published IP list:
  - [Stripe IP addresses](https://docs.stripe.com/ips)
- Re-check the published Stripe ranges during go-live and whenever firewall rules change.
- Do not rely on IP allowlisting as the only control; signature verification remains mandatory.

## Clustering and CDN
- `DNS_CLUSTER_QUERY` should resolve to the Railway private service domain (`*.railway.internal`) when clustering is enabled.
- Runtime fallback order is: explicit `DNS_CLUSTER_QUERY`, then `RAILWAY_PRIVATE_DOMAIN`, then `RAILWAY_PRIVATE_NETWORKING_DOMAIN`.
- `rel/env.sh.eex` auto-exports `DNS_CLUSTER_QUERY` from `RAILWAY_PRIVATE_DOMAIN` only when `DNS_CLUSTER_QUERY` is unset; it does not auto-export from `RAILWAY_PRIVATE_NETWORKING_DOMAIN`.
- `rel/env.sh.eex` sets named distribution and IPv6 transport for Railway-compatible clustering; keep `RELEASE_COOKIE` consistent across replicas.
- After autoscaling, verify that PubSub-sensitive flows propagate across nodes:
  - checkout/order state changes
  - catalog/shipping cache invalidations
- Cloudflare should cache digested static assets aggressively.
- Cloudflare must not cache cart, checkout, order, waiting-room, or authenticated account pages.

## Rollback
- If the release is unhealthy, roll back application code first.
- Do not attempt to reverse already-authorized or already-settled payments from the app rollback path.
- Keep webhook endpoints available during rollback so provider events still land.
- After rollback:
  - rerun `GET /health/ready`
  - inspect webhook backlog
  - inspect email outbox backlog
  - reconcile paid orders that arrived during the transition window

## Incident Response
- Webhook failures:
  - inspect `webhook_receipts` backlog and failed rows
  - verify edge/WAF rules did not block provider traffic
  - verify `STORE_STRIPE_WEBHOOK_SECRET` and endpoint configuration match
- Renewal failures:
  - inspect renewal backlog telemetry
  - confirm stored payment references exist
  - inspect authentication-required emails for action URLs
- Email failures:
  - inspect `email_outboxes` pending and failed counts
  - confirm provider credentials and retry queues

## Observability Notes
- Ignore these noisy exception classes in Sentry:
  - `Phoenix.Router.NoRouteError`
  - `Ecto.NoResultsError`
- Use `request_id`, `order_ref`, `provider_event_id`, `error_code`, `oban_job_id`, and `worker` metadata when correlating incidents.
