# JC-229 — Renewal Collection Lifecycle / Bound-Contract Initiation Design

**Date:** 2026-10-13\
**Issue:** JC-229 — SBH-10-04 — Renewal Initiation Uses Bound Contract\
**Repository:** `JCSchoeman96/Store_Blueprint_Hardening`\
**Canonical authority:** current `origin/main` + Linear JC-229 acceptance criteria + locked NewU/NewYou CER decisions relevant to subscription renewal, payment, retry, cancellation, suspension, inventory, and access.

## 1. Purpose

JC-229 closes a reusable Store capability gap required by NewU while hardening the Store blueprint in its own right.

The implementation must make one subscription renewal occurrence durable and commercially stable across:

- worker retries;
- provider retries;
- timeouts and ambiguous provider outcomes;
- multiple collection attempts;
- physical inventory reservation generations;
- cancellation races;
- suspension/recovery;
- delayed callbacks and reconciliation;
- process crashes between local state transitions and provider I/O.

The commercial identity of the renewal comes from the immutable bound `RenewalAttempt`, not mutable `Subscription`, `Plan`, or current/pending plan state.

NewU-specific policy must not be hard-coded into Store. Store owns generic mechanisms and invariants; NewU consumes them with its locked policy/configuration.

## 2. Authority and anti-drift rules

1. `origin/main` is the accepted runtime. Start from the then-current `origin/main`, not an old workstream branch.
2. Linear is the execution queue. Historical governance/pin documents are provenance only.
3. PR #127 (`JC-229: add durable renewal collection lifecycle`) is **historical design/test evidence only**. Do not rebase, merge, or cherry-pick it wholesale.
4. JC-340 / PR #142 are not implementation gates under the current `AGENTS.md` workflow.
5. If current `origin/main` has advanced from the review-time SHA `c5f2a7a430d7932e4106400f7863316c79fd88e7`, inspect every intervening change touching subscriptions, payments, orders/inventory, workers, migrations, or lifecycle docs before implementation.
6. Use Ash 3.x and the repository’s existing domain/action patterns. Do not bypass Ash/resource invariants with ad-hoc SQL except where an accepted current pattern explicitly requires a compare-and-set/lock primitive.
7. Never treat Redis/cache state, Oban uniqueness, or process-local locks as correctness authority.

## 3. NewU reuse law

Before implementation, create a CER conformance table in the PR/design notes:

| Locked NewU CER decision / need | Generic Store invariant/capability | JC-229 code surface | Test proving compatibility |
|---|---|---|---|

Only **locked/accepted** CER decisions are binding. Working notes, proposals, and Pre-JIT questions are not silently promoted to requirements.

### JC-229 CER conformance matrix

The requirements below are the confirmed NewYou acceptance requirements recorded in the 2026-09-26 CER v0.30.3 reconciliation on Linear JC-229. `CER-UPD-001` remains accepted working input, not Product Law, and is excluded from this matrix.

| Locked NewU CER decision / need | Generic Store invariant/capability | JC-229 code surface | Test proving compatibility |
|---|---|---|---|
| One intended renewal keeps one commercial identity across scheduling, technical retries, provider calls, callbacks, reconciliation, restart, and outage recovery. A billing retry is not a new renewal occurrence. | One immutable `RenewalAttempt` owns the occurrence. Sequential `RenewalCollectionAttempt` rows identify collections within it, and all collections reuse the occurrence's Order and bound contract. | `RenewalAttempt`, `RenewalCollectionAttempt`, and `RenewalCollectionAttempts` | Collection replay and ordinal tests; bound-contract mutation and retry tests. |
| Ambiguous provider state remains unresolved until authoritative evidence exists. A timeout or local failure does not prove that no charge occurred. | Dispatch evidence and provider-verified financial outcome are independent. Unknown outcomes replay the same collection and PaymentIntent. | Collection dispatch/outcome transitions and the accepted Payments observation/finality path | Timeout, crash-after-claim, local-failure, and same-collection PaymentIntent replay tests. |
| One renewal may have multiple payment attempts, but may establish at most one successful collection consequence and one paid period. | Verified success permanently closes the occurrence to later collection ordinals. | Collection ordinal allocation and terminal outcome actions | Success-blocks-next-ordinal and concurrent-start tests. |
| Late verified success for the same still-authorized renewal preserves the original billing-period boundaries. | Collection success remains tied to the immutable attempt period; JC-229 does not create a new period during reconciliation. | Exact success handoff from collection to downstream renewal processing | Exact handoff and original-period-preservation tests. |
| Queued or stale work re-reads current Commerce authority before an irreversible collection boundary. | Cancellation, suspension, and retry-due status gate new collection and dispatch under the accepted transaction/lock order. | Collection start, dispatch claim, cancellation and suspension authority checks | Deterministic cancellation-vs-dispatch and suspension-vs-dispatch tests. |
| Provider observation, Commerce interpretation, Entitlement consequence, and execution evidence remain distinct truths. | Provider observations are reconciled through Payments; collection financial outcome is separate from dispatch state; subscription/access effects remain outside JC-229. | Payments reconciliation, collection outcome actions, exact JC-230 handoff | Reordered-observation monotonicity tests and exact-handoff boundary test. |

