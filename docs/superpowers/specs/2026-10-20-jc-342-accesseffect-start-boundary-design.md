# JC-342 / SBH-50-06R1 — Immutable AccessEffect Start-Boundary Evidence

Status: **DESIGN APPROVED / SPEC REVIEW REQUIRED / IMPLEMENTATION NOT AUTHORIZED**  
Date: 2026-10-20  
Repository: `JCSchoeman96/Store_Blueprint_Hardening`  
Design base: `cf57cddcbbba39adbec0adda66b883720b55c2be`  
Design base tree: `92c4e03cf4c328380bc0d44c3a4805e8a13976d4`

## 1. Purpose

Complete the durable Subscription-owned `AccessEffect` target contract so delayed Entitlements convergence can consume authoritative business-effective start evidence rather than inventing `valid_from_at` from worker execution time.

The accepted AccessEffect foundation currently persists the target end boundary (`valid_until_at`) and source/provenance evidence, but it does not persist an authoritative start boundary. Current Entitlements issuance helpers can therefore derive `valid_from_at` from `DateTime.utc_now()`. That is acceptable only as legacy behaviour; it is not acceptable for the future AccessEffect executor because worker time is not commercial truth.

JC-342 adds the missing durable target evidence without implementing JC-245 active convergence, JC-246 non-effective convergence, JC-247 purchased access policy, or NewYou multi-component target sets.

## 2. Backward planning from the long-term goal

### 2.1 Ultimate goal

The long-term Store/NewYou access architecture is:

```text
authoritative commercial source transition
        ↓ same PostgreSQL authoritative commit
source-versioned desired access target
        ↓ durable AccessEffect obligation
stale-safe source-target executor
        ↓
Entitlements durable source-scoped grants
        ↓
cache / PubSub / UI projections
```

A delayed or retried worker must be able to converge actual access from durable source truth without reinterpreting mutable Plan state, wall-clock execution time, queue history, cache state, or callback order.

### 2.2 Systems required to reach that goal

Working backwards, the platform requires:

1. immutable commercial provenance and authoritative source version;
2. a durable canonical desired access target with complete temporal evidence;
3. idempotent target fingerprinting and contradiction detection;
4. stale-target suppression and source-level serialization;
5. exact-source Entitlements convergence;
6. durable retry/recovery from AccessEffect state rather than worker history;
7. post-commit projection repair;
8. later richer target-set representation where NewYou component composition requires it.

Items 1, 3, 4, 6 and parts of 7 already exist in the accepted hardening path. JC-342 closes the missing temporal-evidence gap in item 2.

### 2.3 Why JC-342 must precede JC-245

JC-245 must execute a current effective AccessEffect using immutable target evidence. Without a persisted start boundary it would have to choose one of three invalid approaches:

- use worker execution time;
- reconstruct historical commercial timing from mutable/current state at execution time;
- silently widen the AccessEffect contract while implementing the executor.

JC-342 separates that contract decision from execution logic and keeps JC-245 bounded.

## 3. Domain and resource map

### 3.1 Domain ownership

| Domain | Owns | Does not own |
|---|---|---|
| Subscriptions / Commerce | commercial lifecycle, source version, desired access target, target validity evidence | actual EntitlementGrant truth |
| `AccessEffect` | durable source-versioned desired access obligation and execution lifecycle | generic events, payments, email, arbitrary side effects |
| Entitlements | durable actual grant rows and source-scoped convergence | Subscription lifecycle or commercial policy selection |
| Cachex / PubSub | derived read/UI projections | correctness authority or target ordering |
| Oban | acceleration and operations scheduling | business truth or latest-target authority |

### 3.2 Existing AccessEffect lifecycle

The lifecycle is unchanged by JC-342:

```text
REQUIRED
  → PENDING
    → APPLIED

PENDING
  → FAILED_RETRYABLE
    → PENDING

PENDING
  → SUPERSEDED

APPLIED = terminal
SUPERSEDED = terminal
```

JC-342 adds target evidence only. It introduces no new lifecycle state.

### 3.3 Target descriptor after JC-342

For the current Store scalar target model:

```text
AccessEffect target
├── subscription/source identity
├── source_version
├── disposition
├── entitlement_kind
├── entitlement_scope_key
├── valid_from_at        NEW
├── valid_until_at
├── source_order_line_item_id
├── contract_change_id
├── plan_revision_id
└── target_fingerprint
```

`valid_from_at` means the authoritative business-effective start of the desired scalar access target. It is not an execution timestamp, queue timestamp, AccessEffect lifecycle timestamp, or cache timestamp.

## 4. State, transition and invariant implications

JC-342 does not change AccessEffect state transitions. It changes the completeness rules for target establishment and exact replay.

### 4.1 Start applicability for current Store scalar targets

The applicability rules for current Store scalar targets are:

| Target shape | `valid_from_at` rule |
|---|---|
| `EFFECTIVE` with a complete non-nil entitlement kind/scope pair | Require the authoritative, non-nil business-effective start. |
| New `EFFECTIVE` target with entitlement kind and scope both nil | Require `valid_from_at` to be nil. This target remains legal; a supplied non-nil start fails validation. |
| New current JC-342 non-effective scalar target | Require `valid_from_at` to be nil; a supplied non-nil start fails validation. |
| Historical row | Remain nullable; never reconstruct a start. |

The start requirement applies to a **new effective entitlement target**, which means an `EFFECTIVE` target with both entitlement kind and scope present. If its authoritative start is absent, fail closed and create no row. When `valid_until_at` is non-nil, require `DateTime.compare(valid_from_at, valid_until_at) == :lt`; equal or inverted boundaries fail closed before insertion. Do not compare the start with wall-clock time: a future authoritative start is valid. Do not use worker time or another inferred timestamp.

For new `EFFECTIVE` nil/nil targets and new current non-effective scalar targets, a caller-supplied non-nil `valid_from_at` fails validation. Do not silently discard or canonicalize that evidence to nil. Existing-row replay resolution in §4.2 and §5 still runs before these new-row validations.

### 4.2 Existing-row replay resolution

Resolve an existing same-source-version row before applying the required-start check for a new row:

```text
same subscription + source_version row exists
→ compare the incoming v2 fingerprint with the stored fingerprint first
→ if equal, reuse that AccessEffect identity
→ otherwise apply only the nil-start legacy v1 fallback defined in §5
→ if neither comparison matches, fail closed as contradictory evidence
```

This ordering also applies when a replay input has the shape of a new effective entitlement target but a nil start. Do not reject it with the new-row validation before resolving the existing-row replay.

### 4.3 New-row establishment

After existing-row replay resolution finds no reusable row, a new effective entitlement target must have its authoritative non-nil start before establishment. If `valid_until_at` is non-nil, require `DateTime.compare(valid_from_at, valid_until_at) == :lt`; equal or inverted boundaries fail closed before insertion. A future `valid_from_at` is valid, including when it is later than current wall-clock time. No `valid_from_at <= DateTime.utc_now()` or equivalent wall-clock guard is permitted. New rows use fingerprint v2.

An `EFFECTIVE` nil/nil target remains legal only with a nil start, and current JC-342 non-effective scalar targets also require a nil start. A caller-supplied non-nil start for either shape fails validation; it must not be silently erased or canonicalized. A source version cannot be inserted again with materially different target evidence.

### 4.4 Non-effective targets

Current JC-342 non-effective scalar targets use `valid_from_at = nil`. JC-342 does not infer or add a start for these targets. Future target shapes may define other temporal rules only under separate governance.

### 4.5 Historical AccessEffects

Historical rows remain nullable for `valid_from_at` and retain their existing lifecycle states. The migration must not fabricate historical authority. Do not reconstruct or populate a start from another field or source.

Legacy v1 replay may reuse a matching historical row only under the exact compatibility rule in §5. Reuse must not update the historical fingerprint, start value, or any other row evidence.

## 5. Fingerprint contract v2

The current fingerprint descriptor is versioned. JC-342 must bump the descriptor version rather than silently changing v1 semantics. New rows use v2. No fingerprint-version database column is added or required.

Conceptually:

```text
v1 = source + source_version + disposition + kind/scope + valid_until + provenance

v2 = source + source_version + disposition + kind/scope + valid_from + valid_until + provenance
```

