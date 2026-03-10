# Phase 28 — Production Readiness And Release Contract

## GOAL

Implement Phase 28 as the production-operability contract for the single-tenant Store blueprint:

- release-safe operator workflows
- fail-closed runtime configuration
- Stripe live-provider hardening
- webhook evidence retention and purge
- health/readiness probes
- observability, alerting hooks, and error-tracker filtering
- backup/restore and go-live/rollback runbooks

without introducing new commerce features or absorbing Phase 29 performance-benchmark scope.

## LINKS CONSULTED

### Project docs

- `AGENTS.md`
- `docs/phases/phase_27_variable_subscriptions.md`
- `docs/phases/phase_27a_membership_subscriptions_entitlements.md`
- `docs/phases/phase_28_production_readiness_release_checklist.md`
- `docs/phases/phase_29_performance_architecture_optimizations.md`
- `docs/governance/enforcement_gates.md`
- `docs/governance/idempotency.md`
- `docs/governance/payment_provider_contract.md`
- `docs/governance/outbound_http.md`
- `docs/governance/observability_slos.md`
- `docs/governance/audit_and_pii.md`
- `docs/governance/retention.md`
- `docs/governance/step_up.md`
- `docs/governance/performance_scaling.md`
- `docs/governance/policy_matrix.md`
- `docs/governance/subscriptions_rollout_rollback.md`
- `docs/agent_notes/phase_27_docs.md`
- `docs/agent_notes/phase_29_docs.md`

### Key implementation files reviewed

- `config/runtime.exs`
- `config/prod.exs`
- `config/config.exs`
- `mix.exs`
- `.github/workflows/ci.yml`
- `.github/workflows/nightly-hardening.yml`
- `lib/store/application.ex`
- `lib/store/payments/providers.ex`
- `lib/store/payments/providers/stripe.ex`
- `lib/store/payments/webhook_receipt.ex`
- `lib/store/comms/domain.ex`
- `lib/store/digital/facade.ex`
- `lib/store_web/router.ex`
- `lib/store_web/endpoint.ex`
- `lib/store_web/telemetry.ex`

### External references

- https://hexdocs.pm/elixir/main/config-and-releases.html
- https://hexdocs.pm/mix/Mix.Tasks.Release.html
- https://hexdocs.pm/ecto_sql/Ecto.Adapters.Postgres.html
- https://hexdocs.pm/postgrex/0.17.5/readme.html
- https://hexdocs.pm/oban/telemetry.html
- https://hexdocs.pm/sentry/Sentry.DefaultEventFilter.html
- https://docs.stripe.com/webhooks
- https://docs.stripe.com/ips
- https://www.postgresql.org/docs/current/backup-dump.html
- https://docs.aws.amazon.com/AmazonS3/latest/userguide/Versioning.html

## DECISIONS / PINS

1. Phase 28 is operational-only; no new catalog/cart/checkout/subscription capabilities are added.
2. Operator entrypoints are release functions, not Mix tasks:
   - `Store.Release.preflight/0`
   - `Store.Release.restore_audit/0`
3. Release runbooks must use:
   - `bin/store eval "Store.Release.preflight()"`
   - `bin/store eval "Store.Release.restore_audit()"`
4. Stripe is the only provider made production-usable in this phase.
5. Stripe production runtime is fail-closed when enabled:
   - `STORE_STRIPE_SECRET_KEY`
   - `STORE_STRIPE_PUBLISHABLE_KEY`
   - `STORE_STRIPE_WEBHOOK_SECRET`
6. PgBouncer transaction-pool compatibility is mandatory:
   - env `STORE_DB_POOL_MODE=session|transaction`
   - when `transaction`, repo config sets `prepare: :unnamed`
7. `Store.Admin.SiteSetting` remains non-secret only; secrets stay ENV-only.
8. Health endpoints are read-only and operational only:
   - `GET /health/live`
   - `GET /health/ready`
9. Webhook evidence purge keeps `payload_sha256` and minimal metadata, but scrubs `raw_body` and `headers` after TTL.
10. Purge must emit scrubbed audit evidence.
11. Sentry is the default Phase 28 error tracker.
12. Explicit ignore filters are required for:
   - `Phoenix.Router.NoRouteError`
   - `Ecto.NoResultsError`
13. Edge/WAF Stripe allowlisting is documented as a runbook requirement, but signature verification remains the real trust boundary.
14. Phase 28 may add observability signals needed for readiness and ops, but must not add new latency benchmark suites or broaden Phase 29 budgets/gates.

## PREVIOUS/NEXT PHASE BOUNDARY CHECK

### Previous phase (27 / 27A) protections

- Keep renewal, dunning, entitlement, and reconciliation behavior owned by existing Phase 27/27A surfaces.
- Do not redesign renewal workers, subscription lifecycle rules, or entitlements cache semantics in Phase 28.
- Reuse `docs/governance/subscriptions_rollout_rollback.md` instead of inventing a second subscriptions rollback policy.

### Next phase (29) protections

- Do not add new benchmark harnesses, load-generation profiles, or throughput/stampede suites in Phase 28.
- Do not widen Phase 29 performance budgets; only add telemetry and readiness signals that support operations.
- Index and cache verification in Phase 28 is limited to production-readiness checks and documentation.

### Additional anti-creep pins

