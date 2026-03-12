# Phase 31 Docs

## Links Consulted
- [AGENTS.md](/home/jcs/projects/store_blueprint/AGENTS.md)
- [docs/governance/performance_scaling.md](/home/jcs/projects/store_blueprint/docs/governance/performance_scaling.md)
- [docs/governance/observability_slos.md](/home/jcs/projects/store_blueprint/docs/governance/observability_slos.md)
- [lib/store/checkout/domain.ex](/home/jcs/projects/store_blueprint/lib/store/checkout/domain.ex)
- [lib/store/orders/domain.ex](/home/jcs/projects/store_blueprint/lib/store/orders/domain.ex)
- [lib/store/orders/order.ex](/home/jcs/projects/store_blueprint/lib/store/orders/order.ex)
- [lib/store/payments/domain.ex](/home/jcs/projects/store_blueprint/lib/store/payments/domain.ex)
- [lib/store/payments/interlocks.ex](/home/jcs/projects/store_blueprint/lib/store/payments/interlocks.ex)
- [lib/store/orders/inventory_reservations.ex](/home/jcs/projects/store_blueprint/lib/store/orders/inventory_reservations.ex)
- [config/config.exs](/home/jcs/projects/store_blueprint/config/config.exs)
- [config/test.exs](/home/jcs/projects/store_blueprint/config/test.exs)
- [priv/perf/pending_provider_setup_crucible.exs](/home/jcs/projects/store_blueprint/priv/perf/pending_provider_setup_crucible.exs)
- [priv/perf/run_phase_311_pending_provider_setup_crucible.exs](/home/jcs/projects/store_blueprint/priv/perf/run_phase_311_pending_provider_setup_crucible.exs)
- [tmp/perf/phase31_pending_provider_setup_crucible_report.json](/home/jcs/projects/store_blueprint/tmp/perf/phase31_pending_provider_setup_crucible_report.json)
- [lib/store_web/live/static_to_live.ex](/home/jcs/projects/store_blueprint/lib/store_web/live/static_to_live.ex)
- [lib/store_web/live/shop_live/index.ex](/home/jcs/projects/store_blueprint/lib/store_web/live/shop_live/index.ex)
- [lib/store_web/live/shop_live/show.ex](/home/jcs/projects/store_blueprint/lib/store_web/live/shop_live/show.ex)
- [lib/store_web/live/cart_live.ex](/home/jcs/projects/store_blueprint/lib/store_web/live/cart_live.ex)
- [lib/store_web/live/checkout_live/placeholder.ex](/home/jcs/projects/store_blueprint/lib/store_web/live/checkout_live/placeholder.ex)
- [lib/store/catalog/facade.ex](/home/jcs/projects/store_blueprint/lib/store/catalog/facade.ex)
- [lib/store/carts/facade.ex](/home/jcs/projects/store_blueprint/lib/store/carts/facade.ex)
- [lib/store_web/telemetry.ex](/home/jcs/projects/store_blueprint/lib/store_web/telemetry.ex)

## Decisions / Pins
1. Phase 31 stays focused on checkout write-path physics, not storefront reads.
2. Oban pool isolation was already present before implementation:
   - `Oban` runs on `Store.DirectRepo`
   - benchmark/test configs already split `Store.Repo` and `Store.DirectRepo` pools
3. Provider setup must remain outside DB transaction scope, but Phase 31 adds a recoverable intermediate state instead of relying on implicit local payment-intent idempotency alone.
4. The new resumable state is `pending_provider_setup`.
5. `pending_provider_setup` must be bounded:
   - default TTL `15 minutes`
   - stale orders are cancelled by a periodic worker
   - inventory reservations are released immediately on successful sweep
6. Stripe/provider retries must converge on the same local/provider intent:
   - deterministic local `payment_intent_key` remains the provider idempotency key
   - retry/resume must never create a duplicate order for the same checkout key
7. Phase 31 is not complete without a ghost-checkout crucible:
   - benchmark-only TTL override `30s`
   - benchmark-only sweep loop `5s`
   - batch size `50`
   - Wave 1 abandoned clients must hold inventory before expiry
   - probe users must fail before expiry
   - Wave 2 must reclaim the same stock after sweep
