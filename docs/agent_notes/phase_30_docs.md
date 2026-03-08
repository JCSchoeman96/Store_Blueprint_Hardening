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
9. Phase 30.3 adds two harder pins:
   - public product detail must flow through a fixed `Store.Catalog.Types.ProductDetail` contract so LiveView/template code remains unchanged while the loader moves to Ecto projection
   - checkout reservation must use a deterministic set-based Postgres CTE with `RETURNING`, but full checkout finalization must still rollback on any missing reservation so there is no partial checkout success
10. Phase 30.3 optimization stops once the checkout finalization path is in the `8-10` query band or the remaining work would require correctness-hostile drift.

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
- Phase 30.3 product detail contract:
  - added `Store.Catalog.Types.ProductDetail` as the stable internal storefront detail contract
  - `CatalogFacade.get_product_detail_for_public/2` now returns `%ProductDetail{}`
  - added `Store.Catalog.ProductDetailProjection` for the facade-owned public detail loader
  - `VariantResolver` now resolves selections in memory over the projected payload instead of owning the data-loading contract
- Phase 30.3 checkout finalization changes:
  - `Store.Orders.reserve_inventory_for_checkout/2` now uses a deterministic reservation CTE with `RETURNING`
  - checkout compares requested vs reserved rows and rolls back with `OUT_OF_STOCK` details containing unavailable variant identifiers
  - priced line-item and adjustment snapshot writes now batch via `Repo.insert_all`
  - finalized checkout summaries stop recomputing all shipping quote options and instead reuse the finalized order evidence
- Phase 30.3 targeted tests added/updated:
  - public product detail contract test
  - structured unavailable-variant conflict details test for checkout finalization
  - existing shop detail LiveView tests still pass without template changes

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
  - Phase 30.3 rerun:
    - `create_payment_intent` stayed flat at `17` mean queries
    - `finalize_totals` dropped again from `31` to `22` mean queries
    - the `8-10` query guardrail was not reached; the remaining cost is still dominated by synchronous finalize orchestration and order/tax snapshot writes
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
  - Phase 30.3 fresh rerun:
    - smoke suite:
      - `start_from_cart`: `15` mean queries, `246.73ms`
      - `finalize_totals`: `22` mean queries, `288.80ms`
      - `create_payment_intent`: `17` mean queries, `182.76ms`
    - storefront k6:
      - failed rate: `8.19%`
      - dropped iterations: `10185`
      - `shop_index` p95: `2.91s`
      - `shop_show` p95: `4.00s`
      - `cart` p95: `2.90s`
      - `checkout` p95: `2.87s`
    - webhook k6:
      - unique ingress failed rate: `19.12%`, `webhook` p95: `17.65s`, `callback` p95: `16.41s`
      - duplicate replay failed rate: `18.71%`, `webhook` p95: `18.82s`, `callback` p95: `18.39s`
  - Interpretation:
    - Phase 30.3 preserved correctness and improved checkout query counts again
    - product detail no longer crashes and now honors a stable contract, but `shop_show` still has unresolved latency under real HTTP load
    - the webhook ingress path did not reproduce the extremely low failure-rate numbers from the previous phase on the latest rerun, so those benchmarks need a follow-up investigation before being treated as stable

## Notes
- The current checkout LiveView requires server-generated quote options before shipping can be saved. The browser benchmark uses a browser-ready checkout fixture to exercise the payment-facing half of the real UI without adding a synthetic checkout API.
- Benchmark run sequence:
  1. `STORE_TEST_DB_SUFFIX=bench MIX_ENV=test mix ecto.create && STORE_TEST_DB_SUFFIX=bench MIX_ENV=test mix ecto.migrate`
  2. For this workstation, set safe pool overrides under the local `max_connections` ceiling:
     - `export STORE_BENCH_POOL_SIZE=100`
     - `export STORE_BENCH_DIRECT_POOL_SIZE=60`
  3. `export PORT=4000`
  4. `STORE_TEST_DB_SUFFIX=bench MIX_ENV=test mix run --no-start priv/perf/benchmark_bootstrap.exs`
  5. `STORE_TEST_DB_SUFFIX=bench MIX_ENV=test mix run --no-start --no-halt priv/perf/benchmark_server.exs`
  6. Run `k6` against the `base_url` written into `tmp/perf/benchmark_data.json` (defaults to `http://127.0.0.1:$PORT`)
  7. Storefront HTTP:
     - `k6 run perf/k6/http_storefront.js`
  8. Webhook unique ingress:
     - `k6 run -e STORE_WEBHOOK_MODE=unique_ingress perf/k6/webhook_ingress.js`
  9. Webhook duplicate replay:
     - `k6 run -e STORE_WEBHOOK_MODE=duplicate_replay perf/k6/webhook_ingress.js`
