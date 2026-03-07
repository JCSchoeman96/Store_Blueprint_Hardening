# Phase 29 — Performance Architecture & Smoke Gates

## GOAL

Implement a deterministic, CI-enforced performance suite for hot/warm/cold paths with explicit latency gates:
- critical-path mean latency < 100ms
- checkout p99 < 5s
- Redis warm-layer required for CI/stress profiles
- concurrency, thundering-herd, stampede, mirror-consistency, and HLL coverage

## LINKS CONSULTED

- `AGENTS.md`
- `docs/phases/phase_29_performance_architecture_optimizations.md`
- `docs/governance/performance_scaling.md`
- `docs/governance/observability_slos.md`
- `docs/governance/inventory_reservations.md`
- `test/store/checkout/domain_test.exs`
- `test/store/governance/inventory_reservations_test.exs`
- `test/store/subscriptions/performance_test.exs`

## DECISIONS / PINS

1. Performance suite entrypoint is `priv/repo/performance_smoke_test.exs`.
2. Suite is self-running via standalone invocation:
   - `MIX_ENV=test STORE_PERF_SMOKE=true mix run --no-start priv/repo/performance_smoke_test.exs`
   - script exits early (code 0) if `STORE_PERF_SMOKE` is not enabled.
3. Redis is mandatory for `ci_gate` and `full_stress` profiles; script fails immediately if Redis ping fails.
4. Profiles:
   - `ci_gate`: scheduler-scaled concurrency
   - `full_stress`: 100+ user and 1000-request style stress defaults
   - `local_dev`: reduced load for local validation
5. Stampede gate is resource-scoped using repo telemetry filter and bounded by `STORE_PERF_STAMPEDE_MAX_RESOURCE_QUERIES` (default 1).
6. HLL gate uses relative error, not exact cardinality equality.
7. Mirror consistency uses a counted quiescent barrier (`barrier(expected_updates)`) that waits for all async updates, preventing false negatives from cross-process cast ordering.
8. CI adds required `performance_smoke_required` job; nightly adds `full_stress` execution.
9. Repo pool size is scheduler-aware by default (`min(max(schedulers * 4, 20), 60)`) and can be overridden via `STORE_PERF_REPO_POOL_SIZE`.
10. Checkout payment provider is env/config driven (`STORE_PERF_PROVIDER` or enabled/default provider config), fail-closed if unsupported/disabled.
11. v0.0.8 adds an async observer scaffold to the standalone smoke script instead of a separate profiler entrypoint.
12. The first observer dimensions are DB lock contention and pool-pressure, scoped only to the checkout concurrency and domain thundering-herd scenarios.
13. Observer metrics are report-only in `local_dev` and enforced as hard gates in `ci_gate` / `full_stress`.
14. Pool pressure is defined for v0.0.8 as active Postgres client-backend utilization against configured repo pool size, not DBConnection checkout telemetry.
15. Phase 29.1 adds a test-only payment-provider fault injector at `Store.Payments.Providers.create_intent/3`, driven by app config instead of env reads inside the provider boundary.
16. Provider fault modes are `:slow`, `:timeout`, and `:error`, mapped to `PAYMENT_PROVIDER_TIMEOUT` / `PAYMENT_PROVIDER_DOWN` for negative-path assertions.
17. Provider-fault smoke scenarios prepare finalized checkout state first, then measure only concurrent `create_intent_for_order/3` execution.
18. Provider slowness is interpreted via `mean_db_share_ratio`: high end-to-end latency with low DB share and low pool/lock pressure is acceptable isolation; high latency with high DB share or DB pressure is a failure.
19. `checkout_concurrency` now distributes users across a variant pool, while `domain_thundering_herd` remains the explicit same-SKU contention scenario.

## PLAN

1. Add `benchee` dependency.
2. Implement performance script modules:
   - config/profile scaling
   - stats/percentiles
   - fail-fast gate checks
   - Redis round-robin pool
   - single-flight cache primitive
   - write-through mirror GenServer
   - fixtures + domain-flow runners
3. Add Benchee micro-benchmarks for hot/warm/cold primitives.
4. Add ExUnit smoke gates for:
   - hot/warm/cold latency
   - checkout concurrency
   - seat-hold concurrency
   - domain/Redis thundering herd
   - single-flight stampede
   - HLL relative error
   - cold saturation including `query_time + queue_time`
   - mirror consistency with barrier
5. Print summary table and emit JSON report at `tmp/perf/performance_smoke_report.json`.
6. Wire CI and nightly workflows to run the suite and upload artifacts.

## DONE