The Store implementation must remain generic. Examples:

- If NewU specifies a concrete grace interval, Store should model contractual retry/grace policy and consume the bound value; do not hard-code “72 hours”.
- If NewU requires a physical product renewal, Store must preserve exact reservation-generation correctness; do not make all subscriptions physical.
- If NewU has access/membership recovery behavior, Store must expose the durable payment/renewal truth that later lifecycle code can consume; do not embed NewU membership product rules in the generic collection resource.

## 4. Existing accepted semantics JC-229 must preserve

### JC-287 — provider observation
Provider observations are durable evidence only. Observation order/time does not itself authorize Commerce mutation.

### JC-282 — payment outcome precedence
Use accepted provider-finality and `PaymentOutcomeResolver` semantics. Exact verified success can correct stale/local failure. Terminal non-success requires provider-certified terminal evidence. Success is monotonic.

### JC-281 — cancellation precedence
- payment-first: preserve paid truth; cancellation later does not invent a remediation refund;
- cancellation-first: withdraw renewal authority; later exact money is still payment truth but must not reactivate/consume stock and must cause exactly one remediation refund;
- stale workers must not perform a new provider mutation after cancellation.

### JC-265 — suspension
- `suspended` receives no new automatic due/dispatch/new renewal authority;
- an already-reached/ambiguous exact collection remains reconcilable;
- a late exact success for the already-authorized renewal may repair the subscription through the accepted recovery path;
- cancellation remains able to win the access-authority race;
- `canceled` and `expired` remain terminal.

### JC-327 / inventory exact-generation guard
Use the accepted `Store.Orders.guard_exact_generation/4` seam and current exact-generation release/fence primitives. Do not reintroduce unlocked exact-generation reads.

## 5. Scope

### In scope

1. Add durable `RenewalCollectionAttempt` identity under a bound `RenewalAttempt`.
2. Separate dispatch evidence from financial outcome.
3. Allocate collection ordinals safely and monotonically.
4. Bind each collection to at most one exact `PaymentIntent`; bind an intent to at most one collection.
5. Construct/reuse the renewal Order and PaymentIntent from immutable bound RenewalAttempt evidence.
6. Use deterministic collection idempotency key:
   `renewal-collection:<collection_attempt_id>`.
7. Make provider dispatch replay/crash safe:
   persist “may have been reached” before outbound provider mutation.
8. Support pre-submission fencing and same-collection dispatch epoch resume.
9. Integrate exact physical reservation-generation ownership and release/fence behavior.
10. Refresh financial truth only through accepted Payments/provider-verification semantics.
11. Permit a new collection ordinal only after provider-certified terminal financial non-success and current dunning authority.
12. Block new collection/dispatch authority after cancellation/suspension as required by accepted lifecycle semantics.
13. Preserve exact success identity for downstream JC-230:
   `order_id + renewal_attempt_id + collection_attempt_id + payment_intent_id`.
14. Add deterministic race/crash/replay tests and performance evidence.

### Out of scope

1. JC-230 subscription period extension, entitlement grant/reissue, or final paid-renewal application.
2. NewU-specific membership/product policy.
3. Rewriting accepted JC-287/282/281/265 semantics.
4. General payment-provider redesign.
5. Re-admission/task-base/governance pin workflow.
6. Closing historical PRs/issues unless the human explicitly authorizes it.

