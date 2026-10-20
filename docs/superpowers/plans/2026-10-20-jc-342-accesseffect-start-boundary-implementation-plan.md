# JC-342 AccessEffect Start-Boundary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Use TDD for every behavior change and stop at every STOP condition below.

**Goal:** Persist immutable `AccessEffect.valid_from_at` business-effective start evidence, introduce fingerprint v2 with exact v1 replay compatibility, and wire the currently authorized Store production paths without expanding into Entitlements execution.

**Architecture:** PostgreSQL remains the durable authority. `EstablishAccessEffectInput` transports and canonicalizes `valid_from_at` but does not enforce new-row temporal semantics, because legacy same-source-version v1 replay must resolve first. `Store.Subscriptions.Facade` performs replay-first compatibility, then validates temporal target shape only when inserting a new AccessEffect. `AccessEffect.target_fingerprint/1` becomes canonical v2; a narrowly named legacy v1 helper exists only for replay compatibility.

**Tech Stack:** Elixir, Ash, AshPostgres, PostgreSQL, ExUnit.

**Canonical Base:** `25d709b6226c38149f1f62ae8525f353dafb0a8e`

**Canonical Base Tree:** `b8197f49c2bcc143d440bc4e206e1390fde3c713`

**Spec:** `docs/superpowers/specs/2026-10-20-jc-342-accesseffect-start-boundary-design.md`

## Governance Admission Note

The human written-spec review is now approved, but the merged repository spec header and Linear authority text still contain the pre-approval wording `SPEC REVIEW REQUIRED` / written-spec review pending. Before any implementation work begins, the docs-only planning PR that installs this plan must update those authority markers to the equivalent of:

`DESIGN APPROVED / SPEC APPROVED / IMPLEMENTATION PLAN REVIEW REQUIRED / IMPLEMENTATION NOT AUTHORIZED`

This status correction records an approval that already occurred; it does **not** authorize implementation. The implementation plan itself must still receive explicit human approval and be merged as canonical authority before coding starts.

## Global Constraints

- Do not implement JC-245, JC-246, JC-247, NewYou target sets, or Entitlements read-side enforcement.
- Do not modify `Store.Entitlements.EntitlementGrant` or add an Entitlements resource/schema.
- Do not add a generic `AccessEffectTargetItem` or any target-set child resource.
- Add `valid_from_at` as `:utc_datetime_usec`, nullable, with no default and no historical backfill.
- Do not infer historical starts from `inserted_at`, `updated_at`, Subscription state, Plan state, worker time, queue time, Redis, ETS, Cachex, PubSub, or Oban.
- New effective entitlement target = `disposition == :effective` with both entitlement kind and scope present.
- New effective entitlement targets require non-nil `valid_from_at`.
- If a new effective entitlement target has non-nil `valid_until_at`, require strict `valid_from_at < valid_until_at`.
- Future `valid_from_at` values are valid; never compare them against `DateTime.utc_now()`.
- New effective nil/nil targets require `valid_from_at == nil`; supplied non-nil start fails closed.
- New current non-effective scalar targets require `valid_from_at == nil`; supplied non-nil start fails closed.
- Existing same-source-version replay resolves before the new-row temporal validations.
- New rows use fingerprint v2.
- Historical stored v1 fingerprints are never rewritten.
- v1 fallback is permitted only when incoming `valid_from_at == nil`.
- Incoming non-nil `valid_from_at` must never match through v1 fallback.
- Preserve existing source lock, transaction composition, stale-write rules, identity, lifecycle, and supersession semantics.
- No new index, Redis/ETS/Cachex/PubSub/Oban structure, worker, read path, or query is authorized.
- PostgreSQL remains cold/durable correctness authority; this task adds durable evidence only and does not create a new hot/warm data path.
- Performance expectation: zero new runtime reads/joins; fingerprint work remains in-process and bounded; no table scan is introduced.

## File Map

### Modify
- `lib/store/subscriptions/access_effect.ex`
  - Add nullable `valid_from_at`.
  - Accept it in `:establish`.
  - Make canonical fingerprint v2 include it.
  - Preserve an exact, narrowly scoped v1 fingerprint helper for historical replay.
- `lib/store/subscriptions/inputs/establish_access_effect_input.ex`
  - Carry and canonicalize `valid_from_at`.
  - Do **not** enforce new-row start presence/order/shape here.
