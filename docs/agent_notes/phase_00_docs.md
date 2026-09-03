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
- `mix check` (PASS: `453` tests, `3` properties, `0` failures, all static checks
  clean; the final rerun logged one Postgrex client disconnect but still exited zero)

### GATES

- Root cause: `HARNESS / THRESHOLD DEFECT`.
- Commerce P0 invariant failure: `NO` in the observed scenario; inventory correctness
  assertions passed.
- Exact target assertion reproduced locally: `YES`; exact CI environment reproduced:
  `NO`.
- `git diff --check`: `PASS`; the required chaos performance gate remains red and no
  fresh green rerun was claimed.
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

## S0-ARCH-01C Inventory reservation admission ADR correction (2026-08-30)

### GOAL

- Apply the accepted `PASS WITH CORRECTIONS` architecture-review findings to the
  inventory reservation admission ADR without implementing admission or changing the
  certification/merge status.

### PLAN

- Cross-check the ADR against the current reservation identity, locking, Redis, waiting
  room, configuration, and migration sources.
- Make only the required architecture-document corrections, record the documentation
  gate, and run targeted content and diff validation.

### Links Consulted

- [`s0_inventory_reservation_admission_architecture.md`](../hardening/s0_inventory_reservation_admission_architecture.md)
- [`inventory_reservations.ex`](../../lib/store/orders/inventory_reservations.ex),
  [`inventory_reservation.ex`](../../lib/store/orders/inventory_reservation.ex), and
  [`inventory_item.ex`](../../lib/store/catalog/inventory_item.ex)
- [`phase_11_inventory_reservations.exs`](../../priv/repo/migrations/20260224201500_phase_11_inventory_reservations.exs)
- [`redis.ex`](../../lib/store/support/redis.ex), [`redix_client.ex`](../../lib/store/support/rate_limit/redix_client.ex),
  [`application.ex`](../../lib/store/application.ex), and [`waiting_room.ex`](../../lib/store_web/waiting_room.ex)
- [`runtime.exs`](../../config/runtime.exs), [`test.exs`](../../config/test.exs),
  [`performance_scaling.md`](../governance/performance_scaling.md), and
  [`phase_29_performance_architecture_optimizations.md`](../phases/phase_29_performance_architecture_optimizations.md)

### Decisions / Pins

- Option A remains selected: distributed Redis-backed admission before the existing
  PostgreSQL reservation transaction; Option B remains rejected for now.
- The MVP freezes `K_v = 1` per variant and retains a separate cluster-wide `B_total`
  reservation DB-entry budget. Both capacities must be granted atomically.
- The corrected ADR defines the bounded admission-to-commit deadline, known versus
  ambiguous PostgreSQL outcomes, durable `reservation_key` recovery, and an ephemeral
  recovery fence. PostgreSQL remains the only inventory authority.
- Queue bounds, queue/process lifetime separation, separate queue and lease expiry
  semantics, fail-closed Redis behavior, PubSub/Stream boundaries, and required
  observability are explicit. `InventoryAdmission` remains internal.
- The MVP requires no new PostgreSQL migration solely for admission, assuming the
  existing reservation identity and index guarantees remain present. No implementation
  is authorized.

### DONE

- Updated only the inventory admission ADR and this existing Phase 00 documentation note.
- Added the accepted corrections without changing production code, tests, migrations,
  Redis/PostgreSQL configuration, or performance certification.

### NEXT

- Perform the independent acceptance review of the corrected ADR. Do not implement
  admission, resume S0 performance certification, start S1, or merge PR #1.

### BLOCKERS

- S0 merge readiness remains blocked pending the required architecture acceptance and
  existing performance gates.
- `bd dolt test` is unavailable in this checkout because the CLI is using embedded mode
  without a Dolt server.

### COMMANDS RUN

- `bd dolt test`, `bd status`, `bd ready`, `bd create ...`, and `bd update ... --claim`
- `rg`, `sed`, `nl`, `tail`, `git status -sb`, focused source/document reads, and
  `apply_patch`
- Targeted required-content, empty-placeholder, document-whitespace, and
  `git diff --check` validation for this correction

### GATES

- Documentation-only scope: PASS. No `lib/`, `test/`, `priv/repo/migrations/`,
  `config/`, or `.github/` changes are authorized by this task.
- Implementation status remains `NOT AUTHORIZED`.
- S0 performance certification and merge readiness remain `BLOCKED`.