- Interpretation:
  - storefront product detail no longer crashes and is now contract-stable, but the route remains materially too slow under k6 and still needs another projection/LiveView pass
  - checkout finalization is cheaper than before, but not yet in the target `8-10` query band; the latest validated smoke baseline is `22` mean queries
  - the latest webhook rerun remained benchmarkable with fresh signatures, but unique and duplicate modes both showed high tail latency and failure rate again; treat the earlier near-zero-failure webhook numbers as non-stable until rerun conditions are reconciled

## Phase 30.4
### Links Consulted
- [StoreWeb.ShopLive.Show](/home/jcs/projects/store_blueprint/lib/store_web/live/shop_live/show.ex)
- [Store.Catalog.Facade](/home/jcs/projects/store_blueprint/lib/store/catalog/facade.ex)
- [Store.Catalog.ProductDetailProjection](/home/jcs/projects/store_blueprint/lib/store/catalog/product_detail_projection.ex)
- [Store.Catalog.VariantResolver](/home/jcs/projects/store_blueprint/lib/store/catalog/variant_resolver.ex)
- [Store.Catalog.Types.ProductDetail](/home/jcs/projects/store_blueprint/lib/store/catalog/types/product_detail.ex)
- [StoreWeb.Telemetry](/home/jcs/projects/store_blueprint/lib/store_web/telemetry.ex)
- [perf/k6/http_storefront.js](/home/jcs/projects/store_blueprint/perf/k6/http_storefront.js)

### Decisions / Pins
- The `/shop/:slug` investigation is treated as a LiveView lifecycle split, not as a DB-only problem.
- Product detail stays behind the stable `%Store.Catalog.Types.ProductDetail{}` contract.
- New telemetry split:
  - `[:store, :shop_live, :product_detail]` for adapter-side timing with `phase`, `connected?`, reductions delta, and memory delta
  - `[:store, :catalog, :product_detail, :public]` for domain timing with repo stats and payload diagnostics
- The public detail payload remains facade-owned and web stays adapter-only.
- `VariantResolver` stays pure in-memory, but now uses precomputed selection indexes instead of repeated full-row scans.
- Mixed storefront k6 remains the acceptance gate; a new `perf/k6/http_shop_detail.js` script exists for route-only diagnosis.
- Smoke regressions must run on an isolated test DB suffix because the performance script writes committed fixture data.

### Implementation
- Added [Store.Catalog.ProductDetailTelemetry](/home/jcs/projects/store_blueprint/lib/store/catalog/product_detail_telemetry.ex).
- Instrumented [StoreWeb.ShopLive.Show](/home/jcs/projects/store_blueprint/lib/store_web/live/shop_live/show.ex) to emit:
  - `phase: :static_render | :live_join`
  - `connected?`
  - reductions delta
  - memory delta
- Instrumented [Store.Catalog.Facade.get_product_detail_for_public/2](/home/jcs/projects/store_blueprint/lib/store/catalog/facade.ex) with repo stats capture and payload diagnostics.
- Extended [Store.Catalog.ProductDetailProjection](/home/jcs/projects/store_blueprint/lib/store/catalog/product_detail_projection.ex) with:
  - a single `load_public_detail/1` entrypoint
  - prebuilt `detail_options`
  - precomputed variant lookup and selection indexes
