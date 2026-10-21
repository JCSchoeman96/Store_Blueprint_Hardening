# ENT-T1: Entitlement temporal read and projection refresh boundary

Status: **ENT_T1 DESIGN PASS / IMPLEMENTATION NOT AUTHORIZED PENDING AUTHORITY ACCEPTANCE**

Base reviewed: `da0dfa9b022f26872efe1f17277e62769c6c0808`

This design supplements JC-342 / SBH-50. It does not revise the AccessEffect contract or authorize implementation. ENT-T1 freezes entitlement read semantics and a per-LiveView boundary timer. Runtime work remains gated on explicit authority acceptance. JC-245/246 future convergence remains blocked pending that acceptance and implementation of the read gate.

## 1. Purpose and bounded scope

Entitlement reads must honor both validity boundaries. A future AccessEffect executor may persist an authoritative start, but the current `EntitlementSet.effective_grants/2` ignores `valid_from_at`. This design specifies the read contract needed before future-dated grants can safely be admitted.

This authority covers:

- the half-open temporal interval for a grant;
- deterministic evaluation at an explicit `as_of` instant;
- separation of raw Cachex rows from time-derived projections;
- the unused `scopes_by_kind` projection;
- the gate for future exact-source AccessEffect convergence;
- nearest-boundary refresh of connected LiveView projections with one-shot per-view timers.

It does not implement JC-245/246, change AccessEffect lifecycle or fingerprints, add target sets, or authorize runtime implementation.

## 2. Current evidence

`EntitlementGrant` stores non-null `valid_from_at` and nullable `valid_to_at` (`lib/store/entitlements/entitlement_grant.ex`). Its legacy and strict issue helpers assign `valid_from_at` from call-time UTC (`lib/store/entitlements/facade.ex`). The strict upsert does not update that start field on replay (`lib/store/entitlements/entitlement_grant.ex`, `:issue` action).

`EntitlementSet.effective_grants/2` currently checks active status, absence of revocation, and `valid_to_at > now`; it does not check the start (`lib/store/entitlements/types/entitlement_set.ex`). The end boundary is already exclusive. The start boundary is currently unenforced.

Cachex stores the full raw `EntitlementSet` for 60 seconds. Its TTL expires an entry; it does not refresh it or broadcast an event (`lib/store/entitlements/cache.ex`). The `expires_at` field is metadata and is not checked by `Cache.fetch`. `scopes_by_kind` is computed once when the set is built (`lib/store/entitlements/facade.ex`) and has no production or test consumers. It is a materialized temporal projection that can go stale while the raw grant rows remain valid cache contents.

Connected LiveViews keep entitlement sets in assigns and refresh them on write-driven PubSub invalidation. The subscriptions index also keeps a materialized `entitlements` list and recomputes it on invalidation. There is no timer or boundary event for `valid_from_at` or `valid_to_at`. No production caller supplies `required_entitlement` to the invalidation helper.

Existing entitlement tests cover end expiry when a held set is checked again, write invalidation, a suspension invalidation, and single-flight cache misses. They do not cover future starts, exact start/end equality, explicit `as_of`, TTL refresh, or no-write LiveView refresh.

## 3. Frozen temporal contract

The valid interval is half-open:

```text
[valid_from_at, valid_to_at)
```

For a grant to be effective at `as_of`:

1. `status == :active`;
2. `revoked_at == nil`;
3. `valid_from_at` is present;
4. `valid_from_at <= as_of`;
5. `valid_to_at == nil OR as_of < valid_to_at`.

The start is inclusive. The end is exclusive. A missing start fails closed, including for historical or malformed rows. No code may substitute fetch time, worker time, wall-clock time, or a default for a missing start while evaluating a grant.

Every temporal evaluation takes an explicit `as_of: DateTime` value. Callers capture one UTC instant for a logical projection and pass the same instant to each filter or membership check in that operation. `DateTime` comparisons compare instants, including values represented with a UTC offset. Grant timestamps use `:utc_datetime_usec`; comparisons preserve exact microsecond values and do not round or truncate them. The evaluator does not read the clock internally.

