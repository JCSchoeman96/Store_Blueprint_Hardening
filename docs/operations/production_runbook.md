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
  - `bin/store eval "Ecto.Migrator.with_repo(Store.Repo, &Ecto.Migrator.run(&1, :up, all: true))"`

## Go-Live Checklist
- Verify production env vars are present:
  - `DATABASE_URL`
  - `SECRET_KEY_BASE`
  - `PHX_HOST`
  - `PORT`
  - `STORE_DB_POOL_MODE`
  - `STORE_STRIPE_SECRET_KEY`
  - `STORE_STRIPE_PUBLISHABLE_KEY`
  - `STORE_STRIPE_WEBHOOK_SECRET`
  - `SENTRY_DSN`
  - `STORE_WEBHOOK_RETENTION_DAYS`
  - `STORE_WEBHOOK_RATE_LIMIT_LIMIT`
  - `STORE_WEBHOOK_RATE_LIMIT_WINDOW_SECONDS`
  - `STORE_ADMIN_RATE_LIMIT_LIMIT`
  - `STORE_ADMIN_RATE_LIMIT_WINDOW_SECONDS`
- Run preflight from the release:
  - `bin/store eval "Store.Release.preflight()"`
- Run migrations before shifting traffic.
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
- Keep Stripe signature verification enabled at the app boundary.
- Also allow Stripe webhook traffic at the edge or reverse proxy using Stripe’s published IP list:
  - [Stripe IP addresses](https://docs.stripe.com/ips)
- Re-check the published Stripe ranges during go-live and whenever firewall rules change.
- Do not rely on IP allowlisting as the only control; signature verification remains mandatory.

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
