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

## Goal

Make entitlement reads obey the half-open interval `[valid_from_at, valid_to_at)`, evaluate against explicit `as_of`, separate raw cached rows from materialized projections, and establish the read-side prerequisite for future exact-source JC-245 grants.

## Frozen requirements

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

## Task 1: Specify the deterministic evaluator tests

**Files:** `test/store/entitlements/types/entitlement_set_test.exs`

1. Create grants with fixed UTC microsecond starts and ends.
2. Assert one microsecond before start is ineffective, exact start is effective, and one microsecond after start is effective.
3. Assert one microsecond before end is effective, exact end is ineffective, and one microsecond after end is ineffective.
4. Assert nil end is open-ended and nil start fails closed.
5. Assert revoked and non-active grants remain ineffective within otherwise valid windows.
6. Assert multiple overlapping current grants and a mixed set of current, future, ended, revoked, and open-ended grants.
7. Assert an offset `DateTime` representing the same UTC instant produces the same result, with no rounding of microseconds.
8. Run only the new focused test and confirm the current behavior fails for the intended missing start gate/API contract.

**Acceptance:** the tests fully encode `[start, end)`, including exact equality at both edges, with no sleep and no DB dependency.

**STOP:** if `DateTime` canonicalization cannot represent the accepted UTC microsecond precision without ambiguity, record the type decision before implementation.

## Task 2: Implement explicit `as_of` temporal evaluation

**Files:** `lib/store/entitlements/types/entitlement_set.ex`, focused evaluator tests.

1. Change the evaluator APIs so temporal evaluation requires an explicit `as_of` value.
2. Compare `DateTime` instants directly, preserving the exact `:utc_datetime_usec` boundary without rounding or truncation.
3. Filter active, unrevoked grants with non-nil `valid_from_at <= as_of` and nil end or `as_of < valid_to_at`.
4. Ensure `has_entitlement?` passes that same instant into grant filtering.
5. Keep clock capture in callers outside the evaluator. Do not add a hidden default.
6. Run focused evaluator tests and inspect all compile-time callers before proceeding.

**Acceptance:** every in-repository temporal evaluator call supplies an explicit instant, and boundary tests pass.

**STOP:** if a caller cannot supply one coherent instant for its logical operation, do not add per-grant clock reads. Identify and review that caller.

## Task 3: Remove stale derived cache projection

**Files:** `lib/store/entitlements/facade.ex`, `lib/store/entitlements/types/entitlement_set.ex`, focused facade tests.

1. Reconfirm with `rg` that `scopes_by_kind` has no production or test consumer.
2. Remove the field and its fetch-time projection builder.
3. Keep cached grant rows raw and derive any visible list at one explicit `as_of`.
4. Add tests that evaluate the same fetched set across both a future start and an expiry boundary at explicit instants, without a second Repo query.
5. Preserve existing write invalidation and concurrent miss coalescing tests.

**Acceptance:** no stale `scopes_by_kind` data remains in the set; repeated temporal projection from one set adds zero database queries.

**STOP:** if a hidden/external consumer depends on the struct field or if repository telemetry shows a new query is needed to evaluate at a second instant.

## Task 4: Review existing production consumers

**Candidate files:** `lib/store_web/live/entitlement_aware.ex`, `lib/store_web/live/subscriptions_live/index.ex`.

This task remains unauthorized until the human accepts the design and plan. It is included because the current call sites use implicit time and the subscriptions index stores a time-derived `entitlements` projection.

1. Search all `effective_grants/2` and `has_entitlement?/4` call sites.
2. Pass one explicit captured `as_of` to each logical evaluation, including `EntitlementAware` and `SubscriptionsLive.Index`.
3. Verify server-side decisions re-evaluate at action time rather than trusting a prior LiveView assign.
4. Keep write-driven PubSub invalidation as the existing refresh path.
5. Leave start/end projection refresh to Task 5's selected timer; do not treat that presentation refresh as authorization authority.

**Acceptance:** all current callers compile with explicit `as_of`; any authorization-sensitive event evaluates current grants at decision time.

**STOP:** if a required caller cannot preserve one explicit `as_of` for a logical evaluation within the four approved runtime files. Return to authority review before expanding scope.

## Task 5: Implement the frozen LiveView boundary timer

**Files:** `lib/store_web/live/entitlement_aware.ex`, `lib/store_web/live/subscriptions_live/index.ex`, `test/store_web/live/subscriptions_live_test.exs`.

1. On connected view set assignment or refresh, best-effort cancel the previous timer, advance generation, and derive the current projection and `next_temporal_boundary/2` from the assigned raw set.
2. If `next_temporal_boundary/2` or a carried boundary is `<= as_of`, immediately refresh in process from the held raw set, capture a fresh UTC `as_of`, and derive again. Never schedule delay zero or enter a zero-delay loop.
3. Keep no timer if the helper returns nil. Otherwise arm one `:erlang.start_timer/3` one-shot timer. Its delivered message carries the runtime timer reference; include the current generation token in the payload.
4. A chunk message captures a fresh UTC `as_of` and compares it with the stored target. If still future, re-arm locally without evaluating grants or authorization or fetching data. If scheduling/mailbox delay means the actual boundary has passed, take the actual-boundary refresh path in that handler.
5. A matching actual-boundary message captures one explicit UTC `as_of`, reevaluates the held raw set, updates the `SubscriptionsLive.Index` materialized `entitlements` list, and schedules the next boundary.
6. A stale reference or generation is ignored. Set replacement enters `REPLACED`, best-effort cancels, advances generation, and schedules from the new set. If a future boundary remains, transition to `SCHEDULED`; otherwise transition to `NO_TIMER`.
7. Before-boundary chunk lifecycle is `SCHEDULED → REARM → SCHEDULED`; a delayed chunk whose target has passed uses `SCHEDULED → REFRESHING`; actual boundary lifecycle is `SCHEDULED → REFRESHING → SCHEDULED` or `NO_TIMER`; process termination is terminal and runtime cancels timers targeting the exited PID.
8. Convert time remaining to integer milliseconds by rounding up. Add no randomized or policy delay. Millisecond rounding can schedule the wake less than one millisecond after the exact microsecond boundary; runtime delivery may be later. No authorization decision may rely on the timer.
9. Assert boundary/chunk handlers perform zero Repo queries, Cachex fetches, PubSub broadcasts, Redis operations, Oban work, or durable mutations.

Use controllable timer/message tests for start and end boundaries, timer cancellation/replacement, stale reference/generation, no-boundary behavior, and long-horizon local re-arm. Do not use sleeps.

**Acceptance:** at most one active timer per relevant connected view; zero timers otherwise; start/end projection transitions occur from the held raw set; stale messages have no effect; pre-boundary re-arm causes no grant/authorization evaluation; no timer handler fetch or broadcast; server authorization still rechecks independently. 100,000-view timer, mailbox, and rendering capacity remains UNMEASURED.

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