- `lib/store/subscriptions/facade.ex`
  - Apply v2-first / nil-start-v1-fallback replay.
  - Apply new-row temporal validation after replay fails and before insertion.
  - Wire authoritative start for the existing effective suspended-recovery path.
  - Pass explicit nil start on current non-effective establishment paths.
- `test/store/subscriptions/access_effect_test.exs`
  - Own unit/integration coverage for input, storage, fingerprinting, replay compatibility, temporal validation, idempotency, rollback and conflict behavior.
- `test/store/subscriptions/sbh_30_05_dunning_adversarial_boundary_test.exs`
  - Prove suspended recovery persists the exact renewal occurrence start and suspension remains start-less.
- `test/store/subscriptions/sbh_40_03_scheduled_cancellation_race_test.exs`
  - Prove scheduled-cancellation non-effective effects remain start-less where an AccessEffect is established.

### Generate
- `priv/repo/migrations/<generated_timestamp>_*.exs`
  - Add only nullable `access_effects.valid_from_at :utc_datetime_usec`.
  - No default, backfill, CHECK, index, trigger, rewrite, or data migration.
- `priv/resource_snapshots/repo/access_effects/<generated_timestamp>.json`
  - Generator-owned AshPostgres snapshot corresponding to the resource change.

### Explicitly Do Not Modify
- `lib/store/entitlements/entitlement_grant.ex`
- `lib/store/entitlements/types/entitlement_set.ex`
- any JC-245/JC-246/JC-247 executor/worker implementation
- any NewYou-specific module
- any Redis/Cachex/PubSub/Oban infrastructure

## Review Focus

1. **Historical nil-start replay:** a stored v1 row with `valid_from_at = nil` must be reused without rewriting its fingerprint or start evidence.
2. **No false legacy equality:** an incoming non-nil start must never fall back to v1, even if every old v1 field matches.
3. **Replay-before-validation:** an effective nil-start input may reuse a matching historical v1 row, but the same input must fail when no row exists.
4. **Interval semantics:** open-ended and future starts are legal; equal or inverted bounded intervals fail closed.
5. **Start-less target shapes:** effective nil/nil and non-effective new targets reject non-nil starts while preserving current nil-start production behavior.

---

## Task 1 — Add Start Evidence to the Typed Contract and Durable Schema

**Files**
- Modify: `lib/store/subscriptions/inputs/establish_access_effect_input.ex`
- Modify: `lib/store/subscriptions/access_effect.ex`
- Generate: `priv/repo/migrations/<generated_timestamp>_*.exs`
- Generate: `priv/resource_snapshots/repo/access_effects/<generated_timestamp>.json`
- Test: `test/store/subscriptions/access_effect_test.exs`

**Interfaces**
- `EstablishAccessEffectInput.t()` gains `valid_from_at: DateTime.t() | nil`.
- `EstablishAccessEffectInput.new/1` parses `valid_from_at` through the existing optional DateTime canonicalization path and truncates to microseconds.
- `AccessEffect` gains nullable private `valid_from_at :utc_datetime_usec`.
- `AccessEffect :establish` accepts `:valid_from_at`.

**Steps**
- [ ] Add failing metadata/input tests:
  - AccessEffect exposes `valid_from_at` as private `Ash.Type.UtcDatetimeUsec`, nullable.
  - typed input accepts nil start.
  - typed input accepts a `DateTime` and canonicalizes to microsecond precision.
  - typed input rejects a non-DateTime/non-nil start with existing `VALIDATION_ERROR`.
  - typed input deliberately accepts an effective entitlement target with nil start at this stage; semantic rejection belongs after replay resolution.
- [ ] Run only the new focused tests and confirm they fail for the missing field/transport.
- [ ] Add `valid_from_at` to the struct, enforce-key list, type, constructor parse sequence, returned struct, AccessEffect attribute, and `:establish` accept list.
- [ ] Generate AshPostgres migration/snapshot using the repository generator. Inspect the generated diff before proceeding.
- [ ] Verify the generated migration is column-only: nullable UTC microsecond timestamp, no default/backfill/index/CHECK/trigger/data rewrite.
- [ ] Run `mix ash_postgres.generate_migrations --check`.
- [ ] Run the Task 1 focused tests.
- [ ] Commit Task 1 independently.