- Reduced transformation overhead in [Store.Catalog.VariantResolver](/home/jcs/projects/store_blueprint/lib/store/catalog/variant_resolver.ex):
  - no repeated `Enum.filter` scans across `variant_rows` for every availability cell
  - availability matrix now reuses per-option base candidate sets and selection indexes
- Added telemetry-aware regression coverage in:
  - [test/store/catalog/facade_public_product_test.exs](/home/jcs/projects/store_blueprint/test/store/catalog/facade_public_product_test.exs)
  - [test/store_web/live/shop_live/show_test.exs](/home/jcs/projects/store_blueprint/test/store_web/live/shop_live/show_test.exs)
- Added `STORE_K6_QUICK=1` stage overrides for [perf/k6/http_storefront.js](/home/jcs/projects/store_blueprint/perf/k6/http_storefront.js).
- Added route-only diagnostic script [perf/k6/http_shop_detail.js](/home/jcs/projects/store_blueprint/perf/k6/http_shop_detail.js).

### Performance & Scaling Review
- Hot path:
  - `/shop/:slug` now has explicit visibility into:
    - LiveView static render vs live join time
    - catalog repo query count and query time
    - BEAM reductions and memory delta
    - payload size and cardinality
- Query count / N+1 risk:
  - no new DB fan-out was introduced
  - the public detail path still runs through a small fixed query set, but the in-memory N-scan cost is reduced via precomputed selection indexes
- Caching:
  - the existing availability cache is retained
  - cached payload now stores more reusable derived data (`detail_options`, row/index maps) to reduce repeated transformation work

## Phase 30.6
### Links Consulted
- [Store.Perf.BenchmarkHarness](/home/jcs/projects/store_blueprint/lib/store/perf/benchmark_harness.ex)
- [Store.Perf.ProductDetailPoller](/home/jcs/projects/store_blueprint/lib/store/perf/product_detail_poller.ex)
- [Store.Perf.ProductDetailPollerSummary](/home/jcs/projects/store_blueprint/lib/store/perf/product_detail_poller_summary.ex)
- [Store.Catalog.ProductDetailTelemetry](/home/jcs/projects/store_blueprint/lib/store/catalog/product_detail_telemetry.ex)
- [StoreWeb.ShopLive.Show](/home/jcs/projects/store_blueprint/lib/store_web/live/shop_live/show.ex)
- [priv/perf/benchmark_server.exs](/home/jcs/projects/store_blueprint/priv/perf/benchmark_server.exs)
- [priv/perf/product_detail_poller_summary.exs](/home/jcs/projects/store_blueprint/priv/perf/product_detail_poller_summary.exs)
- [perf/playwright/product_detail_live_join.mjs](/home/jcs/projects/store_blueprint/perf/playwright/product_detail_live_join.mjs)
- [perf/playwright/playwright.config.mjs](/home/jcs/projects/store_blueprint/perf/playwright/playwright.config.mjs)

### Decisions / Pins
- Phase 30.6 is diagnosis-only. No new checkout or product-detail optimization is allowed in this slice.
- Browser driver is Playwright, not `k6/browser`, because local Node/Playwright support is reliable in this environment and Chromium can be installed user-local.
- The benchmark server is the single source of truth for:
  - isolated benchmark DB suffix
  - explicit `PORT`
  - benchmark base URL
  - poller startup
- Browser join runs must include guardrails:
  - `quick = 20 joins`
  - `full = 100 joins`
  - ramp = `5 joins/sec`
  - hold = `3000ms`
  - run is marked invalid if client CPU stays above `90%` or free memory drops below the configured floor
- Attribution rule is pinned:
  - if `live_join` query count/time dominates, next target is domain/projection/session reuse
  - if repo time is low but reductions are high, next target is BEAM transformation work
  - if payload bytes/hash diverge between static and live, next target is hydration/payload compaction
  - if websocket open/join ack dominates while server metrics stay low, next target is LiveView join transport/lifecycle

### Implementation
- Added Playwright harness files:
  - [package.json](/home/jcs/projects/store_blueprint/package.json)
  - [package-lock.json](/home/jcs/projects/store_blueprint/package-lock.json)
  - [perf/playwright/playwright.config.mjs](/home/jcs/projects/store_blueprint/perf/playwright/playwright.config.mjs)
  - [perf/playwright/product_detail_live_join.mjs](/home/jcs/projects/store_blueprint/perf/playwright/product_detail_live_join.mjs)