### Performance & Scaling Review

- Inventory rows and `InventoryReservation` remain HOT durable PostgreSQL truth; Redis
  admission is HOT ephemeral coordination; telemetry/read projections are WARM; durable
  reservation history is COLD after the write.
- `K_v = 1` bounds same-row entrants and `B_total` preserves global Store.Repo headroom.
  Finite `Q_variant_max` and `Q_global_max`, queue/lease TTLs, and bounded recovery keep
  pressure outside PostgreSQL without requiring a blocked BEAM process per waiter.
- PubSub and Redis Streams have no correctness role in the MVP. Existing PostgreSQL
  identity/index support is reused; no admission migration is required. 100k behaviour
  remains an unmeasured implementation/certification concern, not a claim in this note.

## S0-PLAN-01 Inventory reservation admission implementation plan (2026-09-01)

### GOAL

- Design the smallest implementation tracer bullet for frozen S0-ARCH-01 Option A
  without implementing admission or authorizing production changes.

### PLAN

- Cross-check the frozen ADR against the current reservation, identity/index,
  Redis, waiting-room, Oban, configuration, and performance-harness conventions.
- Produce one implementation plan defining the resource map, lifecycle, Redis atomic
  contracts, bounded deadlines/queues, recovery owner, tests, rollout, phases, and
  TOON micro-prompts.

### Links Consulted

- [`s0_inventory_reservation_admission_architecture.md`](../hardening/s0_inventory_reservation_admission_architecture.md)
- [`s0_inventory_reservation_admission_implementation_plan.md`](../hardening/s0_inventory_reservation_admission_implementation_plan.md)
- [`inventory_reservations.ex`](../../lib/store/orders/inventory_reservations.ex),
  [`inventory_reservation.ex`](../../lib/store/orders/inventory_reservation.ex),
  [`inventory_item.ex`](../../lib/store/catalog/inventory_item.ex), and
  [`domain.ex`](../../lib/store/orders/domain.ex)
- [`phase_11_inventory_reservations.exs`](../../priv/repo/migrations/20260224201500_phase_11_inventory_reservations.exs)
- [`redis.ex`](../../lib/store/support/redis.ex), [`redix_client.ex`](../../lib/store/support/rate_limit/redix_client.ex),
  [`waiting_room.ex`](../../lib/store_web/waiting_room.ex), and
  [`application.ex`](../../lib/store/application.ex)
- [`config.exs`](../../config/config.exs), [`runtime.exs`](../../config/runtime.exs),
  [`test.exs`](../../config/test.exs), existing Oban workers, and the current
  performance smoke/observer support
- [`performance_scaling.md`](../governance/performance_scaling.md),
  [`05_test_strategy.md`](../hardening/05_test_strategy.md), and
  [`08_extraction_gates.md`](../hardening/08_extraction_gates.md)

### Decisions / Pins

- The tracer bullet remains single-variant and freezes `K_v = 1`; `B_total` remains a
  separate cluster-global budget below aggregate Store.Repo capacity/headroom.
- Redis structures and multi-key transitions are server-side atomic; Redis remains
  coordination state only, and PostgreSQL remains durable inventory truth.
- Queue lifetime is independent of Phoenix process lifetime. Finite queue bounds,
  fail-closed Redis behavior, bounded lease/deadline rules, and recovery fencing are
  implementation requirements.
- Ambiguous DB outcomes use a bounded Oban recovery worker and durable
  `reservation_key` lookup. Recovery does not automatically issue a second durable
  attempt.
- Existing quantity-adjustment semantics remain serialized on the same durable
  order/variant identity. No admission resource, migration, Redis inventory ledger,
  multi-variant path, or package extraction is planned.
- The existing generic waiting room and PubSub are not admission correctness
  authorities; Redis Streams are not required for MVP correctness.

### DONE

- Created [`s0_inventory_reservation_admission_implementation_plan.md`](../hardening/s0_inventory_reservation_admission_implementation_plan.md)
  as the single implementation-planning artifact.
- Kept the work documentation-only. No production code, tests, migrations, Redis or
  PostgreSQL configuration, writes, or performance runs were performed.

### NEXT

- Obtain the independent implementation-plan review. Do not implement admission,
  resume S0 performance certification, start S1, or merge PR #1.

### BLOCKERS

- Implementation remains blocked until the plan is independently accepted.
- S0 performance certification and merge readiness remain blocked.
- `bd dolt test` is unavailable in this checkout because the CLI is using embedded
  mode without a Dolt server.

