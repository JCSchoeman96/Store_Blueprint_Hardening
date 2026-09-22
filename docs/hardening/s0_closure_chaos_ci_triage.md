# S0 Closure — Chaos Performance CI Triage

## 1. Scope

This is the S0-CLOSE-01 investigation of the required `performance_smoke_chaos_required`
job for PR #1 at commit `b601bdec6e4d64deb58290a8dede17fda82f70c4` on
`hardening/s0-baseline`.

The scope is limited to identifying the exact failure, reproducing it where practical,
classifying its cause, and defining one follow-up correction task. This document does
not approve extraction, start S1 hardening, or change application, test, migration,
configuration, workflow, threshold, or gate behaviour.

The evidence shows a failed required CI gate, not a merge-ready S0 baseline. The
primary classification is `HARNESS / THRESHOLD DEFECT`. The underlying inventory row
contention remains a real hot-path characteristic that requires separately bounded
performance work; that observation is not a reason to weaken this required gate.

## 2. GitHub Failure Evidence

The fresh GitHub Actions run was [run 33111068594](https://github.com/JCSchoeman96/Store_Blueprint_Hardening/actions/runs/33111068594).
The failed job was [`performance_smoke_chaos_required`, job 98654523076](https://github.com/JCSchoeman96/Store_Blueprint_Hardening/actions/runs/33111068594/job/98654523076).

| Field | Observed evidence |
|---|---|
| Workflow run | `33111068594`, run number `14`, attempt `1` |
| Head | `b601bdec6e4d64deb58290a8dede17fda82f70c4` |
| Job | `performance_smoke_chaos_required` |
| Job result | `failure` |
| Failing step | `Run mobile-realistic chaos smoke gate` |
| Command | `mix run --no-start priv/repo/performance_smoke_test.exs` |
| Process result | Exit code `1` |
| Failing test | `thundering herd on domain reservation has one winner` (`Store.PerformanceSmokeTest`) |
| Failing assertion | `Gate.assert_observer_summary(observer_summary)` at `priv/repo/performance_smoke_test.exs:1715`; the helper fails at line `621` when `summary.pass` is false |
| Failed observer | `domain_thundering_herd_observer` |
| Failed metric | `peak_lock_wait_ratio=0.44`, above `lock_wait_max_ratio=0.1` |
| Related sample | `peak_lock_waiters=11`, `peak_active_backend_utilization=0.625`, `lock_wait_min_active_backends=10` |
| Threshold counts | `samples_over_lock_threshold=1`; `samples_over_pool_threshold=0` |
| Suite result | `7 tests, 1 failure`; `ExUnit` stopped after the first failure because the harness uses `max_failures: 1` |

The relevant CI output was:

```text
1) test thundering herd on domain reservation has one winner (Store.PerformanceSmokeTest)
   priv/repo/performance_smoke_test.exs:1666
   observer gate failed for domain_thundering_herd_observer:
   peak_lock_wait_ratio=0.44
   peak_lock_waiters=11
   peak_active_backend_utilization=0.625
   lock_wait_max_ratio=0.1
   lock_wait_min_active_backends=10
   pool_utilization_max_ratio=0.95
   samples_over_lock_threshold=1
   samples_over_pool_threshold=0
   code: Gate.assert_observer_summary(observer_summary)
   stacktrace:
     priv/repo/performance_smoke_test.exs:621: Store.PerformanceSmoke.Gate.assert_observer_summary!/1
     priv/repo/performance_smoke_test.exs:1715: (test)
...
7 tests, 1 failure
...
Performance smoke suite failed
##[error]Process completed with exit code 1.
```

There was no timeout, deadlock report, or unrelated harness exception. The CI pool
gate passed: no sample exceeded the `0.95` pool utilization threshold. The only test
failure was the intended `ExUnit` assertion in the observer gate.

No PostgreSQL or Redis error was reported during the workload. Redis logged the
environment warning `Memory overcommit must be enabled` and completed its RDB save.
PostgreSQL logged two missing-table errors during teardown, after the smoke work:
`checkout_sessions` and `shipping_rate_rules`. Those cleanup errors are secondary
harness hygiene evidence and did not cause the failed assertion or its exit code.

The uploaded [chaos performance report](https://github.com/JCSchoeman96/Store_Blueprint_Hardening/actions/runs/33111068594/artifacts/9662673540)
records the same failed status and observer values. All reported latency, provider
fault, cache, checkout, and non-observer smoke metrics passed their configured gates.

## 3. Failing Command and Source Paths

The workflow invokes the same standalone command for both required smoke jobs:

```bash
mix run --no-start priv/repo/performance_smoke_test.exs
```

The exact source and evidence paths are:

| Path | Role in the failure |
|---|---|
| [`ci.yml`](../../.github/workflows/ci.yml) ([CI view](https://github.com/JCSchoeman96/Store_Blueprint_Hardening/blob/b601bdec6e4d64deb58290a8dede17fda82f70c4/.github/workflows/ci.yml#L303-L406)) | Defines the normal and required chaos jobs, services, environment, and command |
| [`performance_smoke_test.exs`](../../priv/repo/performance_smoke_test.exs) ([source](https://github.com/JCSchoeman96/Store_Blueprint_Hardening/blob/b601bdec6e4d64deb58290a8dede17fda82f70c4/priv/repo/performance_smoke_test.exs)) | Loads the profile, derives workload values, captures observer samples, and asserts thresholds |
| [`performance_smoke_test.exs`, observer gate](../../priv/repo/performance_smoke_test.exs#L619-L735) | Queries `pg_stat_activity`, computes lock/pool ratios, and requires zero threshold violations |
| [`performance_smoke_test.exs`, domain test](../../priv/repo/performance_smoke_test.exs#L1666-L1716) | Creates the one-unit inventory herd, asserts one winner and failed competitors, then asserts latency and observer gates |
| [`chaos_profile.ex`](../../lib/store/perf/chaos_profile.ex) ([source](https://github.com/JCSchoeman96/Store_Blueprint_Hardening/blob/b601bdec6e4d64deb58290a8dede17fda82f70c4/lib/store/perf/chaos_profile.ex)) | Provides the deterministic `mobile_realistic` provider-latency distribution |
| [`stripe_api_stub.ex`](../../test/support/stripe_api_stub.ex) | Applies the chaos profile to Stripe stub calls; it is not called by the direct reservation test |
| [`inventory_reservations.ex`](../../lib/store/orders/inventory_reservations.ex) ([source](https://github.com/JCSchoeman96/Store_Blueprint_Hardening/blob/b601bdec6e4d64deb58290a8dede17fda82f70c4/lib/store/orders/inventory_reservations.ex)) | Uses a PostgreSQL transaction and `FOR UPDATE` on the inventory row |
| [`inventory_reservations.md`](../governance/inventory_reservations.md) | Governs no-oversell behaviour and expected serialization for a popular variant |
| [`06_performance_data_map.md`](06_performance_data_map.md) | Records the inventory single-row lock hotspot and its expected serialization |

The effective CI chaos configuration recorded in the report was:

| Setting | Value |
|---|---|
| Smoke profile | `ci_gate` |
| Chaos profile | `mobile_realistic` |
| Chaos seed | `ci-mobile-realistic` |
| Repository pool | `40` |
| Checkout variant pool | `56` |
| Concurrent users | `56` |
| Provider-fault users | `50` |
| Thundering-herd users | `80` |
| Stampede requests | `480` |
| Redis pool | `28` |
| Observer interval | `500 ms` |
| Lock ratio threshold | `0.10`, evaluated only when active backends are at least `10` |
| Pool ratio threshold | `0.95` |
| Provider fault delay | `2000 ms` fallback delay |
| ExUnit behaviour | deterministic seed `0`, `max_failures: 1` |

The observer takes an immediate sample and then samples at the configured interval.
The failed CI domain observer summary contained only one sample. Consequently, the
gate measured a transient point in the intentionally serialized herd rather than a
stable distribution over the complete contention window.

The domain test creates one inventory unit and sends all `80` orders through
`Store.Orders.InventoryReservations.reserve_inventory/3`. The reservation path locks
the same inventory row with `FOR UPDATE`; one transaction wins and the other
transactions wait and then return `OUT_OF_STOCK`. The test also asserts the one-winner
result and a domain mean latency below `250 ms`.

## 4. Normal vs Chaos Profile

Both CI jobs use the same command, services, database port, repository pool, workload
shape, thresholds, and observer implementation. The normal job was `98654523019`.
The [normal report](https://github.com/JCSchoeman96/Store_Blueprint_Hardening/actions/runs/33111068594/artifacts/9662670636)
and chaos report both record the effective CI load shown above.

| Dimension | Normal Smoke | Chaos Smoke |
|---|---|---|
| Workload | Same standalone performance smoke suite; all `12` tests completed | Same suite and effective load; stopped after the first failure at `7` tests because of `max_failures: 1` |
| Concurrency | `56` concurrent users, `80` domain-herd users, `50` provider-fault users, repository pool `40` | Same values |
| Fault injection | `baseline` chaos profile and default seed `store-perf-chaos`; explicit slow/timeout/error provider cases still run | `mobile_realistic` profile with seed `ci-mobile-realistic`; deterministic latency is applied to Stripe stub calls and provider-fault scenarios |
| Duration | Same observer interval `500 ms`; same Benchee smoke settings and provider fallback delay; no separate fixed suite-duration setting | Same configured durations; profile latency changes scheduling, and the suite stops at the first failure |
| DB settings | PostgreSQL `16` service, port `5433`, repository pool `40`, direct pool `10`, test migrations | Same settings and service definition |
| Redis behaviour | Redis `7` service, port `6379`, pool `28`; Redis tests pass; no Redis authority in the domain reservation test | Same Redis behaviour; the chaos profile does not inject a Redis fault into the domain reservation test |
| Thresholds | Same report thresholds, including lock ratio `0.10`, minimum active backends `10`, pool ratio `0.95`, domain mean `250 ms`, and checkout p99 `5000 ms` | Same thresholds |
| Assertions | Domain metric passed (`mean 70.35 ms`, p99 `116.502 ms`); one observer sample saw `0` waiters and passed | Domain metric passed (`mean 73.1856 ms`, p99 `114.575 ms`); one observer sample saw `11` waiters and failed the lock gate |

The extra chaos condition that can affect this test is the deterministic provider
latency profile in preceding provider calls. Source inspection shows no provider fault
branch in `reserve_inventory/3`; the direct domain reservation workload is the same.
The evidence therefore implicates timing-sensitive observer capture around an expected
row-lock queue, not a chaos-injected payment or inventory failure.

## 5. Reproduction Results

The exact smoke command was attempted locally with the same declared chaos profile,
seed, database port, pool size, and test profile:

```bash
MIX_ENV=test \
STORE_DB_PORT=5433 \
STORE_PERF_SMOKE=true \
STORE_PERF_PROFILE=ci_gate \
STORE_PERF_CHAOS_PROFILE=mobile_realistic \
STORE_PERF_CHAOS_SEED=ci-mobile-realistic \
STORE_PERF_REPO_POOL_SIZE=40 \
PGHOST=localhost \
PGPORT=5433 \
PGUSER=postgres \
PGPASSWORD=postgres \
PGDATABASE=store_test \
mix run --no-start priv/repo/performance_smoke_test.exs
```

`REPRODUCED: YES` for the target observer assertion. The exact GitHub runner was not
reproduced: the local BEAM reported `24` schedulers while CI derived its effective
`ci_gate` workload from `4` schedulers, and local PostgreSQL/Redis versions were
`16.13`/`7.4.8` versus CI image versions `16.15`/`7.4.11`. The local first set also
used the existing `store_test` database. A dedicated `store_tests0close` database was
then created and migrated with the existing `mix ash_postgres.create` and
`mix ash_postgres.migrate` commands before the clean CI-shaped attempts.

The five literal-profile attempts were the bounded repeat set. A separate dedicated
database was then used to exclude the existing local fixture state; three confirmation
attempts were made there, with two stopping earlier at a local provider-timeout gate.
The results were:

| Attempt | Environment | Result |
|---|---|---|
| Literal run 1 | Literal CI environment variables on local services | PASS; domain observer `0` waiters, ratio `0.00`; suite passed |
| Literal run 2 | Same command and services | FAIL; target observer ratio `0.975`, `39` waiters, pool utilization `1.0`; domain one-winner and latency assertions passed |
| Literal run 3 | Same command and services | PASS; domain observer `0` waiters, ratio `0.00`; suite passed |
| Literal run 4 | Same command and services | FAIL before the target test at the provider-timeout gate; not the GitHub assertion |
| Literal run 5 | Same command and services | FAIL; target observer ratio `0.57142857`, `8` waiters, pool utilization `0.35`; domain one-winner and latency assertions passed |
| Clean run 1 | Dedicated migrated DB with explicit CI-shaped loads `56/80/50/480` | FAIL; target observer ratio `0.375`, `6` waiters, pool utilization `0.4`; domain one-winner and latency assertions passed |
| Clean run 2 | Same dedicated DB and CI-shaped loads | FAIL before the target test at the local provider-timeout gate; no target assertion evaluated |
| Clean run 3 | Same dedicated DB and CI-shaped loads | FAIL before the target test at the local provider-timeout gate; no target assertion evaluated |

These were bounded diagnostic runs, not a soak or stress certification. They show
that the target observer failure is reproducible, but its observed ratio depends on
whether the single sample lands while the row lock is queued. The alternating local
results are explained by this capture timing and by local environment differences;
they do not establish an unexplained application flake.

The local PostgreSQL teardown emitted the same missing-table cleanup errors observed
in CI. The current migrated schema contains `checkout_drafts` and `shipping_rates`,
which confirms that those cleanup names are stale, but the errors occur after the
workload and are not the cause of the target observer assertion.

## 6. Root Cause Classification

Classification: **HARNESS / THRESHOLD DEFECT**

The classification is based on these facts:

- The domain test deliberately creates a last-unit herd against one inventory row.
  PostgreSQL row-lock serialization is the intended no-oversell mechanism, and the
  inventory governance document explicitly expects serialization for a popular SKU.
- The test's one-winner assertion, `79` losing `OUT_OF_STOCK` results, and domain
  latency metric all passed. The failed condition is the observer's zero-tolerance
  sample rule, not a commerce result.
- `lock_wait_max_ratio=0.10` is enforced as zero permitted samples above the ratio.
  No corresponding governance acceptance criterion requiring zero lock wait for this
  intentionally serialized workload was found.
- The observer samples immediately and every `500 ms`. The failing CI run captured
  only one domain sample, so a transient queue is enough to fail the whole required
  gate. The normal job's one sample happened to see no waiters.
- The chaos profile changes Stripe stub timing in preceding tests but does not inject
  a fault into the direct reservation call. Clean local CI-shaped execution observed
  the same target assertion.

This is not classified as `NONDETERMINISTIC / FLAKY FAILURE`: the varying result is
accounted for by the known sampling window and deliberately contended row lock. It is
not classified as `CI / ENVIRONMENT-SPECIFIC FAILURE`: CI and local environments
differ, but the target assertion also occurs locally on a clean database and the CI
pool gate did not show runner resource exhaustion. It is not classified as a real
commerce correctness failure because the protected reservation assertions passed.

The classification does not mean the inventory hotspot should be ignored. It means
the current observer contract is not a valid extraction-certification criterion for
this workload until its measurement window and acceptance rule are made explicit and
deterministic.

## 7. Commerce Correctness Impact

The failing scenario did not fail a protected commerce invariant.

| Protected concern | Evidence from this run |
|---|---|
| Inventory overselling | PASS: inventory was forced to one unit and exactly one reservation succeeded |
| Reservation failure semantics | PASS: the other `79` attempts returned the expected failure class/count |
| Reservation exactly-once result | No duplicate successful reservation was observed; the test's one-winner assertion passed |
| Payment idempotency / duplicate commercial effects | Not exercised by the failing domain test; no payment call or payment state transition occurred |
| Checkout uniqueness | Not exercised by the failing domain test |
| Subscription renewal uniqueness | Not exercised |
| Entitlement correctness | Not exercised |
| Worker replay safety | Not exercised; Oban is disabled for this smoke harness |
| Transaction/lock ordering | No ordering failure or deadlock was reported; the single-variant test intentionally serialized on one row |

Therefore this incident is not a P0 correctness failure. It remains a blocking CI
gate failure. A future correction or certification run that demonstrates duplicate
effects, overselling, incorrect consume/release, or replay failure must be escalated
as P0 before any extraction decision.

## 8. Performance & Scaling Impact

The affected path is an inventory reservation hot path:

| Field | Assessment |
|---|---|
| Data class | `HOT` |
| Authoritative store | PostgreSQL; inventory counters and reservation rows are durable database truth |
| Current cache | ETS `Store.Catalog.StockFastPath` with a five-second best-effort derived quantity cache; it is a cart precheck and cannot authorize the final reservation |
| Redis structure | None relevant to this domain reservation failure; the separate Redis seat herd checks passed |
| DB indexes | Existing unique `inventory_items.variant_id` and reservation indexes/constraints covering variant/state/expiry, order/variant, and reservation identity; the failure does not identify a missing index |
| Locking | `FOR UPDATE` on the inventory item row; multi-variant paths sort UUIDs by binary UUID order; this one-unit test intentionally makes all contenders queue on one row |
| Oban | Disabled in the standalone smoke; no queue, retry, or fan-out is involved |
| PubSub | Not involved |
| Cache rules | ETS is a derived precheck only; PostgreSQL wins on reservation; no cache may become durable stock or reservation truth |
| TTL / invalidation | StockFastPath uses a five-second TTL and explicit variant invalidation; reservation correctness does not depend on the cache being fresh |
| Stream/batch requirement | None for one reservation transaction; any later high-volume workload must preserve bounded transactions and idempotency |
| Expected 100k-concurrency behaviour | Not certified or measured. A single popular variant remains a PostgreSQL row-lock hotspot, so throughput is bounded by serialized access even with more web nodes |

The failure exposes transient PostgreSQL row-lock contention and observer sampling
sensitivity. It does not show Redis pressure, cache stampede, Oban amplification,
connection-pool exhaustion, scheduler exhaustion, mailbox growth, or memory growth.
The CI observer's peak active backend utilization was `0.625`, below the `0.95`
pool threshold.

The performance evidence is therefore sufficient to require a narrowly scoped
observer-contract correction and later measured contention work. It is not sufficient
to claim 100k-concurrency readiness or to prescribe a production performance fix in
this triage.

## 9. Security Impact

No security boundary was degraded by the failure or by the chaos behaviour exercised.

| Security dimension | Assessment |
|---|---|
| Trust boundary | The observer and reservation calls run inside the test harness; this is not a public web request or provider callback |
| Authorization owner | The domain reservation surface remains the owner of reservation semantics; the observer only reads PostgreSQL activity statistics |
| Actor/system requirements | No public caller supplied `system?: true`, `authorize?: false`, guest-cart token, or step-up value in the failing path |
| Replay risk | No webhook replay or provider event was injected; the observer itself has no commerce write path |
| Data exposure | The report contains aggregate lock/pool metrics, not secrets, provider credentials, client secrets, or customer PII |
| Authorization / ownership | No ownership check was bypassed or changed |
| Payment/webhook verification | Not involved; no fail-open verification path was exercised |
| Entitlement freshness / rate limiting | Not involved |
| Audit | No financially or privilege-sensitive audit event was created by this observer-only failure; extraction gates still require durable audit decisions for those actions |

The stale teardown table names are a harness maintenance issue, not a security
decision. Any later observer correction must preserve the domain invariant assertions
and must not turn an internal measurement path into an application authority path.

## 10. S0 Merge Decision

**BLOCKED**

The required chaos performance job is red at the inspected S0 head. This triage does
not make the PR merge-ready, and no unchanged fresh GitHub rerun has passed after the
failure. The baseline is eligible for a new decision only after the separate
correction task below and fresh green required CI evidence.

## 11. Required Next Task

Define exactly one correction task:

**Correct the domain-thundering-herd chaos observer contract in the smoke harness.**

The task must make observer capture of the intentionally row-lock-serialized workload
deterministic and define a documented lock-contention acceptance criterion that is
consistent with the no-oversell contract. It must retain the existing one-winner,
failed-loser, latency, and required-gate assertions, and must not weaken separate
replay-safety protections. It must not pass by increasing a threshold solely to hide
contention, reducing the workload, disabling chaos, allowing failure, or changing
production reservation semantics.

Acceptance evidence for that one task is:

- the observer covers the complete intended contention window rather than relying on
  one opportunistic sample;
- the acceptance criterion is reviewed against the inventory governance contract and
  the measured workload;
- bounded repeated executions produce interpretable observer results;
- the protected one-winner/no-oversell assertions remain green; and
- the required chaos job passes in a fresh CI run with the gate still required.

This task does not include an application fix, schema/index change, provider change,
stale-cleanup repair, threshold relaxation, or S1 hardening.

## 12. S0-CLOSE-08 final checkout pool-saturation disposition

Sections 10 and 11 record the earlier S0-CLOSE-01 state and observer-correction task.
This section is the durable final disposition for S0-CLOSE-08 at the exact head below.
It records the accepted checkout evidence without reopening diagnosis or changing
checkout code, the diagnostic harness, `InventoryAdmission`, S0-ARCH-01, or S0-PLAN-01.

### Disposition

| Field | Final status |
|---|---|
| S0-CLOSE-08 | `CLOSED` |
| Disposition | `PERFORMANCE RISK DOCUMENTED FOR LATER HARDENING` |
| Production checkout defect | `NOT PROVEN` |
| Historical 40/40 | `REAL BUT TIMING-SENSITIVE TRANSIENT SIGNAL` |
| Historical measurement | Sampled `pg_stat_activity` active `Store.Repo` backends |
| Measurement qualification | It was not an Ecto pool ownership high-water measurement |
| Generic pool threshold | `0.95`, `KEEP` |
| Observer interval | `500 ms`, `KEEP` |
| Another checkout performance run | `NOT AUTHORIZED` |

### Exact-head evidence provenance

The accepted evidence is bound to this exact repository head and retained CI and
diagnostic references:

| Evidence | Value |
|---|---|
| SHA | [`f65c78d42305fa519950212133d520f85bdc7771`](https://github.com/JCSchoeman96/Store_Blueprint_Hardening/commit/f65c78d42305fa519950212133d520f85bdc7771) |
| CI run | [`33623793594`](https://github.com/JCSchoeman96/Store_Blueprint_Hardening/actions/runs/33623793594) |
| Performance job | [`100227324103`](https://github.com/JCSchoeman96/Store_Blueprint_Hardening/actions/runs/33623793594/job/100227324103) |
| Artifact | [`9844075073`, `performance-smoke-artifacts`](https://github.com/JCSchoeman96/Store_Blueprint_Hardening/actions/runs/33623793594/artifacts/9844075073) |
| Diagnostic run | `12802` |

### Correctness and checkout measurements

| Correctness measure | Result |
|---|---:|
| Expected | `56` |
| Completed | `56` |
| Successful | `56` |
| Governed failures | `0` |
| Unexpected failures | `0` |
| DB errors | `0` |
| Deadlocks | `0` |

| Checkout or observer measure | Result |
|---|---:|
| Checkout mean | `1776.696 ms` |
| Checkout p99 | `1783.676 ms` |
| Store.Repo pool | `40` |
| Observer samples | `5` |
| Peak Store.Repo active | `18` |
| Peak utilization | `0.45` |
| Samples at or above `0.95` | `0` |
| Lock waiters | `0` |

The diagnostic evidence contains `6586` sequenced events, `0` sequence gaps, `0`
evidence drops, and `0` instrumentation errors. The buffer maximum was `8192` and the
buffer peak was `541`.

### Retention signal at the peak sample

The raw PostgreSQL evidence at the exact-head peak sample included:

| Scope | Sessions | State | Wait event |
|---|---:|---|---|
| `Store.Repo` | `18` | `active` | `ClientRead` |
| `Store.Repo` | `12` | `idle` | `ClientRead` |
| `Store.Repo` | `10` | `idle in transaction` | `ClientRead` |
| `DirectRepo` | `10` | `idle` | `ClientRead` |
| Lock waits | `0` | n/a | n/a |

CONNECTION RETENTION DEFECT: `NOT PROVEN`

OPEN-TRANSACTION / CLIENT-WAIT RETENTION SIGNAL: `OBSERVED`

The `10` `idle in transaction` sessions do not prove that provider or CPU work was
holding connections. They are a future checkout-hardening observation only.

### Bounded query evidence

| Query measure | Result |
|---|---:|
| Repo query events | `6350` total |
| Approximate per completed checkout | `113.393` |

The retained checkout-step counts were:

| Checkout step | Queries per event |
|---|---:|
| `start_from_cart` | `15` |
| `set_shipping` | `20` |
| `finalize_totals` | `22` |
| `create_payment_intent` | `26` |

QUERY AMPLIFICATION: `NOT PROVEN`

High query volume exists, but the current evidence lacks sufficient per-worker,
per-phase, and baseline attribution to classify it as amplification or N+1 behaviour.
That investigation is deferred.

### Observability limitations

| Limitation | Status |
|---|---|
| Worker synchronization | `NOT OBSERVABLE` at per-worker granularity |
| Inventory runtime subphase | `NOT AVAILABLE` |
| Connection retention across provider/CPU work | `NOT PROVEN` |
| Ecto pool ownership high-water | `NOT AVAILABLE` |

These are future instrumentation and hardening concerns, not S0-CLOSE-08 blockers.

### Performance & Scaling Review

Active checkout database work is HOT. Observer and query-event evidence is WARM.
This retained closure record is COLD documentation and has no runtime authority.

The measured query count is `6350` total, or approximately `113.393` per completed
checkout. The retained step counts do not establish query amplification or N+1
behaviour. This record makes no index, cache, or Oban change and makes no new
idempotency claim. The existing `0.95` generic pool gate and `500 ms` observer interval
remain unchanged. The diagnostic sequence and buffer metrics are retained, but
per-worker synchronization, inventory subphase timing, and Ecto connection ownership
remain unobservable in this evidence.

### 100k disposition

| Question | Status |
|---|---|
| 100k certification | `NOT PERFORMED` |
| Safe at 100k | `NOT PROVEN` |
| Unsafe at 100k | `NOT PROVEN` |

Store.Repo and PostgreSQL connections are finite. Additional Phoenix nodes can
increase aggregate database connection demand. Frozen `InventoryAdmission` may address
only inventory-reservation admission and contention. It does not solve general
checkout database concurrency.

### Deferred checkout hardening register

These items are recorded for later checkout horizontal hardening. They are deferred
observations, not implementation tasks opened by S0-CLOSE-08:

1. Query and transaction attribution and reduction.
2. `idle in transaction` and `ClientRead` investigation.
3. Ecto checkout and connection ownership observability, if a supported telemetry path
   exists.
4. Per-worker and phase synchronization evidence, if future capacity testing requires
   it.
5. Inventory reservation subphase attribution.
6. Independent checkout admission and backpressure, only if later evidence warrants
   it.

### S0 boundary status

| Boundary | Status |
|---|---|
| S0-MEM-01 | `CLOSED / DEFECT PROVEN` |
| S0-MEM-02 | `PASS / ACCEPTED` |
| S0-MEM-03 | `CLOSED` |
| S0-ARCH-01 | `FROZEN` |
| S0-PLAN-01 | `FROZEN` |
| Inventory implementation authorized | `NO` |
| S0-CLOSE-02 | `BLOCKED` |
| S0 merge readiness | `BLOCKED` |

## 13. S0-MEM-03 memory and runtime baseline closure

This section closes S0-MEM-03 at the exact head below. It records the proven dynamic
atom defect and the bounded remediation for the three affected status query parsers.
It does not certify repository-wide memory safety, 100k concurrency, or the remaining
runtime observations. It does not change subscription or entitlement lifecycle
states, filtering semantics, LiveView behaviour, checkout, or InventoryAdmission.

### Exact-head evidence

| Evidence | Result |
|---|---|
| Repository head | `b730a1e1d3e159cab95e24fbb4786fd7abee830d` |
| Branch | `hardening/s0-baseline` |
| PR #1 | `OPEN / UNMERGED` |
| CI run | [`33651910720`](https://github.com/JCSchoeman96/Store_Blueprint_Hardening/actions/runs/33651910720) |
| CI conclusion | `SUCCESS` |
| `check_static` | `PASS` |
| `test_pr_strict` | `PASS` |
| `performance_smoke_required` | `PASS` |
| `performance_smoke_chaos_required` | `PASS` |
| `dialyzer_required` | `NOMINAL PASS` |

The Dialyzer job is green because the configured gate retains
`--ignore-exit-status`. That job result does not erase the separately documented
semantic Dialyzer caveat.

### Proven defect and remediation

| Finding | Status | Evidence |
|---|---|---|
| Pre-validation dynamic atom creation in subscription and entitlement status parsing | `FIXED` | The three parsers normalize binary input, then use finite compile-time binary-to-status maps. |
| `INV-MEM-ATOM-001` on the three affected query paths | `ENFORCED` | Invalid runtime binaries are rejected before any status atom is returned. |
| Subscription lifecycle status set | `UNCHANGED` | `pending`, `active`, `past_due`, `canceled`, `expired` remain the allowed values. |
| Entitlement lifecycle status set | `UNCHANGED` | `active`, `revoked`, `expired` remain the allowed values. |
| Invalid status result | `UNCHANGED` | Invalid binaries, atoms, and other values retain `VALIDATION_ERROR` with `status is invalid`. |

The affected paths are [`UserSubscriptionIndexQuery`](../../lib/store/subscriptions/queries/user_subscription_index_query.ex),
[`AdminSubscriptionIndexQuery`](../../lib/store/subscriptions/queries/admin_subscription_index_query.ex),
and [`UserEntitlementIndexQuery`](../../lib/store/entitlements/queries/user_entitlement_index_query.ex).
Their focused public `new/1` regressions prove that a runtime-unique invalid binary
raises `ArgumentError` under `String.to_existing_atom/1` before and after parsing.

This enforcement statement is scoped to these three S0-MEM-02 paths. It is not a
repository-wide audit of every possible runtime atom conversion.

### Deferred observations

The following observations remain unproven. They are deferred and are not relabelled
as defects by this closure:

| Observation | Status | Disposition |
|---|---|---|
| Redix retained heap high-water | `NOT PROVEN` | Deferred; no memory workload rerun. |
| Cachex/ETS/Redis cardinality | `NOT PROVEN` | Deferred; no cardinality audit or tuning. |
| RedisAggregates mailbox risk | `NOT PROVEN` | Deferred; no mailbox workload or tuning. |
| Oban/PubSub behaviour at 100k | `NOT PROVEN` | Deferred; no 100k workload or certification. |
| Overall platform memory safety | `NOT PROVEN` | No platform-wide memory-safety claim is made. |
| Overall 100k concurrency certification | `NOT PROVEN` | No capacity claim is made. |

### Validation record

| Gate | Result |
|---|---|
| Focused public query-contract tests | `15 tests, 0 failures` |
| Focused forbidden-conversion search in the three parsers | `PASS` |
| `mix compile --warnings-as-errors` | `PASS` in the implementation commit; exact-head CI also passed `check_static` and strict tests |
| Formatter check | `PASS` |
| Strict Credo | `PASS` |
| `git diff --check` | `PASS` |
| S0-MEM-01 workload rerun | `NOT RUN` |
| New memory/performance workload | `NOT RUN` |

### Performance & Scaling Review

| Concern | Closure assessment |
|---|---|
| Data layer | `HOT` request parsing. |
| State | Finite compile-time binary-to-status maps local to each query module. |
| Memory | `O(1)` bounded status vocabulary; invalid input does not add an atom. |
| GC | No new concern introduced. |
| Mailbox | None introduced. |
| Resource cleanup | None required. |
| Post-load | These paths have fixed status cardinality and do not intern arbitrary invalid binaries. |
| Cache | No change. |
| Redis | No change. |
| Store.Repo | No change. |
| PubSub | No change. |
| Oban | No change. |
| 100k behavior | Overall behavior remains unmeasured and uncertified. Only the atom-creation cardinality of these status parsers is bounded. |

S0-MEM-03 is documentation-only. No production code, tests, migration, schema,
configuration, checkout path, InventoryAdmission path, Redix setting, cache setting,
Redis structure, Oban behavior, or PubSub behavior changed in this closure.
