# Entitlement temporal read and projection refresh implementation plan

> **For agentic workers:** Use the accepted implementation authority and the execution workflow selected for the later implementation. ENT_T1 design passes, but do not execute until authority acceptance.

**Goal:** Make entitlement evaluation honor `[valid_from_at, valid_to_at)`, require an explicit evaluation instant, and define boundary refresh for materialized projections.

**Architecture:** PostgreSQL grant rows remain durable authority. Cachex retains raw grants that each decision filters using explicit `as_of`. Each relevant connected LiveView holds at most one nearest-boundary one-shot timer and recomputes its materialized projection locally from the assigned raw set. The timer performs no database/cache fetch, PubSub broadcast, or durable mutation. This plan is not executable until the human accepts the authority.

**Tech Stack:** Elixir, Phoenix LiveView, Ash 3.x, Cachex, ExUnit.

---

Status: **ENT_T1 DESIGN PASS / IMPLEMENTATION NOT AUTHORIZED PENDING AUTHORITY ACCEPTANCE**

Base reviewed: `da0dfa9b022f26872efe1f17277e62769c6c0808`

Design: `docs/superpowers/specs/2026-10-21-entitlements-temporal-read-boundary-design.md`

This is a future implementation plan, not execution authority. Per-LiveView nearest-boundary timers are the frozen design. Do not start implementation until the human accepts the design and plan as authority. JC-245/246 future grant convergence remains blocked until that acceptance and the read-side gate implementation.

## Global constraints

- `valid_from_at <= as_of` and `as_of < valid_to_at` when an end exists.
- Start is inclusive; end is exclusive.
- Nil start fails closed.
- Every evaluator call receives explicit `as_of`; no hidden wall-clock read occurs inside filtering.
- Cachex retains raw grants. Cache TTL does not refresh or notify at validity boundaries.
- Remove unused `scopes_by_kind`; if production use is discovered before implementation, stop and revise the design rather than retaining a stale projection by default.
- Use at most one active timer per relevant connected LiveView, and no timer when there is no future boundary that can change the effective grant set.
- A relevant view is connected and holds a materialized entitlement projection for rendering; views without that projection schedule no timer.
- Boundary timer handling evaluates the assigned raw set at one explicit `as_of`; it performs zero DB queries, Cachex fetches, PubSub broadcasts, Redis operations, Oban work, or durable mutations.
- Timer messages carry a timer reference and generation token. Set refresh cancels/replaces and advances generation; stale messages are ignored.
- Once a known boundary passes, the stored projection is non-authoritative until refresh. Scheduling or mailbox delay may temporarily leave rendered UI stale; authorization independently reevaluates raw grants at a fresh explicit `as_of` and never depends on timer delivery.
- No jitter is added past the authoritative boundary. Timer delivery can be late under scheduler/mailbox load.
- Freeze `MAX_SCHEDULE_CHUNK_MS=86400000` as a conservative bounded re-arm application policy, not an OTP maximum. Re-arm locally without grant or authorization evaluation, or fetching data, before the true boundary.
- No scheduler registry, boundary worker, index, Redis/ETS store, Oban activation job, polling, status mutation, new lifecycle state, schema, or migration.
- Keep Cachex raw-set contents and 60-second TTL unchanged; write invalidation remains post-commit and PubSub write-driven.
- 100,000-view architecture is bounded to at most 100,000 timer entries and no process per timer. Capacity remains UNMEASURED; no throughput claim.
- Future exact-source JC-245 behavior remains gated on this read contract and must use immutable AccessEffect interval evidence.

## Review focus

Review raw Cachex rows separately from materialized LiveView projections. Verify that each logical entitlement decision captures one explicit `as_of`, and that timer messages only refresh presentation from the held raw set. Check source identity, stale-target rules, and exact AccessEffect interval evidence before any later JC-245 implementation. No implementation starts until the human accepts this design and plan.

## Proposed file boundary after review

### Modify