7. BEAM allocator tuning remains deferred. The first concrete write-path reduction in this phase is code-path work:
   - stop recomputing shipping quote options during `set_shipping` summary rebuild
   - add trace telemetry to expose `set_shipping` / `finalize_totals` substep cost

## Plan
1. Add an explicit order-level provider setup state and timestamp.
2. Update checkout/payment idempotency to treat `pending_provider_setup` as resumable, not terminal.
3. Add stale provider-setup sweep + reservation release worker.
4. Add checkout trace telemetry for `set_shipping` and `finalize_totals`.
5. Extend contention summaries with p99 and dominant-cause classification.
6. Validate retry, sweep, state-machine, and related checkout/webhook/live behavior.
7. Add a dedicated pending-provider TTL crucible with backlog visibility, probe-wave negative control, and second-wave reclaim proof.

## DONE
- Added `Order.state = :pending_provider_setup` and `provider_setup_started_at`.
- Added order actions:
  - `begin_provider_setup`
  - `refresh_provider_setup`
  - `provider_setup_ready`
- Allowed order payment/cancel transitions from `pending_provider_setup`.
- Updated checkout order reuse so `begin_checkout` treats both `pending_payment` and `pending_provider_setup` as resumable checkout states.
- Updated payment intent creation flow so provider setup:
  - marks the order `pending_provider_setup` before the outbound provider call
  - resumes safely when the same checkout retries
  - returns the order to `pending_payment` once provider setup is persisted locally
- Preserved existing deterministic provider idempotency by continuing to use the stable `payment_intent_key` as the provider idempotency key.
- Added `Store.Orders.sweep_stale_pending_provider_setup/2`.
- Added [expire_pending_provider_setup_orders_worker.ex](/home/jcs/projects/store_blueprint/lib/store/workers/expire_pending_provider_setup_orders_worker.ex) and scheduled it in Oban cron.
- Added immediate reservation release on stale pending-provider sweep, then order cancellation.
- Added new telemetry surfaces:
  - `store.checkout.trace.*`
  - `store.checkout.provider_setup.*`
  - `store.checkout.pending_provider_setup.resume.*`
  - `store.checkout.pending_provider_setup.sweep.*`
- Reduced `set_shipping` duplicated work by reusing the quote options and quote request already generated earlier in the request instead of recalculating them for the summary view.
- Added dominant-cause classification and p99s to checkout contention summaries.
- Added `Store.Orders.pending_provider_setup_backlog_snapshot/2` and matching telemetry/metrics for:
  - backlog count
  - oldest age
  - reserved variant count
- Added benchmark-only TTL/sweep override support:
  - `STORE_PROVIDER_SETUP_TTL_SECONDS`
  - `STORE_PROVIDER_SETUP_SWEEP_BATCH_SIZE`
  - `STORE_PERF_PENDING_PROVIDER_SWEEP_INTERVAL_MS`
- Added the dedicated pending-provider crucible runner:
  - [pending_provider_setup_crucible.exs](/home/jcs/projects/store_blueprint/priv/perf/pending_provider_setup_crucible.exs)
  - [run_phase_311_pending_provider_setup_crucible.exs](/home/jcs/projects/store_blueprint/priv/perf/run_phase_311_pending_provider_setup_crucible.exs)
- Added dedicated low-stock benchmark fixtures for the crucible so the same inventory is genuinely contested.
- Added focused coverage for:
  - backlog snapshot count/age/reserved variants
  - empty sweep no-op
  - multi-batch stale backlog drain
- Added focused regression coverage for:
  - provider timeout/error retry with `pending_provider_setup`
  - stale pending-provider sweep
  - order state-machine transition into and out of provider setup
- Batched stale-sweep post-commit notifications across the whole sweep iteration instead of notifying per cancelled order. This reduced the 50-order crucible batches from `581ms` to `496.56ms`.

## TTL Crucible Results
- Artifact: [phase31_pending_provider_setup_crucible_report.json](/home/jcs/projects/store_blueprint/tmp/perf/phase31_pending_provider_setup_crucible_report.json)
- Config:
  - TTL `30s`
  - sweep interval `5s`
  - sweep batch size `50`
  - abandoned clients `200`
  - probe clients `5`
  - second-wave clients `200`
  - provider delay `45000ms`