**STOP**
- STOP if the generator proposes unrelated schema changes.
- STOP if adding the field requires a global NOT NULL/CHECK or historical backfill.
- STOP if the typed input must enforce start presence/order before replay can run.
- STOP if any new query/index/cache structure appears necessary.

---

## Task 2 — Freeze Fingerprint v2 While Preserving Exact Historical v1

**Files**
- Modify: `lib/store/subscriptions/access_effect.ex`
- Modify: `test/store/subscriptions/access_effect_test.exs`

**Interfaces**
- `AccessEffect.target_fingerprint/1` remains the canonical fingerprint entry point and now returns v2.
- Add one narrow compatibility helper: `AccessEffect.legacy_target_fingerprint_v1/1`.
- Do not add a generic fingerprint-version argument or persisted fingerprint-version column.

**Steps**
- [ ] Before changing fingerprint behavior, add a characterization test with fixed canonical literal input that captures the accepted v1 hash produced by the current descriptor.
- [ ] Run that characterization test on the accepted base and record the fixed expected hash in the test.
- [ ] Add failing v2 tests proving:
  - changing only `valid_from_at` changes the canonical fingerprint;
  - nil `valid_from_at` is still explicitly represented in v2;
  - every previously canonical target field remains material;
  - the v1 compatibility helper still returns the fixed historical hash.
- [ ] Implement the smallest split between canonical v2 descriptor construction and exact legacy v1 descriptor construction.
- [ ] Keep field ordering for v1 byte-for-byte equivalent to the accepted v1 descriptor.
- [ ] Set the canonical fingerprint version to 2 and include `datetime_micros(valid_from_at)` immediately before `valid_until_at` in the v2 descriptor.
- [ ] Ensure `set_target_fingerprint/2` writes only v2 for newly created rows.
- [ ] Run the focused fingerprint tests.
- [ ] Commit Task 2 independently.

**STOP**
- STOP if the accepted v1 hash cannot be reproduced exactly.
- STOP if compatibility would require rewriting historical rows.
- STOP if a database fingerprint-version column is proposed.
- STOP if a generic multi-version framework is proposed; JC-342 needs only v2 canonical + exact v1 compatibility.

---

## Task 3 — Implement Replay-First Compatibility and New-Row Temporal Guards

**Files**
- Modify: `lib/store/subscriptions/facade.ex`
- Modify: `test/store/subscriptions/access_effect_test.exs`

**Interfaces**
- Existing `establish_access_effect_for_system/1` remains the public system boundary.
- Existing source lock and caller-owned transaction behavior remain unchanged.
- Existing same-source-version row handling becomes:
  1. compare stored fingerprint with incoming canonical v2;
  2. if mismatch and incoming `valid_from_at == nil`, compare stored fingerprint with exact legacy v1;
  3. otherwise return existing `IDEMPOTENCY_KEY_REUSE_MISMATCH`.
- New-row path gains a private temporal target validator after replay has returned no reusable row.
- Use the repository's existing normalized `VALIDATION_ERROR`; do not create a new error taxonomy for JC-342.

**Temporal validator rules**
- effective + complete kind/scope:
  - start required;
  - end nil allowed;
  - when end exists, `DateTime.compare(start, end) == :lt`;
  - start may be in the future.
- effective + nil/nil:
  - start must be nil.
- non-effective:
  - start must be nil.
- half-present entitlement pair remains rejected by the typed input as today.

**Steps**
- [ ] Add a test helper that can seed a historical v1 AccessEffect row with `valid_from_at = nil` without rewriting commercial evidence.
- [ ] Add failing historical replay tests:
  - v1 + incoming nil exact evidence reuses the same identity;
  - reused v1 row keeps its original fingerprint unchanged;
  - reused v1 row keeps `valid_from_at = nil`;
  - v1 + incoming non-nil start fails with `IDEMPOTENCY_KEY_REUSE_MISMATCH`.
- [ ] Add failing new-row tests:
  - effective complete target + nil start fails and persists no row;
  - effective complete target + start before end succeeds;
  - effective complete target + nil end succeeds;
  - start == end fails;
  - start > end fails;
  - future start + later end succeeds;
  - effective nil/nil + nil start succeeds when otherwise valid;
  - effective nil/nil + non-nil start fails;
  - non-effective + nil start succeeds;
  - non-effective + non-nil start fails.