- `lib/store/entitlements/types/entitlement_set.ex`
  - Require `as_of` for temporal evaluation.
  - Implement inclusive start and exclusive end checks with nil-start fail-closed behavior.
  - Add `next_temporal_boundary(set, as_of)` using only boundaries that can change the effective grant list.
  - Keep membership checks tied to the same explicit instant.
  - Remove `scopes_by_kind` from the set if confirmed unused at implementation start.
- `lib/store/entitlements/facade.ex`
  - Build a raw-grants set without time-derived `scopes_by_kind`.
  - Preserve the one-query cache-miss behavior and single-flight semantics.
- `lib/store_web/live/entitlement_aware.ex`
  - Candidate future path: pass one captured `as_of` to membership checks.
  - Re-evaluate server-side decisions at event time rather than trusting an older assign.
- `lib/store_web/live/subscriptions_live/index.ex`
  - Candidate future path: pass one captured `as_of` when materializing displayed grants.
  - Recompute the `entitlements` assign on matching boundary messages and reschedule the next boundary.
- `test/store/entitlements/facade_test.exs`
  - Replace sleep-based temporal assertions with explicit fixed instants.
  - Cover raw cache reuse across two `as_of` values and existing invalidation behavior.
- Add `test/store/entitlements/types/entitlement_set_test.exs` for pure evaluator and next-boundary derivation tests.
- `test/store_web/live/subscriptions_live_test.exs` for explicit-time caller behavior and controllable boundary timer messages.

These four production files and the three focused test paths below are the complete proposed scope. Present authorized runtime/test paths are **NONE_PENDING_AUTHORITY_ACCEPTANCE** until the human accepts this design and plan.

### Do not modify under this plan

- `lib/store/entitlements/entitlement_grant.ex` or its schema/migration.
- AccessEffect resources, migrations, fingerprints, or lifecycle.
- Subscription executor/worker behavior.
- Any LiveView file beyond `entitlement_aware.ex` and `subscriptions_live/index.ex`.
- `lib/store/entitlements/cache.ex`; Cachex behavior and TTL remain unchanged.
- Cache TTL, Cachex structure, PubSub topics/messages, Oban, Redis, or ETS.
- Any NewYou target-set module.

If a server-side LiveView event uses an old assign as an authorization decision, stop and document the exact caller. Add only the narrowly required re-evaluation and regression test after review confirms it belongs in ENT-T1. Do not silently expand the file boundary.

## Task 1: Migrate temporal evaluation atomically to explicit `as_of`

**Files:** `lib/store/entitlements/types/entitlement_set.ex`, `lib/store/entitlements/facade.ex`, `lib/store_web/live/entitlement_aware.ex`, `lib/store_web/live/subscriptions_live/index.ex`, `test/store/entitlements/types/entitlement_set_test.exs`, `test/store/entitlements/facade_test.exs`, `test/store_web/live/subscriptions_live_test.exs`.

1. [ ] Add fixed-instant tests for `[valid_from_at, valid_to_at)`: one microsecond before, exact equality, and one microsecond after both edges; nil start/end; revoked, inactive, expired; overlapping and mixed grants; equivalent UTC instants with different offsets; and deterministic repeated evaluation at one `as_of`.
2. [ ] Run the focused evaluator and facade tests. Confirm RED for the missing-start predicate using the boundary tests. Record with a static signature/source check that implicit-time defaults still exist; do not claim those tests fail while explicit `as_of` arities remain accepted.
3. [ ] Implement `effective_grants(set, as_of)` and `has_entitlement?(set, kind, scope_key, as_of)` with required explicit `as_of`. Preserve exact `:utc_datetime_usec` comparisons, inclusive start, exclusive end, nil-start fail-closed behavior, and active/unrevoked status filtering.
4. [ ] While the old defaults still exist, migrate every production and test caller to the explicit API. Capture one UTC `as_of` per logical evaluation in `EntitlementAware` and `SubscriptionsLive.Index`; migrate facade tests and every `EntitlementSet` caller.
5. [ ] After the call-site migration, remove hidden default-time arities in the same atomic task. Remove `scopes_by_kind` from the set and builder after confirming it has no consumers. Keep Cachex raw rows and TTL unchanged. Test reuse of the same raw set across future-start and end boundaries with no second Repo query.
6. [ ] Search and xref all evaluator calls. Confirm no implicit-time caller or hidden wall-clock read remains, then rerun the focused evaluator, facade, and caller tests.