- Result: `pass`
- Peak backlog: `200`
- Probe wave: `5/5` blocked with `OUT_OF_STOCK`, `0` successes before expiry
- Drain behavior:
  - expected sweep iterations `4`
  - actual sweep iterations `4`
  - max sweep duration `496.56ms`
  - backlog returned to zero within the `90s` closure window
  - released reservations matched swept orders
- Recovery proof:
  - second wave successful cycles `200`
  - second wave failed cycles `0`
  - the same seats became sellable again after sweep
- Runtime profile during crucible:
  - scheduler run queue max `2`
  - active backends max `8`
  - lock waiters max `0`

## Performance & Scaling Review
- Hot:
  - `set_shipping` no longer recomputes shipping quotes for the same request during summary rendering.
  - `create_payment_intent` now has explicit provider-setup telemetry and resumable order state.
  - pending-provider sweeps now batch notification delivery per sweep iteration instead of per order.
- Warm:
  - contention artifacts now include `p99_*` and `dominant_cause`.
  - trace mode can be enabled with `STORE_CHECKOUT_TRACE=true`.
  - pending-provider backlog snapshots and the TTL crucible are now first-class benchmark artifacts.
- Cold:
  - added one targeted schema change: `orders.provider_setup_started_at` plus index on `(state, provider_setup_started_at)`.
- DB query count + N+1 risk:
  - `set_shipping` duplicated quote-read work was removed from the same request path.
  - `finalize_totals` still needs deeper allocation/query-shape work after trace data is collected.
  - pending-provider sweep remains one transaction per order for correctness, but the per-batch notifier overhead was removed.
- Caching:
  - Phase 29 ETS/Redis shipping cache remains the system of record for quote/rule reuse.
  - Phase 31 reuses the same request-local quote results so the web summary path does not force a second quote pass.
- Oban uniqueness / idempotency:
  - Oban repo isolation was already in place via `Store.DirectRepo`.
  - stale provider setup cleanup is unique-by-worker cron on the inventory queue.
  - the crucible uses the same sweep domain logic with a benchmark-only fast loop instead of altering production cron cadence.
- Telemetry / logging:
  - added substep traces for `set_shipping` and `finalize_totals`
  - added provider-setup duration and stale-sweep metrics
  - added resume counter for `pending_provider_setup`
  - added pending-provider backlog metrics and crucible backlog sampling

## Notes
- The new stale-provider sweep is intentionally conservative: if a checkout is still actively retrying, `refresh_provider_setup` updates the timestamp on resumed setup attempts.
- Existing reservation expiry still exists as a second safety net; Phase 31 adds a faster explicit reclaim path tied to abandoned provider setup.
- Existing local payment intent reuse already prevented duplicate local intents; Phase 31 closes the order-state and inventory leak around that behavior.

## Phase 31.B Static-to-Live / Resume-Safe UI

### Decisions / Pins
1. Flash-sale release gating for Phase 31.B is limited to:
   - `ShopLive.Index`
   - `ShopLive.Show`
   - `CartLive`
   - `CheckoutLive.Placeholder`
2. Disconnected render on those four LiveViews must perform `0` DB queries.
3. Warm hydration moves to connected-only execution through a shared helper and bounded jitter:
   - default jitter `25..150ms`
   - non-critical storefront/cart warm loads are jittered
   - checkout resume hydration remains immediate
4. Web continues to call domain facades only; no `Ash.Query` or `Repo` is introduced in LiveViews.
5. List-heavy storefront assigns must use plain-map view models plus LiveView streams, not Ash structs held in socket assigns.
6. Resume-safe checkout UI is live, not static:
   - checkout subscribes to the order-specific PubSub topic
   - if the pending-provider order is cancelled by the sweeper, the LiveView moves to an explicit `expired_restart_required` state

### DONE
- Added [static_to_live.ex](/home/jcs/projects/store_blueprint/lib/store_web/live/static_to_live.ex) to centralize:
  - warm-load scheduling
  - jitter handling
  - mount telemetry emission
