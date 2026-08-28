# Phase 00 Docs Notes

## Links Consulted (Hexdocs / web search)
- https://hexdocs.pm/phoenix/Mix.Tasks.Phx.New.html
- https://hexdocs.pm/bandit/Bandit.PhoenixAdapter.html
- https://hexdocs.pm/ash/
- https://hexdocs.pm/ash_postgres/
- https://hexdocs.pm/ash_authentication_phoenix/liveview.html
- https://hexdocs.pm/petal_components/readme.html
- https://hexdocs.pm/oban/
- https://hexdocs.pm/req/Req.html
- https://hexdocs.pm/ash/Ash.Notifier.html
- https://hexdocs.pm/credo/
- https://hexdocs.pm/ex_doc/readme.html
- https://hexdocs.pm/stream_data/StreamData.html
- https://hexdocs.pm/dialyxir/readme.html
- https://hex.pm/packages/ash
- https://hex.pm/packages/ash_postgres
- https://hex.pm/packages/ash_authentication
- https://hex.pm/packages/ash_authentication_phoenix
- https://hex.pm/packages/petal_components
- https://hex.pm/packages/oban
- https://hex.pm/packages/req
- https://hex.pm/packages/credo
- https://hex.pm/packages/ex_doc
- https://hex.pm/packages/stream_data
- https://hex.pm/packages/dialyxir

## What the Docs Recommend Now
- Use `mix phx.new` with `--live` and configure Bandit as the endpoint adapter.
- Keep web concerns in `StoreWeb` and domain logic in Ash resources/actions.
- Use Ash 3.x + AshPostgres with UUID primary keys for resources.
- In transaction-bound Ash actions, use `return_notifications?: true` and dispatch with `Ash.Notifier.notify/1` only after commit.
- Prefer Oban workers for retryable/side-effectful workflows.
- Use a single HTTP wrapper around Req for outbound calls.
- Use Credo, docs, and test gates in CI for mechanical enforcement.

## What We Will Implement (Decisions)
- Generate `Store` / `:store` Phoenix LiveView app in this repo root.
- Keep single-tenant semantics only; no tenant routing, no `tenant_id`.
- Add dependencies from blueprint: Ash stack, Petal Components, Oban, Req, Credo, ExDoc, StreamData, Dialyxir.
- Add `mix check` and `mix check.ci` aliases.
- Use `STORE_DB_PORT` with default `5433` in `dev`/`test` to match local Docker Postgres setup.
- Add Phase 00 enforcement gates:
  - no Repo calls in `lib/store_web/**`
  - moduledoc required (`@moduledoc` or `@moduledoc false`)
  - required docs-first phase notes present
- Missed-notification policy:
  - transactional action paths must collect and deliver notifications post-commit
  - test env sets `config :ash, :missed_notifications, :raise` so drops fail CI
  - post-commit notify failures are logged (no worker retry loop on already-committed writes)

## Version Pins / Breaking Changes
- Requested constraint families:
  - `ash ~> 3.0`, `ash_postgres ~> 2.0`, `ash_authentication ~> 4.0`
  - `ash_authentication_phoenix ~> 2.0`, `petal_components ~> 3.0`
  - `oban ~> 2.0`, `req ~> 0.5`, `credo ~> 1.7`, `ex_doc ~> 0.37`
  - `stream_data ~> 1.1`, `dialyxir ~> 1.4`
- Resolved versions in `mix.lock`:
  - `ash 3.17.0`
  - `ash_postgres 2.6.32`
  - `ash_authentication 4.13.7`
  - `ash_authentication_phoenix 2.15.0`
  - `petal_components 3.0.1`
  - `oban 2.20.3`
  - `req 0.5.17`
  - `credo 1.7.16`
  - `ex_doc 0.40.1`
  - `stream_data 1.2.0`
  - `dialyxir 1.4.7`
- Breaking change watch:
  - Ash 3.x APIs differ from Ash 2.x; avoid older DSL/examples.
  - AshAuthentication/AshAuthenticationPhoenix options can shift by minor versions; verify docs on each bump.
  - `stream_data` must not be test-only in this stack because Ash depends on it at runtime.
  - `mix check` in `:test` requires `ex_doc` available in `:test` for the `mix docs` gate.

