# Governance: Performance & Scaling (Required companion)
Single-tenant does not mean “low traffic”. This doc standardizes planning for hot paths.

`AGENTS.md` is the process authority. Phase 29 is the detailed performance and
runtime resource safety authority. This file is the short mandatory companion
checklist and must remain aligned with both.

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

## Memory, GC & Runtime Resource Safety (MANDATORY)

Treat runtime resource safety as a permanent part of every runtime-relevant plan,
implementation, and performance review. Check each applicable resource explicitly.

- **Process lifetime:** bound process creation, verify expected termination, and
  prove that Tasks and workers cannot become orphaned.
- **Process memory:** investigate unexplained monotonic heap growth and keep
  long-lived process memory bounded.
- **Mailboxes:** keep `message_queue_len` bounded under supported load. A
  long-lived consumer must not accumulate messages indefinitely.
- **GenServers:** bound in-memory state and prevent unbounded event or history
  accumulation.
- **ETS:** name the owner, bound table size, and name the cleanup or TTL owner.
- **Binaries:** inspect large-binary and sub-binary retention risks.
- **Atoms:** never create atoms dynamically from user-controlled input. Atom
  growth must remain bounded.
- **Cache:** give Cachex and ETS entries bounded capacity, TTL, and eviction
  where appropriate.
- **Redis:** give queues, leases, metadata, fences, and hot keys explicit
  retention and cleanup rules.
- **Oban:** bound backlog, retries, dead jobs, uniqueness windows, and cleanup.
- **LiveView:** bound socket assigns and state, and clean up subscriptions and
  processes when clients disconnect.
- **PubSub:** bound subscriber and process lifetimes and remove stale
  subscriptions.
- **Timers and monitors:** prevent timer and monitor accumulation.
- **Ports and NIFs:** make lifecycle and cleanup explicit wherever used.
- **GC:** monitor minor and full-sweep behavior, avoid oversized long-lived
  heaps, and identify GC-driven latency spikes and excessive allocation churn.
- **Resource leaks:** check processes, ETS tables, ports, timers, telemetry
  handlers, subscriptions, workers, and caches.

### Permanent invariants

- **PERF-MEM-001:** After a bounded workload and cooldown or expiry period,
  memory, process counts, mailbox depths, ETS/cache state, and transient
  coordination state must converge toward a stable post-load baseline instead of
  increasing monotonically across equivalent runs.
- **PERF-GC-001:** Hot and long-lived processes must not require continuously
  expanding heaps or excessive major or full-sweep garbage collection to sustain
  supported throughput.
- **PERF-MBOX-001:** No long-lived process may accumulate an unbounded mailbox
  under supported load.
- **PERF-RESOURCE-001:** Processes, Tasks, timers, ETS tables, telemetry
  handlers, PubSub subscriptions, leases, fences, cache entries, and other
  transient resources must have explicit ownership and bounded cleanup.

### Runtime measurement requirement

For relevant load or soak evidence, record measurements at all three points:

1. **Baseline before load**
2. **Peak load**
3. **Post-load cooldown or drain**

Where feasible, record BEAM total memory, process memory, binary memory, ETS
memory, atom memory, process count, port count, ETS table count, and for hot
processes memory, `heap_size`, `total_heap_size`, `message_queue_len`, and
reductions. Record GC behavior as well. At each window, also record applicable
resource cardinalities such as active Tasks/workers, timer and monitor counts,
ETS entries, Cachex entries and capacity, Redis keys/queues/leases/fences,
Oban ready/retry/scheduled/dead-job/backlog and uniqueness counts, LiveView
sockets/subscriptions, PubSub subscribers, and telemetry handlers.

The review must classify the observed failure mode as a memory leak, memory
bloat, memory churn or allocation churn, GC pressure, mailbox pressure, or
resource leak. A single peak sample is not evidence of a leak or of safe
post-load behavior.

### 100k and flash-sale review

Moving contention away from PostgreSQL is insufficient if the replacement creates
one BEAM process per waiter, one timer or monitor per unbounded request,
unbounded Redis state, unbounded ETS or cache state, unbounded Oban jobs, or
unbounded mailboxes. For high-concurrency designs, answer all four questions:

- Where does waiting state live?
- Is it bounded?
- Who cleans it up?
- What happens after cooldown?

## Performance & Scaling Review (MANDATORY for new actions)
For every new domain action, answer:
- DATA LAYER (hot/warm/cold)
- INDEXES
- CACHE
- REDIS STRUCTURE
- TTL
- INVALIDATION/CLEANUP
- PUBSUB
- STORE.REPO EFFECT
- 100K STATUS
- MEMORY: bounded process, ETS, cache, and transient resource state, where applicable
- GC: allocation, heap, and major or full-sweep considerations, where applicable
- MAILBOX: bounded long-lived process queues, where applicable
- RESOURCE CLEANUP: owner, expiry, and termination behavior, where applicable
- POST-LOAD: expected convergence after workload cooldown, where applicable
- Safe under 100k concurrent users?
- Can this be streamed instead of loaded?