- Refactored [index.ex](/home/jcs/projects/store_blueprint/lib/store_web/live/shop_live/index.ex):
  - disconnected pass is shell-only
  - connected pass loads product cards after websocket upgrade
  - product cards are streamed with `stream/4`
  - lifecycle telemetry event `store.shop_live.index.mount` is emitted for `static` and `live` phases
- Refactored [show.ex](/home/jcs/projects/store_blueprint/lib/store_web/live/shop_live/show.ex):
  - disconnected pass is slug/loading shell only
  - connected pass performs product detail hydration
  - initial warm load is jittered; subsequent param-driven reloads are immediate
  - lifecycle telemetry event `store.shop_live.show.mount` is emitted
- Refactored [cart_live.ex](/home/jcs/projects/store_blueprint/lib/store_web/live/cart_live.ex):
  - disconnected pass is cart-token shell only
  - connected pass loads cart view after websocket upgrade
  - initial warm load is jittered; mutation-triggered reloads remain immediate
  - lifecycle telemetry event `store.cart_live.mount` is emitted
- Refactored [placeholder.ex](/home/jcs/projects/store_blueprint/lib/store_web/live/checkout_live/placeholder.ex):
  - disconnected pass is checkout-key/loading shell only
  - connected pass hydrates checkout state
  - subscribes to `Store.Orders.order_topic(order_id)` when resumable order state is present
  - transitions to `expired_restart_required` when the stale-provider sweep cancels the order
  - lifecycle telemetry event `store.checkout_live.mount` is emitted
- Added order PubSub broadcasting in [domain.ex](/home/jcs/projects/store_blueprint/lib/store/orders/domain.ex) for stale pending-provider expiry.
- Follow-up remediation:
  - warm-load jitter keys now include a per-socket component, so identical `/shop` or `/cart` joins no longer align on the same delay bucket
  - storefront product-card reads now use a dedicated projected query and a separate product-card cache variant instead of loading full product structs and then mapping them down
  - order-state PubSub is now emitted for provider-setup start/refresh/ready transitions as well as stale-provider expiry so the checkout resume UI can stay in sync across tabs
- Added plain-map storefront card projection in [facade.ex](/home/jcs/projects/store_blueprint/lib/store/catalog/facade.ex) via `list_product_cards_for_public/2`.
- Tightened cart/payment read shapes in:
  - [facade.ex](/home/jcs/projects/store_blueprint/lib/store/carts/facade.ex)
  - [domain.ex](/home/jcs/projects/store_blueprint/lib/store/payments/domain.ex)
- Extended [telemetry.ex](/home/jcs/projects/store_blueprint/lib/store_web/telemetry.ex) with mount metrics for shop index, shop show, cart, and checkout.

### Performance & Scaling Review
- Hot:
  - the four release-gating LiveViews now render a cold shell without DB work on the disconnected pass
  - connected hydration is smoothed by bounded jitter for non-critical warm loads, reducing websocket-upgrade herd risk
  - checkout resume UI no longer risks a stale “pay again” dead-end after a sweep-driven cancellation
- Warm:
  - storefront product cards are plain maps, not Ash structs, reducing per-socket heap retention
  - shop index uses `stream/4`, avoiding a large persistent list assign on long-lived LiveView processes
  - cart view loading uses narrower projection helpers for line items/catalog data
  - product-card cache entries are now namespaced separately from full product-list cache entries, so the card projection path does not accidentally reuse heavier cached structs
- Cold:
  - no schema/index change was required for Phase 31.B
- DB query count + N+1 risk:
  - disconnected render query count for the four release-gating LiveViews is now expected to remain `0`
  - connected passes still use the existing domain facades; no new web-layer query composition was introduced
  - storefront list rendering now uses a dedicated card projection instead of passing larger product structs to the LiveView
- Caching / invalidation / stampede protection:
  - storefront/list warm reads continue to sit behind the Phase 29 cache layers
  - jittered websocket-upgrade hydration now includes a per-socket key component, reducing mass reconnect burst alignment even when many clients hit the same route/query
- Telemetry / logging:
  - new lifecycle metrics:
    - `store.shop_live.index.mount`
    - `store.shop_live.show.mount`
    - `store.cart_live.mount`
    - `store.checkout_live.mount`
  - each event includes phase/result metadata and repo stats so static-pass zero-query behavior can be asserted in tests