- No multi-tenant capability.
- No new provider-managed billing portal UX.
- No infrastructure-specific manifests (Fly.io, Kubernetes, Terraform).
- No outbound HTTP from web.

## GAP AUDIT

### Already present

- `runtime.exs` already drives core prod config for DB, Phoenix, comms, digital, payments, and rate-limit backend.
- Webhook controllers already verify signatures, persist receipts, and enqueue exactly one worker.
- Email outbox delivery and stale-processing reclaim already exist.
- Digital signed URL issuance, redirect host validation, and rate-limit seam already exist.
- Subscription renewals and rollback/reconciliation docs already exist from Phase 27/27A.
- Telemetry skeleton for repo, carts, checkout, catalog, and ingress events already exists.

### Missing or incomplete

- No Phase 28 docs/runbooks.
- No release module/operator entrypoints.
- No health/readiness endpoints.
- No PgBouncer transaction-pool switch in runtime config.
- No Sentry integration or explicit noise filter.
- No webhook evidence purge worker/schedule.
- No backlog-age telemetry for receipts/outbox/renewals.
- No dependency-audit gate in CI.
- Stripe outbound path is still synthetic and not production-usable.

## PLAN

1. Write docs-first note and runbook scaffolding.
2. Add runtime hardening, release entrypoints, health routes, and prod security headers/session posture.
3. Replace synthetic Stripe outbound flows with real API-backed checkout/setup/off-session calls through `Store.Support.HTTP.ReqClient`.
4. Add webhook evidence purge, Sentry integration, backlog telemetry, and digital signed URL outcome telemetry.
5. Add CI dependency-audit enforcement and platform-agnostic backup/restore/go-live/rollback docs.
6. Run focused tests plus `mix check`, then finish closure protocol.

## DONE

- Session start protocol complete:
  - `bd dolt test`
  - `bd status`
  - `bd ready`
- Created Phase 28 bead tree:
  - `store_blueprint-7yf.25`
  - `store_blueprint-7yf.25.1`
  - `store_blueprint-7yf.25.2`
  - `store_blueprint-7yf.25.3`
  - `store_blueprint-7yf.25.4`
  - `store_blueprint-7yf.25.5`
- Added bead dependencies matching the approved execution order.
- Claimed `store_blueprint-7yf.25.1`.
- Docs-first Phase 28 note created before implementation changes.
- Added release entrypoints:
  - `Store.Release.preflight/0`
  - `Store.Release.restore_audit/0`
- Added runtime fail-closed production config for Stripe, Sentry, PgBouncer transaction pooling, CSP, logging, webhook/admin rate limits, and webhook retention.
- Added read-only health endpoints:
  - `GET /health/live`
  - `GET /health/ready`
- Replaced synthetic Stripe outbound flows with real API-backed checkout/setup/off-session calls through `Store.Support.HTTP.ReqClient`.
- Added webhook evidence purge worker, retention telemetry, Sentry filtering, structured logging metadata, and digital signed URL outcome telemetry.
- Added operator docs:
  - `docs/operations/production_runbook.md`
  - `docs/operations/backup_restore.md`
- Added explicit CI dependency audit gate.
- Verification complete:
  - focused targeted suites passed
  - `mix check` passed

## NEXT

1. Update bead statuses/closure notes in the beads tool once `bd` is available in the shell.
2. Review and commit the Phase 28 change set.
3. Run the repository sync/closure protocol if this turn is being finalized into a phase-close workflow.

## BLOCKERS

- None at note-creation time.

## COMMANDS RUN

- `bd dolt test`
- `bd status`
- `bd ready`
- `git status -sb`
- `bd create ...` (`store_blueprint-7yf.25` through `.25.5`)
- `bd dep add ...`
- `bd update store_blueprint-7yf.25.1 --claim`
- `sed -n ...` against phase/governance/runtime/provider/router/telemetry files
- `rg ...` against config/lib/test/docs

## GATES

- Docs-first note exists before code edits.
- Phase 28 pins include release-vs-mix, Stripe webhook secret, PgBouncer transaction mode, Sentry noise filtering, and WAF allowlisting requirements.

## PERFORMANCE & SCALING REVIEW

### Hot / warm / cold

- Hot:
  - webhook verify + enqueue
  - webhook worker apply path
  - checkout payment intent creation
  - email outbox delivery
  - signed URL issuance
- Warm:
  - readiness probes
  - backlog-age measurements
  - admin observability views
- Cold:
  - restore audit
  - runbooks and incident workflows

### Query count + N+1 risk

- Health/readiness must use bounded checks only.
- Backlog metrics must use aggregate queries, not row iteration.
- Retention purge must process in bounded batches and avoid full-table scans.

### Indexes

- Reuse existing `webhook_receipts.received_at`, `processing_status`, and `provider_event_id` indexes.
- Reuse existing `email_outboxes.state, inserted_at` index.
- Reuse existing subscription due indexes from Phase 27/27A.

### Caching / TTL / invalidation

- No new user-facing cache layer in Phase 28.
- TTL is introduced for webhook evidence retention only.

### Oban uniqueness / idempotency

- Purge worker must be replay-safe and safe under retries.
- Existing webhook/outbox/renewal workers remain the single source of mutation truth.

### Telemetry / logging

- Add backlog-age gauges and signed URL outcome signals.
- Add structured operational metadata and filter known routing/no-result noise from error tracking.