## Performance & Scaling Review
- Hot paths:
  - Request path stays thin in web; no direct Repo calls in web.
  - Side effects deferred to workers to avoid slow request latency.
- Warm paths:
  - CI gates (`mix check`) run per PR; optimized with simple file scans.
  - Docs and credo checks are deterministic and cached by CI where available.
  - Post-commit notification delivery adds negligible overhead versus write latency and prevents ghost-state risk.
- Cold paths:
  - Docs generation and dialyzer are slower, mainly CI/nightly concerns.
- Indexes:
  - No new Phase 00 data indexes yet; uniqueness/index strategy starts in later phases.
- TTL:
  - No TTL behavior in Phase 00.
- Invalidation:
  - No cache invalidation in Phase 00.
- PubSub:
  - Phoenix PubSub baseline only; no domain PubSub contracts yet.

## Dialyzer Cold Path (Update)
- `mix check.types` is a separate cold-path check and is not part of `mix check`.
- `mix check.types` runs in `MIX_ENV=test` via Mix `preferred_envs` mapping, matching main gate compilation surface.
- Local bootstrap and usage:
  - `MIX_ENV=test mix dialyzer --plt` (one-time/bootstrap when PLT cache is cold)
  - `mix check.types` (normal local run)
- CI policy:
  - Dialyzer runs advisory first (`--ignore-exit-status`).
  - Move to required after baseline cleanup by removing `--ignore-exit-status`.

## S0-05 Test Strategy (2026-08-27)

### Links Consulted
- [`docs/hardening/00_current_state.md`](../hardening/00_current_state.md)
- [`docs/hardening/01_domain_map.md`](../hardening/01_domain_map.md)
- [`docs/hardening/02_lifecycle_registry.md`](../hardening/02_lifecycle_registry.md)
- [`docs/hardening/02_1_lifecycle_registry_gaps.md`](../hardening/02_1_lifecycle_registry_gaps.md)
- [`docs/hardening/03_invariant_registry.md`](../hardening/03_invariant_registry.md)
- [`docs/hardening/04_dependency_map.md`](../hardening/04_dependency_map.md)
- [`mix.exs`](../../mix.exs), [`config/test.exs`](../../config/test.exs), [`test/test_helper.exs`](../../test/test_helper.exs), and [`test/support`](../../test/support)
- [`test`](../../test), [`.github/workflows/ci.yml`](../../.github/workflows/ci.yml), [`.github/workflows/nightly-hardening.yml`](../../.github/workflows/nightly-hardening.yml)
- [`docs/governance`](../governance), and [`priv/repo/performance_smoke_test.exs`](../../priv/repo/performance_smoke_test.exs)

### Decisions and Pins
- This phase records current test evidence and gaps only. It does not add tests or alter test/application behaviour.
- Qualitative confidence is used because no line-coverage or branch-coverage reporting is configured in the inspected Mix aliases or workflows.
- The application is single-tenant. Ownership and privilege tests are in scope; tenant-isolation coverage is not a current implementation guarantee.
- Provider calls remain stubbed in the current test harness. Live provider integration is recorded as a gap rather than inferred from adapter tests.
- Postgres remains the source of truth for financial and lifecycle state. Cache and queue tests are treated as supporting-path evidence.

### Plan
- Inventory domain, lifecycle, invariant, worker, security, performance, and CI tests.
- Map current harness configuration and workflow execution, then separate current coverage from future extraction gates.
- Verify documentation links and wording, run repository checks, and confirm no application or test files changed.

### Performance & Scaling Review
- Hot paths reviewed: checkout, payment confirmation, entitlement lookup, and subscription renewal.
- Current evidence includes the standalone performance smoke harness, query/lock/pool telemetry, Cachex/ETS/Redis tests, and bounded subscription/entitlement query tests.
- Missing evidence includes generic webhook/renewal/entitlement soak, multi-node cache/PubSub behaviour, production-like Oban execution, and live-provider load.

## S0-06 Performance Data Map (2026-08-27)