The v2 descriptor always contains `valid_from_at`, including when its value is nil. The v1 descriptor omits that field. This keeps the descriptors distinct without a fingerprint-version database column.

Required invariant:

```text
fingerprint v2 covers every field that materially changes the current scalar desired access target
```

`valid_from_at` is material and therefore must be included.

Existing stored v1 fingerprints are historical evidence. Never rewrite them to v2. Never add or infer `valid_from_at` for a historical row.

For an existing same-source-version row, resolve replay in this order:

1. Compute the incoming v2 fingerprint, including its `valid_from_at` value, and compare it with the stored fingerprint. If it matches, reuse the existing row.
2. Only if the incoming `valid_from_at` is nil and the v2 comparison did not match, compute the historical v1 fingerprint descriptor, which omits `valid_from_at`. If that fingerprint matches the stored fingerprint, reuse the existing row without updating its fingerprint, `valid_from_at`, or any other row evidence.
3. If neither comparison matches, fail closed as a same-source-version conflict. When the incoming `valid_from_at` is non-nil, do not compute or accept a v1 fallback. A v1 row must never be treated as equal to a target that asserts a non-nil start.

This replay resolution must run before the new-row effective-entitlement start requirement. Apply that requirement only after no existing row qualifies for reuse and the operation is proceeding to insert a new row.

## 6. Source-of-truth rules for `valid_from_at`

`valid_from_at` must originate from the authoritative source transition or exact bound commercial evidence.

Examples for later consumers:

| Future source case | Correct start authority |
|---|---|
| Initial paid activation | authoritative initial funded/commercial start |
| Paid renewal | exact successful RenewalAttempt `period_start_at` / exact paid contract evidence |
| Same-renewal recovery | original paid occurrence start, not recovery-worker time |
| Restored current paid access after valid rescission | authoritative live funded-period start |
| Future component target | separately governed component/source start evidence |

JC-342 should not wire every future source case. It only makes the AccessEffect contract capable of carrying the evidence and updates currently authorized establishment call sites only where their start is already deterministic.

Forbidden start authorities:

- `DateTime.utc_now()` at executor/worker time;
- Oban enqueue or attempt time;
- process start time;
- PubSub delivery time;
- cache insertion/fetch time;
- Redis/ETS state;
- mutable public Plan state read during delayed execution.

## 7. NewYou compatibility and future target sets

### 7.1 What JC-342 intentionally solves for NewYou

NewYou requires:

- future-dated sources to remain ineffective before the authoritative start;
- business timestamps rather than worker execution time;
- one latest authoritative source target version;
- stale/out-of-order work to be unable to restore obsolete rights;
- recovery from durable source truth;
- independent source provenance.

JC-342 directly strengthens the first two requirements and makes the current Store AccessEffect target materially more suitable for the later source-versioned convergence model.

### 7.2 What JC-342 intentionally does not solve

NewYou later needs richer commercial composition:

- base membership + recurring add-ons;
- package/bundle composition;
- multi-component entitlement target sets;
- gifts/sponsor/complimentary/lifetime source taxonomy;
- limited-benefit / additive-credit semantics;
- source effect classes and billing suppression rules.

JC-342 must not pre-build those models.

### 7.3 Extensibility invariant

Current Store meaning:

```text
one AccessEffect/source version
→ zero-or-one scalar Store entitlement target
→ target-level valid_from_at / valid_until_at
```

This is not a permanent law that all future components share one interval.

A later separately governed target-set extension may represent per-component target validity while preserving:

- one latest authoritative target version per source;
- AccessEffect durable obligation lifecycle;
- stale-target suppression;
- source provenance;
- Commerce owns desired target;
- Entitlements owns actual grants.

No `AccessEffectTargetItem` or generic target-set child resource is authorized in JC-342.

### 7.4 Downstream effective-grant start gate

Persisting `valid_from_at` is necessary but not sufficient for future-dated access. The current `Store.Entitlements.Types.EntitlementSet.effective_grants/2` evaluation does not enforce `now >= grant.valid_from_at`. Until a separately authorized downstream change enforces that read-side gate, future executor or NewYou admission must STOP if a future-dated grant could be considered effective before its authoritative start. This is a downstream prerequisite only: JC-342 does not modify Entitlements or expand its implementation scope.