- Added poller summary pipeline:
  - [lib/store/perf/product_detail_poller_summary.ex](/home/jcs/projects/store_blueprint/lib/store/perf/product_detail_poller_summary.ex)
  - [priv/perf/product_detail_poller_summary.exs](/home/jcs/projects/store_blueprint/priv/perf/product_detail_poller_summary.exs)
- Extended product detail telemetry:
  - `payload_hash` emitted for static and live phases
  - shop-live events now include repo stats for full `handle_params/3`
- Fixed poller logging bugs:
  - `MapSet` metadata values are serialized before NDJSON write
  - summary matching uses real boolean keys for `connected?`
- Added cleanup support:
  - tracked Chromium PIDs are persisted and cleaned between runs
  - benchmark runbook now prints Playwright and poller-summary commands
- Added regression coverage:
  - [test/store/perf/product_detail_poller_summary_test.exs](/home/jcs/projects/store_blueprint/test/store/perf/product_detail_poller_summary_test.exs)
  - updated [test/store_web/live/shop_live/show_test.exs](/home/jcs/projects/store_blueprint/test/store_web/live/shop_live/show_test.exs)

### Validation
- Targeted tests:
  - `MIX_ENV=test mix test test/store_web/live/shop_live/show_test.exs test/store/perf/product_detail_poller_summary_test.exs`
- Playwright quick run:
  - artifact: [tmp/perf/playwright_product_detail_live_join.json](/home/jcs/projects/store_blueprint/tmp/perf/playwright_product_detail_live_join.json)
  - `20/20` joins successful
  - `invalid_client_saturated = false`
  - aggregate:
    - `avg_static_http_ms = 65.36`
    - `p95_static_http_ms = 88.82`
    - `avg_ws_open_ms = 0.76`
    - `p95_ws_open_ms = 1.55`
    - `avg_join_ack_ms = 11.78`
    - `p95_join_ack_ms = 61.63`
- Playwright full run:
  - artifact: [tmp/perf/playwright_product_detail_live_join_full.json](/home/jcs/projects/store_blueprint/tmp/perf/playwright_product_detail_live_join_full.json)
  - `100/100` joins successful
  - `invalid_client_saturated = false`
  - aggregate:
    - `avg_static_http_ms = 53.72`
    - `p95_static_http_ms = 74.19`
    - `avg_ws_open_ms = 0.89`
    - `p95_ws_open_ms = 1.71`
    - `avg_join_ack_ms = 7.54`
    - `p95_join_ack_ms = 11.76`
- Poller summary:
  - artifact: [tmp/perf/product_detail_poller_summary.json](/home/jcs/projects/store_blueprint/tmp/perf/product_detail_poller_summary.json)
  - static render:
    - `count = 100`
    - `avg query_count = 1.73`
    - `avg duration = 7.19ms`
    - `avg reductions_delta = 10539.74`
    - `avg memory_delta = 92164`
  - live join:
    - `count = 100`
    - `avg query_count = 1.02`
    - `avg duration = 4.63ms`
    - `avg reductions_delta = 7766.85`
    - `avg memory_delta = 121926`
  - static vs live:
    - `query_count_delta = -0.71`
    - `reductions_delta = -2772.90`
    - `payload_bytes_delta = 0`
    - `payload_hash_match? = true`

### Findings
- `/shop/:slug` `live_join` is healthy under a real browser driver in this environment.
- The remaining work is not websocket handshake latency:
  - `p95 ws_open_ms` is ~`1.71ms`
  - `p95 join_ack_ms` is ~`11.76ms`
- The route is not showing a payload divergence bug:
  - static and live payload hashes match
  - payload bytes delta is `0`
- `live_join` is doing less DB work than static render:
  - `1.02` avg queries vs `1.73`
- `live_join` is also doing less BEAM reduction work than static render:
  - `7766.85` avg reductions vs `10539.74`