**RED→GREEN verification:** fixed-time boundary tests prove the missing-start defect RED. The static signature/source check records the pre-migration defaults. Migrate all callers while the defaults still exist, then remove those defaults in the same atomic task. Focused evaluator, facade, and caller tests plus the no-implicit-caller search establish GREEN only after all steps complete. Do not claim an intermediate GREEN.

**STOP:** if one caller cannot supply a coherent explicit instant within the four approved production files, stop and return to authority review before widening scope.

## Task 2: Add local materialized-projection boundary refresh

**Files:** `lib/store_web/live/entitlement_aware.ex`, `lib/store_web/live/subscriptions_live/index.ex`, `test/store_web/live/subscriptions_live_test.exs`.

1. [ ] Add controllable timer/message tests for no relevant boundary, exact start/end refresh, set replacement, timer cancellation, stale timer reference/generation, and local one-day chunk re-arm. Do not use sleeps.
2. [ ] Run the focused LiveView tests and confirm RED for missing boundary refresh.
3. [ ] On connected view assignment or set refresh, best-effort cancel the old timer, advance generation, and derive the current projection and next future boundary from the held raw set with one explicit UTC `as_of`.
4. [ ] If a derived or carried boundary is `<= as_of`, refresh the projection immediately in process, capture a fresh UTC `as_of`, and derive again. Never schedule delay zero or enter a zero-delay loop.
5. [ ] Keep `NO_TIMER` when no relevant future boundary can change the projection. Otherwise schedule one `:erlang.start_timer/3` one-shot timer with ref and generation. Use `MAX_SCHEDULE_CHUNK_MS=86400000`; do not add jitter or adaptive runtime behavior.
6. [ ] A pre-boundary chunk expiry captures fresh UTC `as_of` and compares only with the stored target. If still future, re-arm locally without grant/authorization evaluation or DB, Cachex, PubSub, Redis, Oban, or durable side effects. At the true boundary, evaluate the held set at one explicit `as_of`, refresh the materialized projection, and schedule the next boundary.
7. [ ] Ignore stale ref/generation messages. On set replacement, enter `REPLACED`, cancel best effort, increment generation, and schedule from the new set. Process termination is terminal; timers target the LiveView PID.
8. [ ] Round remaining microseconds up to integer milliseconds. This may wake less than one millisecond after the exact boundary; no policy or randomized delay is added. Runtime or mailbox delay may make the rendered UI temporarily stale. Authorization independently evaluates raw grants at a fresh explicit `as_of` and never depends on timer delivery.
9. [ ] Assert timer handlers perform zero Repo queries, Cachex fetches, PubSub broadcasts, Redis operations, Oban work, or durable mutations.

**RED→GREEN verification:** controllable timer tests fail before the boundary handler exists and pass after it handles start/end transitions, replacement, stale messages, and chunk re-arm. Confirm at most one active timer per relevant connected view, no timer otherwise, and zero I/O or durable side effects.

## Task 3: Audit the completed migration and runtime bounds

This is a verification task after Tasks 1 and 2, not a place to defer caller migration.

1. [ ] Re-run static search/xref for every `effective_grants` and `has_entitlement?` call and confirm explicit `as_of` at all production and test sites.
2. [ ] Confirm Cachex stores raw rows with the existing 60-second TTL and only post-commit write invalidation changes its contents.
3. [ ] Confirm the four production files and three test paths are the only changed runtime/test paths. Do not edit `lib/store/entitlements/cache.ex`.
4. [ ] Verify `MAX_SCHEDULE_CHUNK_MS=86400000` is the fixed application re-arm cap, and verify `:erlang.start_timer/3` API and cancellation semantics against pinned OTP 28.3. Do not claim a numeric OTP maximum or add adaptive behavior.
5. [ ] Record the Performance & Scaling Review and Runtime Resource Safety Review. At 100,000 relevant views, retain the architecture pass with constraints, but mark timer, mailbox, render capacity and throughput UNMEASURED. A coincident cohort may cluster expiration and re-arm work; boundary handling adds no DB, Cachex, Redis, Oban, or PubSub amplification.