### Links Consulted
- [`docs/hardening/06_performance_data_map.md`](../hardening/06_performance_data_map.md)
- [`docs/governance/performance_scaling.md`](../governance/performance_scaling.md)
- [`docs/phases/phase_29_performance_architecture_optimizations.md`](../phases/phase_29_performance_architecture_optimizations.md)
- [`priv/repo/migrations`](../../priv/repo/migrations)
- [`lib/store/catalog`](../../lib/store/catalog), [`lib/store/carts`](../../lib/store/carts), and [`lib/store/checkout`](../../lib/store/checkout)
- [`lib/store/orders`](../../lib/store/orders), [`lib/store/payments`](../../lib/store/payments), [`lib/store/subscriptions`](../../lib/store/subscriptions), and [`lib/store/entitlements`](../../lib/store/entitlements)
- [`lib/store/workers`](../../lib/store/workers) and [`config/config.exs`](../../config/config.exs)

### Decisions and Pins
- The implementation and migrations are the source of truth; governance guidance is recorded as comparison context only.
- Postgres remains authoritative for orders, payment application, subscriptions, entitlements, and inventory reservations. Catalog, stock, and entitlement caches are derived projections or hints.
- Hot/warm/cold classification is based on access pressure and correctness sensitivity, not data retention.
- Candidate query/index gaps and cache opportunities are observations for measurement, not approved changes.
- S0-06 makes no code, query, schema, cache, Redis, or infrastructure change.

### Plan
- Map table ownership, relationships, constraints, indexes, and query-critical columns from migrations.
- Trace checkout, payment webhook, subscription renewal, entitlement, inventory, and worker paths through the domain facades.
- Record current cache TTLs/invalidation, concurrency boundaries, queue limits, retry/idempotency anchors, and evidence gaps.
- Verify the document structure, links, diff scope, and repository gates before updating PR #1.

### Performance & Scaling Review
- Hot paths: catalog browse/detail, active carts, checkout finalization, payment webhooks, entitlement checks, inventory reservation, and due renewal rows.
- Warm/cold paths: recent customer/order/subscription views, settled payment evidence, renewal history, outboxes, fulfillment history, provider events, and audit/metric records.
- Query/N+1 risks: admin catalog filtering in Elixir, per-item cart merge work, per-grant entitlement revocation, branch-dependent payment lookups, and per-subscription renewal work.
- Index evidence: Phase 29 product/order keyset indexes, inventory active-expiry indexes, payment/provider idempotency constraints, entitlement user/status indexes, and Phase 27 partial renewal tick indexes were recorded; candidate gaps require `EXPLAIN` and cardinality data.
- Cache review: existing Cachex/ETS/Redis paths were documented with TTL, invalidation, per-node/shared behavior, and stampede risks. No cache tier was added.
- Oban review: five-minute renewal fan-out, one-minute inventory/provider sweeps, bounded batches, worker uniqueness where present, retry counts, and webhook/refund replay protection were documented.
- Telemetry gaps: no production p95/p99, lock-wait, cache-hit, multi-node invalidation, queue-lag, or 100k-concurrency result was inferred from static inspection.

## S0-07 Security Model (2026-08-27)

### Links Consulted
- [`docs/hardening/07_security_model.md`](../hardening/07_security_model.md)
- [`docs/hardening/00_current_state.md`](../hardening/00_current_state.md), [`docs/hardening/02_1_lifecycle_registry_gaps.md`](../hardening/02_1_lifecycle_registry_gaps.md), and [`docs/hardening/05_test_strategy.md`](../hardening/05_test_strategy.md)
- [`docs/phases/phase_02_auth.md`](../phases/phase_02_auth.md), [`docs/phases/phase_03_admin.md`](../phases/phase_03_admin.md), and [`docs/phases/phase_06_policy_matrix.md`](../phases/phase_06_policy_matrix.md)
- [`docs/governance/policy_matrix.md`](../governance/policy_matrix.md), [`docs/governance/payment_provider_contract.md`](../governance/payment_provider_contract.md), [`docs/governance/payment_provider_capabilities.md`](../governance/payment_provider_capabilities.md), [`docs/governance/idempotency.md`](../governance/idempotency.md), [`docs/governance/refund_semantics.md`](../governance/refund_semantics.md), [`docs/governance/step_up.md`](../governance/step_up.md), and [`docs/governance/audit_and_pii.md`](../governance/audit_and_pii.md)
- Authentication, policy, facade, provider, webhook, worker, cache, and migration sources under [`lib`](../../lib) and [`priv/repo/migrations`](../../priv/repo/migrations), plus targeted security and performance tests under [`test`](../../test)