- [ ] Add explicit ordering test: the historical v1 exact replay with nil start succeeds even though the same shape would fail as a new effective row.
- [ ] Add v2 replay/conflict tests:
  - exact v2 replay reuses one identity;
  - same source version with only `valid_from_at` changed conflicts.
- [ ] Replace the single equality replay branch with v2-first / nil-start-v1-fallback logic.
- [ ] Add the private new-row temporal validator only in the `existing == nil` path, after current source-version/provenance/PlanRevision entitlement checks and before insertion.
- [ ] Preserve the existing lock, transaction, stale-write and supersession call order.
- [ ] Run the entire `test/store/subscriptions/access_effect_test.exs`.
- [ ] Commit Task 3 independently.

**STOP**
- STOP if legacy replay can only be made to work by weakening new-row validation globally.
- STOP if replay mutates any historical row.
- STOP if non-nil incoming start can reach v1 fallback.
- STOP if any validator reads the current clock.
- STOP if source locking or transaction ownership must be changed.

---

## Task 4 — Wire Authoritative Production Starts Without Expanding Scope

**Files**
- Modify: `lib/store/subscriptions/facade.ex`
- Modify: `test/store/subscriptions/sbh_30_05_dunning_adversarial_boundary_test.exs`
- Modify: `test/store/subscriptions/sbh_40_03_scheduled_cancellation_race_test.exs` only where an existing assertion already owns the scheduled-cancellation AccessEffect result

**Production call-site rules**
- `establish_suspended_recovery_access_effect/4`:
  - set `valid_from_at` from the exact bound `RenewalAttempt.period_start_at`;
  - retain `valid_until_at = recovered.current_period_end_at`;
  - do not use recovery execution time.
- Scheduled-cancellation non-effective establishment:
  - pass `valid_from_at: nil` explicitly.
- Suspension non-effective establishment:
  - pass `valid_from_at: nil` explicitly.
- Do not invent starts for any other source case.

**Steps**
- [ ] Add failing dunning/recovery assertion proving the effective recovery AccessEffect persists `valid_from_at == occurrence.attempt.period_start_at` and its end remains the exact recovered period end.
- [ ] Extend the relevant suspension assertion to prove the non-effective AccessEffect has `valid_from_at == nil`.
- [ ] Where scheduled-cancellation tests already inspect the resulting AccessEffect, add the nil-start assertion without creating a new broad test fixture solely for JC-342.
- [ ] Add `valid_from_at` explicitly to the three production `EstablishAccessEffectInput.new/1` construction sites.
- [ ] Do not add `DateTime.utc_now()` or any fallback timestamp.
- [ ] Run:
  - `mix test test/store/subscriptions/access_effect_test.exs`
  - `mix test test/store/subscriptions/sbh_30_05_dunning_adversarial_boundary_test.exs`
  - `mix test test/store/subscriptions/sbh_40_03_scheduled_cancellation_race_test.exs`
- [ ] Commit Task 4 independently.

**STOP**
- STOP if any effective production call site lacks deterministic immutable start evidence.
- STOP if another production effective AccessEffect establishment site exists beyond the currently enumerated one and its start authority is not obvious from immutable bound evidence.
- STOP if satisfying a test requires reading mutable Plan state, current wall-clock time, queue/worker time, Redis, ETS, Cachex, PubSub or Oban.
- STOP if Entitlements code must change.

---

## Task 5 — Full Regression, Performance/Scaling Review, and PR Gate

**Files**
- No new functional scope.
- Only fix defects directly attributable to Tasks 1–4 and still inside the JC-342 spec.

**Steps**
- [ ] Re-run `mix ash_postgres.generate_migrations --check`.
- [ ] Run `mix check`.
- [ ] Run the full strict test suite with `mix test --max-failures 1`.
- [ ] Run `mix dialyzer` if it is part of the repository-supported local gate; otherwise require the exact-head CI Dialyzer job.
- [ ] Run `git diff --check`.
- [ ] Review the final diff and prove:
  - no Entitlements source file changed;
  - no Redis/ETS/Cachex/PubSub/Oban code changed;
  - no new index or query path was added;
  - no historical data backfill exists;
  - no generic target-set abstraction exists;
  - migration/snapshot changes are limited to the nullable start column.
