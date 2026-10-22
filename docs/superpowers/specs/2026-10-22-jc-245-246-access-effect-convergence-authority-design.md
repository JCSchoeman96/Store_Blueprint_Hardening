# JC-245/246 AccessEffect convergence authority design

Status: A1 design pass. Review draft only. This document does not authorize implementation.

- Reviewed base: 43d5487927af68b33df754c0ca0695b09fabacca
- Reviewed tree: 754f03502c9a4b8e6f049d6e6724340d6f31f5a8
- Review-start repository state: `main` at the reviewed base; these two drafts were the only untracked paths; one worktree.

## Decision

The current main source supports a bounded design for shared Subscription-source convergence and separate EFFECTIVE and NON_EFFECTIVE AccessEffect executors. The shared foundation can be planned as its own PR. JC-245 and JC-246 remain blocked on that foundation. JC-300 remains a separate later source-writer cutover gate.

This pass does not claim global grant convergence. Existing legacy writers can still bypass the AccessEffect fence until their assigned cutover. It does not authorize coding, change Linear state, or revise SBH-50.

## Relationship to accepted work

- JC-342 is accepted on this base. AccessEffect now persists exact valid_from_at evidence and uses fingerprint v2 for new rows. JC-342 preserves historical v1 rows and permits only an exact nil-start v1 compatibility match; the recovery target must use persisted evidence rather than worker time. See docs/superpowers/specs/2026-10-20-jc-342-accesseffect-start-boundary-design.md and lib/store/subscriptions/access_effect.ex:49-63, 338-355.
- ENT-T1 is accepted on this base. Entitlement evaluation uses explicit as_of with the interval [valid_from_at, valid_to_at). Cachex keeps raw grants and its 60-second TTL. See docs/superpowers/specs/2026-10-21-entitlements-temporal-read-boundary-design.md and lib/store/entitlements/types/entitlement_set.ex:18-79.
- SBH-50 is a frozen historical record. Its earlier base and dependency pins are provenance, not current-main gates. This design uses its ownership split and current code evidence without editing or re-admitting SBH-50. The current mix.lock pins Ash 3.36.1 and AshPostgres 2.13.0.

## Fingerprint byte contract and compatibility

Keep the current `AccessEffect.target_fingerprint/1` byte contract unchanged. Version 2 hashes this exact ordered descriptor:

```text
{
  :store_subscriptions_access_effect_target,
  2,
  Ecto.UUID.dump(subscription_id) bytes,
  source_version,
  disposition,
  entitlement_kind,
  entitlement_scope_key,
  DateTime.to_unix(valid_from_at, :microsecond) or nil,
  DateTime.to_unix(valid_until_at, :microsecond) or nil,
  Ecto.UUID.dump(source_order_line_item_id) bytes,
  Ecto.UUID.dump(contract_change_id) bytes or nil,
  Ecto.UUID.dump(plan_revision_id) bytes
}
```

Encode the tuple with `:erlang.term_to_binary(descriptor, [:deterministic])`, hash the bytes with SHA-256, then encode the digest as lowercase Base16. Tuple order, atom and integer values, raw UUID bytes, datetime microseconds, deterministic Erlang encoding, and lowercase hex are part of the contract. Do not substitute UUID text, JSON, formatted timestamps, a map, or another encoding. The current implementation is at `lib/store/subscriptions/access_effect.ex:338-391`.

Version 1 used the same domain atom and all the same fields except `valid_from_at`: its descriptor begins with version integer `1`, then subscription UUID bytes, source_version, disposition, entitlement_kind, entitlement_scope_key, valid_until_at microseconds or nil, source order line item UUID bytes, optional contract change UUID bytes or nil, and plan revision UUID bytes. It used the same deterministic Erlang encoding, SHA-256, and lowercase Base16. Do not add a reconstructed start to this legacy descriptor or rewrite a stored fingerprint.

Validate persisted evidence in this order:

1. Recompute v2 from the AccessEffect's persisted fields. A match passes fingerprint integrity.
2. Only after a v2 mismatch, and only when persisted `valid_from_at` is nil, recompute the exact v1 descriptor from those same persisted fields. A match passes fingerprint integrity. A mismatch fails closed.
3. If persisted `valid_from_at` is non-nil and v2 mismatches, fail closed without trying v1. Never infer a historical start from Subscription, Plan, worker time, or any other source.

Fingerprint integrity and target executability are separate checks. A historical EFFECTIVE pair with nil `valid_from_at` may pass v1 integrity, but it is incomplete for execution. Fail before calling Entitlements. Do not converge grants, mark APPLIED, or classify it as stale or superseded. EFFECTIVE nil/nil with nil start and the current NON_EFFECTIVE nil-start empty target are legitimate executable empty targets. An EFFECTIVE pair still requires a persisted non-nil start, regardless of fingerprint version.