### Decisions and Pins
- This is architecture discovery only. No resource policy, authorization behavior, authentication flow, tenancy model, or application code was changed.
- Implementation and migrations are current-state evidence. Governance and phase documents are comparison context unless the implementation confirms the behavior.
- Authentication is AshAuthentication with password and Google identity strategies, stored signed tokens, browser sessions, bearer API actors, and explicit optional/required/admin route boundaries.
- Authorization is resource-specific. It combines Ash policies, database-backed role assignments, owner filters, parent-resource preparations, facade checks, and trusted system contexts.
- The application is single-tenant. No tenant identifier, tenant routing, tenant-qualified cache key, or PostgreSQL RLS policy was found.
- Stripe is the implemented payment provider boundary. Other provider adapters are not evidence of production-ready signature verification, normalization, or recurring operations.
- Guest cart and checkout tokens are bearer capabilities. Payment proof comes from verified provider evidence and worker reconciliation, not customer return parameters.

### Plan
- Map authentication/session/token boundaries and the role/policy locations for catalog, orders, payments, subscriptions, entitlements, and inventory.
- Trace user ownership from cart through order, payment, subscription, entitlement, and digital download grant, including guest checkout paths.
- Trace payment webhook verification, receipt deduplication, worker replay handling, refund checks, and subscription renewal authority.
- Inspect database foreign keys, unique/check constraints, cache keys, rate limits, queue uniqueness, and evidence-retention behavior.
- Record extraction readiness as READY, PARTIAL, or NOT READY without implementing a hardening change.

### Performance & Scaling Review
- Hot paths reviewed: catalog and availability reads, cart/checkout ownership checks, webhook verify-persist-enqueue, payment/refund reconciliation, entitlement lookup, digital URL issuance, inventory reservation, and subscription renewal.
- Current cache interactions: public catalog projections use catalog/availability caches; effective entitlement sets use a per-user Cachex key with a 60-second TTL and PubSub invalidation. Missing invalidation can leave stale access state.
- Query/N+1 risks: role lookups on repeated policy checks, parent-order child reads, cart merge, digital revocation, and per-subscription renewal work. PostgreSQL remains authoritative for security-sensitive state.
- Queue/security interaction: bounded webhook/refund/subscription queues and retries can delay payment, revocation, or renewal state during bursts. Receipt and renewal identities limit duplicate work but do not eliminate queue lag.
- Rate-limit interaction: webhook limits are IP-keyed and may use per-node ETS or shared Redis; the current limiter fails open on backend errors. No production load, multi-node cache, queue-lag, or webhook-storm result was inferred.

## S0-08 Subscription Commerce Extraction Gates (2026-08-27)

### GOAL

Convert the S0-01 through S0-07 evidence, verified against the implementation, into
objective PASS / FAIL / BLOCKED / NOT APPLICABLE gates for future commerce extraction.
This closes S0 discovery. It does not authorize extraction or change commercial
behavior.

### PLAN

- Read the S0 hardening documents and authoritative governance records.
- Verify lifecycle, authority, financial, payment, subscription, entitlement,
  security, provider, CI, test, migration, and performance claims against source.
- Record deterministic gate IDs, current statuses, evidence requirements, and
  extraction-blocking conditions.
- Summarize provider and capability readiness, the S0 closure decision, and the
  ordered hardening gate backlog.
- Run the available repository checks and record unavailable stress/soak evidence as
  BLOCKED rather than treating it as PASS.

### Links Consulted