### Validation
- Targeted tests:
  - `mix test test/store/catalog/facade_public_product_test.exs`
  - `mix test test/store_web/live/shop_live/show_test.exs`
  - `mix test test/store_web/live/cart_checkout_live_test.exs`
- Broad gates:
  - `mix check`
  - `MIX_ENV=test STORE_PERF_SMOKE=true mix run --no-start priv/repo/performance_smoke_test.exs`

## Phase 31.C Release Hardening / Waiting Room Closure

### Links Consulted
- [AGENTS.md](/home/jcs/projects/store_blueprint/AGENTS.md)
- [docs/governance/performance_scaling.md](/home/jcs/projects/store_blueprint/docs/governance/performance_scaling.md)
- [docs/phases/phase_29_performance_architecture_optimizations.md](/home/jcs/projects/store_blueprint/docs/phases/phase_29_performance_architecture_optimizations.md)
- [config/config.exs](/home/jcs/projects/store_blueprint/config/config.exs)
- [lib/store/support/rate_limit.ex](/home/jcs/projects/store_blueprint/lib/store/support/rate_limit.ex)
- [lib/store/support/rate_limit/ets_backend.ex](/home/jcs/projects/store_blueprint/lib/store/support/rate_limit/ets_backend.ex)
- [lib/store/support/rate_limit/redis_backend.ex](/home/jcs/projects/store_blueprint/lib/store/support/rate_limit/redis_backend.ex)
- [lib/store/support/telemetry/redis_aggregates.ex](/home/jcs/projects/store_blueprint/lib/store/support/telemetry/redis_aggregates.ex)
- [lib/store/workers/flush_redis_aggregate_buckets_worker.ex](/home/jcs/projects/store_blueprint/lib/store/workers/flush_redis_aggregate_buckets_worker.ex)
- [lib/store/operations/aggregate_bucket.ex](/home/jcs/projects/store_blueprint/lib/store/operations/aggregate_bucket.ex)
- [lib/store_web/waiting_room.ex](/home/jcs/projects/store_blueprint/lib/store_web/waiting_room.ex)
- [lib/store_web/plugs/waiting_room.ex](/home/jcs/projects/store_blueprint/lib/store_web/plugs/waiting_room.ex)
- [lib/store_web/live_socket.ex](/home/jcs/projects/store_blueprint/lib/store_web/live_socket.ex)
- [lib/store_web/endpoint.ex](/home/jcs/projects/store_blueprint/lib/store_web/endpoint.ex)
- [lib/store/comms/email_outbox.ex](/home/jcs/projects/store_blueprint/lib/store/comms/email_outbox.ex)
- [lib/store/comms/facade.ex](/home/jcs/projects/store_blueprint/lib/store/comms/facade.ex)
- [lib/store/fulfillment/fulfillment_order.ex](/home/jcs/projects/store_blueprint/lib/store/fulfillment/fulfillment_order.ex)
- [lib/store/fulfillment/domain.ex](/home/jcs/projects/store_blueprint/lib/store/fulfillment/domain.ex)
- [priv/repo/migrations/20260312130000_phase_31c_ops_metric_buckets.exs](/home/jcs/projects/store_blueprint/priv/repo/migrations/20260312130000_phase_31c_ops_metric_buckets.exs)
- [priv/repo/migrations/20260312133000_phase_31c_admin_keyset_indexes.exs](/home/jcs/projects/store_blueprint/priv/repo/migrations/20260312133000_phase_31c_admin_keyset_indexes.exs)
- [tmp/perf/performance_smoke_report.json](/home/jcs/projects/store_blueprint/tmp/perf/performance_smoke_report.json)

### Decisions / Pins
1. Open Phase 29 governance debt is treated as a release blocker, not deferred work.
2. Redis remains the real-time sink for high-velocity operational aggregates, but durability now uses immutable time-bucketed keys plus a periodic flush worker on `Store.DirectRepo`.
3. Waiting-room enforcement must happen before router work for HTTP and before LiveView process allocation for websocket reconnects.
4. The waiting-room response is a static HTML holding page with auto-refresh, not a blank `429`.
5. Admin/account operational lists stay synchronous, but must be protected by:
   - keyset pagination
   - composite filter+sort indexes
   - narrow projections
   - explicit rate limiting