## Current state and resource map

| Resource or path | Current role and evidence |
|---|---|
| Subscription | Owns commercial lifecycle, aggregate_version, and source target derivation. aggregate_version is at lib/store/subscriptions/subscription.ex:30-34. The locked read uses FOR UPDATE in lib/store/subscriptions/facade.ex:2971-2982. |
| AccessEffect | Stores one immutable desired target per Subscription source version. It has a unique subscription_id/source_version identity, disposition, target pair, valid_from_at, valid_until_at, and v2 target_fingerprint. See lib/store/subscriptions/access_effect.ex:18-107. |
| AccessEffect status | Current enum values are required, pending, applied, failed_retryable, and superseded. See lib/store/subscriptions/types/access_effect_status.ex:1-8. |
| AccessEffect reads | The current selector sorts by source_version descending and limits to one at lib/store/subscriptions/access_effect.ex:133-140. Existing execution recovery selects non-effective required, pending, or failed_retryable rows by updated_at/id at :142-173. |
| EntitlementGrant | Stores durable grant rows. Its :issue action upserts on unique_user_scope_source, but its upsert_fields omit valid_from_at. The resource currently defaults valid_from_at to DateTime.utc_now(). See lib/store/entitlements/entitlement_grant.ex:30-47, 104-108, 129-145. |
| Entitlements facade | The strict issue helper and suspension revoke helper require an existing transaction. The issue helper still supplies worker time, and the revoke helper updates grants one at a time. See lib/store/entitlements/facade.ex:97-222, 243-360. |
| Cache and PubSub | Cachex is a read projection with a 60-second TTL. The facade calls invalidation after its write paths, but its public post-commit entrypoint does not check Repo.in_transaction? today. See lib/store/entitlements/cache.ex:8-104 and lib/store/entitlements/facade.ex:226-240, 394-398. |
| Recovery worker | The existing Oban worker is unique over worker, queue, and args for 55 seconds, with max_attempts 5. It carries keyset cursors. It is orchestration only. See lib/store/workers/run_subscription_access_effect_recovery_worker.ex:1-109. |

AccessEffect is established today for suspended recovery, scheduled cancellation, and failed-payment suspension. The call sites are lib/store/subscriptions/facade.ex:7158-7178, 7654-7666, and 7948-7974. The initial paid-order subscription and immediate cancellation paths do not establish an AccessEffect today.

The existing non-effective executor is partial. It locks Subscription then candidate AccessEffect, reads the latest effect, derives a reason from Subscription state, calls the row-by-row revoker, and marks APPLIED in one local transaction. Its currentness predicate requires aggregate_version equality at lib/store/subscriptions/facade.ex:8338-8408. That equality is wrong for an unrelated aggregate bump. It is a current implementation defect, not the A1 rule.

## Ownership

| Owner | Responsibility | Exclusions |
|---|---|---|
| Store.Subscriptions | Establish immutable AccessEffect evidence, serialize the source, validate currentness, choose the exact disposition and target, and mark that exact effect APPLIED after complete convergence. | Does not mutate EntitlementGrant rows directly in the future executor paths. |
| Store.Entitlements | Converge the complete grant set for exactly one Subscription source, inside the caller-owned PostgreSQL transaction. Owns the post-commit Cachex and PubSub projection helper. | Does not load Subscription or Plan policy, derive targets from status, choose current effects, or mark AccessEffect APPLIED. |
| AccessEffect executor | One separate EFFECTIVE executor in JC-245 and one separate NON_EFFECTIVE executor in JC-246. Each uses the shared source fence and Entitlements convergence authority. | No combined generic executor and no cross-source mutation. |
| Oban recovery worker | Page bounded recovery selectors and call the appropriate executor. | Queue order, uniqueness, retries, and worker memory are not correctness authority. |
| JC-300 | Prove source coverage and cut over all remaining direct grant writers. | It does not merge into either executor PR. |

No NewYou target-set or multi-component policy is part of this design.

## Target cardinality and temporal evidence

The source target has zero-or-one cardinality.

| AccessEffect evidence | Exact Subscription-source grant set |
|---|---|
| EFFECTIVE with a complete kind/scope pair | Exactly one active grant with that pair and exact persisted interval. |
| EFFECTIVE with nil/nil kind and scope | Empty set. The Subscription remains commercially effective; Entitlements creates no placeholder grant. |
| NON_EFFECTIVE | Empty set. This remains semantically distinct from EFFECTIVE nil/nil. |

