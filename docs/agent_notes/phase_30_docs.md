# Phase 30 Docs

## Links Consulted
- [docs/agent_notes/phase_29_docs.md](/home/jcs/projects/store_blueprint/docs/agent_notes/phase_29_docs.md)
- [docs/governance/performance_scaling.md](/home/jcs/projects/store_blueprint/docs/governance/performance_scaling.md)
- [docs/phases/phase_29_performance_architecture_optimizations.md](/home/jcs/projects/store_blueprint/docs/phases/phase_29_performance_architecture_optimizations.md)
- [priv/repo/performance_smoke_test.exs](/home/jcs/projects/store_blueprint/priv/repo/performance_smoke_test.exs)
- [lib/store/carts/facade.ex](/home/jcs/projects/store_blueprint/lib/store/carts/facade.ex)
- [lib/store/checkout/domain.ex](/home/jcs/projects/store_blueprint/lib/store/checkout/domain.ex)
- [lib/store/payments/domain.ex](/home/jcs/projects/store_blueprint/lib/store/payments/domain.ex)
- [lib/store/payments/interlocks.ex](/home/jcs/projects/store_blueprint/lib/store/payments/interlocks.ex)
- [lib/store_web/router.ex](/home/jcs/projects/store_blueprint/lib/store_web/router.ex)
- [lib/store_web/live/cart_live.ex](/home/jcs/projects/store_blueprint/lib/store_web/live/cart_live.ex)
- [lib/store_web/live/checkout_live/placeholder.ex](/home/jcs/projects/store_blueprint/lib/store_web/live/checkout_live/placeholder.ex)

## Decisions / Pins
1. Phase 30 uses a hybrid benchmark shape:
   - `k6/http` for scalable HTTP ingress and webhook coverage
   - `k6/browser` for a low-concurrency real browser checkout journey
   - the standalone smoke suite remains the correctness and contention gate
2. Query counting is process-local and emitter-process-scoped via `Store.Support.Telemetry.RepoStats`.
3. Step telemetry is emitted under:
   - `[:store, :carts, :step]`
   - `[:store, :checkout, :step]`
4. The first optimization slice stays surgical:
   - remove redundant reloads in cart mutations
   - avoid reloading checkout context after shipping/finalize when the updated order is already in hand
   - collapse the payment-intent blocking checks into one read
5. No new public checkout API is introduced in this phase.
6. The k6 benchmark harness must run against an isolated test database suffix via `STORE_TEST_DB_SUFFIX` so it never pollutes the default `store_test` database used by `mix test` and `mix check`.
7. Phase 30.2 keeps the benchmark-only large pool profile in `config/test.exs`:
   - default benchmark profile for `STORE_TEST_DB_SUFFIX=bench` is `200/200` for `Store.Repo` / `Store.DirectRepo`
   - local benchmark runs on this workstation must override that down to `100/60` because local Postgres reports `max_connections = 300`
8. Phase 30.2 optimization focus is:
   - reduce `finalize_totals` query fan-out without changing reservation/quote integrity rules
   - reduce `create_payment_intent` query fan-out by using a minimal payment context and a single blocking-state preflight read
   - remove remaining public storefront projection overhead from the product listing path

## Plan
1. Add `RepoStats.capture/2` and replace ad hoc query counters.
2. Emit per-step query/time telemetry for cart load/add and checkout start/shipping/finalize/payment intent.
3. Extend the smoke suite to capture and report checkout step summaries.
4. Add `priv/perf/benchmark_bootstrap.exs` to prepare reusable benchmark fixtures and write `tmp/perf/benchmark_data.json`.
5. Add `perf/k6/http_storefront.js`, `perf/k6/browser_checkout.js`, and `perf/k6/webhook_ingress.js`.
6. Apply low-risk round-trip reductions in cart, checkout, and payment interlocks.