6. `Store.DirectRepo` remains the only background-work isolation boundary; no new repo abstraction is added.

### DONE
- Upgraded the rate-limit seam to expose live counts and windows through `Store.Support.RateLimit.check/5`.
- Added endpoint-level waiting-room enforcement in [waiting_room.ex](/home/jcs/projects/store_blueprint/lib/store_web/waiting_room.ex) and [waiting_room.ex](/home/jcs/projects/store_blueprint/lib/store_web/plugs/waiting_room.ex):
  - hot public scopes: `/shop`, `/cart`, `/checkout`
  - static auto-refresh HTML response
  - browser-session scope propagation for websocket gating
- Replaced the direct LiveView socket mount with [live_socket.ex](/home/jcs/projects/store_blueprint/lib/store_web/live_socket.ex) so websocket upgrades are admitted or rejected in `connect/3` before LiveView process allocation.
- Added waiting-room telemetry and metrics:
  - `store.waiting_room.http.*`
  - `store.waiting_room.socket.*`
- Converted Redis telemetry sinks to immutable bucket keys in [redis_aggregates.ex](/home/jcs/projects/store_blueprint/lib/store/support/telemetry/redis_aggregates.ex) and added:
  - [aggregate_bucket.ex](/home/jcs/projects/store_blueprint/lib/store/operations/aggregate_bucket.ex)
  - [flush_redis_aggregate_buckets_worker.ex](/home/jcs/projects/store_blueprint/lib/store/workers/flush_redis_aggregate_buckets_worker.ex)
  - cron wiring in `config/config.exs`
- Added bucket-flush telemetry and metrics:
  - `store.ops.redis_aggregate_flush.duration`
  - `store.ops.redis_aggregate_flush.bucket_count`
  - `store.ops.redis_aggregate_flush.row_count`
- Hardened admin keyset/query contracts:
  - email outbox moved to keyset pagination with explicit `select`
  - fulfillment queue moved to keyset pagination with explicit `select`
  - matching composite indexes added for `state/template_kind + inserted_at + id`
- Updated operational health checks so waiting-room config is part of the runtime readiness surface.

### Performance & Scaling Review
- Hot:
  - initial public route throttling now happens before router and LiveView mount work
  - websocket reconnect storms are rejected in `connect/3`, not in `on_mount`, so LiveView processes are not allocated for denied upgrades
  - redis aggregate writes stay cheap on the request path because writers only touch the current bucket
- Warm:
  - rate-limit state sits behind the existing ETS/Redis backend seam
  - durable aggregate flush runs asynchronously on `Store.DirectRepo`, preserving `Store.Repo` capacity for storefront and checkout traffic
  - admin operational lists now page by keyset instead of offset, reducing long-scan amplification under load
- Cold:
  - schema additions are narrowly scoped:
    - `ops_metric_buckets`
    - composite admin indexes for email outbox and fulfillment queue
- DB query count + N+1 risk:
  - waiting-room paths perform zero application DB work
  - aggregate durability avoids `GET`/`SET 0` counter reset races by flushing only historical buckets
  - admin list reads now use explicit projection plus keyset paging; no new offset scan surface was introduced
- Caching / invalidation / stampede protection:
  - this pass reuses the Phase 29 cache posture; it does not widen cache ownership
  - waiting-room admission control uses the existing shared rate-limit seam instead of introducing another cache or limiter
- Oban uniqueness / idempotency:
  - flush work stays isolated on `Store.DirectRepo`
  - bucket flushes are idempotent because Postgres uses UPSERT against immutable bucket identities and Redis keys are deleted only after success
- Telemetry / logging:
  - added explicit HTTP/socket waiting-room metrics
  - added explicit Redis aggregate flush metrics
  - existing checkout/pending-provider metrics remain unchanged and continue to back the flash-sale dashboards