A half-present pair is invalid. Do not add dummy entitlements, collections of targets, or NewYou composition.

For a pair target, copy AccessEffect.valid_from_at to EntitlementGrant.valid_from_at and AccessEffect.valid_until_at to EntitlementGrant.valid_to_at without rounding or reading execution time. The current establishment validation requires a start for an effective pair and rejects start >= end when an end exists. It permits nil start only for an empty target. See lib/store/subscriptions/facade.ex:8779-8809.

Use a dedicated bounded EntitlementGrant create/upsert action for exact-source convergence. On an identity conflict, it writes the complete target state: exact persisted `valid_from_at`, exact persisted `valid_to_at`, `status: :active`, `revoked_at: nil`, and `revoked_reason: nil`. The caller verifies the returned row's full identity, exact interval, active status, and cleared revocation evidence. It does not use worker time or the resource default as target evidence.

Keep the existing generic `:issue` action's upsert fields and the resource's `valid_from_at` default unchanged in F0. Existing paid-order and charged-renewal callers pass a worker-time start, so adding `valid_from_at` to the generic upsert would change their conflict replay behavior. No bounded caller-impact review authorizes that global change in this design. If the dedicated action cannot provide one bounded Ash upsert with the required fields, stop F0 and request a bounded caller-impact review before changing `:issue`. Do not remove the `valid_from_at` default without separate proof.

The pinned Ash create path reads `upsert_identity` and `upsert_fields` from each create action, and AshPostgres executes a single create through its upsert-capable bulk-create path (`deps/ash/lib/ash/actions/create/create.ex:136-186`, `deps/ash_postgres/lib/data_layer.ex:2337-2445, 3143-3169`). F0 must still capture query or SQL telemetry to confirm the implemented action keeps the stated DML bound.

The interval is start-inclusive and end-exclusive under ENT-T1. Entitlements receives a typed immutable input containing:

- subscription_id and user_id;
- disposition;
- entitlement_kind and entitlement_scope_key, either both present or both nil;
- exact valid_from_at, nil only when the target is legitimately empty;
- exact valid_to_at;
- reason as caller-supplied mutation metadata;
- access_effect_id, source_version, and target_fingerprint.

The input contains no Subscription or Plan struct, status, access_on_cancel or access_on_past_due policy, lookup instruction, or worker execution time. Reason is metadata only. It does not select the target, affect currentness, or enter the target fingerprint.

Keep three concepts separate:

- Desired disposition is EFFECTIVE or NON_EFFECTIVE.
- EntitlementGrant persists an active or revoked row state.
- ENT-T1 classifies a read at `as_of` as FUTURE, EFFECTIVE, ENDED, REVOKED, or INACTIVE.

These values describe different facts and must not be collapsed into one lifecycle.

## AccessEffect and convergence state machines

AccessEffect execution follows these transitions:

```text
REQUIRED
  -> PENDING
  -> APPLIED

PENDING
  -> FAILED_RETRYABLE
  -> PENDING

PENDING
  -> SUPERSEDED

APPLIED and SUPERSEDED are terminal.
```

The candidate may enter convergence only while the caller holds the exact Subscription lock and candidate AccessEffect lock, the latest effect ID equals the candidate ID, `effect.source_version <= subscription.aggregate_version`, the fingerprint passes the ordered integrity check, the target is executable, and the candidate status is executable. A stale candidate with valid, executable evidence may become SUPERSEDED without grant mutation. An incomplete nil-start EFFECTIVE pair fails before stale handling and is not marked SUPERSEDED.

Exact-source convergence follows this transaction-local state machine:

```text
UNCONVERGED
  -> LOCKED
  -> CONVERGING
  -> CONVERGED

Any error during CONVERGING
  -> ROLLBACK
```

No partial grant mutation may commit. The outer transaction rolls back the entire set and the APPLIED transition on any convergence error.

## Shared source fence and transaction contract

The caller owns one outer Store.Repo PostgreSQL transaction. A shared internal Subscription-side fence must run only inside that transaction and fail closed otherwise. Use this order:

1. Read the candidate effect ID without a row lock only to obtain subscription_id.
2. Lock that exact Subscription row with `FOR UPDATE`.
3. Lock the candidate AccessEffect row with `FOR UPDATE`.
4. Require `effect.source_version <= subscription.aggregate_version`. A greater value fails closed. Equality is not required.
5. Recompute v2 from persisted fields first. Only after a v2 mismatch, try v1 when persisted `valid_from_at` is nil. Any mismatch fails closed. Do not rewrite a fingerprint or reconstruct a start.
6. Validate target executability before stale handling. An EFFECTIVE pair with nil start is execution-incomplete even if v1 integrity passed. Fail without grant convergence, APPLIED, or SUPERSEDED. EFFECTIVE nil/nil with nil start and the current NON_EFFECTIVE nil-start empty target remain executable.
7. Read the latest AccessEffect for the Subscription, ordered by source_version descending. Require its ID to equal the candidate ID before convergence. A valid, executable candidate whose ID is not latest may be superseded without touching grants.
8. Permit execution only from required, pending, or failed_retryable. Applied and superseded are non-executable.
9. Build the typed Entitlements input from the locked Subscription identity and persisted AccessEffect evidence. Do not load Plan or infer a target from current status.

The latest effect ID is the source-target ordering check. The source_version inequality allows unrelated aggregate updates while the latest effect remains the same. The current equality comparison at lib/store/subscriptions/facade.ex:8383-8385 must be removed from executor currentness.

Effect-establishment paths also lock the exact Subscription row before reusing or inserting an effect. The shared Subscription lock therefore serializes target creation with execution. The executor keeps that lock through convergence and the APPLIED write, so a second latest-effect read before APPLIED is unnecessary. If a future effect writer can insert without taking this same source lock, stop and resolve that writer before using the fence.

The locked Subscription row is the source-level mutex. The candidate AccessEffect row lock protects that exact obligation and its lifecycle. Exact-source grant row locks protect only rows that already exist; when the source has no grants, that query locks no rows and cannot serialize concurrent work. Grant-row locks alone are insufficient. Both the JC-245 and JC-246 executors must hold the Subscription `FOR UPDATE` lock when they invoke shared convergence and through commit.

Within the same transaction, Entitlements checks `Repo.in_transaction?` and locks only rows with `source_kind = subscription` and `source_id = the exact subscription_id`, ordered by native PostgreSQL UUID id ascending with `FOR UPDATE`. The existing `entitlement_grants_source_index` covers this exact-source selector. Do not cast UUIDs to strings for lock ordering.

Converge the complete set with set-oriented writes:

- EFFECTIVE with a pair: one dedicated convergence upsert for the desired identity, then one atomic bulk update for every other active row in the exact source set.
- EFFECTIVE nil/nil or NON_EFFECTIVE: one atomic bulk update for every active row in the exact source set.
- Already non-active rows may remain as history. No other source or Subscription is touched.
- Any read, validation, upsert, bulk update, or APPLIED transition error rolls back the outer transaction. No per-grant update loop may return partial success.

The current lock and mutation code has no finite grant-row count bound. A set-oriented path is feasible with the locked Ash version: Ash.bulk_update/4 documents a single-pass query update for fully atomic actions at deps/ash/lib/ash.ex:3840-3848, and AshPostgres implements update_query at deps/ash_postgres/lib/data_layer.ex:1840. The current `:revoke` action is marked `require_atomic?(false)`, so the future implementation must add an atomic-safe action and call `bulk_update` with strategy `[:atomic]` only. It must fail if Ash cannot use that strategy; stream fallback is prohibited. The dedicated convergence upsert is one resource action and one database upsert. This gives a grant mutation bound of at most two DML statements per pair target and one for an empty target, independent of source-row count. The exact-source lock is one ordered indexed query, also independent of source-row count in round-trip count, though it may return all matching rows. Source-row processing cost, memory use, and lock wait remain unmeasured. The implementation PR must capture SQL or query telemetry to verify the bound.

After full set convergence, update that exact effect to APPLIED and store projection_user_ids in the same outer transaction. Commit before any cache invalidation, PubSub, or Ash notifier delivery. A mutation failure must not leave an APPLIED effect or a partial grant set.

The executor transaction order is:

```text
caller-owned PostgreSQL transaction
  -> lock exact Subscription source
  -> lock candidate AccessEffect
  -> read latest effect and prove currentness
  -> build immutable target input from the persisted effect
  -> lock exact-source grant rows
  -> converge the complete grant set
  -> mark that exact effect APPLIED
  -> commit
  -> invalidate Cachex
  -> publish PubSub
```

The source lock stays held through commit. It prevents a newer effect producer from changing the latest target during convergence. Any failure before commit rolls back grant changes and APPLIED together. Projection runs only after a successful commit.

## Replay, stale effects, and failures