## 8. Data model and migration design

### 8.1 Column

Add the nullable attribute using the repository-native timestamp contract:

```text
Ash attribute: valid_from_at uses :utc_datetime_usec with allow_nil?(true)
Generated migration: add :valid_from_at, :utc_datetime_usec, null: true
```

Match the existing `valid_until_at` Ash type and nullability semantics.

### 8.2 Backfill

No historical backfill.

A historical row without a persisted start does not become trustworthy merely because a timestamp can be guessed from Subscription, grant insertion time, worker history, period end, plan metadata or `inserted_at`.

### 8.3 Constraints

Do not add a global `NOT NULL` constraint.

Do not add a broad database CHECK until the implementation plan proves every currently legal `disposition + entitlement pair + legacy row` shape.

After existing-row replay resolution under §5, new-row validation must enforce the authoritative non-nil start and strict `valid_from_at < valid_until_at` ordering when the end is present for effective entitlement targets with a complete non-nil kind/scope pair. It must allow effective nil/nil targets and current JC-342 non-effective scalar targets only with a nil start; a supplied non-nil start fails validation rather than being discarded. Future starts remain valid without a wall-clock comparison.

JC-342 does not require a CHECK constraint for this rule.

### 8.4 Indexes

No new index is expected.

`valid_from_at` is target evidence, not a selector or recovery cursor in JC-342. Adding an index without a proven query path would create write/storage cost with no demonstrated value.

## 9. API and boundary design

### 9.1 Typed establishment input

`EstablishAccessEffectInput` must be able to carry `valid_from_at`.

The typed input remains the canonical boundary for establishment. Do not bypass it with ad-hoc maps solely to accommodate the new field.

### 9.2 AccessEffect establishment

Existing transaction composability remains mandatory:

```text
source access-changing truth
+ AccessEffect establishment
= same caller-owned PostgreSQL authoritative transaction
```

JC-342 must not make AccessEffect establishment post-commit only.

### 9.3 Entitlements executor boundary

JC-342 does not make the old Entitlements issue helper canonical. It must not implement the JC-245 executor.

Later JC-245 will consume `valid_from_at` from AccessEffect/immutable source evidence instead of deriving it from execution time.

## 10. Architecture and file boundaries

Expected implementation surfaces after a reviewed plan:

```text
lib/store/subscriptions/access_effect.ex
lib/store/subscriptions/inputs/establish_access_effect_input.ex
lib/store/subscriptions/facade.ex                    only if establishment wiring requires it
priv/repo/migrations/<timestamp>_jc342_*.exs
priv/resource_snapshots/repo/...                     exact generated snapshot path
focused AccessEffect tests
```

Likely call sites that establish effective targets may require narrow updates if they already possess deterministic start evidence. The implementation plan must enumerate them before coding.

Explicit exclusions:

```text
lib/store/entitlements/entitlement_grant.ex
new Entitlements resource/schema
new AccessEffect child resource
generic target-set infrastructure
JC-245 executor implementation
JC-246 revocation executor implementation
JC-247 policy implementation
NewYou product-specific composition
```

## 11. Error handling and fail-closed rules

The design prefers explicit incompleteness over invented authority.

If a new effective target requires a start but the source cannot prove one:

```text
return existing normalized validation/internal authority error
no AccessEffect with guessed time
no Entitlements mutation
```

Do not invent a second temporal truth source to keep the operation green.

Existing-row replay must follow the v2-first, nil-only v1 fallback in §5. If no allowed comparison matches, return the existing same-source-version conflict. Never treat a v1 row as matching an incoming target with a non-nil start.

## 12. Concurrency and replay

JC-342 changes no lock protocol.

The following invariants remain:

- source version is provenance, not equality with the latest unrelated Subscription aggregate version;
- one source version cannot acquire two materially different canonical targets;
- older effects cannot become current after a newer target exists;
- outer transaction rollback must remove a newly established AccessEffect;
- duplicate exact establishment is idempotent.

Adding `valid_from_at` to the fingerprint strengthens contradiction detection under replay and concurrency.

## 13. Performance & scaling review

### 13.1 Data tier

`valid_from_at` belongs to the **cold durable PostgreSQL authority** together with the rest of the AccessEffect target.

