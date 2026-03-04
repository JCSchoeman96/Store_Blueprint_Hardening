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

## NEXT

1. Monitor CI behavior for threshold stability under real runner load.
2. Tune per-profile load defaults if CI noise exceeds acceptable variance.
3. Expand benchmark targets as new hot paths are introduced.

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

- Performance smoke script: pending validation after implementation.
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
