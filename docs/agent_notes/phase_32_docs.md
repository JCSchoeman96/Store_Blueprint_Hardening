# Phase 32 — Railway Go-Live Hardening

## Links Consulted
- https://docs.railway.com/networking/private-networking
- https://docs.railway.com/networking/private-networking/how-it-works
- https://docs.railway.com/reference/config-as-code
- https://docs.railway.com/guides/pre-deploy-command
- https://hexdocs.pm/phoenix/Mix.Tasks.Phx.Gen.Release.html
- https://hexdocs.pm/remote_ip/RemoteIp.html
- https://www.cloudflare.com/ips-v4
- https://www.cloudflare.com/ips-v6

## Decisions / Pins
- No PDF or Chromium work is part of Phase 32.
- Railway deploys use explicit release commands via `bin/store eval ...`; no production `mix` dependency.
- Railway migrations run in the platform pre-deploy hook through `Store.Release.migrate_all/0`.
- `dns_cluster` remains the clustering mechanism.
- Release distribution is explicitly named and Railway-compatible through `rel/env.sh.eex`.
- Client IP recovery behind Cloudflare is trusted-proxy based and must run before waiting-room or request-rate-limit logic.
- CDN/origin hardening is limited to immutable static asset caching and explicit non-caching of waiting-room/dynamic routes.

## Implementation Plan
1. Extend `Store.Release` with explicit migration entrypoints and JSON reports.
2. Add Railway deployment files: `Dockerfile`, `.dockerignore`, `railway.toml`, `rel/env.sh.eex`.
3. Add trusted proxy recovery before endpoint waiting-room/rate-limit plugs using `remote_ip`.
4. Add immutable cache headers for static assets at the Phoenix origin.
5. Expand runtime/runbook checks for clustering, release cookie, trusted proxies, and Railway pre-deploy migration flow.

## Performance & Scaling Review
- Hot path impact:
  - Waiting room and admin/webhook rate limits now key off the actual client IP behind Cloudflare instead of edge proxy IPs.
  - Static asset cache headers reduce origin bandwidth and free the BEAM for HTML/websocket traffic.
- Warm/cold:
  - `dns_cluster` remains optional-safe in single-node mode and active when `DNS_CLUSTER_QUERY` is set.
  - Release migrations stay outside request paths and run only during Railway pre-deploy lifecycle.
- DB / Oban:
  - No new request-path DB work is introduced.
  - Release migration execution is explicit and isolated from normal web boot.
- Telemetry / ops:
  - Existing waiting-room telemetry stays authoritative.
  - Preflight/runtime checks now include trusted proxy and cluster readiness context.

---

## Phase 32 Addendum — Soak Stabilization (2026-03-12)

### Links Consulted
- [docs/governance/performance_scaling.md](../governance/performance_scaling.md)
- [docs/phases/phase_29_performance_architecture_optimizations.md](../phases/phase_29_performance_architecture_optimizations.md)
- [docs/agent_notes/phase_30_docs.md](./phase_30_docs.md)
- [lib/store/payments/domain.ex](../../lib/store/payments/domain.ex)
- [lib/store/checkout/domain.ex](../../lib/store/checkout/domain.ex)
- [lib/store/perf/product_detail_poller_summary.ex](../../lib/store/perf/product_detail_poller_summary.ex)
- [priv/perf/run_phase_309_durability.exs](../../priv/perf/run_phase_309_durability.exs)

### Artifacts Reviewed
- `phase308_stress_to_failure_report.json`
- `phase309_durability_report.json`
- `checkout_write_contention_phase308_400.json`
- `phase308_writer_450.log`
- `tmp/perf/product_detail_poller_phase309.ndjson`
- Benchmark DB state on `STORE_TEST_DB_SUFFIX=benchfinal`

### Decisions / Pins
- Keep the public interfaces unchanged:
  - `Store.Checkout.set_shipping/3`
  - `Store.Payments.create_intent_for_order/3`
- Keep `380` as the conservative local waiting-room trigger for this workstation slice.
- Keep `400` as the tested healthy ceiling and `450` as the write-path red line until the soak gate passes cleanly.
- Keep the `15 minute` stale pending-provider TTL; add immediate self-heal for fresh rows that already have provider refs instead of shortening the cancel window.
- Treat `pending_provider_setup + provider refs + created/submitted intent` as locally recoverable state, not as a reason to re-hit the provider.
- Standardize the provider timeout envelope on:
  - task timeout `4000ms`
  - Finch pool timeout `5000ms`
  - Req receive timeout `6000ms`
- Treat late post-writer memory drop as recovery lag / temporary pressure rather than a leak if the drop appears only after the writer actually exits.

### Plan
1. Split checkout payment setup into provider-request and local-finalize phases so local reconciliation can be replayed safely without issuing another provider call.
2. Collapse `set_shipping` persistence into one order action and remove the guaranteed-empty `order_line_items` read from the pre-finalize path.
3. Extend durability summaries with writer-finished timing, memory component breakdowns, and pending-provider backlog trends.
4. Add regression coverage for provider recovery, worker self-heal, shipping-path query shape, and durability classification.

