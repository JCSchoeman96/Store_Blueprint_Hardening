# Runtime Environment Contract

This document is the deployment contract for runtime configuration enforced by `config/runtime.exs`, with release/runtime context from `Dockerfile`, `docker-compose.yml`, `rel/env.sh.eex`, and `pgbouncer/pgbouncer.ini`.

## Runtime modes

- `PHX_SERVER=true` enables the web server in release mode.
- `STORE_DB_POOL_MODE`:
  - `session` (default): normal prepared statement behavior.
  - `transaction`: sets `prepare: :unnamed` for both `Store.Repo` and `Store.DirectRepo`, which is the PgBouncer-safe mode for transaction pooling.
- `STORE_RATE_LIMIT_BACKEND`:
  - `ets` (default) or `redis`.
- `STORE_COMMS_PROVIDER`:
  - `swoosh` (default) or `req_postmark`.
- `STORE_DIGITAL_STORAGE_PROVIDER`:
  - `s3` (default) or `fake`.

## Required in production

The app raises at boot if these are missing in `MIX_ENV=prod`:

- `DATABASE_URL`
- `SECRET_KEY_BASE`
- `STORE_TOKEN_SIGNING_SECRET`
- `STORE_GOOGLE_CLIENT_ID`
- `STORE_GOOGLE_CLIENT_SECRET`
- `STORE_GOOGLE_REDIRECT_URI_BASE`
- `STORE_QUOTE_HASH_SECRET`
- `SENTRY_DSN`

## Conditionally required in production

- Stripe when enabled via `STORE_PAYMENTS_ENABLED_PROVIDERS`:
  - `STORE_STRIPE_WEBHOOK_SECRET`
  - `STORE_STRIPE_SECRET_KEY`
  - `STORE_STRIPE_PUBLISHABLE_KEY`
- Postmark provider (`STORE_COMMS_PROVIDER=req_postmark`):
  - `STORE_POSTMARK_SERVER_TOKEN`
- S3 storage (`STORE_DIGITAL_STORAGE_PROVIDER=s3`):
  - `STORE_DIGITAL_S3_ACCESS_KEY_ID`
  - `STORE_DIGITAL_S3_SECRET_ACCESS_KEY`

## Optional with defaults

### Phoenix / endpoint / cluster

- `PHX_SERVER` (Docker release sets default `true`)
- `PORT` (default `4000`)
- `PHX_HOST` (default `example.com`)
- `ECTO_IPV6` (`true`/`1` enables IPv6 socket options)
- `DNS_CLUSTER_QUERY` (fallbacks: `RAILWAY_PRIVATE_DOMAIN`, `RAILWAY_PRIVATE_NETWORKING_DOMAIN`)
- `STORE_CLUSTER_TRANSPORT` (`inet6` default in release env script, or `inet`)
- `STORE_TRUSTED_PROXY_PROXIES` (comma-separated CIDRs/IPs; defaults from compile-time config)
- `STORE_TRUSTED_PROXY_HEADERS` (default `cf-connecting-ip,x-forwarded-for`)

### Database pooling

- `STORE_DB_POOL_MODE` (`session` default; `transaction` for PgBouncer transaction pools)
- `POOL_SIZE` (default `10`)

### Logging and security headers

- `STORE_LOG_LEVEL` (`debug|info|warning|error`, default `info`)
- `STORE_LOG_FORMAT` (`text|json`, default `text`)
- `STORE_CSP_MODE` (`disabled|enforce|report_only`, default `disabled`)
- `STORE_CSP_POLICY` (default Stripe-compatible policy when CSP is enabled)
- `STORE_CSP_REPORT_URI` (optional report endpoint)

### Payments and provider HTTP tuning

- `STORE_PAYMENTS_ENABLED_PROVIDERS` (comma-separated list; default empty)
- `STORE_PAYMENTS_DEFAULT_PURCHASE_PROVIDER_FOR_UI` (must be in enabled providers when set)
- `STORE_STRIPE_API_BASE_URL` (default `https://api.stripe.com`)
- `STORE_STRIPE_API_VERSION` (default `2025-02-24.acacia`)
- `STORE_PAYMENT_TIMEOUT_MS` (default `5000`)
- `STORE_PAYMENT_PROVIDER_TASK_TIMEOUT_MS` (default `4000`)
- `STORE_PAYMENT_HTTP_POOL_SIZE` (default `400`)
- `STORE_PAYMENT_HTTP_RECEIVE_TIMEOUT_MS` (defaults from `STORE_PAYMENT_TIMEOUT_MS`, fallback `6000`)
- `STORE_PAYMENT_HTTP_POOL_TIMEOUT_MS` (default `5000`)