It does not belong in Redis, ETS, Cachex or process state as correctness authority.

### 13.2 Query cost

Expected steady-state effect:

```text
new runtime reads: 0
new runtime joins: 0
new recovery scans: 0
new index: 0 expected
```

The executor later reads the timestamp from the already-required AccessEffect row, avoiding historical reconstruction queries.

### 13.3 100k-user safety

This change adds one timestamp to a bounded source-target row. It does not introduce a global scan, per-request cache lookup, distributed lock or provider call. It is safer at scale than dynamically reconstructing commercial time for delayed workers.

### 13.4 Cache / PubSub / Redis / Oban

No change.

No invalidation rule changes.
No new TTL.
No Redis structure.
No PubSub broadcast.
No Oban uniqueness or worker behaviour.

### 13.5 Invalidation

Not applicable: `valid_from_at` is immutable target evidence. It is not cached separately and is never mutated in place to represent a later target. A later desired target is a newer source-versioned AccessEffect.

## 14. Security and integrity review

Main integrity risk: granting access earlier than the commercial authority intended.

JC-342 reduces that risk by making start time durable and fingerprinted.

Required protections:

- no early activation from worker time;
- no mutable plan lookup to rewrite historical start;
- no stale v1/v2 replay ambiguity treated as success without proof;
- no source-crossing mutation;
- no independent source revoked/rewritten by this task;
- no cache state treated as authority.

## 15. Failure modes and edge cases

1. **Legacy v1 replay with nil start** — exact historical descriptor match reuses the existing row without changing its fingerprint or row evidence.
2. **Legacy v1 row with asserted non-nil start** — never use the v1 fallback; fail closed.
3. **Same source version, different start** — contradiction; fail closed.
4. **New effective entitlement target missing start** — reject before insertion.
5. **Effective nil/nil target** — remains legal with nil start.
6. **Current non-effective scalar target** — retains nil start.
7. **Effective interval with start before end** — valid bounded interval succeeds.
8. **Effective interval without an end** — open-ended target succeeds.
9. **Equal or inverted effective interval** — fail closed before insertion.
10. **Future effective start before a later end** — succeeds without a wall-clock guard.
11. **Effective nil/nil target with a supplied start** — fail validation without silently discarding the start.
12. **Current non-effective scalar target with a supplied start** — fail validation without silently discarding the start.
13. **Historical rows** — leave nullable; do not fabricate or reconstruct a start.
14. **Source owner cannot prove a required new start** — STOP; do not guess.
15. **Future target-set requirement** — govern separately; do not add a generic child model here.
16. **Main moves before implementation** — re-admit against the new accepted tip.
17. **Generated Ash snapshot differs from intended schema** — STOP until migration/resource alignment is understood.
18. **Any new selector starts querying `valid_from_at`** — review index need from actual EXPLAIN evidence, not assumption.

## 16. Required verification matrix

Implementation review must verify at least:

### Target establishment and replay

- new effective entitlement target with an authoritative non-nil `valid_from_at` succeeds;
- new effective entitlement target without a start fails closed before insertion;
- new effective entitlement target with a start before a non-nil end succeeds;
- open-ended new effective entitlement target succeeds;
- equal or inverted effective interval fails closed before insertion;
- future start with a later end succeeds without comparing against wall-clock time;
- effective nil/nil target remains legal with `valid_from_at = nil`;
- effective nil/nil target with a supplied non-nil start fails validation;
- current non-effective scalar target retains `valid_from_at = nil`;
- current non-effective scalar target with a supplied non-nil start fails validation;
- exact v2 replay reuses the existing AccessEffect;
- same v2 source version with a different start conflicts;
- fingerprint v2 changes when only the start changes and remains deterministic for exact replay;
- exact legacy v1 replay with nil `valid_from_at` reuses the existing row;
- a legacy v1 row plus asserted non-nil `valid_from_at` fails closed;
- legacy replay does not rewrite the stored fingerprint or any row evidence;
- existing-row replay resolution runs before new-row effective-target start validation.

### Transactionality

- AccessEffect created inside an outer transaction disappears on rollback;
- no independent post-commit AccessEffect is left behind.

### Legacy compatibility