### COMMANDS RUN

- `bd dolt test`, `bd status`, `bd ready`, `bd show`, `bd create`, and
  `bd update ... --claim`
- Focused `rg`, `sed`, `nl`, `tail`, `wc`, and `git status` reads
- `apply_patch` for the planning artifact and this required Phase 00 note

### GATES

- Documentation-only scope: PASS. The only current-task edits are the planning
  artifact and this phase note; no `lib/`, `test/`, `priv/repo/migrations/`, or
  `config/` implementation edits were made.
- `K_v = 1`, global `B_total`, atomic dual-budget admission, PostgreSQL authority,
  bounded queue/process lifetime, recovery fencing, and `NOT AUTHORIZED` are explicit.
- No performance certification or 100k claim was made.

### Performance & Scaling Review

- InventoryAdmission request/lease state is HOT transient coordination; Redis is
  HOT/WARM bounded coordination; InventoryItem and InventoryReservation remain
  COLD/DURABLE PostgreSQL truth with only derived hot projections.
- `K_v = 1` removes same-row herd amplification and `B_total` preserves global
  Store.Repo headroom. Queue bounds, lease/deadline windows, bounded cleanup, and
  caller-independent status interactions keep pressure outside PostgreSQL.
- Existing reservation/index assumptions are reused with no migration. PubSub is
  read-side only, Redis Streams are not required, and 100k behavior remains an
  unmeasured certification concern.

## S0-PLAN-01C implementation-plan correction (2026-09-01)

### GOAL

- Correct the three blocking implementation-plan findings without changing the frozen
  S0-ARCH-01 ADR or authorizing InventoryAdmission implementation.

### Links Consulted

- [`s0_inventory_reservation_admission_implementation_plan.md`](../hardening/s0_inventory_reservation_admission_implementation_plan.md)
- [`s0_inventory_reservation_admission_architecture.md`](../hardening/s0_inventory_reservation_admission_architecture.md)
- [`inventory_reservations.ex`](../../lib/store/orders/inventory_reservations.ex)
- [`inventory_reservation.ex`](../../lib/store/orders/inventory_reservation.ex)
- [`inventory_item.ex`](../../lib/store/catalog/inventory_item.ex)
- [`phase_11_inventory_reservations.exs`](../../priv/repo/migrations/20260224201500_phase_11_inventory_reservations.exs)
- [`ecto/repo.ex`](../../deps/ecto/lib/ecto/repo.ex), [`db_connection.ex`](../../deps/db_connection/lib/db_connection.ex)
- [`checkout/domain.ex`](../../lib/store/checkout/domain.ex), [`payments/interlocks.ex`](../../lib/store/payments/interlocks.ex),
  [`subscriptions/facade.ex`](../../lib/store/subscriptions/facade.ex)
- [`expire_inventory_reservations_worker.ex`](../../lib/store/workers/expire_inventory_reservations_worker.ex),
  [`expire_pending_provider_setup_orders_worker.ex`](../../lib/store/workers/expire_pending_provider_setup_orders_worker.ex)

### Decisions / Pins

- `reservation_key` remains the durable order/variant row identity. Each authorized
  mutation now has a server-generated `operation_id`, `operation_epoch`, and
  `request_fingerprint`; no client value or new PostgreSQL mutation resource is used.
- The plan now requires one live protected mutation per `reservation_key`. A later
  quantity adjustment receives a new operation identity only after the prior operation
  is resolved. The C2 matrix below fixes one policy for every capable writer; it does
  not leave fencing versus exclusion to the coding agent.
- `InventoryReservations.reserve_inventory_outcome/3` is the planned internal seam
  before the existing lossy public `RESERVATION_CONFLICT` mapper. It preserves known
  commit, known rollback/rejection, and ambiguous database outcomes without introducing
  a generic transaction framework.
- The existing schema is sufficient for the supported MVP mutations: the unique
  reservation/inventory identities, reservation/inventory versions, quantities,
  lifecycle fields, and inventory counters support an operation-specific durable
  PRE/POST predicate under the serialization invariant. Row existence alone is never
  adjustment commit proof.
- `InventoryReservations.recovery_snapshot/1` compares the durable PRE/POST state in
  PostgreSQL. POST resolves committed, PRE resolves rolled back, and neither or lost
  ephemeral evidence resolves `UNRESOLVED` and remains fail closed.
