# PR #9 and workstation infrastructure integration plan

> **For agentic workers:** Execute this plan in the registered integration workstream. The source heads are evidence only; do not modify their branches.

**Goal:** Reconcile PR #9 provider-wait lifecycle guarantees with current `main`, then apply the workstation PostgreSQL 18 and Redis namespace migration.

**Architecture:** Keep current `origin/main` as the code base. Port PR #9 ownership proof and lifecycle behavior into the current observer/provider-phase flow. After those behaviors pass focused tests, add the workstation DEV/TEST endpoints and run-scoped Redis key ownership. Keep CI services job-owned and preserve the strict BEAM/nightly setup.

**Tech stack:** Elixir, ExUnit, Ecto/PostgreSQL 18, Redix/Redis 7, Docker Compose, GitHub Actions.

---

## Performance and scaling review

- **Hot paths:** payment checkout and provider waits, rate limiting, aggregate telemetry in Redis, and performance-smoke observation.
- **Database load:** the change adds read-only connection-pool metrics and existing `pg_stat_activity` sampling to provider-wait ownership proof. It adds no application query or migration. Preserve current-main Repo/DirectRepo attribution and bounded inventory lock-wait drain checks.
- **Indexes:** no index changes are needed because the change adds no application query.
- **Redis:** prefix every project key by project and environment; append a random run identifier in TEST and performance runs. Delete only keys matching the owned prefix. No cache TTL or invalidation behavior changes.
- **Oban:** no queue, uniqueness, or idempotency behavior changes.
- **Telemetry:** preserve provider setup start/terminal tracking and phase-aware observer output. Report provider-wait proof status and incomplete evidence without converting an incomplete proof into a pass.

## Read-only source comparison

The repository baseline is `origin/main` at `0bb6965635d9b020d3321c438b658fe7feb063af`. The approved PR #9 source is `d52668e34ec37400355c9ce9c22c681661105a9c`. The workstation migration candidate is `e7699dc00d518bc35a3e59851feeea2ee8ae4071`; the prior integration attempt `2ef62a0` supplies the candidate nightly workflow changes but is not the implementation base. The strict-BEAM nightly predecessor is `fc815101ed9e7d714eb397bd5793ab25f88556be`.

No repository-local infrastructure audit report was found by searching tracked documentation. The source review found that the migrations require PostgreSQL's `citext` extension, installed by migration `20260222122018`; no unusual server configuration was found. Shared PostgreSQL remains suitable when each environment has its own database and role, and shared Redis is suitable after all keys and cleanup are scoped. The clean PostgreSQL 18 TEST migration later verified that `citext` is available and that the non-superuser TEST role can install it.

### Required behavior from current `main`

`priv/repo/performance_smoke_test.exs` and `test/support/performance_smoke_observer_contract.ex` identify Store.Repo and Store.DirectRepo connections by application name, collect database activity and row-lock evidence, classify expected inventory-reservation waits separately from unexpected lock waits, include elapsed wait duration, and require expected contention to drain after the workload. The observer reports pre-provider, provider-wait, and post-provider sample counts and repository-pool utilization. Provider-fault gates require provider-wait samples, enforce the configured pool limit, and keep the existing observer summary/gate behavior.

`Store.PerformanceSmoke.ProviderPhase` tracks provider setup task start and terminal events. Observer samples must continue to record `ProviderPhase.current/0` while provider-fault traffic runs. Current main tests in `test/store/perf/observer_contract_test.exs` remain independent evidence for observer classification, thresholds, and drain behavior.

### Required behavior from PR #9

`test/support/provider_wait_ownership_probe.ex` must retain its cohort accounting, explicit barrier-reached count, baseline/barrier connection-pool snapshots, topology-change detection, and process-local `Store.Repo.checked_out?/0` evidence. It must report retained ownership as failure, unavailable/incomplete evidence as incomplete, and reject an incomplete cohort as proof. Release state must be made durable before waiter notifications, all registered waiters must be released, and release timeout must prevent a passing proof.

`Store.PerformanceSmoke.RedisPool.transfer_teardown_ownership!/2` must unlink the pool from its setup owner, register cleanup and stop the owned supervisor in `on_exit`, and stop the pool and re-raise if callback registration fails. Cleanup must run while the pool is alive. The lifecycle tests from PR #9 must remain, including owner-death behavior, usable pool during cleanup, deterministic shutdown, and fail-closed callback-registration failure.

PR #9 also caps provider-fault concurrency to at most one quarter of the Store.Repo pool (with a minimum of one), tracks peak in-flight provider tasks, and enters the ownership barrier before each simulated provider response. Keep that cap, tracking, and barrier placement in the provider fault scenario.

The read-only review found behavior gaps that must be corrected while preserving the PR guarantees. PR #9's linked-owner test returns normally but expects the linked supervisor to die; the test must signal an abnormal owner shutdown. Its timeout test manually finalizes a proof instead of exercising the actual sampler/release path; add a test that drives `await_and_sample!/0` and proves a timed-out waiter cannot yield a passing result. Keep unlink and callback registration under fail-closed cleanup so a failed transfer cannot leave an unowned pool.

Current `main` also registers a teardown for the performance-smoke mirror. Keep that callback and its explicit stop even while splitting RedisPool into its own module. PR #9 removes the callback, which would leave the mirror lifecycle unmanaged after the setup owner exits.

### Required behavior from the workstation migration candidate