- existing rows with NULL `valid_from_at` remain readable;
- migration performs no fabricated historical backfill;
- existing non-effective flows continue to establish/read/recover as governed.

### Boundary safety

- no tested path substitutes `DateTime.utc_now()`/worker time for the new AccessEffect target field;
- no target-set child resource is introduced;
- no EntitlementGrant schema change;
- no AccessEffect lifecycle state change.

## 17. STOP conditions

Implementation must STOP and return for authority review if any of the following occurs:

1. Canonical `main` moves from the approved task base before implementation and the design is not re-admitted.
2. A required effective source case lacks deterministic immutable start evidence.
3. Correctness would require inventing a historical start for existing rows.
4. `DateTime.utc_now()`, worker time, queue time, PubSub, Redis, ETS, Cachex or process state would become start authority.
5. A global `NOT NULL` or CHECK would invalidate legitimate legacy/non-effective rows without separately governed migration semantics.
6. Safe v1/v2 same-source-version compatibility cannot be established.
7. EntitlementGrant schema/resource changes are required.
8. A generic target-set child schema is proposed.
9. A new AccessEffect lifecycle state is proposed.
10. Scope expands into JC-245 active executor, JC-246 non-effective executor, JC-247 access-policy wiring, or NewYou product-specific composition.
11. Additional indexes are proposed without a concrete selector/query-plan need.
12. Redis, ETS, process locks or cache state are proposed as target authority.

## 18. Success criteria

JC-342 is complete only when the accepted implementation proves:

```text
VALID_FROM_DURABLE=YES
VALID_FROM_BUSINESS_AUTHORITY=YES
WORKER_TIME_AUTHORITY=NO

FINGERPRINT_VERSION=2
VALID_FROM_IN_FINGERPRINT=YES
EXACT_REPLAY_IDEMPOTENT=YES
CONTRADICTORY_START_FAILS_CLOSED=YES
LEGACY_V1_NIL_START_REPLAY=YES
LEGACY_V1_ASSERTED_START_REPLAY=FAILS_CLOSED
LEGACY_FINGERPRINT_AND_ROW_EVIDENCE_REWRITES=NONE

LEGACY_BACKFILL=NONE
LEGACY_ROWS_READABLE=YES
NON_EFFECTIVE_REGRESSION=NONE
EFFECTIVE_NIL_NIL_START=NIL
NEW_EFFECTIVE_ENTITLEMENT_START_REQUIRED=YES
INTERVAL_ORDERING=STRICT_IF_END_PRESENT
FUTURE_STARTS_ALLOWED=YES
INVALID_START_SHAPES_FAIL_CLOSED=YES
ENTITLEMENT_READ_START_GATE=DOWNSTREAM_TRACKED
JC342_ENTITLEMENTS_SCOPE_EXPANSION=NONE

OUTER_TRANSACTION_ROLLBACK=PASS
NEW_INDEX=NONE unless evidence requires one

ENTITLEMENT_GRANT_SCHEMA_CHANGE=NONE
ACCESS_EFFECT_LIFECYCLE_CHANGE=NONE
TARGET_SET_OVERBUILD=NONE

NEWYOU_VALIDITY_ALIGNMENT=YES
NEWYOU_TARGET_SET_COMPATIBLE=YES
NEWYOU_COMPONENT_MODEL_DEFERRED=YES
```

## 19. Sequencing after JC-342

After merge and post-merge acceptance:

```text
JC-342 accepted
→ re-admit JC-245 against then-current main
→ implement stale-safe effective AccessEffect execution/recovery
→ reuse common source-target fence for JC-246
→ wire purchased access_on_past_due/access_on_cancel target creation in JC-247
→ reconcile historical divergence / production cutover in later governed rows
```

JC-342 is intentionally small in data shape but foundational in meaning: it ensures every future executor can distinguish **when access became commercially authoritative** from **when a worker happened to run**.

Downstream gate: before admitting future-dated executor or NewYou behavior, separately authorized work must ensure effective-grant evaluation enforces `now >= grant.valid_from_at`. The current `EntitlementSet.effective_grants/2` does not enforce this condition; future-dated access work must STOP until that read-side gate is in place. This does not expand JC-342 implementation scope.