- No PostgreSQL migration is required for this correction. If the serialization or
  PRE/POST evidence contract cannot be enforced, implementation must stop for a new
  schema/concurrency review rather than weaken recovery.
- The bounded Oban recovery worker remains the fixed MVP recovery owner. Redis remains
  coordination only; Redis metadata loss quarantines admission and never manufactures
  rollback or availability.

### DONE

- Updated only the implementation plan and this phase note. The plan now contains the
  operation descriptor, structured outcome seam, insert/adjustment recovery proof,
  same-reservation fence, Redis evidence-loss behavior, and path-exact TOON outputs.
- Kept implementation status `NOT AUTHORIZED`. The frozen architecture ADR was not
  changed.

### BLOCKERS

- S0-PLAN-01 remains ready for independent re-review only after documentation
  validation. S0 performance certification, the separate checkout-concurrency blocker,
  S0-CLOSE-02, and merge readiness remain blocked.
- No migration, production code, tests, Redis/PostgreSQL writes, performance run, or
  checkout-concurrency triage is authorized by this correction.

### Performance & Scaling Review

- Operation descriptors and leases remain HOT transient coordination in Redis/Elixir;
  Redis recovery metadata is HOT/WARM and never stock truth. InventoryItem and
  InventoryReservation remain COLD/DURABLE PostgreSQL truth.
- `K_v = 1` and global `B_total` still bound DB entry. The preflight descriptor read is
  performed only after admission under the held budgets; queued requests do not use
  Store.Repo. PRE/POST recovery does not issue an unrestricted second attempt.
- Existing unique/index/version fields are reused with no migration. PubSub remains
  read-side only, Redis Streams remain unnecessary for MVP correctness, and 100k
  behavior remains unmeasured. The checkout-concurrency performance blocker remains
  outside this plan.

## S0-PLAN-01C2 same-reservation writer serialization correction (2026-09-01)

### GOAL

- Freeze one deterministic policy for every current writer that can invalidate the
  operation-specific PRE/POST recovery proof. Keep S0-ARCH-01 frozen and keep
  implementation unauthorized.

### SOURCE MATRIX

- `Store.Orders.reserve_inventory/3` at [`lib/store/orders/domain.ex`](../../lib/store/orders/domain.ex:169)
  remains `ADMISSION_REQUIRED` in `ENFORCED` mode. It is the only normal
  single-variant reserve entry and owns `K_v = 1`, `B_total`, and the reservation
  fence before the existing transaction.
- `Store.Orders.reserve_inventory_for_checkout/3` at
  [`lib/store/orders/domain.ex`](../../lib/store/orders/domain.ex:176), including
  [`lib/store/checkout/domain.ex`](../../lib/store/checkout/domain.ex:767) and the
  one-item renewal call at [`lib/store/subscriptions/facade.ex`](../../lib/store/subscriptions/facade.ex:2627),
  is `ENFORCED_UNAVAILABLE`. It returns `INVENTORY_ADMISSION_UNSUPPORTED` before
  the CTE for every item count. No multi-variant or single-item CTE bypass is allowed.
- `consume_reservations_for_order/2` at
  [`lib/store/orders/inventory_reservations.ex`](../../lib/store/orders/inventory_reservations.ex:100),
  reached by [`lib/store/payments/interlocks.ex`](../../lib/store/payments/interlocks.ex:595),
  is `SHARED_RESERVATION_FENCE` and stays outside the admission queue.
- `release_reservations_for_order/2` at
  [`lib/store/orders/inventory_reservations.ex`](../../lib/store/orders/inventory_reservations.ex:112),
  reached by payment, subscription, and pending-provider cleanup callers, is
  `SHARED_RESERVATION_FENCE` and stays outside the admission queue.
- `expire_reservations/2` and [`ExpireInventoryReservationsWorker`](../../lib/store/workers/expire_inventory_reservations_worker.ex:11)
  are `SHARED_RESERVATION_FENCE`. A busy candidate is deferred and a Redis failure
  causes a governed worker retry. Neither path uses a raw system bypass.
- Pending-provider cleanup through
  [`lib/store/orders/domain.ex`](../../lib/store/orders/domain.ex:699) and
  [`lib/store/workers/expire_pending_provider_setup_orders_worker.ex`](../../lib/store/workers/expire_pending_provider_setup_orders_worker.ex:31)
  inherits `SHARED_RESERVATION_FENCE`. A busy or unavailable release rolls back the
  cancellation transaction so bounded Oban retry can run it later.