- [ ] Performance & Scaling Review:
  - data layer: cold/durable PostgreSQL target evidence;
  - hot/warm representation: none required;
  - new DB reads/joins: zero;
  - write amplification: one additional timestamp value on existing AccessEffect insert;
  - 100k concurrency safety: unchanged source serialization and unique source-version identity remain the concurrency authority;
  - cache invalidation/PubSub: none because JC-342 adds no new read projection;
  - streaming: not applicable;
  - indexes: none because `valid_from_at` is not a selector in this task.
- [ ] Push a signed branch and open one implementation PR against current `main`.
- [ ] Require exact-head CI success for `check_static`, `test_pr_strict`, both required performance jobs, and `dialyzer_required`.
- [ ] Leave the PR open and unmerged for final human/adversarial review.

**STOP**
- STOP if `main` moved before branch creation or before final review; rebase/reconcile against the new accepted authority before continuing.
- STOP on any failing focused/full/CI test; diagnose rather than rerunning blindly.
- STOP if migration alignment reports unrelated drift.
- STOP if implementation scope expands beyond the canonical spec.
- STOP before merge. Human approval remains required.

---

## Expected Success State

```text
BASE_SHA=25d709b6226c38149f1f62ae8525f353dafb0a8e
BASE_TREE=b8197f49c2bcc143d440bc4e206e1390fde3c713

VALID_FROM_COLUMN=NULLABLE_UTC_DATETIME_USEC
HISTORICAL_BACKFILL=NONE
NEW_INDEX=NONE
NEW_RUNTIME_READS=0

FINGERPRINT_CANONICAL_VERSION=2
LEGACY_V1_REPLAY=EXACT_NIL_START_ONLY
LEGACY_ROW_REWRITE=NO
NON_NIL_START_V1_FALLBACK=NO

REPLAY_BEFORE_NEW_ROW_VALIDATION=YES
EFFECTIVE_TARGET_START_REQUIRED=YES
BOUNDED_INTERVAL_STRICT_LT=YES
OPEN_ENDED_TARGET_ALLOWED=YES
FUTURE_START_ALLOWED=YES
STARTLESS_SHAPES_REJECT_NON_NIL_START=YES

SUSPENDED_RECOVERY_START_AUTHORITY=RENEWAL_ATTEMPT_PERIOD_START
NON_EFFECTIVE_START=NIL

ENTITLEMENTS_SCOPE_CHANGE=NONE
JC245_246_247_SCOPE_CHANGE=NONE
NEWYOU_TARGET_SET_OVERBUILD=NONE
REDIS_CACHE_PUBSUB_OBAN_CHANGE=NONE

FOCUSED_TESTS=PASS
FULL_STRICT_TESTS=PASS
MIGRATION_ALIGNMENT=PASS
SIGNED_HISTORY=PASS
EXACT_HEAD_CI=PASS
IMPLEMENTATION_PR=OPEN_UNMERGED
IMPLEMENTATION_AUTHORIZED=YES_ONLY_AFTER_PLAN_APPROVAL
MERGE_AUTHORIZED=NO
```

## Plan Self-Review

### Spec coverage
- Durable nullable start evidence: Task 1.
- No backfill/global constraint/index: Tasks 1 and 5.
- Fingerprint v2 + immutable v1 compatibility: Task 2.
- Replay-first semantics and strict temporal validation: Task 3.
- Deterministic current production wiring: Task 4.
- Performance/scaling and scope exclusions: Task 5.
- Downstream EntitlementSet start-gate gap remains documented only; no JC-342 code change: Global Constraints / Task 5.

### Type consistency
- One field name everywhere: `valid_from_at`.
- One canonical v2 API: `AccessEffect.target_fingerprint/1`.
- One explicit compatibility API: `AccessEffect.legacy_target_fingerprint_v1/1`.
- Public establishment boundary remains `Facade.establish_access_effect_for_system/1`.

### Proportion / YAGNI
- No new resource, service, worker, state, cache, index, read API, or generic target-set abstraction.
- Compatibility is narrowly limited to historical v1 replay.
- Production wiring changes only the currently enumerated AccessEffect establishment sites.