- Replaying an exact executable target within the local transaction is idempotent: the dedicated upsert converges the one desired identity and the bulk update removes any other active row for that source.
- Applied and superseded effects do not execute again. Projection repair for an applied effect is separate from grant convergence.
- A candidate whose ID is not the latest effect cannot mutate grants. If its lifecycle allows it, move it through pending to superseded using the existing transitions.
- A candidate with source_version greater than the locked aggregate version fails closed. Do not treat it as current.
- A fingerprint mismatch fails closed before any grant mutation.
- A convergence error rolls back all source grant changes and the APPLIED transition. Record a retryable status only after that rollback, in a separate transaction, and only if the same candidate remains current.
- `LOCAL_TRANSACTION_IDEMPOTENCE=YES` applies while the Subscription source mutex is held and the same target is replayed in the caller's transaction.
- `GLOBAL_SOURCE_CONVERGENCE_IDEMPOTENCE=NOT_YET_PROVEN`. Legacy source writers can bypass the fence until JC-300; do not promote local replay behavior into a global convergence claim.
- `NON_EFFECTIVE_REPLAY_IDEMPOTENT=LOCALLY_YES_GLOBALLY_NOT_PROVEN` remains true for the same reason.

## Recovery selectors and index scope

Keep the existing non-effective selector and index unchanged:

- Selector: disposition non_effective; status required, pending, or failed_retryable; updated_at <= through_updated_at; keyset cursor updated_at/id; bounded limit 1..500.
- Index: (updated_at, id) with partial predicate disposition = non_effective and status in required, pending, failed_retryable.
- Source: lib/store/subscriptions/access_effect.ex:142-173 and 310-315.

F0 adds a separate effective selector with the same cursor and bound, changing only the disposition predicate to effective. F0 adds the matching partial index on `(updated_at, id) WHERE disposition = 'effective' AND status IN ('required', 'pending', 'failed_retryable')`, the resource selector, one migration, and its generated AccessEffect snapshot. Do not replace or broaden the non-effective index. The projection repair selector and index remain unchanged. F1 consumes the F0 selector and index and adds recovery orchestration without a migration.

The only authorized future migration is the new effective recovery partial index and its generated AccessEffect resource snapshot update. Do not add columns, identities, grant indexes, or unrelated constraints. MIGRATION_AUTHORIZED=YES means this narrow future-plan scope only. It does not authorize executing the migration now.

## Projection lifecycle and post-commit repair

Projection is derived state. Keep the AccessEffect lifecycle state APPLIED and the existing projection evidence columns. Model delivery as:

    COMMITTED_NOT_PROJECTED -> CACHE_INVALIDATED -> PUBSUB_DELIVERED

After the outer database commit:

1. The Entitlements-owned helper fails closed if Repo.in_transaction? is true.
2. Invalidate the Cachex raw EntitlementSet.
3. Broadcast entitlements_invalidated.
4. Mark projection_delivered_at only after both steps succeed.

A cache or PubSub failure cannot undo grant truth or the committed APPLIED effect. Leave projection_delivered_at nil so the existing projection repair selector can retry. The current projection selector and partial index use APPLIED, projection_user_ids present, projection_delivered_at nil, ordered by inserted_at/id at lib/store/subscriptions/access_effect.ex:175-205 and 317-320. Retry may repeat invalidation and broadcast. Do not add Redis, ETS correctness state, a generic outbox, or a new AccessEffect state.

## Legacy writer audit

The search covered every EntitlementGrant and entitlement_grants reference in lib, all four Subscription-source write facade calls, Store.Admin code, system callers, the Entitlements domain, and the public surface registry. It found four source-writing call sites, with the charged-renewal call split into two distinct execution lanes. No Admin, JSON:API, direct Repo, or other system grant writer exists in current source. The resource's admin policy is not itself a caller. Review-required count is zero for this base.