- Direct `InventoryReservation` Ash mutation actions and direct
  `InventoryItem.update_counts`, `set_on_hand`, and `adjust_on_hand` actions have no
  production caller in the focused search. Test fixtures use direct `set_on_hand`
  in [`test/store_web/live/cart_checkout_live_test.exs`](../../test/store_web/live/cart_checkout_live_test.exs:170),
  [`test/store/checkout/domain_test.exs`](../../test/store/checkout/domain_test.exs:458),
  and [`test/store/governance/catalog_phase_25_test.exs`](../../test/store/governance/catalog_phase_25_test.exs:125)
  (also at lines 212 and 228). They are `ENFORCED_UNAVAILABLE`; fixtures may prepare
  data before enforcement, but no direct action is a live-operation bypass.
  `InventoryItem.create` during product creation is the sole
  `PROVABLY_NON_OVERLAPPING` inventory-only writer because its variant is new and
  cannot already have a reservation.
- The recovery worker is `RECOVERY_ONLY`: it reads PostgreSQL truth and resolves
  fences, but it does not start a second durable mutation. No other raw SQL or direct
  resource mutation caller was found.

### DECISIONS / PINS

- `INV-PLAN-SER-001` is normative. While an operation for `reservation_key` is
  `QUEUED`, `ADMITTED`, `RESERVING`, `UNKNOWN_DB_OUTCOME`, `RECOVERING`, or
  `UNRESOLVED`, no second writer can mutate that key. A lifecycle writer must first
  acquire the same server-owned Redis reservation fence; an `ENFORCED_UNAVAILABLE`
  path cannot enter PostgreSQL.
- The shared fence is a coordination record only. The owner and owner token are
  checked atomically. It is released after known commit or known rollback. An
  ambiguous lifecycle result retains its descriptor and fence for the bounded Oban
  recovery path. Fence TTL never proves rollback.
- Order-scoped lifecycle target keys are materialized by a bounded PostgreSQL read
  before the complete fence set is acquired. The existing lifecycle transaction uses
  only that fenced set and does not re-scan for newly appearing rows; an uncertain
  target read fails closed and a newly appearing row waits for a later pass.
- `K_v = 1` still serializes all enforced reserve mutations for one variant. A
  lifecycle mutation for a different reservation key may alter the same inventory
  counters. The existing version increments are part of PRE/POST comparison; a
  changed unrelated inventory snapshot resolves `UNRESOLVED`, never a guessed
  `COMMITTED` or `ROLLED_BACK`. Direct unversioned inventory updates are closed in
  `ENFORCED` mode.
- `DISABLED` preserves legacy behavior only while no protected operation is live.
  Mode changes require a deployment drain. No client, system actor, maintenance
  caller, or test may select a raw bypass during `ENFORCED`.
- Redis unavailable or uncertain while acquiring a lifecycle fence returns
  `INVENTORY_ADMISSION_UNAVAILABLE` and performs no durable lifecycle mutation. The
  generic fail-open waiting room cannot override this rule.
- The existing schema remains sufficient only under this exact writer policy. The
  unique `reservation_key`, `(order_id, variant_id)`, and `inventory_items.variant_id`
  indexes plus the existing quantity, state, counter, and version fields remain the
  PRE/POST proof. No migration or durable mutation identity is added.
- TOON IN-04 is the single focused implementation prompt for this matrix and names
  every affected future source and test path. The current checkout-concurrency
  performance blocker remains outside this correction.

### DONE

- Updated only the implementation plan and this phase note. No production code,
  tests, migrations, configuration, Redis/PostgreSQL writes, or performance runs
  were performed.
- Kept `S0-ARCH-01` frozen and `IMPLEMENTATION STATUS: NOT AUTHORIZED`.

### NEXT

- Run the targeted documentation checks, commit only these two documentation files,
  push `hardening/s0-baseline` for PR #1, and obtain the final independent
  implementation-plan review. Do not start IA-01, triage checkout performance, or
  merge PR #1.

### Performance & Scaling Review

- InventoryAdmission and the shared fence are HOT Redis/Elixir coordination. Redis is
  HOT/WARM coordination only. InventoryItem and InventoryReservation remain
  COLD/DURABLE PostgreSQL truth.