The canonical APIs are:

```elixir
effective_grants(set, as_of)
has_entitlement?(set, kind, scope_key, as_of)
next_temporal_boundary(set, as_of)
```

All three require explicit `as_of`; none has a hidden clock default. `next_temporal_boundary/2` returns the earliest future instant at which the effective grant list can change, or nil. For an active, unrevoked grant whose start is after `as_of`, the start is a candidate only when the end is absent or strictly later than the start. For a currently effective active, unrevoked grant, its end is a candidate. Expired, revoked, inactive, missing-start, and never-effective rows do not contribute.

The existing API's default `DateTime.utc_now()` is removed from the evaluator. A small caller helper may capture the current instant at a request/event boundary, but temporal rules remain explicit and deterministic at the evaluator boundary. No floating-point time arithmetic is permitted.

## 4. Cache and projection contract

### 4.1 Raw cache contents

Cachex may retain the fetched raw grant rows and fetch metadata. A cached set is not proof that every grant in it is effective at every later instant. Every read projection filters its raw grants using the caller's explicit `as_of`.

Cache TTL remains a memory/freshness policy for database rows. It is not a validity-boundary timer and must not be presented as one. Expiration of a Cachex entry alone does not notify or refresh connected LiveViews.

### 4.2 Materialized projections

`scopes_by_kind` is unused outside its construction and should be removed from `EntitlementSet` and its builder in the eventual implementation. Reintroducing it requires a production caller and a defined refresh rule. Any future materialized entitlement list must be derived from raw grants at a specific `as_of` and must not be reused across a different `as_of` without re-filtering.

If a later cache stores an already-filtered effective projection, its TTL must not extend beyond the earliest relevant future boundary:

```text
effective_ttl = min(normal_cache_ttl, next_boundary - as_of)
```

`next_boundary` is the earliest future `valid_from_at` or `valid_to_at` that can change the projection. Expiry alone does not refresh a connected LiveView or publish an event. The current Cachex value is a raw grant set, so it may span a time boundary while each decision re-filters it with a fresh explicit `as_of`.

For a UI that renders a list, compute the list from raw cached grants at one captured `as_of`. A future view may retain the raw set and the list, but the list's associated `as_of` must be explicit. Once a known validity boundary passes, an already-materialized projection is non-authoritative until refreshed. Refresh is scheduled at the boundary, but scheduler, mailbox, or load delay can temporarily leave rendered UI stale. Authorization checks independently reevaluate raw grants at a fresh explicit `as_of`; timer delivery is not correctness authority.

### 4.3 Authorization reads

Server-side access decisions must evaluate the grant against a fresh, explicitly captured `as_of` at the decision point. LiveView assigns are presentation state, not authorization authority. A prior assignment cannot authorize later server events without re-evaluation. This rule is independent of any UI refresh mechanism.

## 5. JC-245 future grant admission gate

JC-342 persists immutable AccessEffect start evidence but explicitly leaves entitlement read-side enforcement to downstream work. Until ENT-T1's temporal evaluator is implemented and covered, JC-245 must not project a future-dated effective target into an active `EntitlementGrant`.

When admitted later, exact-source convergence must:

- select the current AccessEffect under the existing source/version and stale-target rules;
- take `valid_from_at` and `valid_until_at` from that exact durable target;
- reject a missing start for an effective entitlement target;
- reject a bounded interval unless `valid_from_at < valid_until_at`;
- upsert only the exact source grant identity and preserve replay safety;
- avoid deriving or changing temporal fields from worker execution time;
- rely on the read contract above to keep a future-start grant ineffective before its start.

An executor must never make an old or superseded AccessEffect current merely to avoid a temporal gap. Existing source locks, transaction composition, and stale-write protections remain authoritative. If exact-source target evidence is absent or contradictory, fail closed and leave the grant projection unchanged.

## 6. Conceptual entitlement lifecycle