| Lane | Current behavior and evidence | Future owner | Class |
|---|---|---|---|
| Initial paid-order subscription issue | create_subscriptions_from_paid_order_for_system runs issue_subscription_entitlements_after_commit. maybe_issue_entitlement converts issue errors to skipped. The facade helper derives valid_from_at from DateTime.utc_now(). See lib/store/subscriptions/facade.ex:2057-2074, 3704-3712, 3786-3795 and lib/store/entitlements/facade.ex:53-95. No AccessEffect is established in this path. | JC-300 source cutover | RETAIN_UNTIL_JC300 |
| Ordinary charged renewal | finish_paid_renewal_reconciliation calls sync_charged_renewal_entitlement, which uses the strict single-grant issue helper and a separate transaction. The helper derives valid_from_at from worker time. See lib/store/subscriptions/facade.ex:2841-2851, 7526-7554 and lib/store/entitlements/facade.ex:97-156. Ordinary renewals do not establish an AccessEffect. | JC-300 source cutover | RETAIN_UNTIL_JC300 |
| Suspended charged-renewal recovery | apply_first_reconciliation establishes an EFFECTIVE AccessEffect using attempt.period_start_at, then the paid-renewal finish path still invokes the strict issue helper. Thread the effect ID through the result and have JC-245 execute it instead of issuing a second legacy grant. See lib/store/subscriptions/facade.ex:7064-7089, 7158-7178, 2841-2851, 7526-7554. | JC-245 | REPLACE_IN_JC245 |
| Immediate cancellation | finalize_immediate_cancellation calls the legacy post-commit revoke and discards its result. It updates source grants one at a time and can suppress mutation failures. No AccessEffect is established for this path. User and Admin API callers share this path. See lib/store/subscriptions/facade.ex:2162-2208, 3893-3906 and lib/store/entitlements/facade.ex:160-195, 346-360. | JC-300 source cutover | RETAIN_UNTIL_JC300 |
| AccessEffect non-effective execution | execute_suspension_access_effect_for_system covers suspension and scheduled-cancellation effects. The executor locks the source and candidate, but calls the row-by-row strict revoker. Its current aggregate equality check is wrong. See lib/store/subscriptions/facade.ex:156-194, 8338-8456 and lib/store/entitlements/facade.ex:198-222, 243-344. | JC-246 | REPLACE_IN_JC246 |

Counts use distinct execution lanes, not raw call-site count. There are five lanes, four write facade call sites, and no unclassified writer. The three retained lanes are explicit compatibility debt, not evidence of a global fence. JC-300 must audit them again at its own current base.

## Lock order and compatibility

All effect executors use the same lock order: exact Subscription, candidate AccessEffect, exact-source EntitlementGrant rows in native UUID order. Do not lock grants before the Subscription or effect. Do not use UUID text sorting.

The shared Entitlements function never starts or commits the outer transaction. It rejects calls outside one. Legacy issue and revoke APIs remain temporarily callable for the three retained lanes. They are not aliases for the convergence authority and do not make its guarantee global.

The exact-source index remains (source_kind, source_id). The non-effective recovery index stays in place. The effective recovery index is additive. Grant history stays in the existing table and identity. No tenant_id, Redis representation, ETS correctness state, multi-target schema, or new source lifecycle state is introduced.

## Performance and scaling review

| Dimension | A1 design |
|---|---|
| Data authority | PostgreSQL stores AccessEffect and EntitlementGrant truth. Redis has no representation, and ETS holds no correctness state. |
| Hot, warm, cold | Hot reads use Cachex raw EntitlementSet. Warm writes use a caller-owned PostgreSQL transaction, exact Subscription lock, exact-source row locks, and set-oriented DML. Cold recovery uses bounded, keyset-paginated AccessEffect selectors. |
| Query count and N+1 | Database round trips are bounded independently of source-row count. Grant mutation uses at most two DML statements for a pair target and one for an empty target. The transaction also performs one exact-source ordered row-lock read. Candidate, Subscription, latest-effect, and lifecycle operations have a fixed count. The exact total statement count and lock waits remain UNMEASURED until implementation telemetry. Per-grant mutation loops are prohibited. |
| Indexes | Keep entitlement_grants_source_index on (source_kind, source_id), the existing partial non-effective recovery index, and the existing projection repair index. Add only the effective partial recovery index. Do not add a broad or user lookup index for this work. |
| Cache and stampede | Keep Cachex raw grants and its 60-second TTL. Invalidate Cachex after commit, then publish PubSub. No new cache, TTL, invalidation mode, or stampede mechanism. |
| Oban | Reuse the existing recovery worker only. Preserve bounded keyset pages, uniqueness, and idempotent executor behavior. Oban is a retry mechanism, never correctness authority. No new job is authorized. |
| External I/O | No outbound I/O inside the transaction. Cachex and PubSub run after commit. |
| Telemetry | Future implementation records query and DML counts, source-row count, lock wait, convergence failures, recovery lag, projection failures, and cursor progress. Do not log user data. |
| 100,000 scale | No table scan or global lock. Recovery is index-backed and limited to 1..500 rows per page. Grant DML remains exact-source and set-oriented. There is no per-user Redis correctness registry and no synchronous external I/O. Per-source row count, memory, GC, lock wait, Oban mailbox behavior, throughput, and convergence are UNMEASURED. No capacity claim follows from this static audit. Any convergence or no-accumulation claim needs at least two equivalent bounded repetitions. |