Timeout guardrails enforced at boot:

- `STORE_PAYMENT_HTTP_RECEIVE_TIMEOUT_MS` must be greater than `STORE_PAYMENT_PROVIDER_TASK_TIMEOUT_MS`.
- `STORE_PAYMENT_HTTP_POOL_TIMEOUT_MS` must be greater than `STORE_PAYMENT_PROVIDER_TASK_TIMEOUT_MS`.

### Comms

- `STORE_COMMS_FROM_NAME` (default `Store`)
- `STORE_COMMS_FROM_EMAIL` (default `no-reply@example.com`)
- `STORE_COMMS_SUPPORT_EMAIL` (default `support@example.com`)
- `STORE_POSTMARK_URL` (default `https://api.postmarkapp.com/email`)

### Digital

- `STORE_DIGITAL_ALLOWED_REDIRECT_HOSTS` (default `downloads.example.com`)
- `STORE_DIGITAL_SIGNED_URL_TTL_SECONDS` (default `120`)
- `STORE_DIGITAL_DEFAULT_GRANT_TTL_DAYS` (default `30`)
- `STORE_DIGITAL_REFUND_REVOCATION_POLICY` (`strict_line_scoped|strict_order_scoped|threshold`, default `strict_line_scoped`)
- `STORE_DIGITAL_FAKE_HOST` (default `downloads.local`)
- `STORE_DIGITAL_S3_REGION` (default `us-east-1`)
- `STORE_DIGITAL_S3_HOST` (optional)
- `STORE_DIGITAL_S3_SCHEME` (optional)
- `STORE_DIGITAL_S3_PORT` (optional integer)

### Rate limiting and Redis

- `STORE_RATE_LIMIT_BACKEND` (`ets|redis`, default `ets`)
- `STORE_REDIS_KEY_PREFIX` (default `prod:store`)
- `STORE_REDIS_HOST` (default `localhost`)
- `STORE_REDIS_PORT` (default `6379`)
- `STORE_REDIS_DB` (default `0`)
- `STORE_REDIS_USERNAME` (optional)
- `STORE_REDIS_PASSWORD` (optional)
- `STORE_REDIS_SSL` (`true`/`1` enables TLS; default false)
- `STORE_WEBHOOK_RATE_LIMIT_LIMIT` (default `120`)
- `STORE_WEBHOOK_RATE_LIMIT_WINDOW_SECONDS` (default `60`)
- `STORE_ADMIN_RATE_LIMIT_LIMIT` (default `300`)
- `STORE_ADMIN_RATE_LIMIT_WINDOW_SECONDS` (default `60`)
- `STORE_PUBLIC_WAITING_ROOM_LIMIT` (default `380`)
- `STORE_PUBLIC_WAITING_ROOM_HARD_LIMIT` (default `450`)
- `STORE_PUBLIC_WAITING_ROOM_WINDOW_SECONDS` (default `10`)
- `STORE_LIVE_WAITING_ROOM_LIMIT` (default `380`)
- `STORE_LIVE_WAITING_ROOM_HARD_LIMIT` (default `450`)
- `STORE_LIVE_WAITING_ROOM_WINDOW_SECONDS` (default `10`)
- `STORE_WAITING_ROOM_REFRESH_SECONDS` (default `10`)
- `STORE_DIGITAL_SIGNED_DOWNLOAD_LIMIT` (default `10`)
- `STORE_DIGITAL_SIGNED_DOWNLOAD_WINDOW_SECONDS` (default `60`)

### Operations

- `STORE_WEBHOOK_RETENTION_DAYS` (default `30`)

## PgBouncer transaction pooling implications

For PgBouncer in transaction mode (`pool_mode = transaction`), use:

- `STORE_DB_POOL_MODE=transaction`

This forces Ecto to use unnamed prepared statements (`prepare: :unnamed`) for both repos and avoids transaction-pool prepared-statement failures.

Use `DATABASE_URL` to point at PgBouncer when this mode is enabled. Keep migration and release procedures aligned with your deployment policy for `Store.DirectRepo` usage.