## 6. Domain model

Create `Store.Subscriptions.RenewalCollectionAttempt` as a child of `RenewalAttempt`.

Required fields:

- `id` — UUIDv7 primary key
- `renewal_attempt_id` — required FK, delete restrict
- `collection_ordinal` — positive integer
- `dispatch_state`
- `financial_outcome`
- `reservation_generation_id` — nullable UUID
- `dispatch_epoch` — positive integer, default 1
- `fenced_through_epoch` — non-negative integer, default 0
- `last_fence_event_id` — nullable UUID
- `last_fenced_at` — nullable timestamp
- `payment_intent_id` — nullable FK, delete restrict
- timestamps

Use the historical PR #127 names unless current-main conventions make a compelling incompatibility visible. Do not gratuitously rename states or fields.

### Dispatch states

- `not_started`
- `may_have_been_reached`
- `not_submitted`

Dispatch state answers only: **could the provider mutation for this epoch have been reached?**

It does not answer whether money succeeded or failed.

### Financial outcomes

- `unresolved`
- `requires_action`
- `verified_success`
- `verified_terminal_financial_non_success`

Financial outcome answers only the provider-verified financial truth for the exact PaymentIntent/collection.

## 7. Lifecycle laws

### 7.1 Collection creation

A `RenewalAttempt` represents one commercial renewal occurrence.

A `RenewalCollectionAttempt` represents one collection identity within that occurrence.

Rules:

1. Lock in repository-approved order. Preserve current subscription/renewal lock ordering.
2. The parent RenewalAttempt must contain a complete bound contract before collection begins.
3. Ordinals must be contiguous: `1, 2, 3...`.
4. At most one active collection (`unresolved` or `requires_action`) may exist for a RenewalAttempt.
5. Replaying “start collection” while an active collection exists returns that same collection.
6. If any collection is `verified_success`, the renewal is permanently closed to new collection ordinals.
7. A next ordinal is legal only when the latest collection is `verified_terminal_financial_non_success` **and** current dunning/renewal authority permits another retry.
8. `requires_action` is active; it never authorizes a new ordinal.
9. A local PaymentIntent `failed` value is not sufficient to authorize the next ordinal.

### 7.2 Dispatch epoch lifecycle

For one collection:

`not_started(epoch N)`\
→ `may_have_been_reached(epoch N)`

only by exact expected-epoch compare-and-set after validating exact Order/PaymentIntent/physical generation. Commit this transition **before outbound provider mutation**.

If the worker dies or times out after that commit, the provider may have received the request. The same collection/PaymentIntent/idempotency key must be reconciled/replayed safely; never create a fresh collection merely because the caller lacks a response.

Pre-submission fence:

`not_started(epoch N)`\
→ `not_submitted(epoch N)`

only when provider submission is proven not to have begun. For a physical renewal, exact reservation release/fence and the collection transition must be serialized in the same transaction using current exact-generation authority.

`not_submitted(epoch N)` does **not** mean payment failed. Financial outcome remains `unresolved`.

Resume:

`not_submitted(epoch N)`\
→ `not_started(epoch N+1)`

on the **same collection** after the previous epoch is fenced. If physical inventory is needed, bind the fresh exact reservation generation before dispatch.

Do not skip epochs.

### 7.3 Financial lifecycle

Legal transitions:

- `unresolved → requires_action`
- `unresolved → verified_success`
- `unresolved → verified_terminal_financial_non_success`
- `requires_action → verified_success`
- `requires_action → verified_terminal_financial_non_success`
- identical terminal replay may be accepted idempotently

Illegal:

- terminal → nonterminal
- `verified_success → anything else`
- `verified_terminal_financial_non_success → verified_success` unless accepted current Payments finality semantics explicitly demonstrate that the former was not truly terminal (if that is possible, then the state must not have been recorded as terminal in the first place).

Do not infer terminal financial non-success from `not_submitted`, cancellation, local timeout, local PI failure, worker exhaustion, or lack of callback.

## 8. Bound commercial contract

Provider/payment construction must use immutable fields on the bound RenewalAttempt:

- exact period start/end;
- plan revision identity;
- variant identity where applicable;
- quantity;
- amount in integer minor units;
- currency;
- expected subscription version / charged contract version;
- charged contract snapshot;
- exact renewal identity.

Mutable current/pending Subscription/Plan fields may be used only for present-time **authority/operational checks** (e.g. cancellation, suspension, retry due time, inventory availability), never to redefine the commercial amount/currency/variant of the already-bound occurrence.

If persisted Order or PaymentIntent evidence conflicts with the bound RenewalAttempt, fail closed before provider mutation.

## 9. Order and PaymentIntent reuse

One RenewalAttempt + one renewal Order may survive multiple collection attempts.

For each collection:

1. Reuse/create the exact Order for the bound occurrence through current Order/Payments domain surfaces.
2. Validate existing Order identity/totals/currency/items against the bound contract.
3. Create or reuse exactly one PaymentIntent for the collection.
4. Its idempotency key is `renewal-collection:<collection_attempt_id>`.
5. Same collection replay => same PaymentIntent/idempotency key.
6. New collection ordinal after certified terminal non-success => new collection identity and therefore a new PaymentIntent identity/key.
7. Do not fall back to legacy `RenewalAttempt.payment_intent_id` as downstream success authority once the collection lifecycle is active.

## 10. Provider boundary

Subscriptions must not invent a second provider-finality model.

Use accepted Payments functionality for:

- provider request construction/dispatch;
- provider observation;
- provider finality;
- exact PaymentIntent validation;
- `PaymentOutcomeResolver`;
- exact payment application identity.

If a typed system/domain API is missing, extend the smallest accepted Payments domain surface. Do not call provider modules directly from workers/web in violation of repository boundaries.

Before the outbound provider mutation, durable local state must already establish:

- exact collection id;
- exact PaymentIntent id;
- exact Order/renewal association;
- dispatch epoch;
- `may_have_been_reached`.

## 11. Physical inventory

Physical inventory is an operational precondition, not a source of commercial identity.

- `reservation_generation_id` records the exact generation owned by the collection/epoch.
- Validate with accepted `Store.Orders.guard_exact_generation/4`.
- No unlocked exact-generation read is authoritative.
- Pre-submission fence may release only the exact active generation.
- A stale release/fence cannot release a newer generation.
- A collection whose provider request may have been reached must not casually release/replace physical ownership as if no payment could exist; follow accepted cancellation/payment settlement behavior.
- Digital/nonphysical renewals must not be forced through physical-generation requirements.

## 12. Cancellation and suspension

### Cancellation

Before new provider mutation, current cancellation authority must be checked under the same accepted locking/serialization model as JC-281.

If cancellation has withdrawn authority before dispatch:
- do not make a new provider mutation;
- fence/release exact pre-submission physical ownership where legal;
- preserve financial truth as unresolved unless provider evidence says otherwise.

If dispatch is already `may_have_been_reached`:
- do not pretend it was not submitted;
- reconcile exact provider truth;
- if exact money later succeeds after cancellation-first, preserve payment truth, do not reactivate or consume stock, and allow accepted remediation refund path to run exactly once.

### Suspension

When the subscription is `suspended`:
- do not start a new collection;
- do not allocate a new collection ordinal;
- do not perform a new automatic provider mutation for a collection that had not already crossed the dispatch point;
- do allow reconciliation of a `may_have_been_reached` exact collection;
- allow late exact success to flow into the existing JC-265 recovery semantics.

### Terminal subscription states

`canceled` and `expired` never gain new renewal/collection authority.

## 13. JC-230 boundary

JC-229 must produce exact durable success evidence but must not apply the subscription renewal itself.

Downstream success handoff must identify:

- `order_id`
- `renewal_attempt_id`
- `collection_attempt_id`
- `payment_intent_id`

JC-230 must never be forced to infer the winning PaymentIntent from a stale/legacy RenewalAttempt field.

## 14. Database invariants

Use Ash resource constraints plus database constraints/indexes.

Required durable constraints:

1. unique `(renewal_attempt_id, collection_ordinal)`;
2. at most one active (`unresolved` / `requires_action`) collection per renewal attempt;
3. unique non-null `payment_intent_id`;
4. `collection_ordinal > 0`;
5. valid dispatch-state enum values;
6. valid financial-outcome enum values;
7. epoch/fence consistency:
   - `dispatch_epoch > 0`;
   - `0 <= fenced_through_epoch <= dispatch_epoch`;
   - `not_submitted` implies `fenced_through_epoch == dispatch_epoch`;
   - active `not_started` or `may_have_been_reached` after a fence implies the expected next-epoch relationship;
   - fence metadata is all-null at epoch 1 before any fence and all-present when a fence exists;
8. non-`unresolved` financial outcome requires a PaymentIntent;
9. terminal financial outcomes cannot regress through any public action.

Generate a **fresh migration against current main**. Do not copy the historical migration verbatim. Update Ash snapshots with the repository’s current commands and verify generated diff manually.

## 15. Error/observability policy

- Reuse registry-backed `SCREAMING_SNAKE_CASE` errors where current semantics already cover the case.
- Add only genuinely new stable error codes.
- Emit useful telemetry around:
  - collection start/replay;
  - dispatch claim;
  - pre-submission fence/resume;
  - provider dispatch outcome category;
  - financial refresh/reconciliation;
  - ordinal allocation;
  - blocked authority/conflict.
- Do not include secrets/provider payloads in logs.
- Do not log mutable subscription fields as if they were the bound commercial contract.

## 16. Required deterministic tests

At minimum prove:

### Identity / DB
- first collection gets ordinal 1;
- replay returns same active collection;
- concurrent start creates one active row;
- ordinals remain contiguous;
- unique PI association;
- DB rejects contradictory epoch/fence states.

### Bound contract
- amount/currency/variant/quantity come from RenewalAttempt even if current Subscription/Plan changes afterward;
- conflicting persisted Order/PaymentIntent evidence blocks provider call;
- retry uses the same bound commercial identity.

### Dispatch / crash / replay
- claim persists `may_have_been_reached` before provider mutation;
- crash after claim but before response does not create new collection/PI;
- timeout/unknown outcome keeps same collection active;
- stale epoch claim loses;
- pre-submission fence and dispatch claim race has one legal winner;
- `not_submitted` never becomes financial failure;
- resume increments epoch exactly by one.

### Provider finality
- `requires_action` remains active;
- local failed PI without provider terminal evidence remains unresolved/reconcilable;
- exact provider success becomes `verified_success`;
- provider-certified terminal non-success enables later ordinal subject to dunning authority;
- success is monotonic under reordered callbacks/reads.

### Inventory
- exact generation must be active before dispatch;
- stale generation cannot be released;
- fence/release race with replacement generation is safe;
- nonphysical renewal does not require inventory.

### Cancellation / suspension
- cancellation-first before dispatch => zero provider mutation;
- cancellation after claim => reconciliation, not fictitious “not submitted”;
- later success after cancellation-first preserves money truth and drives exactly one remediation refund without reactivation/stock consumption;
- suspended subscription gets no new collection/dispatch;
- already-reached suspended collection may reconcile;
- late exact success can feed accepted JC-265 recovery;
- canceled/expired never get new authority.

### Downstream boundary
- success handoff includes exact collection + PI identity;
- no success path falls back to stale `RenewalAttempt.payment_intent_id`.

## 17. Performance acceptance

Renewals are a repository-defined hot path.

PR must include a **Performance & Scaling Review** covering:

- hot/warm/cold path;
- exact query counts for representative JC-229 operations;
- N+1 risk;
- new index cost/selectivity;
- provider read/write bounds;
- Oban uniqueness/idempotency;
- cache stance (cache cannot be correctness authority);
- telemetry;
- contention/lock ordering.

Do not carry historical PR #127 query numbers forward as current claims. Measure current implementation.

## 18. Completion criteria

JC-229 is ready for independent review only when:

1. all relevant NewU locked CER requirements are mapped to reusable Store invariants/tests;
2. exact current-main diff is focused on JC-229;
3. migration/snapshots align;
4. targeted tests pass;
5. full repository required checks pass;
6. exact-head CI passes;
7. race/crash/provider-ambiguity tests are deterministic;
8. PR documents lifecycle matrices, DB invariants, performance, and CER conformance;
9. no JC-230 side effects have leaked into JC-229;
10. no historical governance workflow has been resurrected as an execution gate.