The conceptual states below are read-time classifications. The persisted `EntitlementStatus` enum currently contains `:active`, `:revoked`, and `:expired`; it does not persist `FUTURE`, `EFFECTIVE`, or `ENDED` as separate states.

### STATES

- `REVOKED`: `status == :revoked OR revoked_at != nil`.
- `ENDED`: `status == :expired OR (valid_to_at != nil AND as_of >= valid_to_at)`.
- `INACTIVE`: non-active/unclassifiable status, missing `valid_from_at`, or any fail-closed temporal input.
- `FUTURE`: active and unrevoked, start is present, `as_of < valid_from_at`, and not ended/revoked.
- `EFFECTIVE`: active and unrevoked, start is present, `valid_from_at <= as_of`, and end is absent or `as_of < valid_to_at`.

Classification precedence is `REVOKED`, then `ENDED`, then `INACTIVE`, then `FUTURE` or `EFFECTIVE`. Revocation therefore dominates an otherwise valid interval. An expired status or reached end dominates the temporal classification. Nil start fails closed even when end is nil.

### TRANSITIONS

- `FUTURE → EFFECTIVE` when `as_of == valid_from_at`, with no write.
- `EFFECTIVE → ENDED` when `as_of == valid_to_at`, with no write.
- `FUTURE → ENDED` if its end is reached before its start, though a newly established effective target must reject such an inverted interval.
- Any non-revoked state → `REVOKED` when persisted status becomes revoked or `revoked_at` becomes non-nil.
- Any non-revoked state → `ENDED` when persisted status becomes expired.

### TRANSITION_GUARDS

- `valid_from_at` is required to classify a grant as `FUTURE` or `EFFECTIVE`.
- Comparisons use `DateTime` instants, normalized to UTC without rounding. Entitlement resource fields use `:utc_datetime_usec`; equality is evaluated at exact microsecond precision.
- Start equality is effective: `valid_from_at == as_of` means `EFFECTIVE`.
- End equality is ended: `valid_to_at == as_of` means `ENDED`.
- Non-active or unclassifiable statuses fail closed as `INACTIVE`, except explicit `:revoked` and `:expired` classifications above.
- A fresh grant read is not required for a time-only transition; the same raw row can cross `FUTURE → EFFECTIVE` or `EFFECTIVE → ENDED` as `as_of` changes.

### SIDE_EFFECTS

- Time-only `FUTURE → EFFECTIVE` and `EFFECTIVE → ENDED` cause no database write, AccessEffect mutation, cache invalidation, or PubSub broadcast.
- Persisted revocation/expiry remains a write transition and uses existing write invalidation behavior.
- A matching LiveView boundary timer updates only that view's materialized projection and schedules the next boundary. It does not mutate durable state or call Cachex, PubSub, Redis, or Oban.

### TERMINAL_STATES

- `REVOKED` and `ENDED` are terminal for the particular grant row's read classification.
- A later commercial target is represented by the existing source-convergence rules and a later/current grant target, not by reopening an ended or revoked row through read-time evaluation.
- `INACTIVE` and `FUTURE` are not terminal classifications; they may become effective as time advances only when a valid start exists and no end/revocation guard prevents it.

## 7. LiveView refresh strategy decision

The refresh question concerns presentation assigns and boundary-triggered UI behavior. It does not change the requirement to re-evaluate authorization at each server-side decision.

The required choices are A through D. A is selected with explicit bounds. The comparison ranks each option for the listed dimensions. Rankings are qualitative because 100,000-connection capacity remains unmeasured.