- [`docs/hardening/00_current_state.md`](../hardening/00_current_state.md)
- [`docs/hardening/01_domain_map.md`](../hardening/01_domain_map.md)
- [`docs/hardening/02_lifecycle_registry.md`](../hardening/02_lifecycle_registry.md)
- [`docs/hardening/02_1_lifecycle_registry_gaps.md`](../hardening/02_1_lifecycle_registry_gaps.md)
- [`docs/hardening/03_invariant_registry.md`](../hardening/03_invariant_registry.md)
- [`docs/hardening/04_dependency_map.md`](../hardening/04_dependency_map.md)
- [`docs/hardening/05_test_strategy.md`](../hardening/05_test_strategy.md)
- [`docs/hardening/06_performance_data_map.md`](../hardening/06_performance_data_map.md)
- [`docs/hardening/07_security_model.md`](../hardening/07_security_model.md)
- [`docs/governance`](../governance), especially lifecycle, idempotency, inventory,
  payment-provider, policy, step-up, audit, and performance records
- [`lib/store`](../../lib/store), [`lib/store_web`](../../lib/store_web),
  [`priv/repo/migrations`](../../priv/repo/migrations), [`test`](../../test),
  [`mix.exs`](../../mix.exs), and [`.github/workflows`](../../.github/workflows)
- [`docs/hardening/08_extraction_gates.md`](../hardening/08_extraction_gates.md)

### Decisions / Pins

- The implementation and migrations remain the source of truth. No prior hardening
  document was rewritten.
- No commerce capability is extraction-ready merely because feature tests pass.
- `PASS` requires evidence that satisfies the gate; `FAIL` records source-proven
  absence or contradiction; `BLOCKED` records unavailable required evidence or
  environment; `NOT APPLICABLE` requires an explicit capability decision.
- Current architecture remains single-tenant. `TEN-001` passes for an explicit
  single-tenant consumer; `TEN-002` blocks any multi-tenant consumer pending a
  separate architecture decision. No tenancy model was selected.
- Postgres remains durable financial, lifecycle, inventory, payment, subscription,
  and entitlement truth. Cachex, ETS, Redis, PubSub, and Oban are derived or
  asynchronous mechanisms and cannot become durable commerce authority.
- Current source-backed strengths include integer minor-unit money, UUIDv7 IDs,
  selected binary UUID ordering, immutable order line/adjustment resources, selected
  state machines, unique payment application and renewal identities, database-locked
  inventory reservation, a Stripe boundary, and policy/worker tests.
- Blocking findings include governance/code drift, direct InventoryReservation state
  writes, incomplete payment evidence authority and replay handling, broad payment
  success fan-out, subscription and checkout coupling, subscription/entitlement
  coupling, renewal races, guest-token fallback, consumer-only step-up evidence,
  trusted system paths, public sensitive attributes, cache/revocation windows,
  provider maturity, incomplete load/soak evidence, and advisory Dialyzer semantics.
- The current `mix deps.audit` result is PASS. The earlier S0-01 audit failure remains
  historical evidence and was not silently rewritten because the current run differs.
- The empty `01_domain_map.md` did not create a material contradiction: the source and
  other S0 maps supply the domain evidence, so it was not modified.

### DONE

- Completed [`docs/hardening/08_extraction_gates.md`](../hardening/08_extraction_gates.md)
  with deterministic gate IDs across governance, lifecycle, financial integrity,
  concurrency, payments, subscriptions, entitlements, security, tenancy,
  performance, testing, CI, supply chain, and extraction architecture.
- Added the required global summary, lifecycle candidate snapshot, provider readiness
  matrix, capability readiness matrix, S0 closure decision, ordered backlog, finding
  coverage map, performance review, security review, and validation record.
- Classified the current decision as: S0 discovery PASS, immediate extraction NO,
  controlled hardening YES, and multi-tenant extraction BLOCKED without a separate
  architecture decision.
- Changed only the extraction-gates document and this Phase 00 note. No application,
  test, migration, policy, cache, Redis, provider, tenancy, or CI behavior changed.

### NEXT

- Use the P0 gate groups in `08_extraction_gates.md` to scope the first implementation-
  hardening phase. The first focus is authoritative lifecycle/invariant parity and CI
  truth, followed by financial/payment replay and durable post-commit handoff proof.
- Do not copy or rename extraction modules until `EXT-001` through `EXT-003` and all
  applicable blocking gates pass.

### BLOCKERS