- Added `benchee` dependency.
- Added `priv/repo/performance_smoke_test.exs` with Benchee + ExUnit performance gate suite.
- Added Redis round-robin benchmark pool for concurrent warm-path command execution.
- Added deterministic Redis ping gate at startup for required profiles.
- Added explicit perf-smoke enable switch (`STORE_PERF_SMOKE=true`) and standalone `--no-start` execution contract.
- Added adaptive repo pool sizing and explicit repo timeout/queue tuning for stress runs.
- Replaced mirror pseudo-barrier with a counted barrier to guarantee quiescent consistency checks.
- Made checkout payment provider configurable/validated against enabled providers.
- Added summary table output and JSON artifact in `tmp/perf/`.
- Updated CI and nightly jobs to run smoke suite with `STORE_PERF_SMOKE=true` and `--no-start`.
- Added `Store.PerformanceSmoke.Observer` sampling around the DB-heavy burst scenarios.
- Added `pg_stat_activity` lock-wait and active-backend utilization summaries to the smoke report.
- Added observer threshold env overrides:
  - `STORE_PERF_OBSERVER_INTERVAL_MS`
  - `STORE_PERF_LOCK_WAIT_MAX_RATIO`
  - `STORE_PERF_LOCK_WAIT_MIN_ACTIVE_BACKENDS`
  - `STORE_PERF_POOL_UTILIZATION_MAX_RATIO`
- Added a second console/report section for observer summaries keyed by scenario.
- Added provider fault injection to `Store.Payments.Providers.create_intent/3` with app-configured `:slow`, `:timeout`, and `:error` modes plus optional notify hooks for integration tests.
- Added provider-fault smoke scenarios and reporting for:
  - `provider_fault_slow`
  - `provider_fault_timeout`
  - `provider_fault_error`
- Added provider-fault thresholds and env overrides:
  - `STORE_PERF_PROVIDER_DELAY_MS`
  - `STORE_PERF_PROVIDER_USERS`
  - `STORE_PERF_PROVIDER_MODE`
  - `STORE_PERF_PROVIDER_DB_SHARE_MAX_RATIO`
  - `STORE_PERF_PROVIDER_POOL_UTILIZATION_MAX_RATIO`
  - `STORE_PERF_PROVIDER_LOCK_WAIT_MAX_RATIO`
- Added focused payment integration coverage for:
  - no `idle in transaction` leak during slow provider delay
  - retry/idempotent reuse after `PAYMENT_PROVIDER_TIMEOUT`
  - retry/idempotent reuse after `PAYMENT_PROVIDER_DOWN`
- Added checkout fixture pool sizing via `STORE_PERF_CHECKOUT_VARIANT_POOL_SIZE`.
- Changed `checkout_concurrency` to spread users across a configurable variant pool instead of colliding on one inventory row.
- Added a fixture uniqueness assertion so the checkout throughput scenario cannot silently regress into a de facto single-SKU contention test.

## NEXT

1. Monitor CI behavior for threshold stability under real runner load.
2. Tune per-profile load defaults if CI noise exceeds acceptable variance.
3. Expand observer coverage later with VM memory / reductions and, if needed, event-driven provider telemetry beyond the current create-intent smoke scenarios.

## BLOCKERS

- None.

## COMMANDS RUN

- `bd dolt test`
- `bd status`
- `bd ready`
- `bd create ...`
- `bd update store_blueprint-7yf.22 --claim`
- `mix run priv/repo/performance_smoke_test.exs` (validation)
- `MIX_ENV=test STORE_PERF_SMOKE=true mix run --no-start priv/repo/performance_smoke_test.exs` (intended invocation)
- `mix check` (validation)

## GATES

- Performance smoke script: passing after v0.0.8 observer expansion.
- `mix check`: pending validation after implementation.

## PERFORMANCE & SCALING REVIEW

- **Hot path touched**:
  - catalog stock fast path (ETS)
  - checkout orchestration (cart -> checkout -> shipping -> finalize -> payment intent)
  - reservation contention path
  - Redis seat/visitor primitives
- **Data layers**:
  - Hot: ETS (`StockFastPath`, mirror table)
  - Warm: Redis (HASH/ZSET/HLL + lock key)
  - Cold: Postgres (inventory reads under invalidation/saturation)
- **Query count / N+1 risk**:
  - stampede scenario explicitly bounds same-resource query amplification
  - saturation scenario captures repo query and queue times under concurrency
- **Observer coverage / contention insight**:
  - checkout concurrency and domain thundering herd now sample `pg_stat_activity` every 500ms
  - captures peak lock wait ratio, peak lock waiters, and active-backend utilization
  - lock contention is only considered actionable once active backends reach a minimum threshold, to avoid false positives on low-volume samples
  - checkout throughput is now measured with distributed variant selection, so the checkout observer gate reflects general checkout headroom instead of intentional same-row serialization
  - single-SKU lock contention remains intentionally measured by `domain_thundering_herd`
- **Provider fault isolation**:
  - `create_intent_for_order/3` is now exercised under slow, timeout, and provider-down conditions without changing production runtime behavior
  - provider-fault summaries separate total request duration from aggregate DB queue/query time via `mean_db_share_ratio`
  - passing behavior is explicit: provider waits may increase request latency, but must not materially increase lock pressure or active-backend utilization
- **Indexes / DB posture**:
  - relies on existing inventory/order indexes and row-lock semantics
  - no new schema/index changes in this phase
- **Caching strategy**:
  - single-flight cache primitive used to validate stampede protection behavior
  - explicit invalidation used to force cold-path sampling
- **Oban idempotency/uniqueness**:
  - no new Oban workloads introduced by this phase
- **Telemetry / observability**:
  - repo query telemetry used for resource-filtered counting and queue/query timing
  - JSON artifact + console summary for regression tracking
  - observer metrics intentionally stay within gate scope, not full profiling scope, to preserve fast smoke-suite runtime