| Choice | UI boundary correctness | Complexity | 100k timers/processes | DB load | PubSub fanout | Horizontal nodes | Failure recovery | Herd risk |
|---|---|---|---|---|---|---|---|---|
| A. Per-LiveView timer, selected | Read semantics are exact at explicit `as_of`; rendered projection can be temporarily stale if handling is delayed; authorization rechecks independently. | Moderate: one ref, generation token, cancel/replace, and local re-arm. | At most one active timer per relevant connected view, up to 100,000 timer entries at 100,000 relevant views. Timers do not create one BEAM process each. Memory and throughput remain unmeasured. | Zero boundary DB load; timer reads its assigned raw set only. | Zero PubSub fanout; each view updates locally. | Each node owns timers for its local views; no shared registry. | View/node restart loses the timer; mount reconstructs it from the fetched raw set. | Coincident cohorts may cluster up to O(N) expiration, re-arm, and render work. |
| B. Shared node-level scheduler | Can refresh local views at boundaries if every relevant view/boundary is tracked. | High scheduler, registration, deduplication, and reconnect complexity. | Fewer timer entries but O(N) registrations; memory unmeasured. | Boundary scanning may add DB load. | O(N) possible coincident fanout. | Requires node ownership and cross-node duplicate rules. | In-memory schedule is lost on restart unless rebuilt. | High without grouping; grouping delays boundaries. |
| C. Durable scheduled worker/broadcast | Durable work can recover after restart, subject to queue delay and exact targeting. | Highest: uniqueness, cancel/supersession, retries, broadcast coordination. | Can create O(N) jobs or registrations; queue/worker capacity unmeasured. | Target selection may add high reads. | O(N) possible cohort fanout. | Requires cross-node duplicate delivery rules. | Stronger retry/recovery, but stale-job suppression and reconciliation are needed. | High for coincident cohorts; batching adds staleness. |
| D. Display staleness until next event | Server reads can remain correct if every decision re-evaluates at fresh `as_of`; idle display remains stale. | Lowest. | No boundary timers or new processes. | No boundary DB reads. | No boundary broadcast. | No shared timer state. | No schedule to recover. | No timer herd; next-event traffic can spike. |

For each ranking below, 1 is the best fit for that dimension. These are architecture rankings, not measured capacity claims:

- UI boundary freshness: A, B, C, D.
- Implementation complexity: D, A, B, C.
- Timer and process cardinality at 100,000 views: D, B, C, A. A adds timer entries, not one process per timer.
- Added database load: D, A, B, C.
- PubSub fanout: D and A tie, then B, then C.
- Horizontal node operation: D, C, A, B.
- Failure recovery: C, D, A and B tie.
- Thundering-herd risk: D, B, A and C tie.

A is selected because each relevant LiveView derives its own next boundary from its assigned raw set, with no shared registry, DB read, Cachex fetch, or broadcast. B and C add coordination and selection/fanout paths without evidence that they improve the required user-visible behavior enough to justify their complexity. D does not meet the requested boundary refresh behavior. At 100,000 views A has at most 100,000 active timer entries, one per relevant view, and no additional BEAM process per timer. Coincident cohorts may cluster expirations, re-arms, and rendering. Timer, mailbox, and rendering capacity remain **UNMEASURED**. Boundary expiration creates no DB, Cachex, Redis, Oban, or PubSub amplification. This architecture passes with constraints; it is not a throughput certification.

### Timer lifecycle and horizon