### Validation
- Targeted tests:
  - `mix test test/store/support/rate_limit_test.exs test/store_web/plugs/waiting_room_test.exs test/store/support/telemetry/redis_aggregates_test.exs test/store/workers/flush_redis_aggregate_buckets_worker_test.exs`
  - `mix test test/store/governance/comms_policy_test.exs`
  - `mix test test/store/fulfillment/domain_test.exs`
  - `mix test test/store_web/controllers/json_api_router_test.exs`
  - `mix test test/store_web/live/cart_checkout_live_test.exs`
- Broad gates:
  - `mix check` -> `3 properties, 432 tests, 0 failures`
  - `MIX_ENV=test STORE_PERF_SMOKE=true mix run --no-start priv/repo/performance_smoke_test.exs` -> `pass`
- Perf smoke artifact:
  - [performance_smoke_report.json](/home/jcs/projects/store_blueprint/tmp/perf/performance_smoke_report.json)
  - key current numbers:
    - `checkout_concurrency mean 1357.04ms, p99 1367.27ms`
    - `domain_thundering_herd mean 60.53ms, p99 109.37ms`
    - `redis_thundering_herd mean 0.77ms, p99 1.28ms`
    - `provider_fault_slow mean 2070.58ms, p99 2075.55ms, mean DB share 0.03`
    - `create_payment_intent mean 318.05ms`
    - `finalize_totals mean 235.73ms`
    - `start_from_cart mean 239.95ms`

### Notes
- The waiting-room thresholds remain aligned to the latest local destruction data:
  - healthy writer rung `400`
  - first failure `450`
  - conservative trigger `380`
- The waiting-room implementation is intentionally limited to the hot public browser surfaces and `/live`; it does not change webhook or authenticated admin semantics.
- Redis aggregate durability now protects operational history without moving real-time aggregation load back onto Postgres.

## Phase 31.D Supervised Provider Boundary Hardening

### Links Consulted
- [AGENTS.md](/home/jcs/projects/store_blueprint/AGENTS.md)
- [lib/store/payments/domain.ex](/home/jcs/projects/store_blueprint/lib/store/payments/domain.ex)
- [lib/store/payments/providers.ex](/home/jcs/projects/store_blueprint/lib/store/payments/providers.ex)
- [lib/store/payments/providers/stripe.ex](/home/jcs/projects/store_blueprint/lib/store/payments/providers/stripe.ex)
- [lib/store/payments/provider_config.ex](/home/jcs/projects/store_blueprint/lib/store/payments/provider_config.ex)
- [lib/store/payments/provider_task.ex](/home/jcs/projects/store_blueprint/lib/store/payments/provider_task.ex)
- [lib/store/application.ex](/home/jcs/projects/store_blueprint/lib/store/application.ex)
- [lib/store/support/http/req_client.ex](/home/jcs/projects/store_blueprint/lib/store/support/http/req_client.ex)
- [config/config.exs](/home/jcs/projects/store_blueprint/config/config.exs)
- [config/runtime.exs](/home/jcs/projects/store_blueprint/config/runtime.exs)
- [test/store/payments/provider_task_test.exs](/home/jcs/projects/store_blueprint/test/store/payments/provider_task_test.exs)
- [test/store/payments/provider_fault_isolation_test.exs](/home/jcs/projects/store_blueprint/test/store/payments/provider_fault_isolation_test.exs)
- [tmp/perf/performance_smoke_report.json](/home/jcs/projects/store_blueprint/tmp/perf/performance_smoke_report.json)

### Decisions / Pins
1. Keep checkout payment setup synchronous from the user’s perspective; do not move provider setup into Oban.
2. Preserve the existing `pending_provider_setup` state machine and stable `payment_intent_key` idempotency contract.
3. The outbound provider boundary is isolated with:
   - `Task.Supervisor.async_nolink/2`
   - `Task.yield/2`
   - `Task.shutdown/2` with explicit shutdown-result handling
4. The parent process retains all Ash/DB writes; the supervised task owns only the provider HTTP call and provider-boundary result normalization.
5. Stripe outbound HTTP uses a dedicated named Finch pool and explicit timeout hierarchy:
   - task timeout is the smallest timeout
   - Req receive/pool timeouts must be greater than the task timeout
6. Normal returned provider errors and actual BEAM task exits are treated as different failure classes and normalized separately.