Runtime Resource Safety Review for this A1 round is NOT_APPLICABLE because it changes documentation only. Each later runtime PR must review memory, GC, mailbox behavior, cleanup, and post-load convergence.

## Authorized future surfaces

This review draft proposes these future file boundaries only:

- F0 shared foundation: lib/store/entitlements/facade.ex, lib/store/entitlements/entitlement_grant.ex for a dedicated convergence action that leaves generic `:issue` behavior and the `valid_from_at` default unchanged, new typed input/result modules under lib/store/entitlements/inputs/ and lib/store/entitlements/types/, lib/store/subscriptions/access_effect.ex for the effective recovery selector, lib/store/subscriptions/facade.ex for the shared internal current-effect fence, one effective-recovery index migration and its generated AccessEffect snapshot, and focused Entitlements, source-fence, and selector tests.
- F1 JC-245: lib/store/subscriptions/access_effect.ex, lib/store/subscriptions/facade.ex, the existing recovery worker and its cursor arguments, and focused executor/recovery tests. F1 uses the selector and index introduced in F0 and adds no migration.
- F2 JC-246: lib/store/subscriptions/facade.ex and focused non-effective executor/projection tests. Keep the existing non-effective selector and index.
- F3 JC-300: the then-current Subscription and Entitlements writer call sites, source-coverage tests, and any separately admitted migration or index work proven necessary at that base.

The only migration admitted by this design is F0's additive effective recovery index and matching snapshot. No runtime, test, or migration work is authorized until its own issue and human approval are accepted.

## Stops and admission gates

Stop the affected phase if the base moves, the repository is dirty, or more than one worktree exists before implementation. Stop if implementation starts under this draft, any non-documentation file changes during A1, currentness still requires source_version equality, latest effect ID or persisted fingerprint cannot be proven, an effective pair uses worker time, nil targets or pair cardinality become ambiguous, a multi-target schema is proposed, any mutation can partially commit, only per-row mutation is possible, recovery selection cannot use its exact partial index, projection/cache/Redis/ETS becomes correctness authority, any writer is unclassified, executors are combined, JC-300 is absorbed into an executor PR, or NewYou policy is introduced.

A1 passes because the proposed design clears those gates: exact effect ID and fingerprint checks are defined, source-version equality is removed, set-oriented mutation has a bounded Ash API path, all five writer lanes are classified, and executor and cutover PRs remain separate. Fingerprint integrity is separate from target executability. A1 does not authorize a global change to `:issue`; F0 uses a dedicated bounded upsert and retains the resource default. Runtime capacity and query latency remain unmeasured and are not claimed.