## DONE
- Added `Store.Support.Telemetry.RepoStats` with process-local accumulation from repo telemetry.
- Added `RepoStats` isolation tests and migrated the existing subscription performance tests to the new helper.
- Added cart and checkout step telemetry, including query count, queue time, query time, and decode time.
- Extended the standalone smoke suite to report checkout step summaries for:
  - `start_from_cart`
  - `finalize_totals`
  - `create_payment_intent`
- Added the benchmark bootstrap script at `priv/perf/benchmark_bootstrap.exs`.
- Benchmark bootstrap now refuses to run without `STORE_TEST_DB_SUFFIX` so the harness uses an isolated benchmark database such as `store_testbench`.
- Added `perf/k6/` benchmark scripts for storefront HTTP, webhook ingress, and a browser-level checkout journey.
- Fixed the public product slug lookup used by `/shop/:slug` by switching `Product.get_for_public` to a supported action filter shape.
- Removed webhook and callback traffic from the mixed storefront benchmark so storefront latency is measured independently from webhook ingress.
- Reworked webhook ingress benchmarking to:
  - generate fresh Stripe signatures at runtime
  - support `STORE_WEBHOOK_MODE=unique_ingress`
  - support `STORE_WEBHOOK_MODE=duplicate_replay`
  - keep duplicate replay logically identical while refreshing only the signature timestamp
- Added ingress telemetry for webhook and callback controllers covering:
  - verify/normalize duration
  - persist duration and repo stats
  - enqueue duration and repo stats
  - response duration with status bucket and error code
- Reduced duplicate replay cost by skipping the enqueue stage when receipt ingest returns an upsert-skipped duplicate and by applying Oban uniqueness to webhook processing jobs.
- Reduced hot-path chatter by:
  - removing cart post-mutation `Repo.get!/2` reloads
  - reusing the updated checkout order in shipping/finalize flows instead of re-reading checkout context
  - collapsing payment-intent “blocked” checks into one read
- Phase 30.2 checkout reductions:
  - `finalize_totals/3` now carries a single locked finalize context through snapshot creation, reservation, and summary rendering
  - `finalize_totals/3` reuses line items, catalog maps, quote inputs, and shipping weight from the locked context instead of rebuilding them in later helper passes
  - `required_complete?/2` checks are now bulk-computed per variant instead of reloading required plans item-by-item
  - `create_intent_for_order/3` now uses `Checkout.get_payment_context_for_user/2` instead of building a full checkout summary
  - payment-intent interlocks now use one preflight read that answers both "existing by key" and "blocking state for order" decisions
- Phase 30.2 storefront reductions:
  - public product listing moved to a DB-backed joined projection for `default_variant` and `category`
  - product detail path still stays facade-driven, but no longer re-fetches the loaded product inside `VariantResolver`
- Phase 30.2 benchmark normalization:
  - benchmark bootstrap now respects benchmark pool config instead of hardcoding smaller pool sizes
  - local benchmark runs were executed with:
    - `STORE_TEST_DB_SUFFIX=bench`
    - `STORE_BENCH_POOL_SIZE=100`
    - `STORE_BENCH_DIRECT_POOL_SIZE=60`
  - these overrides were necessary because `show max_connections;` on local Postgres returned `300`

## Performance & Scaling Review
- Hot:
  - cart mutation path now avoids a redundant cart reload after version bump
  - checkout set/finalize now avoid re-reading draft/order context immediately after successful updates
  - payment-intent interlocks now use one blocking-state read instead of separate succeeded/in-flight reads
  - webhook duplicate replay now skips duplicate worker enqueue when the receipt upsert is skipped
- Warm:
  - smoke suite now records query-count and repo-time summaries for the key checkout steps
  - k6 bootstrap fixture generation produces stable benchmark inputs for repeatable runs
  - benchmark fixture generation is isolated from the default test database via `STORE_TEST_DB_SUFFIX`
  - webhook benchmark data now stores unsigned payload templates and the signing secret instead of stale signed headers
- Cold:
  - no schema or index changes were made in this phase