- Immediate extraction is blocked by the failed critical/high gates listed in the
  document; this is an intentional S0 decision, not an implementation failure.
- Stress, soak, multi-node cache, and 100k-concurrency certification evidence was not
  available or run in this documentation session, so those gates remain BLOCKED.
- `mix check.types` emitted 178 Dialyzer findings and exited zero because the alias
  still uses `--ignore-exit-status`; the CI type-safety gate therefore remains FAIL.
- `bd dolt test` is unavailable in the current embedded-mode CLI, and
  `dolt-beads.service` is not installed in this checkout environment. Bead work was
  still created and claimed through normal `bd` commands with the existing database
  prefix mismatch explicitly handled by `--force`.

### COMMANDS RUN

- `bd dolt test` (blocked by embedded mode)
- `bd status`
- `bd ready`
- `bd list --all`
- `bd create ... --parent store_blueprint-7yf --force`
- `bd update store_blueprint-7yf.27 --claim`
- `systemctl --user status dolt-beads.service --no-pager` (unit unavailable)
- `git status -sb`
- repository search/read with `rg`, `sed`, `nl`, `wc`
- `mix format --check-formatted` (PASS)
- `mix compile --warnings-as-errors` (PASS)
- `mix deps.audit` (PASS)
- `mix check` (PASS: 453 tests, 3 properties, 0 failures)
- `mix check.types` (exit zero but 178 findings; extraction gate FAIL)
- `git diff --check` (PASS after the document write)

### GATES

- Bead: `store_blueprint-7yf.27`, claimed for S0-08 documentation.
- Documentation scope: only `docs/hardening/08_extraction_gates.md` and this note
  changed.
- Repository validation: ordinary `mix check` PASS; Dialyzer truth FAIL; migration
  alignment, stress, soak, and 100k capacity evidence not claimed.
- Extraction decision: no current capability is READY; proceed to controlled
  hardening only.

### Performance & Scaling Review

- Hot paths covered: catalog browse/detail, cart, checkout, payment webhooks,
  inventory reservation, subscription renewals, and entitlement access.
- The gate document records current Postgres authority, Cachex/ETS/Redis behavior,
  TTLs, invalidation triggers, PubSub rules, existing index families, batching,
  lock/concurrency rules, and expected-but-unmeasured 100k behavior.
- Required measured evidence remains open for query budgets, N+1/cardinality,
  cache-stampede and multi-node invalidation, Oban backpressure, webhook/renewal
  bursts, and 2–4 hour initial / 6–12 hour release soak profiles.

## S0-CLOSE-01 Chaos Performance CI Triage (2026-08-28)

### GOAL

- Identify the exact failure in the required `performance_smoke_chaos_required` job at
  `b601bdec6e4d64deb58290a8dede17fda82f70c4` and close S0-CLOSE-01 with diagnosis only.

### PLAN

- Inspect the GitHub run, failed job, logs, artifact, workflow, smoke harness, chaos
  profile, provider stub, reservation path, and governing performance/inventory notes.
- Compare normal and chaos profiles, attempt the exact command locally, perform bounded
  repeats, classify one root cause, assess commerce/performance/security impact, and
  document one correction task without implementing it.

### Links Consulted

- [`s0_closure_chaos_ci_triage.md`](../hardening/s0_closure_chaos_ci_triage.md)
- [`ci.yml`](../../.github/workflows/ci.yml), [`performance_smoke_test.exs`](../../priv/repo/performance_smoke_test.exs),
  [`chaos_profile.ex`](../../lib/store/perf/chaos_profile.ex), [`stripe_api_stub.ex`](../../test/support/stripe_api_stub.ex),
  and [`inventory_reservations.ex`](../../lib/store/orders/inventory_reservations.ex)