**Acceptance:** audit evidence confirms all caller migrations, scope limits, and timer constraints. No capacity or throughput claim is made without at least two equivalent bounded repetitions.

## Required validation after later implementation approval

- Focused evaluator and entitlement facade tests.
- Existing cache invalidation, concurrent miss, and suspension invalidation tests.
- Static `rg` review proving no hidden evaluator clock default and no stale `scopes_by_kind` consumers.
- Relevant formatting and compilation checks required by the issue.
- Do not run unrelated suites unless the issue acceptance criteria require them.

## Performance and scaling review required in the implementation PR

- Hot/warm/cold classification for filtering, Cachex, and Postgres.
- Repo query count for cache hit, miss, and multiple `as_of` evaluations from one raw set.
- N+1 review and current index review; no new index without an actual query path and plan evidence.
- Cache TTL/invalidation semantics and stampede protection. Do not count TTL as boundary refresh.
- Oban uniqueness/idempotency: `NOT_APPLICABLE`, no job is added.
- Telemetry for Repo query count and relevant projection latency.
- Runtime Resource Safety Review must cover timer entries, scheduler load, GC, mailbox backlog, cancellation on disconnect/set replacement, and post-load convergence. Timers add no process per timer.
- No 100,000-view capacity, throughput, convergence, or no-accumulation claim until at least two equivalent bounded repetitions measure memory, GC, mailbox, timer cardinality/cancellation, callback latency, and post-load convergence. Current capacity status is UNMEASURED.

## Timer horizon evidence

The repository pins Erlang/OTP 28.3 and Elixir 1.19.5-otp-28 in `.tool-versions`. Official [OTP 28 `start_timer/3` documentation](https://www.erlang.org/docs/28/apps/erts/erlang.html#start_timer/3) specifies a nonnegative integer millisecond delay, monotonic-time semantics for relative timers, and a delivered timeout message containing the timer reference. The public docs do not publish a numeric maximum. Do not claim a version-independent maximum or represent the older OTP 17 documentation's 4,294,967,295 ms bound as verified for OTP 28.3.

Freeze `MAX_SCHEDULE_CHUNK_MS=86400000` as a conservative bounded re-arm application policy. Do not discover or adapt to a larger OTP maximum. The implementation check is `IMPLEMENTATION_OTP_CHECK=VERIFY_PINNED_OTP28_3_TIMER_API_AND_CANCEL_SEMANTICS`; verify the API and cancellation behavior on the pinned runtime. Long delays are split into local chunks, so scheduling never depends on a delay beyond this application cap.

## Machine-readable result

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
JC245_MAY_WRITE_FUTURE_GRANT=NO_NOW__YES_ONLY_AFTER_ENT_T1_ACCEPTANCE_READ_GATE_AND_EXACT_ACCESSEFFECT_START
JC245_REQUIRES_EXACT_ACCESSEFFECT_START=YES
JC245_FUTURE_CONVERGENCE_AUTHORITY=ARCHITECTURALLY_ALLOWED_AFTER_ENT_T1_ACCEPTANCE_READ_GATE_AND_EXACT_ACCESSEFFECT_START
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
JC245_246_IMPLEMENTATION_STATUS=BLOCKED_NOW
ENT_T1=PASS
NEXT_ACTION=STOP_FOR_AUTHORITY_REVIEW
RUNTIME_CODE_CHANGED=NO
DOCS_CHANGED=YES
REFS_CHANGED=NO
TESTS_RUN=NO
BASE_SHA=da0dfa9b022f26872efe1f17277e62769c6c0808
```