- DB query count + N+1 risk:
  - query counting is now first-class for the target paths
  - `create_payment_intent` mean query count dropped from `25` to `17`
  - `finalize_totals` mean query count dropped from `36` to `31`
  - the payment-intent path now meets the "material reduction" bar; `finalize_totals` improved but is still the heaviest orchestration path and remains the next reduction target
  - public storefront listing no longer does Elixir-side filter/sort/paginate work after broad resource loads, but `/shop/:slug` still has room for deeper projection work if `shop_show` remains the slowest storefront route
- Indexes:
  - existing uniqueness and hot-path indexes remain the source of truth
  - phase focus was query-count reduction before index churn
- Caching:
  - existing ETS/Redis hot paths from Phase 29 remain unchanged
  - HTTP benchmark coverage is added on top of, not instead of, the cache and stampede smoke gates
- Oban uniqueness / idempotency:
  - unchanged
  - provider fault isolation and webhook enqueue boundaries remain intact
- Telemetry / logging:
  - per-step query metrics added for carts/checkout
  - smoke JSON now includes checkout step summaries
  - webhook ingress now emits route/stage telemetry for verification, persistence, enqueue, and response
  - latest smoke checkout step baselines:
    - `start_from_cart`: `15` mean queries, `217.83ms`
    - `finalize_totals`: `31` mean queries, `362.55ms`
    - `create_payment_intent`: `17` mean queries, `177.34ms`
  - latest k6 storefront results versus Phase 30.1:
    - failed rate: `18.69% -> 3.03%`
    - dropped iterations: `22139 -> 404`
    - `shop_index` p95: `2982ms -> 2787ms`
    - `shop_show` p95: `4010ms -> 4184ms`
    - `cart` p95: `2958ms -> 2887ms`
    - `checkout` p95: `2962ms -> 2707ms`
  - latest k6 webhook results versus Phase 30.1:
    - unique ingress failed rate: `87.40% -> 0.42%`
    - unique ingress `webhook` p95: `5204ms -> 12.43ms`
    - unique ingress `callback` p95: `5125ms -> 12.64ms`
    - duplicate replay failed rate: `88.03% -> 0.00%`
    - duplicate replay `webhook` p95: `4711ms -> 10.42ms`
    - duplicate replay `callback` p95: `4847ms -> 10.43ms`

## Notes
- The current checkout LiveView requires server-generated quote options before shipping can be saved. The browser benchmark uses a browser-ready checkout fixture to exercise the payment-facing half of the real UI without adding a synthetic checkout API.
- Benchmark run sequence:
  1. `STORE_TEST_DB_SUFFIX=bench MIX_ENV=test mix ecto.create && STORE_TEST_DB_SUFFIX=bench MIX_ENV=test mix ecto.migrate`
  2. For this workstation, set safe pool overrides under the local `max_connections` ceiling:
     - `export STORE_BENCH_POOL_SIZE=100`
     - `export STORE_BENCH_DIRECT_POOL_SIZE=60`
  3. `STORE_TEST_DB_SUFFIX=bench MIX_ENV=test mix run --no-start priv/perf/benchmark_bootstrap.exs`
  4. `STORE_TEST_DB_SUFFIX=bench MIX_ENV=test mix phx.server`
  5. Run `k6` against the `base_url` written into `tmp/perf/benchmark_data.json` (defaults to the test endpoint port)
  6. Storefront HTTP:
     - `k6 run perf/k6/http_storefront.js`
  7. Webhook unique ingress:
     - `k6 run -e STORE_WEBHOOK_MODE=unique_ingress perf/k6/webhook_ingress.js`
  8. Webhook duplicate replay:
     - `k6 run -e STORE_WEBHOOK_MODE=duplicate_replay perf/k6/webhook_ingress.js`
- Interpretation:
  - storefront now fails far less often under the benchmark profile, but `shop_show` remains the slowest route and still misses the current `500ms` p95 threshold
  - webhook ingress no longer collapses because of the tiny local pool profile; unique and duplicate modes are both benchmarkable, and duplicate replay is now measurably cheaper than unique ingress