- Queued reserve work performs no Store.Repo checkout. `K_v = 1` and `B_total` are
  unchanged. Lifecycle fencing is a correctness boundary, not a second admission
  queue.
- No pool sizes, thresholds, workloads, Redis topology, PgBouncer behavior, or
  performance claims changed. 100k remains unmeasured, and the checkout-concurrency
  blocker remains outside this task.

## S0-IA-AUTH-01 InventoryAdmission IA-01 authorization (2026-09-02)

### GOAL

- Durably authorize only the first InventoryAdmission implementation slice, IA-01,
  while keeping the frozen architecture and plan unchanged in substance.
- This is the current authorization record. It supersedes earlier `NOT AUTHORIZED`
  snapshots only for the bounded IA-01 decision and does not rewrite those historical
  records.

### LINKS CONSULTED

- [`s0_inventory_reservation_admission_architecture.md`](../hardening/s0_inventory_reservation_admission_architecture.md),
  especially its frozen architecture status and Section 18 implementation gate.
- [`s0_inventory_reservation_admission_implementation_plan.md`](../hardening/s0_inventory_reservation_admission_implementation_plan.md),
  especially Section 24 IA-01 and Section 27 authorization state and boundary.
- [`s0_closure_chaos_ci_triage.md`](../hardening/s0_closure_chaos_ci_triage.md),
  including the retained S0 boundary and its statement that the closure record has
  no runtime authority.
- [`performance_scaling.md`](../governance/performance_scaling.md) and the Phase 29
  performance architecture reference linked by the implementation plan.

### DECISIONS / PINS

- `S0-ARCH-01` remains `FROZEN`.
- `S0-PLAN-01` remains `FROZEN`.
- InventoryAdmission implementation is `AUTHORIZED FOR IA-01 ONLY`.
- IA-01 is `AUTHORIZED / NOT STARTED`. It is a bounded pure domain, value, and state
  foundations tracer bullet, not blanket authorization for the frozen plan.
- IA-02 and later remain `NOT AUTHORIZED`.
- `S0-CLOSE-02` remains `BLOCKED`, and S0 merge readiness remains `BLOCKED`.
- The retained S0-CLOSE-08 boundary table in the chaos/CI document is a historical,
  cold documentation record with no runtime authority. The current authorization is
  carried by the implementation-plan gate and this Phase 00 decision record.

### IA-01 SCOPE

- `Store.Orders.InventoryAdmission.Request`.
- `Store.Orders.InventoryAdmission.Operation`.
- `Store.Orders.InventoryAdmission.Lease`.
- The exact frozen admission state vocabulary: `REQUESTED`, `QUEUED`, `ADMITTED`,
  `RESERVING`, `UNKNOWN_DB_OUTCOME`, `RECOVERING`, `UNRESOLVED`, `COMPLETED`,
  `REJECTED`, `EXPIRED`, and `ABANDONED`.
- Transition validation, terminal-state semantics,
  request identity/fingerprint semantics, server-generated operation identity,
  operation epoch semantics, deadline/value validation, and focused pure tests.
- The exact coding task will be supplied separately after this authorization is
  independently reviewed.

### IA-01 EXCLUSIONS

- Redis EVAL/Lua, queue state, Redis ZSET/HASH structures, `K_v` or `B_total`
  acquisition, promotion, Redis lease renewal, and namespace quarantine.
- `Store.Repo` reservation execution, the `InventoryReservations` outcome seam,
  PostgreSQL mutation, ambiguous database recovery, recovery/reaper workers, and
  shared reservation fences.
- Checkout integration, `reserve_inventory_for_checkout` changes, and multi-variant
  admission.
- Feature/config rollout, runtime configuration, PubSub integration, web/LiveView
  waiting UX, metrics dashboards, performance certification, and 100k testing.
- Extraction/package work, migrations, and schema changes.

### PLAN

- Implement only IA-01 after a separate coding prompt.
- Before any later slice is authorized, IA-01 must be implemented, focused-validated,
  committed and pushed, independently reviewed, and tied to an exact-head CI
  disposition. A later task must make the next authorization decision.
- Keep all Redis, PostgreSQL, checkout, recovery, lifecycle-fence, multi-variant,
  rollout, certification, and extraction work outside this authorization.

### DONE

- Updated the explicit authorization status and bounded gate in the existing
  architecture and implementation-plan records, and appended this Phase 00 decision
  record.
- No production code, tests, Redis, PostgreSQL, configuration, migrations, or
  performance workloads were changed or run by this authorization task.