## A1 machine report

    BASE_SHA=43d5487927af68b33df754c0ca0695b09fabacca
    CURRENTNESS_RULE=LOCK_SUBSCRIPTION_AND_CANDIDATE; LATEST_EFFECT_ID_EQUALS_CANDIDATE; EFFECT_SOURCE_VERSION_LE_LOCKED_AGGREGATE_VERSION; RECOMPUTED_CANONICAL_FINGERPRINT_MATCHES; EXECUTABLE_STATUS_REQUIRED_PENDING_FAILED_RETRYABLE
    SOURCE_VERSION_EQUALITY_REQUIRED=NO
    SOURCE_VERSION_ORDER_RULE=effect.source_version <= subscription.aggregate_version
    FINGERPRINT_RECOMPUTE_REQUIRED=YES
    FINGERPRINT_V2_FIRST=YES
    FINGERPRINT_V1_FALLBACK_ONLY_IF_PERSISTED_VALID_FROM_AT_IS_NIL=YES
    FINGERPRINT_SERIALIZATION=DETERMINISTIC_ERLANG_TERM_BINARY; SHA256; LOWERCASE_BASE16; V2_DESCRIPTOR_IN_SOURCE_ORDER
    FINGERPRINT_INTEGRITY_DISTINCT_FROM_EXECUTABILITY=YES
    HISTORICAL_EFFECTIVE_PAIR_NIL_START=V1_INTEGRITY_MAY_PASS; EXECUTION_INCOMPLETE; FAIL_CLOSED; NO_GRANT_CONVERGENCE; NO_APPLIED; NOT_STALE_OR_SUPERSEDED
    HISTORICAL_FINGERPRINT_REWRITE=NO
    EFFECTIVE_PAIR_NIL_START_EXECUTABLE=NO
    EFFECTIVE_NIL_NIL_NIL_START=LEGITIMATE_EMPTY_TARGET
    CURRENT_NON_EFFECTIVE_NIL_START=LEGITIMATE_EMPTY_TARGET
    EFFECTIVE_WITH_PAIR=ONE_EXACT_ACTIVE_GRANT
    EFFECTIVE_WITHOUT_PAIR=EMPTY_SOURCE_SET
    NON_EFFECTIVE=EMPTY_SOURCE_SET
    NON_EFFECTIVE_REPLAY_IDEMPOTENT=LOCALLY_YES_GLOBALLY_NOT_PROVEN
    LOCAL_TRANSACTION_IDEMPOTENCE=YES
    GLOBAL_SOURCE_CONVERGENCE_IDEMPOTENCE=NOT_YET_PROVEN
    SHARED_CONVERGENCE_AUTHORITY=Store.Entitlements.Facade_TYPED_EXACT_SOURCE_CONVERGENCE_IN_CALLER_OWNED_POSTGRES_TRANSACTION
    EXACT_SOURCE_LOCK_STRATEGY=LOCK_SUBSCRIPTION_THEN_CANDIDATE_EFFECT_THEN_SOURCE_GRANTS_ORDER_BY_NATIVE_UUID_ID_ASC_FOR_UPDATE
    GRANT_ROW_LOCKS_ALONE_ARE_INSUFFICIENT=YES
    SUBSCRIPTION_SOURCE_LOCK_REQUIRED=YES
    JC245_AND_JC246_HOLD_SUBSCRIPTION_LOCK_WHILE_CALLING_SHARED_CONVERGENCE=YES
    SOURCE_SERIALIZATION_AUTHORITY=SUBSCRIPTION_ROW_LOCK
    EMPTY_GRANT_SET_SERIALIZED=YES
    GRANT_ROW_LOCK_ONLY_SUFFICIENT=NO
    MUTATION_DB_CALL_BOUND=DB_ROUND_TRIPS_INDEPENDENT_OF_GRANT_COUNT; MAX_2_SET_ORIENTED_GRANT_DML_FOR_PAIR; MAX_1_FOR_EMPTY_TARGET; ONE_EXACT_SOURCE_LOCK_QUERY; ATOMIC_ONLY
    CONVERGED_GRANT_STATE=EXACT_VALID_FROM_AT; EXACT_VALID_TO_AT; STATUS_ACTIVE; REVOKED_AT_NIL; REVOKED_REASON_NIL
    FULL_INTERVAL_CONVERGENCE=YES
    CONVERGENCE_WRITE_PATH=DEDICATED_BOUNDED_UPSERT
    GENERIC_ISSUE_ACTION_CHANGE=NOT_AUTHORIZED_WITHOUT_BOUNDED_CALLER_IMPACT_REVIEW
    GENERIC_ISSUE_GLOBAL_CHANGE_REQUIRED=NO
    VALID_FROM_DEFAULT=RETAINED
    EFFECTIVE_RECOVERY_SELECTOR=DISPOSITION_EFFECTIVE_AND_STATUS_REQUIRED_PENDING_FAILED_RETRYABLE; UPDATED_AT_ID_KEYSET; LIMIT_1_TO_500
    EFFECTIVE_RECOVERY_INDEX=(updated_at,id)_PARTIAL_DISPOSITION_EFFECTIVE_AND_STATUS_REQUIRED_PENDING_FAILED_RETRYABLE
    EFFECTIVE_RECOVERY_OWNER=F0_SHARED_FOUNDATION
    MIGRATION_AUTHORIZED=YES
    POST_COMMIT_HELPER_TRANSACTION_GUARD=FAIL_CLOSED_WHEN_REPO_IN_TRANSACTION
    LEGACY_WRITERS_TOTAL=5
    LEGACY_REPLACE_JC245=1
    LEGACY_REPLACE_JC246=1
    LEGACY_RETAIN_JC300=3
    LEGACY_REVIEW_REQUIRED=0
    FOUNDATION_PR_SEPARATE=YES
    JC245_PR_SEPARATE=YES
    JC246_PR_SEPARATE=YES
    JC300_CUTOVER_SEPARATE=YES
    JC300_CUTOVER_AUTHORITY=SEPARATE
    F0_PLAN_ONLY_AFTER_AUTHORITY_ACCEPTANCE=YES
    RUNTIME_CHANGED=NO
    TESTS_CHANGED=NO
    MIGRATIONS_CHANGED=NO
    A1_AUTHORITY=PASS
    SHARED_FOUNDATION_ADMISSION=READY_FOR_PLAN
    JC245_ADMISSION=BLOCKED_ON_SHARED_FOUNDATION
    JC246_ADMISSION=BLOCKED_ON_SHARED_FOUNDATION
    JC300=SEPARATE_LATER_GATE
    NEXT_ACTION=STOP_FOR_REVIEW