- The one signal to keep watching is memory:
  - `live_join` average memory delta is higher than static render
  - that is a second-order concern, not the primary current bottleneck
- Decision:
  - do not spend the next phase on `/shop/:slug` query/transport work
  - if latency reappears, target broader contention or LiveView hydration memory shape before doing another domain projection rewrite
- Telemetry / logging:
  - new product detail telemetry is now first-class and can separate:
    - web lifecycle cost
    - domain/repo cost
    - BEAM allocation/CPU cost

### Validation
- Targeted product detail regression tests: `PASS`
  - `MIX_ENV=test mix test test/store/catalog/facade_public_product_test.exs test/store_web/live/shop_live/show_test.exs test/store/governance/catalog_phase_25_test.exs`
- Full repo gate: `PASS`
  - `MIX_ENV=test mix check`
- Isolated smoke regression: `PASS`
  - `STORE_TEST_DB_SUFFIX=phase304smoke MIX_ENV=test STORE_PERF_SMOKE=true mix run --no-start priv/repo/performance_smoke_test.exs`
  - latest isolated step metrics:
    - `start_from_cart`: `15` mean queries, `303.65ms`
    - `finalize_totals`: `22` mean queries, `330.69ms`
    - `create_payment_intent`: `17` mean queries, `225.41ms`
- k6 scripts parse correctly:
  - `k6 inspect perf/k6/http_storefront.js`
  - `k6 inspect perf/k6/http_shop_detail.js`
- Local k6 rerun status:
  - route benchmarks were not rerun in this session because the local `mix phx.server` benchmark harness did not expose the HTTP port within the tool session despite the BEAM booting
  - this is a harness/runtime issue for follow-up, not a compile/test blocker in the Phase 30.4 code itself

## Phase 30.5
### Links Consulted
- [config/test.exs](/home/jcs/projects/store_blueprint/config/test.exs)
- [config/runtime.exs](/home/jcs/projects/store_blueprint/config/runtime.exs)
- [priv/perf/benchmark_bootstrap.exs](/home/jcs/projects/store_blueprint/priv/perf/benchmark_bootstrap.exs)
- [Store.Catalog.ProductDetailTelemetry](/home/jcs/projects/store_blueprint/lib/store/catalog/product_detail_telemetry.ex)
- [StoreWeb.ShopLive.Show](/home/jcs/projects/store_blueprint/lib/store_web/live/shop_live/show.ex)

### Decisions / Pins
- The benchmark server now runs through `priv/perf/benchmark_server.exs`, not `mix phx.server`.
- The benchmark base URL contract is:
  - `STORE_BENCHMARK_BASE_URL` if explicitly set
  - otherwise `http://$STORE_BENCHMARK_HOST:$PORT`
  - defaults: `127.0.0.1:4000`
- The telemetry poller must live inside the same BEAM as the endpoint; a separate `mix run` process cannot observe these product-detail telemetry events.
- `http_shop_detail.js` remains diagnostic-only; `http_storefront.js` remains the acceptance gate.

### Implementation
- Added [Store.Perf.BenchmarkHarness](/home/jcs/projects/store_blueprint/lib/store/perf/benchmark_harness.ex) to centralize:
  - benchmark host/port/base URL
  - isolated test DB validation
  - port preflight
  - endpoint readiness checks
- Added [Store.Perf.ProductDetailPoller](/home/jcs/projects/store_blueprint/lib/store/perf/product_detail_poller.ex) to:
  - subscribe to the product-detail telemetry events
  - print rolling 1-second aggregates
  - append NDJSON rows to `tmp/perf/product_detail_poller.ndjson`
- Added [priv/perf/benchmark_server.exs](/home/jcs/projects/store_blueprint/priv/perf/benchmark_server.exs) to:
  - configure the endpoint
  - start the app and in-process poller
  - wait for `/shop` readiness
  - print the k6 run order
- Updated the benchmark bootstrap to use the same base URL helper as the benchmark server.

### Performance & Scaling Review
- This phase changes benchmark operations, not business behavior.
- The poller now makes `/shop/:slug` attributable across:
  - LiveView static render vs live join
  - repo query/queue/decode time
  - reductions delta
  - memory delta
  - payload size/cardinality