### NEXT

- Supply the separate IA-01 coding prompt. Do not implement IA-02 or later, close
  S0-CLOSE-02, or mark S0 merge-ready.

### BLOCKERS

- `S0-CLOSE-02` remains `BLOCKED` until InventoryAdmission implementation and
  certification work is complete and separately reviewed.
- S0 merge readiness remains `BLOCKED`.

### COMMANDS RUN

- Focused `rg`, `sed`, `git status`, `git diff`, `git rev-parse`, `git merge-base`,
  `git log`, and PR-head checks for authority, baseline, and worktree review.
- `mix check.docs_notes` (PASS), `mix docs` (PASS), `git diff --check` (PASS), and a
  focused authorization-marker assertion (PASS).

### GATES

- Documentation-only authorization change: `PASS`. No production, test,
  configuration, migration, Redis, PostgreSQL, or performance changes are in scope.
- `S0-ARCH-01`: `FROZEN`.
- `S0-PLAN-01`: `FROZEN`.
- InventoryAdmission implementation: `AUTHORIZED FOR IA-01 ONLY`.
- IA-01: `AUTHORIZED / NOT STARTED`.
- IA-02+: `NOT AUTHORIZED`.
- `S0-CLOSE-02`: `BLOCKED`.
- S0 merge readiness: `BLOCKED`.

### Performance & Scaling Review

- Temperature and authority are unchanged. Future IA-01 values are in-memory HOT
  domain data only; Redis admission coordination remains HOT/WARM but unauthorized,
  PostgreSQL inventory and reservation truth remains durable COLD authority, and no
  WARM projection or COLD history changed.
- Database query count is zero for this documentation task. No N+1 risk was added,
  and no database entrant, transaction, or pool behavior changed.
- Existing reservation and inventory indexes remain frozen. No schema or migration
  was added.
- No ETS/Redis cache, TTL, invalidation, or stampede-protection behavior changed.
- No Oban enqueue, worker, uniqueness, or idempotency behavior changed. Recovery and
  reaper workers remain unauthorized.
- No telemetry or logging behavior changed. No performance workload or 100k claim
  was made.

## S0-IA-AUTH-02 InventoryAdmission IA-02 authorization (2026-09-03)

### GOAL

- Durably record IA-01 as independently accepted and frozen.
- Authorize only the IA-02 atomic Redis admission primitive while keeping the frozen
  architecture and plan unchanged in substance.
- This is the current authorization record. It supersedes S0-IA-AUTH-01 only for the
  bounded IA-02 transition and does not rewrite historical IA-01 authorization records.

### LINKS CONSULTED

- [`s0_inventory_reservation_admission_architecture.md`](../hardening/s0_inventory_reservation_admission_architecture.md),
  especially its frozen architecture status and Section 18 implementation gate.
- [`s0_inventory_reservation_admission_implementation_plan.md`](../hardening/s0_inventory_reservation_admission_implementation_plan.md),
  especially Section 24 IA-02 and Section 27 authorization state and boundary.
- IA-01 independent review record: IA-01R1 PASS at
  `f252fcf1d27d22be92a0bffdc88e7306e3c84e4c`, exact-head CI `33754973403` SUCCESS.

### DECISIONS / PINS

- `S0-ARCH-01` remains `FROZEN`.
- `S0-PLAN-01` remains `FROZEN`.
- IA-01 is `COMPLETE / FROZEN`.
- InventoryAdmission implementation is `AUTHORIZED FOR IA-02 ONLY`.
- IA-02 is `AUTHORIZED / NOT STARTED`. It is a bounded atomic Redis admission
  primitive tracer bullet, not blanket authorization for the frozen plan.
- IA-03 and later remain `NOT AUTHORIZED`.
- `S0-CLOSE-02` remains `BLOCKED`, and S0 merge readiness remains `BLOCKED`.

### IA-01 COMPLETION RECORD

- Initial implementation: `7fd2e88fec286d9e216c865d26ef28b1a8c69438`
- IA-01R1 accepted head: `f252fcf1d27d22be92a0bffdc88e7306e3c84e4c`
- Exact-head CI: `33754973403` — SUCCESS
- IA-01 established: pure admission lifecycle/state vocabulary; exact legal transition
  matrix; terminal and `UNRESOLVED` fail-closed semantics; server-derived reservation
  identity; stable logical identity digest; deterministic mutation request fingerprint;
  server-generated operation identity; operation epoch semantics; internally coherent
  PRE/POST operation descriptor; pure Lease/deadline values; distinct DB and lease
  deadline semantics; immutable `K_v = 1`; no Redis/PostgreSQL/config/migration/runtime
  orchestration.

