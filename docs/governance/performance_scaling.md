# Governance: Performance & Scaling (Authoritative)
Single-tenant does not mean “low traffic”. This doc standardizes planning for hot paths.

## Layered caching model
- Hot: ETS/GenServer (10s–5m TTL)
- Warm: Redis (30m–24h TTL)
- Cold: Postgres
- Edge: CDN for static assets
- Client: localStorage/IndexedDB for UX hints (non-sensitive)

## Redis key conventions (MUST)
Prefix keys by environment + app:
- prod:store:<namespace>:...

Avoid embedding user PII in keys.

## Recommended Redis structures
- Rate limiting (auth/webhooks): ZSET timestamps or INCR+EXPIRE
- Webhook dedupe: STRING/SET with TTL
- Inventory reservations: HASH + ZSET expiry (optional ecommerce inventory pack)
- Activity feeds: LIST (optional)
- Unique visitors: HyperLogLog (optional)

## TTL strategy (baseline)
- Rate limit keys: 1–15 minutes
- Webhook dedupe keys: 24–72 hours (provider-dependent)
- Catalog hot cache: 30–300 seconds
- Price book warm cache: 30–120 minutes

## Invalidation triggers (baseline)
- PriceEntry change -> invalidate price book caches
- Product publish/unpublish -> invalidate catalog caches
- Coupon change -> invalidate coupon cache

## PubSub rules
- Topic naming:
  - store:orders:<order_id>
  - store:catalog
  - store:pricing:<price_book_id>
- Broadcast only after durable writes succeed.

## Performance & Scaling Review (MANDATORY for new actions)
For every new domain action, answer:
- Data layer (hot/warm/cold)?
- Is the architecture safe under the defined 100k-user scenario, and what separate measured-capacity evidence is required before making a capacity claim?
- DB indexes required?
- Redis representation needed?
- Can this be streamed instead of loaded?

## Runtime resource safety review

For runtime-affecting or hot-path changes, review the resource lifecycle alongside query, cache, and scaling behavior. The detailed invariants and evidence protocol are defined in [Phase 29](../phases/phase_29_performance_architecture_optimizations.md).

- Process and task lifetime, orphaning, and termination behavior.
- Process heap/state and binary retention, ETS ownership and cardinality, and atom growth.
- Mailbox or queue backlog, workload-specific bounds, backpressure, and drain behavior.
- Allocation and GC pressure for the affected process classes.
- Cachex, Redis, and Oban backlog, expiry, and cleanup under their existing policies.
- LiveView and socket termination, PubSub subscriptions, timers, monitors, and telemetry-handler cleanup.
- Ports, NIFs, and other external-resource ownership and release.
- Post-load cooldown behavior and per-node evidence for multi-node claims.

Do not use RSS alone to decide whether BEAM resources converged. If a relevant dimension is not measured, record it as UNMEASURED and do not claim runtime safety, convergence, or capacity for that dimension. Unrelated or documentation-only changes may mark this review not applicable with a short reason.