### DONE
- Added [provider_task.ex](/home/jcs/projects/store_blueprint/lib/store/payments/provider_task.ex) to isolate provider calls under `Task.Supervisor.async_nolink/2`.
- Added [provider_config.ex](/home/jcs/projects/store_blueprint/lib/store/payments/provider_config.ex) to centralize:
  - task timeout
  - Stripe Finch pool size
  - Req receive/pool timeouts
  - timeout hierarchy validation
- Added dedicated runtime infrastructure in [application.ex](/home/jcs/projects/store_blueprint/lib/store/application.ex):
  - `Store.Payments.ProviderTaskSupervisor`
  - `Store.Payments.Finch`
- Updated [stripe.ex](/home/jcs/projects/store_blueprint/lib/store/payments/providers/stripe.ex) to:
  - validate timeout hierarchy before request execution
  - use the named Finch client through payment request options
- Updated [domain.ex](/home/jcs/projects/store_blueprint/lib/store/payments/domain.ex) so `ensure_provider_reference/5` runs only the outbound provider call inside the supervised task and keeps all persistence in the parent.
- Added provider-task telemetry in [telemetry.ex](/home/jcs/projects/store_blueprint/lib/store_web/telemetry.ex):
  - `store.checkout.provider_setup_task.duration`
  - `store.checkout.provider_setup_task.count`
- Added crash fault injection support in [providers.ex](/home/jcs/projects/store_blueprint/lib/store/payments/providers.ex) so task-exit behavior is exercised explicitly in tests.
- Added focused coverage in:
  - [provider_task_test.exs](/home/jcs/projects/store_blueprint/test/store/payments/provider_task_test.exs)
  - [provider_fault_isolation_test.exs](/home/jcs/projects/store_blueprint/test/store/payments/provider_fault_isolation_test.exs)

### Performance & Scaling Review
- Hot:
  - provider setup remains outside the DB transaction and now also outside the caller process’ fault domain
  - task timeout is the primary arbiter of provider latency on the hot checkout path
  - nested provider result handling distinguishes:
    - provider success
    - provider-returned error
    - task exit
    - true timeout
- Warm:
  - dedicated `Store.Payments.Finch` pool prevents local HTTP client pooling from becoming the hidden bottleneck before the network/provider does
  - pool size is aligned to the current healthy writer ceiling (`400`) by default
  - timeout hierarchy validation fails closed if configuration would let Req/Finch preempt the task supervisor
- Cold:
  - no schema change was required
  - only OTP/runtime additions were introduced: one task supervisor and one Finch child
- DB query count + N+1 risk:
  - no additional DB round-trips were added to the payment setup path
  - all Ash writes remain where they were: before or after the provider call in the parent process
- Oban / idempotency:
  - Oban behavior is unchanged in this slice
  - retry/resume still converges on the same order and local payment intent via `payment_intent_key`
- Telemetry / logging:
  - provider task lifecycle now emits explicit success/error/timeout/exit signals
  - logger metadata is restored inside the supervised worker so request-scoped traces do not disappear across the process boundary

### Validation
- Focused tests:
  - `mix test test/store/payments/provider_task_test.exs test/store/payments/provider_fault_isolation_test.exs`
  - `mix test test/store/payments/create_intent_for_order_test.exs test/store_web/live/cart_checkout_live_test.exs`
- Broad gates:
  - `mix check` -> `3 properties, 440 tests, 0 failures`
  - `MIX_ENV=test STORE_PERF_SMOKE=true mix run --no-start priv/repo/performance_smoke_test.exs` -> `pass`
- Current perf smoke highlights:
  - `checkout_concurrency mean 1154.12ms, p99 1166.59ms`
  - `provider_fault_slow mean 2050.47ms, p99 2054.37ms, mean DB share 0.02`
  - `create_payment_intent mean 282.67ms`
  - `finalize_totals mean 217.06ms`
  - `start_from_cart mean 177.62ms`

### Notes
- `Task.await/2` is intentionally not used anywhere in the provider setup path.
- The shutdown race is handled explicitly: a payload returned during `Task.shutdown/2` is treated as success, not timeout.
- Crash fault tests still log task termination lines at the VM level, but the caller path remains healthy and returns canonical domain errors.
