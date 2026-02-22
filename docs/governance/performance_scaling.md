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
- Safe under 100k concurrent users?
- DB indexes required?
- Redis representation needed?
- Can this be streamed instead of loaded?