DEV and TEST use separate PostgreSQL 18 clusters with `store_blueprint_dev` and `store_blueprint_test` roles/databases. Test partition suffixes append directly (`store_blueprint_test1`, `store_blueprint_test2`). Ordinary development and tests use PostgreSQL on `127.0.0.1:55432` and `127.0.0.1:55433`, and Redis on `127.0.0.1:56379` and `127.0.0.1:56380`.

Redis keys use project/environment prefixes. Test runs get distinct namespace suffixes. Namespace cleanup scans only the owned prefix and deletes those keys. Neither shared path may issue `FLUSHDB` or `FLUSHALL`. Performance/load Redis and PostgreSQL remain explicitly project-isolated. The canonical `compose.yaml` describes the deployable app only, with no workstation databases or Redis. CI keeps job-owned PostgreSQL/Redis services on PostgreSQL 18. Nightly retains the strict BEAM setup and full stress suites while its ephemeral PostgreSQL service moves to PostgreSQL 18.

## Implementation order

### Task 1: Reconcile performance behavior before infrastructure changes

Files: `priv/repo/performance_smoke_test.exs`, `priv/repo/performance_smoke_redis_pool.exs`, `test/support/provider_wait_ownership_probe.ex`, `test/support/performance_smoke_observer_contract.ex`, `test/store/performance_smoke/redis_pool_lifecycle_test.exs`, and focused tests under `test/store/perf/`.

- Preserve the current-main observer and provider-phase implementations and tests.
- Add PR #9 provider-wait ownership instrumentation within the provider-fault scenario while the current ProviderPhase wrapper and Observer capture remain active. Keep its bounded provider concurrency and peak in-flight tracking.
- Keep the RedisPool lifecycle operations in a focused module, make ownership transfer fail closed, and retain both current-main mirror teardown and current-main setup/cleanup behavior.
- Add a ProviderPhase telemetry test; current main has observer contract tests but no direct ProviderPhase test. Preserve the observer contract tests.
- Add independent tests for observer behavior, provider-phase event tracking, ownership proof pass/fail/incomplete states, actual sampler release timeout, owner teardown, cleanup while alive, and failed callback registration.
- Fix PR #9's linked-owner test to terminate the owner abnormally, as the linked supervisor contract requires.
- Run focused reconciliation tests before any workstation endpoint/configuration change.

### Task 2: Layer workstation Redis/PostgreSQL configuration

Files: `.env.example`, `.env.production.example`, `.gitignore`, `.dockerignore`, `config/dev.exs`, `config/test.exs`, `config/runtime.exs`, `lib/store/support/redis.ex`, rate-limit Redis client/backend, performance smoke prefixes, test helpers, CI, deployment docs, and canonical `compose.yaml`.

- Assign the separate DEV and TEST PostgreSQL 18 endpoints and approved role/database names.
- Preserve direct test partition suffixes and require explicit isolated endpoints for performance/load runs.
- Use a project and environment namespace for every Redis key. Give each test process a unique run namespace.
- Keep deletion prefix-scoped, propagate cleanup errors, and remove broad database flush behavior.
- Keep Compose limited to the deployable application and do not touch legacy data or the workstation stack.
- Add independent tests for key namespace shape and for cleanup preserving a key outside the project prefix.

### Task 3: Layer nightly PostgreSQL 18

File: `.github/workflows/nightly-hardening.yml`.

- Preserve `erlef/setup-beam@v1` with `version-type: strict`, matrix seeds, replay/property/performance stress coverage, artifacts, and nightly Dialyzer.
- Use a job-owned PostgreSQL 18 service with the TEST database and non-superuser test role. Keep the Redis 7 service job-owned and ephemeral.
- Give the full-stress smoke explicit PostgreSQL and Redis service endpoints.

### Task 4: Validate and prepare the successor integration

Run the exact checks required by the task: `mix check`; focused lifecycle/observer/provider-phase and Redis namespace tests; clean PostgreSQL 18 TEST migration; read-only DEV connectivity; partition suffix test; Compose config; CI/nightly YAML validation; secret/ignore checks; and `git diff --check`.

Do not push before the reconciliation and migration are internally green. Do not edit or close PR #9. Document whether PR #9 is superseded only after the successor integration is accepted.

### Reconciliation outcome and PR relationship

The implementation keeps PR #9's provider-wait cohort accounting, barrier-reached evidence, pool/topology snapshots, checked-out ownership checks, durable release acknowledgement, bounded provider-fault concurrency, and RedisPool teardown transfer guarantees. It retains PR #9's related lifecycle coverage and corrects the owner-exit test to use an abnormal shutdown and the timeout case to exercise the actual sampler path.

The implementation keeps current-main's Repo/DirectRepo observer attribution, lock-wait classification and drain gates, pool utilization and provider-phase sampling, the provider-phase wrapper around Observer capture, and the performance-smoke mirror teardown. Independent tests cover observer behavior, provider-phase behavior, provider-wait proof states, and Redis lifecycle ownership.

Redis namespace and prefix-only cleanup changes were layered after the focused performance reconciliation passed. They use `store_blueprint_hardening:<environment>:<run-id>` prefixes for tests/performance runs and fixed `dev`/`prod` prefixes where the runtime is long-lived; shared cleanup uses only `SCAN` plus `DEL` for the active prefix. PostgreSQL DEV/TEST settings and CI/nightly PG18 service updates were then layered onto the same baseline.

PR #9 remains untouched. After this successor integration is accepted, PR #9 can be closed as superseded; it must not be merged independently or closed before acceptance.