### DONE
- Added local provider reconciliation in [lib/store/payments/domain.ex](../../lib/store/payments/domain.ex):
  - provider refs are established once,
  - local finalize always runs after refs exist,
  - recoverable pending-provider rows can be resumed by the request path and by the worker sweep.
- Added partial-state telemetry:
  - `pending_no_refs`
  - `pending_refs_created_intent`
  - `recovered_finalized_local`
- Changed stale pending-provider sweep worker to run a recovery pass before the expiry pass.
- Added a single `:set_shipping_details` order action and updated [lib/store/checkout/domain.ex](../../lib/store/checkout/domain.ex) to persist shipping details in one write.
- Changed pre-finalize shipping currency/summary resolution to stay on cart-backed data and avoid the empty `order_line_items` read.
- Extended poller sampling and summary output with:
  - `memory_processes`
  - `memory_processes_used`
  - `memory_binary`
  - `memory_ets`
  - pending-provider backlog sub-metrics
  - nominal cooldown vs actual writer-finished timing
- Updated the Phase 309 durability runner so effective cooldown ends at `max(nominal_cooldown_end_at, writer_finished_at)`.
- Updated the Phase 309 readiness message to speak in the current `380`-trigger framing.

### Commands Run
- `mix compile`
- `mix format lib/store/checkout/domain.ex lib/store/orders/domain.ex priv/perf/run_phase_309_durability.exs test/store/checkout/domain_test.exs test/store/payments/provider_fault_isolation_test.exs test/store/orders/pending_provider_setup_backlog_test.exs test/store/workers/expire_pending_provider_setup_orders_worker_test.exs test/store/perf/product_detail_poller_summary_test.exs`
- `mix test test/store/checkout/domain_test.exs test/store/payments/provider_fault_isolation_test.exs test/store/orders/pending_provider_setup_backlog_test.exs test/store/workers/expire_pending_provider_setup_orders_worker_test.exs test/store/perf/product_detail_poller_summary_test.exs`
- `mix test test/store/payments/create_intent_for_order_test.exs test/store/payments/provider_task_test.exs test/store_web/live/cart_checkout_live_test.exs`
- `mix test test/store/orders/pending_provider_setup_backlog_test.exs test/store/workers/expire_pending_provider_setup_orders_worker_test.exs`
- `mix check`

### GATES
- Targeted checkout/provider/durability regression slice: pass
- Expanded public-boundary regression slice: pass
- Full soak rerun on `STORE_TEST_DB_SUFFIX=benchfinal` / `STORE_PERF_CHAOS_PROFILE=provider_incident`: not yet rerun after code changes
- `mix check`: pass

### Performance & Scaling Review
- Hot:
  - `create_payment_intent` no longer re-enters the provider for stranded rows that already have persisted refs; this removes duplicate provider pressure from the hottest chaos failure mode.
  - `set_shipping` now persists address, method, and quote evidence in one write instead of three sequential order updates.
  - Pre-finalize shipping now infers currency and summary items from cart-backed state first, avoiding the empty `order_line_items` round-trip.
- Warm:
  - Pending-provider worker sweeps now attempt cheap local recovery on fresh recoverable rows before any TTL-based expiry logic.
  - Durability summaries now distinguish writer-active memory pressure from post-writer cooldown behavior, which makes soak diagnosis materially more accurate.
- Cold:
  - Timeout defaults changed only at the provider boundary; no storefront read-path defaults changed.
  - Telemetry additions are observational and low overhead.
- DB query count + N+1 risk:
  - `set_shipping` removes two order updates and the pre-finalize `order_line_items` query from the hot path.
  - Request-local quote reuse remains intact; cart/item/catalog lookups remain bounded to the current checkout scope.
  - No new N+1 read pattern was introduced.
- Indexes:
  - Existing `orders.state`, `orders.checkout_key`, `payment_intents.order_id`, and provider-ref indexes remain sufficient for the new recovery query shape.
  - Recoverable pending-provider lookup filters on `orders.state` plus provider-ref presence; no new index was required for this workstation-bound stabilization slice.
- Caching / invalidation / stampede:
  - Cart-backed fallback remains request-local and does not introduce shared-cache invalidation complexity.
  - No Redis/ETS cache behavior changed in this slice.
- Oban uniqueness / idempotency:
  - Worker behavior remains replay-safe; recovery is local/idempotent and sweep uniqueness is unchanged.
  - Provider intent reuse still hinges on `payment_intent_key`, preventing duplicate intent creation on retry.
- Telemetry / logging:
  - Added explicit telemetry for pending-provider partial states and local recovery results.
  - Added durability visibility for backlog mix and memory-component drift so the next soak can distinguish provider residue from process/binary/ETS growth.