- The next optimization phase should be chosen by the fresh telemetry split:
  - repo-bound if query/queue time dominates
  - BEAM-bound if reductions dominate with low repo time
  - payload-bound if encoded bytes and availability cardinality are large
  - contention-bound if route-only runs are healthy but mixed storefront remains slow

### Validation
- `MIX_ENV=test mix check`: `PASS`
- Isolated smoke regression:
  - `STORE_TEST_DB_SUFFIX=phase305smoke MIX_ENV=test STORE_PERF_SMOKE=true mix run --no-start priv/repo/performance_smoke_test.exs`
  - `PASS`
  - `12 tests, 0 failures`
- Benchmark bootstrap:
  - `STORE_TEST_DB_SUFFIX=phase305bench PORT=4000 STORE_BENCH_POOL_SIZE=100 STORE_BENCH_DIRECT_POOL_SIZE=60 MIX_ENV=test mix run --no-start priv/perf/benchmark_bootstrap.exs`
  - wrote [tmp/perf/benchmark_data.json](/home/jcs/projects/store_blueprint/tmp/perf/benchmark_data.json) with `base_url = http://127.0.0.1:4000`
- Benchmark server:
  - `STORE_TEST_DB_SUFFIX=phase305bench PORT=4000 STORE_BENCH_POOL_SIZE=100 STORE_BENCH_DIRECT_POOL_SIZE=60 MIX_ENV=test mix run --no-start --no-halt priv/perf/benchmark_server.exs`
  - endpoint preflight succeeded at `http://127.0.0.1:4000/shop`
- Diagnostic k6:
  - [tmp/perf/k6_http_shop_detail_quick_phase305_final.json](/home/jcs/projects/store_blueprint/tmp/perf/k6_http_shop_detail_quick_phase305_final.json)
  - `http_req_failed = 0.00%`
  - `shop_show p95 = 5.91ms`
- Acceptance k6:
  - [tmp/perf/k6_http_storefront_quick_phase305_final.json](/home/jcs/projects/store_blueprint/tmp/perf/k6_http_storefront_quick_phase305_final.json)
  - `http_req_failed = 0.00%`
  - `shop_index p95 = 10.36ms`
  - `shop_show p95 = 10.28ms`
  - `cart p95 = 22.92ms`
  - `checkout p95 = 88.44ms`
- Poller artifact:
  - [tmp/perf/product_detail_poller.ndjson](/home/jcs/projects/store_blueprint/tmp/perf/product_detail_poller.ndjson)
  - sampled `shop_live` static render windows with:
    - duration about `2.1ms` to `2.8ms`
    - reductions delta about `6.3k`
    - memory delta about `1KB` to `34KB`
  - sampled `catalog` windows with:
    - `query_count = 1`
    - query time about `1.7ms` to `2.3ms`
    - encoded payload about `572 bytes`
    - `variant_row_count = 1`

### Findings
- The benchmark harness is now stable and unambiguous:
  - bootstrap, server, and k6 all use the same `127.0.0.1:4000` contract
  - the server preflight catches port/readiness issues before k6 runs
- `/shop/:slug` is not currently repo-bound under the quick benchmark profile:
  - product detail is one query
  - repo time is low
  - payload is tiny
- `k6/http` is only exercising the disconnected static render path:
  - poller windows during the benchmark are `phase=static_render` and `connected?=false`
  - no live-join/hydration cost is represented in these numbers
- The previous multi-second `shop_show` readings are not reproducible with the stabilized harness.
- The next route-level optimization should therefore not be another blind projection rewrite.
  - If storefront pain returns only in a broader system benchmark, the next target is system contention.
  - If the remaining concern is interactive LiveView cost, the next benchmark must be browser/live-join aware rather than more `k6/http`.