- A relevant connected LiveView is one that holds a materialized entitlement projection for rendering and whose assigned raw set can change that projection at a future start or end boundary. Views without such a projection schedule no temporal timer.
- Maintain at most one active one-shot timer per relevant connected view. If no relevant future boundary exists, cancel and clear the timer.
- `next_temporal_boundary(set, as_of)` returns the earliest future boundary that can change the effective grant list. An active, unrevoked future grant contributes its start only if its end is absent or later than its start. A currently effective grant contributes its end. Revoked, inactive, expired, nil-start, and never-effective intervals contribute no boundary.
- Lifecycle transitions are `NO_TIMER → SCHEDULED` when a relevant connected view has a future boundary; `SCHEDULED → REARM → SCHEDULED` on a pre-boundary chunk expiry; `SCHEDULED → REFRESHING` at the actual boundary; set replacement enters `REPLACED`; and `REFRESHING` or `REPLACED` transitions to `SCHEDULED` if a future boundary remains, otherwise `NO_TIMER`.
- Before scheduling or after set replacement, capture one UTC `as_of` and derive the current projection plus its next boundary. If `next_temporal_boundary/2` or a boundary carried from a prior calculation is `<= as_of`, immediately refresh in process from the held raw set, capture a fresh UTC `as_of`, and derive again. Never schedule delay zero or enter a zero-delay loop.
- Use `:erlang.start_timer/3`, whose timeout message carries the runtime `TimerRef`; include a monotonically increasing generation token in its message payload. Set replacement enters `REPLACED`, attempts to cancel the previous timer, and increments generation. Cancellation is best effort. Ignore a message unless both timer reference and generation match current state.
- On a chunk message, capture a fresh UTC `as_of` and compare it with the stored target. If the boundary remains future, take `REARM` and schedule the remaining chunk locally without evaluating grants or authorization or fetching data. If scheduling or mailbox delay means the actual boundary has passed, take `REFRESHING` in that same handler. Both paths perform zero DB queries, Cachex fetches, PubSub broadcasts, Redis operations, Oban work, or durable mutations.
- At the actual boundary, capture one explicit UTC `as_of`, reevaluate the held raw set, update the materialized LiveView projection, and derive the next boundary. This path also performs zero DB queries, Cachex fetches, PubSub broadcasts, Redis operations, Oban work, or durable mutations.
- A write invalidation keeps the existing post-commit Cachex invalidation and PubSub flow. The view fetches the refreshed set and enters `REPLACED`; it then derives and schedules from the new set.
- `REFRESHING` or `REPLACED` transitions to `SCHEDULED` if a future boundary remains, otherwise to `NO_TIMER`.
- LiveView process termination is terminal. Since the timer targets the view PID, the runtime cancels that timer when the process exits. Mount reconstructs a timer from the fetched raw set.
- No jitter is added past the authoritative boundary. Runtime scheduling and mailbox load can still delay message handling. A passed boundary makes the stored projection non-authoritative until refresh. Rendered UI may be temporarily stale; authorization independently reevaluates raw grants at a fresh explicit `as_of` and never depends on timer delivery.
- Official OTP 28 documentation for [`erlang:start_timer/3`](https://www.erlang.org/docs/28/apps/erts/erlang.html#start_timer/3) specifies a nonnegative integer millisecond delay and delivers the timer reference with the timeout message. Relative timers use monotonic time. The public docs do not specify a numeric maximum. This repository pins Erlang/OTP 28.3 and Elixir 1.19.5-otp-28.
- Freeze `MAX_SCHEDULE_CHUNK_MS=86400000`. This is a conservative bounded re-arm application policy, not the OTP maximum. If a boundary is farther away, arm one chunk. On chunk expiry, use `REARM`; do not filter the set, evaluate authorization, or fetch data. Repeat locally until the actual boundary. Do not discover or adapt to a larger OTP maximum.
- Convert remaining microseconds to an integer delay by rounding up to milliseconds. Add no randomized or policy delay past the boundary. Millisecond rounding can schedule a wake less than one millisecond after the exact microsecond boundary; runtime or mailbox delay can add lateness. Entitlement reads retain exact microsecond semantics; the timer is only a projection refresh hint.

## 8. Current test coverage matrix

Status meanings: `PRESENT` means a test directly covers the case; `INSUFFICIENT` means related behavior is tested but not the stated boundary; `MISSING` means no matching test was found; `CONTRADICTORY` means current implementation behavior contradicts the required contract.

| Case | Current status | Evidence / gap |
|---|---|---|
| Future start before start | `CONTRADICTORY` | Evaluator ignores `valid_from_at`; no future-start test. |
| Exact start equality | `MISSING` | No equality test. |
| One microsecond before start | `MISSING` | No one-microsecond test. |
| Exact end equality | `INSUFFICIENT` | Implementation uses exclusive end, but existing test checks after a sleep rather than equality. |
| One microsecond before end | `MISSING` | No one-microsecond test. |
| One microsecond after end | `INSUFFICIENT` | Sleep-based end-expiry test is not an exact one-microsecond assertion. |
| Nil start | `MISSING` | Schema disallows nil, but evaluator has no fail-closed behavior test for malformed/legacy structs. |
| Nil end | `INSUFFICIENT` | Implementation treats nil end as open-ended; no dedicated case found. |
| Revoked grant | `INSUFFICIENT` | Write invalidation tests verify revoked grant is no longer effective, but no direct boundary matrix. |
| Inactive/expired status with otherwise active interval | `INSUFFICIENT` | Status check exists; no complete status/interval matrix found. |
| Overlapping grants | `MISSING` | No overlap test found. |
| Mixed current and future grants | `MISSING` | No mixed-set boundary test found. |
| Cached start crossing without write | `MISSING` | No future-start cache test. |
| Cached end crossing without write | `INSUFFICIENT` | Held set is checked after a sleep; no exact boundary. |
| Explicit `as_of` determinism | `MISSING` | API accepts a DateTime argument, but tests do not provide deterministic `as_of` cases. |
| Materialized projection refresh at start | `MISSING` | `scopes_by_kind` is built once; no boundary refresh event/test. |
| Materialized projection refresh at end | `MISSING` | No boundary refresh event/test. |

No tests were run or added for this audit or design update.

## 9. Frozen future test contract

The later implementation tests must cover all of the following with fixed `DateTime` instants and no sleep:

- start 1 microsecond before `as_of`, exactly at `as_of`, and 1 microsecond after `as_of`;
- end 1 microsecond before `as_of`, exactly at `as_of`, and 1 microsecond after `as_of`;
- nil start failing closed and nil end remaining open-ended;
- revoked, non-active, and expired grants with otherwise active intervals;
- multiple overlapping current grants and a set mixing current, future, ended, revoked, and open-ended grants;
- reuse of one raw cached set across start and end boundaries at distinct `as_of` instants, without a database refetch;
- deterministic output for repeated evaluation at the same explicit `as_of`;
- materialized projection refresh at start and end through a controllable timer/message, with zero DB/cache reads, correct boundary derivation, timer replacement, stale reference/generation rejection, and long-horizon local re-arm without early set evaluation;
- stale/superseded AccessEffect rejection in the future executor's separately authorized tests.

The timer/message projection tests use a controllable message/timer seam, not sleep. A horizon-chunk message before the actual boundary only re-arms locally and does not reevaluate the set.

## 10. Runtime and test paths

The exact runtime files proposed for authority acceptance are:

- `lib/store/entitlements/types/entitlement_set.ex` for explicit `as_of` filtering;
- `lib/store/entitlements/facade.ex` for raw set construction and removal of `scopes_by_kind`;
- `lib/store_web/live/entitlement_aware.ex` to pass a captured `as_of` to membership checks and to re-evaluate server decisions;
- `lib/store_web/live/subscriptions_live/index.ex` to pass `as_of` to the displayed grant projection and address the stored `@entitlements` list;
- no other runtime file. In particular, `lib/store/entitlements/cache.ex` is not in scope.

The exact focused test paths proposed for authority acceptance are:

- `test/store/entitlements/types/entitlement_set_test.exs`;
- `test/store/entitlements/facade_test.exs`;
- `test/store_web/live/subscriptions_live_test.exs`.

`SubscriptionsLive.Index` currently materializes an `entitlements` assign during `handle_params` and refreshes it only on write invalidation. It must update this projection on matching start/end timer messages. `EntitlementAware` currently calls `has_entitlement?` without an explicit instant. Its per-user write invalidation remains separate from the local boundary timer.

Present authorized runtime and test paths: **NONE_PENDING_AUTHORITY_ACCEPTANCE**. This design passes its technical review but authorizes no code or tests until the human accepts the authority.

## 11. Performance and scaling review

The implementation plan may touch only the four runtime files and three test files listed in §10. No additional runtime or test path is authorized by this design.

Required tests include:

- start strictly before `as_of` is effective;
- start exactly equal to `as_of` is effective;
- start after `as_of` is ineffective;
- end strictly after `as_of` is effective;
- end exactly equal to `as_of` is ineffective;
- end before `as_of` is ineffective;
- nil end is open-ended;
- nil start fails closed;
- revoked and non-active grants are ineffective at all boundaries;
- `as_of` is explicit, deterministic, and canonicalized to UTC microseconds;
- the same raw cached set yields different correct projections at different `as_of` values without a database refetch;
- `scopes_by_kind` has no remaining consumer and is removed, or a newly evidenced consumer derives it per `as_of`;
- the Cachex TTL does not masquerade as a validity event;
- a future-start exact-source grant remains ineffective before start and becomes effective at start without mutation;
- stale or superseded AccessEffect state cannot be projected by the future executor. This executor case remains outside ENT-T1 implementation unless separately authorized.

Do not use sleeps for boundary correctness tests. Use fixed instants and explicit `as_of` values. Do not run broad or unrelated suites as a substitute for focused contract coverage.

**Hot/warm/cold:** grant filtering and timer boundary handling are hot in-memory operations over the assigned raw set. Cachex is warm and stores raw rows. PostgreSQL grant rows and AccessEffect targets remain cold durable authority.

**Query count and N+1:** explicit time filtering must add zero database queries. Projection over an already loaded set is one in-memory pass, O(number of that user's cached grants). No per-grant lookup is allowed. Preserve the current one-query cache miss path and single-flight behavior.

**Indexes:** the existing user/kind/scope/status and source indexes remain unchanged. Do not add a `valid_from_at` index for in-memory filtering. A future boundary dispatcher would need query-plan evidence before any index proposal.

**Cache, TTL, invalidation:** retain the current 60-second TTL as row-cache policy unless later measurements justify a change. Never use it as a boundary scheduler. No new cache key, Redis/ETS state, or stampede mechanism is authorized here. Write invalidation remains post-commit.

**Oban uniqueness/idempotency:** ENT-T1 adds no job or worker. Future boundary notification work must specify uniqueness and replay behavior separately.

**Telemetry:** focused tests must establish zero Repo queries and zero Cachex fetches during a boundary timer handler. At 100,000 relevant connected views, the architecture allows at most 100,000 one-shot timer entries and no process per timer. Capacity remains **UNMEASURED**; no throughput or convergence claim is permitted without equivalent bounded repetitions measuring timer memory, GC, callback latency, mailbox behavior, disconnect cleanup, and post-load convergence.

## 12. Runtime resource safety review

One-shot timers add timer entries and messages but no process per timer, worker, database connection, or external resource. The implementation PR must include a Runtime Resource Safety Review for timer memory, scheduler load, GC, mailbox backlog, cancellation on disconnect/set replacement, and post-load convergence. Capacity remains UNMEASURED until at least two equivalent bounded repetitions are run.

## 13. Decision and stop conditions

Frozen by this design: half-open interval `[valid_from_at, valid_to_at)`, inclusive start, exclusive end, missing start fails closed, explicit `as_of`, raw cache rows separated from time-derived projections, and exact-source future grant gating.

Architecture decision: A, one nearest-boundary one-shot timer per relevant connected LiveView, is frozen with the bounds in §7. ENT_T1 is **PASS** as a design authority. Implementation remains unauthorized pending human authority acceptance. JC-245/246 remains blocked until that acceptance and the read-side gate are complete. 100,000-view capacity remains UNMEASURED.

## 14. Machine-readable result

```text
ENT_T1_BASE=da0dfa9b022f26872efe1f17277e62769c6c0808
TEMPORAL_INTERVAL=[valid_from_at,valid_to_at)
START_INCLUSIVE=YES
END_EXCLUSIVE=YES
NIL_START_FAILS_CLOSED=YES
CANONICAL_AS_OF=EXPLICIT
RAW_CACHE_MAY_CROSS_BOUNDARY=YES
MATERIALIZED_PROJECTION_AUTHORITY_AFTER_BOUNDARY=NO
BOUNDARY_REFRESH_SCHEDULED=YES
TEMPORARY_UI_STALENESS_UNDER_SCHEDULING_DELAY=POSSIBLE
AUTHORIZATION_CORRECTNESS_DEPENDS_ON_TIMER=NO
SCOPES_BY_KIND_DISPOSITION=remove
LIVEVIEW_BOUNDARY_STRATEGY=PER_LIVEVIEW_NEAREST_BOUNDARY_ONE_SHOT_TIMER
100K_TIMER_REVIEW=ARCHITECTURE_PASS_WITH_CONSTRAINTS
100K_TIMER_CONSTRAINTS=MAX_ONE_ACTIVE_TIMER_PER_RELEVANT_CONNECTED_VIEW; UP_TO_100000_TIMER_ENTRIES; NO_PROCESS_PER_TIMER
100K_MEASURED_CAPACITY=UNMEASURED
100K_RESIDUAL_RISK=COINCIDENT_COHORT_MAY_CLUSTER_EXPIRATIONS_REARMS; TIMER_MAILBOX_RENDER_CAPACITY_UNMEASURED; NO_DB_CACHE_REDIS_OBAN_PUBSUB_AMPLIFICATION
MAX_SCHEDULE_CHUNK_MS=86400000
MAX_SCHEDULE_CHUNK_RATIONALE=CONSERVATIVE_BOUNDED_REARM_APPLICATION_POLICY; NOT_OTP_MAXIMUM
IMPLEMENTATION_OTP_CHECK=VERIFY_PINNED_OTP28_3_TIMER_API_AND_CANCEL_SEMANTICS
MAX_ACTIVE_TEMPORAL_TIMERS_PER_LIVEVIEW=1
TIMER_LIFECYCLE=NO_TIMER_TO_SCHEDULED; CHUNK_EXPIRY_TO_REARM_IF_FUTURE_ELSE_REFRESHING; ACTUAL_BOUNDARY_TO_REFRESHING; SET_REPLACEMENT_TO_REPLACED; FUTURE_BOUNDARY_REMAINS_TO_SCHEDULED_ELSE_NO_TIMER; PROCESS_TERMINATION_TERMINAL
TIMER_SIDE_EFFECTS=ZERO_DB_CACHE_PUBSUB_REDIS_OBAN_OR_DURABLE_MUTATION
BOUNDARY_TIMER_DB_CALLS=0
BOUNDARY_TIMER_CACHE_FETCHES=0
BOUNDARY_TIMER_PUBSUB_BROADCASTS=0
FUTURE_GRANT_REQUIRES_START_MUTATION=NO
JC245_MAY_WRITE_FUTURE_GRANT=YES
JC245_REQUIRES_EXACT_ACCESSEFFECT_START=YES
RAW_CACHE_REEVALUATED_ON_ACCESS=YES
SHARED_SCHEDULER=NO
REDIS_SCHEDULER=NO
OBAN_ACTIVATION=NO
POLLING=NO
AUTHORIZED_RUNTIME_PATHS=NONE_PENDING_AUTHORITY_ACCEPTANCE
AUTHORIZED_TEST_PATHS=NONE_PENDING_AUTHORITY_ACCEPTANCE
PROPOSED_RUNTIME_PATHS=lib/store/entitlements/types/entitlement_set.ex; lib/store/entitlements/facade.ex; lib/store_web/live/entitlement_aware.ex; lib/store_web/live/subscriptions_live/index.ex
PROPOSED_TEST_PATHS=test/store/entitlements/types/entitlement_set_test.exs; test/store/entitlements/facade_test.exs; test/store_web/live/subscriptions_live_test.exs
SCHEMA_CHANGE=NO
MIGRATION=NO
REDIS_CHANGE=NO
OBAN_ACTIVATION_JOB=NO
JC245_246_CURRENT_STATUS=BLOCKED_PENDING_ENT_T1_AUTHORITY_ACCEPTANCE_AND_READ_GATE
ENT_T1=PASS
NEXT_ACTION=STOP_FOR_AUTHORITY_REVIEW
RUNTIME_CODE_CHANGED=NO
DOCS_CHANGED=YES
REFS_CHANGED=NO
TESTS_RUN=NO
BASE_SHA=da0dfa9b022f26872efe1f17277e62769c6c0808
```