- [GitHub run 33111068594](https://github.com/JCSchoeman96/Store_Blueprint_Hardening/actions/runs/33111068594)
  and [chaos job 98654523076](https://github.com/JCSchoeman96/Store_Blueprint_Hardening/actions/runs/33111068594/job/98654523076)
- [`inventory_reservations.md`](../governance/inventory_reservations.md), [`06_performance_data_map.md`](../hardening/06_performance_data_map.md),
  and the current migrated schema

### Decisions / Pins

- Exact failed assertion: `domain_thundering_herd_observer` reported
  `peak_lock_wait_ratio=0.44`, `peak_lock_waiters=11`, and one sample over the
  `0.10` lock threshold; the process exited `1` from the observer assertion.
- Primary classification: `HARNESS / THRESHOLD DEFECT`. The intentional one-unit
  PostgreSQL row-lock herd passed one-winner, `79` loser, and latency assertions; no
  protected commerce invariant failed.
- The target observer assertion reproduced locally, including on a dedicated clean
  database with CI-shaped loads, but exact CI runner versions/scheduler capacity were
  not reproduced. Alternating observations are explained by the known one-sample,
  500 ms observer window, not classified as unexplained flakiness.
- S0 merge decision remains `BLOCKED`. No threshold, workload, required status, or
  chaos injection may be weakened. The stale teardown table names were recorded as
  secondary harness evidence, not folded into the one next task.

### DONE

- Captured run `33111068594`, job `98654523076`, failed step, command, exit code,
  assertion, exact metrics, service observations, and artifact evidence.
- Compared normal versus `mobile_realistic` chaos inputs and verified that the chaos
  profile changes Stripe stub timing, not the direct reservation call.
- Attempted the exact command locally and performed bounded literal-profile and clean
  CI-shaped repeats; no soak or stress certification was started.
- Added the full diagnosis and one correction scope to the triage document. No
  application, test, migration, configuration, workflow, or threshold behaviour changed.

### NEXT

- One separate task: correct and make deterministic the domain-thundering-herd observer
  contract while retaining the protected inventory assertions and required gate.
- Do not begin S1 hardening or extraction from this red baseline.

### BLOCKERS

- Required chaos CI remains red until the separate observer-contract correction is
  completed and a fresh unchanged required CI run is green.
- Exact GitHub runner capacity and versions cannot be reproduced locally; local provider
  timeout timing also prevented some clean repeats from reaching the target test.
- PostgreSQL teardown still names absent `checkout_sessions` and `shipping_rate_rules`
  tables, but those errors occurred after the smoke workload and were not the target
  failure.
- `bd dolt test` remains unavailable because this checkout uses the embedded-mode CLI;
  this does not alter the triage evidence.

### COMMANDS RUN

- `bd dolt test`, `bd status`, `bd ready`, `bd create ...`, and `bd update ... --claim`
- `gh pr view 1`, `gh run view 33111068594`, GitHub job/log/artifact inspection, and
  `gh api` queries for run/job metadata
- `rg`, `sed`, `nl`, `tail`, `git status -sb`, and source/documentation reads
- The exact local `mix run --no-start priv/repo/performance_smoke_test.exs` chaos
  command with bounded repeats and explicit CI-shaped load overrides
- `STORE_TEST_DB_SUFFIX=s0close MIX_ENV=test mix ash_postgres.create` and
  `STORE_TEST_DB_SUFFIX=s0close MIX_ENV=test mix ash_postgres.migrate`

### GATES

- Root cause: `HARNESS / THRESHOLD DEFECT`.
- Commerce P0 invariant failure: `NO` in the observed scenario; inventory correctness
  assertions passed.
- Exact target assertion reproduced locally: `YES`; exact CI environment reproduced:
  `NO`.
- S0 merge status: `BLOCKED`.
- Only the new triage document and this Phase 00 note are in scope; no behaviour changed.

### Performance & Scaling Review

- Affected data is `HOT`: PostgreSQL inventory rows and reservation state are durable
  truth. ETS `StockFastPath` is a five-second derived cart precheck only; Redis, Oban,
  and PubSub are not involved in the failing domain path.
- The relevant lock is PostgreSQL `FOR UPDATE` on the popular variant's inventory row;
  the single-row hotspot is expected for no-oversell serialization. Existing variant,
  state/expiry, order/variant, and reservation-identity indexes/constraints showed no
  missing-index evidence from this failure.
- No cache stampede, Redis pressure, queue amplification, pool exhaustion, scheduler
  pressure, mailbox growth, or memory growth was evidenced. No 100k-concurrency claim
  was made; that behaviour remains unmeasured and requires later workload evidence.