## Phase 30.7
### Links Consulted
- [config/test.exs](/home/jcs/projects/store_blueprint/config/test.exs)
- [Store.Perf.BenchmarkHarness](/home/jcs/projects/store_blueprint/lib/store/perf/benchmark_harness.ex)
- [Store.Perf.ProductDetailPoller](/home/jcs/projects/store_blueprint/lib/store/perf/product_detail_poller.ex)
- [Store.Perf.ProductDetailPollerSummary](/home/jcs/projects/store_blueprint/lib/store/perf/product_detail_poller_summary.ex)
- [priv/perf/checkout_write_contention.exs](/home/jcs/projects/store_blueprint/priv/perf/checkout_write_contention.exs)
- [priv/perf/run_phase_307_contention.exs](/home/jcs/projects/store_blueprint/priv/perf/run_phase_307_contention.exs)
- [perf/k6/http_storefront.js](/home/jcs/projects/store_blueprint/perf/k6/http_storefront.js)

### Decisions / Pins
- Phase 30.7 is diagnosis-only. No checkout optimization lands here.
- Mixed storefront HTTP remains the acceptance load.
- Checkout writers must run in a separate BEAM OS process with dedicated repo pools:
  - server role defaults: `Store.Repo=80`, `Store.DirectRepo=40`
  - writer role defaults: `Store.Repo=20`, `Store.DirectRepo=5`
- The product-detail poller must sample both route telemetry and server-wide contention signals:
  - `:erlang.statistics(:run_queue)`
  - `:erlang.memory(:total)`
  - `pg_stat_activity` active backends
  - `pg_stat_activity` lock waiters
- The orchestration run must include a `30s` cooldown after writers stop so recovery lag can be distinguished from active contention.
- Healthy target for this phase:
  - `shop_show p95 < 50ms` under concurrent checkout writes

### Implementation
- Added writer-role pool config in [config/test.exs](/home/jcs/projects/store_blueprint/config/test.exs) via:
  - `STORE_BENCH_WRITER_POOL_SIZE`
  - `STORE_BENCH_WRITER_DIRECT_POOL_SIZE`
- Extended [Store.Perf.ProductDetailPoller](/home/jcs/projects/store_blueprint/lib/store/perf/product_detail_poller.ex) to sample and persist:
  - scheduler run queue
  - BEAM total memory
  - Postgres active backends
  - Postgres lock waiters
- Extended [Store.Perf.ProductDetailPollerSummary](/home/jcs/projects/store_blueprint/lib/store/perf/product_detail_poller_summary.ex) with:
  - `scheduler`
  - `postgres_activity`
  - `shop_show_under_contention`
- Added [priv/perf/checkout_write_contention.exs](/home/jcs/projects/store_blueprint/priv/perf/checkout_write_contention.exs):
  - standalone writer harness
  - real domain path only:
    - add cart item
    - `Checkout.start_from_cart/3`
    - `Checkout.set_shipping/3`
    - `Checkout.finalize_totals/3`
    - `Payments.create_intent_for_order/3`
  - per-step query/time stats emitted to JSON
- Added [priv/perf/run_phase_307_contention.exs](/home/jcs/projects/store_blueprint/priv/perf/run_phase_307_contention.exs):
  - starts benchmark server
  - starts isolated writer process
  - runs baseline storefront k6
  - runs contention storefront k6
  - enforces overlap and cooldown
  - summarizes the poller output
- Fixed two harness bugs discovered during validation:
  - benchmark k6 artifact path is now absolute through the harness helper
  - child benchmark processes now launch through `exec env ...` so killing the wrapper actually terminates the underlying `beam.smp`
- Fixed the poller formatter crash so tick snapshots continue to append under load.

### Performance & Scaling Review
- Hot path:
  - `/shop/:slug` stays on the read-side acceptance path while real checkout writes run concurrently in a separate BEAM.
  - route telemetry now has enough signal to distinguish:
    - pool queue pressure
    - DB service-time growth
    - scheduler growth
    - lock contention
- Query count / N+1 risk:
  - `shop_show` stays flat at roughly one catalog query plus lightweight static-render work under both baseline and contention
  - no new route-local N+1 behavior appears under write pressure
