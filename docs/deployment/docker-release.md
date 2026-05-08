# Docker Release Operations

This document describes the current release/container model implemented by `Dockerfile` and release scripts.

## Image model

- Multi-stage build:
  - Build stage: `elixir:1.19.5-otp-28`
  - Runtime stage: `debian:bookworm-slim`
- Runtime process:
  - Non-root user: `appuser`
  - Exposed port: `4000`
  - Command: `bin/store start`
- `PHX_SERVER=true` is set in the runtime image.

## Build sequence

The release build performs:

1. `mix deps.get` / `mix deps.compile`
2. `mix compile`
3. `mix assets.deploy`
4. `mix release`

Compiling before assets ensures compile-time/generated assets are available before deployment packaging.

## Required env before boot

Use `docs/deployment/env-vars.md` as the canonical env contract. At minimum in production:

- `DATABASE_URL`
- `SECRET_KEY_BASE`
- `SENTRY_DSN`
- `STORE_TOKEN_SIGNING_SECRET`
- `STORE_GOOGLE_CLIENT_ID`
- `STORE_GOOGLE_CLIENT_SECRET`
- `STORE_GOOGLE_REDIRECT_URI_BASE`
- `STORE_QUOTE_HASH_SECRET`

Additional runtime nuance:

- `PHX_HOST` is optional and defaults to `example.com` unless explicitly set.
- Provider secrets are conditional by enabled provider (for example, Stripe keys are required only when `STORE_PAYMENTS_ENABLED_PROVIDERS` includes `stripe`).

## Preflight and migration commands

Run release commands inside the container/image, not `mix` on production hosts:

- Preflight:
  - `bin/store eval "Store.Release.preflight()"`
- Migrations:
  - `bin/store eval "Store.Release.migrate_all()"`
- Restore audit:
  - `bin/store eval "Store.Release.restore_audit()"`

## Health checks

- Liveness: `GET /health/live`
- Readiness: `GET /health/ready`

## PgBouncer and pool mode

- `pgbouncer/pgbouncer.ini` sets `pool_mode = transaction`.
- In app runtime, use `STORE_DB_POOL_MODE=transaction` to enable `prepare: :unnamed`.
- Keep `POOL_SIZE` consistent with PgBouncer pool sizing and Postgres capacity.

## Operational notes

- Trust proxy settings should be explicit in edge-proxied environments:
  - `STORE_TRUSTED_PROXY_PROXIES`
  - `STORE_TRUSTED_PROXY_HEADERS`
- For clustered deploys, release script behavior in `rel/env.sh.eex` uses:
  - `STORE_CLUSTER_TRANSPORT` (`inet6` default, `inet` optional)
  - `DNS_CLUSTER_QUERY` fallback from Railway private domain vars
- Cloudflare/edge policy should avoid caching authenticated, cart, checkout, and order flows.

## Local infra parity with docker-compose

`docker-compose.yml` provides local runtime dependencies:

- Postgres (`5433`)
- PgBouncer (`6432`) with transaction pooling
- Redis (`6379`)

This is for local parity and does not replace production secret/config management.