### IA-02 SCOPE

- `lib/store/orders/inventory_admission/redis.ex`
- `test/store/orders/inventory_admission_redis_test.exs`
- Versioned InventoryAdmission Redis namespace/key derivation.
- Opaque admission-member handling and enqueue-or-deduplicate semantics.
- Finite per-variant and global queue bounds.
- Atomic `K_v = 1` plus `B_total` admission condition.
- Queue sequence allocation and active lease record creation.
- Operation/request metadata representation and same-reservation live-operation
  exclusion.
- Fail-closed Redis error handling and decoding Redis results into closed internal
  results with focused Redis integration tests.
- The exact coding task will be supplied separately after this authorization is
  independently reviewed.

### IA-02 EXCLUSIONS

- `Store.Repo` reservation execution and
  `InventoryReservations.reserve_inventory_outcome/3`.
- PostgreSQL PRE lookup, PostgreSQL POST lookup, and ambiguous outcome reconciliation.
- `InventoryAdmission.Recovery`, Oban recovery worker, and reaper worker.
- Shared reservation lifecycle fences for consume, release, or expire.
- `Store.Orders` domain integration, checkout integration, and multi-variant admission.
- Payment integration, PubSub/UI, analytics dashboards, and performance certification.
- Extraction/package work, schema changes, migrations, and IA-03 or later tasks.

### PLAN

- Implement only IA-02 after a separate coding prompt.
- Before any later slice is authorized, IA-02 must be implemented, focused-validated,
  committed and pushed, independently reviewed, and tied to an exact-head CI
  disposition. A later task must make the next authorization decision.
- Keep all PostgreSQL mutation, recovery, lifecycle-fence, checkout, multi-variant,
  rollout, certification, and extraction work outside this authorization.

### DONE

- Updated the explicit authorization status and bounded gate in the existing
  architecture and implementation-plan records, and appended this Phase 00 decision
  record.
- No production code, tests, Redis, PostgreSQL, configuration, migrations, or
  performance workloads were changed or run by this authorization task.

### NEXT

- Supply the separate IA-02 coding prompt. Do not implement IA-03 or later, close
  S0-CLOSE-02, or mark S0 merge-ready.

### BLOCKERS

- `S0-CLOSE-02` remains `BLOCKED` until InventoryAdmission implementation and
  certification work is complete and separately reviewed.
- S0 merge readiness remains `BLOCKED`.

### COMMANDS RUN

- Focused `rg`, `git status`, `git diff`, `git rev-parse`, and PR-head checks for
  authority, baseline, and worktree review.
- `mix check.docs_notes` (PASS), `mix docs` (PASS), `git diff --check` (PASS), and a
  focused authorization-marker assertion (PASS).

### GATES

- Documentation-only authorization change: `PASS`. No production, test,
  configuration, migration, Redis, PostgreSQL, or performance changes are in scope.
- `S0-ARCH-01`: `FROZEN`.
- `S0-PLAN-01`: `FROZEN`.
- IA-01: `COMPLETE / FROZEN`.
- InventoryAdmission implementation: `AUTHORIZED FOR IA-02 ONLY`.
- IA-02: `AUTHORIZED / NOT STARTED`.
- IA-03+: `NOT AUTHORIZED`.
- `S0-CLOSE-02`: `BLOCKED`.
- S0 merge readiness: `BLOCKED`.

### Performance & Scaling Review

- Temperature and authority are unchanged. IA-02 introduces HOT Redis coordination
  only within the bounded primitive; PostgreSQL inventory and reservation truth
  remains durable COLD authority, and no WARM projection or COLD history changed.
- Database query count is zero for this documentation task. No N+1 risk was added,
  and no database entrant, transaction, or pool behavior changed.
- Existing reservation and inventory indexes remain frozen. No schema or migration
  was added.
- Redis structures for IA-02 must remain bounded with finite queue and lease
  retention. No process-per-waiter or timer-per-waiter design is authorized.
- No Oban enqueue, worker, uniqueness, or idempotency behavior changed. Recovery and
  reaper workers remain unauthorized.
- No telemetry or logging behavior changed. No performance workload or 100k claim
  was made.