- DB and contention signals:
  - baseline `shop_show`:
    - p95 `7.22ms`
    - average route query count `1.06`
  - contention `shop_show` with `20` isolated writers:
    - p95 `36.41ms`
    - average route query count `1.04`
  - route query count stayed flat while catalog/query time and queue time increased, which points at mild DB service/queue pressure rather than route fan-out
  - `pg_stat_activity` lock waiters stayed at `0`
  - scheduler run queue stayed low:
    - baseline average `0.02`, max `2`
    - contention average `0.22`, max `3`
- Writer-side pressure:
  - `1965` successful checkout cycles
  - `0` failed cycles
  - contention step means:
    - `start_from_cart`: `119.84ms`, `15` queries
    - `set_shipping`: `339.48ms`, `38` queries
    - `finalize_totals`: `191.51ms`, `22` queries
    - `create_payment_intent`: `150.55ms`, `17` queries
- Interpretation:
  - the benchmark server did not collapse under concurrent writers
  - observed storefront slowdown is attributable to moderate DB service/queue growth under write load
  - there is no evidence here of Postgres lock contention leaking into product-detail reads
  - there is no evidence of BEAM scheduler starvation or recovery lag in the quick run

### Validation
- `MIX_ENV=test mix check`: `PASS`
- Isolated smoke regression:
  - `STORE_TEST_DB_SUFFIX=phase307smoke MIX_ENV=test mix ecto.create`
  - `STORE_TEST_DB_SUFFIX=phase307smoke MIX_ENV=test mix ecto.migrate`
  - `STORE_TEST_DB_SUFFIX=phase307smoke MIX_ENV=test STORE_PERF_SMOKE=true mix run --no-start priv/repo/performance_smoke_test.exs`
  - `PASS`
  - `12 tests, 0 failures`
- Phase 30.7 quick contention run:
  - `STORE_TEST_DB_SUFFIX=phase307bench PORT=4000 STORE_PHASE307_MODE=quick STORE_BENCH_POOL_SIZE=80 STORE_BENCH_DIRECT_POOL_SIZE=40 STORE_BENCH_WRITER_POOL_SIZE=20 STORE_BENCH_WRITER_DIRECT_POOL_SIZE=5 MIX_ENV=test mix run --no-start priv/perf/run_phase_307_contention.exs`
  - wrote:
    - [tmp/perf/phase307_contention_report.json](/home/jcs/projects/store_blueprint/tmp/perf/phase307_contention_report.json)
    - [tmp/perf/k6_http_storefront_phase307_baseline.json](/home/jcs/projects/store_blueprint/tmp/perf/k6_http_storefront_phase307_baseline.json)
    - [tmp/perf/k6_http_storefront_phase307_contention.json](/home/jcs/projects/store_blueprint/tmp/perf/k6_http_storefront_phase307_contention.json)
    - [tmp/perf/checkout_write_contention.json](/home/jcs/projects/store_blueprint/tmp/perf/checkout_write_contention.json)
    - [tmp/perf/product_detail_poller_summary_baseline.json](/home/jcs/projects/store_blueprint/tmp/perf/product_detail_poller_summary_baseline.json)
    - [tmp/perf/product_detail_poller_summary_contention.json](/home/jcs/projects/store_blueprint/tmp/perf/product_detail_poller_summary_contention.json)

### Findings
- Acceptance target met:
  - `shop_show p95 < 50ms` under concurrent writes
  - measured contention `shop_show p95 = 36.41ms`
- Baseline vs contention:
  - `shop_show p95`: `7.22ms -> 36.41ms`
  - `shop_index p95`: `7.83ms -> 41.64ms`
  - `cart p95`: `17.09ms -> 72.97ms`
  - `checkout p95`: `45.32ms -> 231.93ms`
  - `http_req_failed_rate`: `0.00% -> 0.00%`
- Classification:
  - `query_count` stayed flat while `query_time` and `queue_time` increased
  - `lock_waiters` remained `0`
  - `run_queue` remained low
  - result: mild DB service/pool queue pressure under write load, not Postgres lock contention and not BEAM scheduler collapse
- Operational conclusion:
  - `/shop/:slug` is healthy under concurrent checkout writes in this quick profile
  - if storefront latency reappears at higher profiles, the next optimization target should be broader DB service/pool behavior under mixed load rather than another product-detail rewrite
