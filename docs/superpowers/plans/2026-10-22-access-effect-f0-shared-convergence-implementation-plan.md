# F0 shared AccessEffect convergence and currentness implementation plan

> For agentic workers: this document is for a future implementation session using the executing-plans skill. Implementation is not authorized. Obtain exact-byte plan approval and a dedicated F0 Linear issue before creating an implementation branch. This correction pass changes only this untracked plan.

Goal: provide the shared exact-source Entitlements convergence function, internal exact-effect currentness fence, fingerprint classifier, EFFECTIVE recovery selector, and post-commit projection guard needed by later executors.

Architecture: add one public facade function, `Store.Entitlements.Facade.converge_subscription_source_grants_for_system/1`. Keep the fence and pure final-set validator in unregistered internal modules. The caller owns the transaction and Subscription mutex. Convergence locks the exact-source grants once, upserts at most one complete target, revokes through one atomic UPDATE without returned records, and checks the final active set with `limit 2`.

Stack: Elixir, Phoenix, Ash 3.36.1, AshPostgres 2.13.0, Ecto SQL 3.14.0, Postgrex 0.22.4, Oban 2.24.1, Cachex 4.1.1, Phoenix.PubSub, ExUnit, telemetry.

## Authority and scope

Read these documents before future implementation:

- `docs/superpowers/specs/2026-10-22-jc-245-246-access-effect-convergence-authority-design.md`
- `docs/superpowers/plans/2026-10-22-jc-245-246-access-effect-convergence-implementation-plan.md`
- `docs/superpowers/specs/2026-10-20-jc-342-accesseffect-start-boundary-design.md`
- `docs/superpowers/specs/2026-10-21-entitlements-temporal-read-boundary-design.md`
- `AGENTS.md`
- `docs/governance/performance_scaling.md`

Programme ownership is exactly:

```text
F0
  shared convergence/currentness foundation

F0.5
  ordinary charged-renewal EFFECTIVE AccessEffect producer
  immediate-cancellation NON_EFFECTIVE AccessEffect producer
  bounded source-order reconciliation

JC-245 / F1
  EFFECTIVE executor

JC-246 / F2
  NON_EFFECTIVE executor

JC-300 / F3
  remaining legacy grant-writer cutover
```

F0 adds no production executor or producer caller. Do not implement F0.5, F1, F2, F3, NewYou target composition, or a generic outbox. Do not change historical SBH-50 bytes.

Keep the generic EntitlementGrant `:issue` action byte-identical, including its accepted attributes, upsert fields, identity and skipped-upsert behavior. Keep the existing `:revoke` action and `valid_from_at` resource attribute/default unchanged. Add dedicated actions instead. Do not add an error code, source-cardinality cap, Redis/ETS correctness state, or per-record revoke fallback.

## Reviewed base and resolved facts

The preceding reviewed plan's SHA256 is `5e1a2ea5f8a5c9e028b23de6a7dcb08c4802922dda8fcd7c4664ae40ed5f4bc5`. The human's final exact-byte approval supplies `APPROVED_PLAN_SHA256`; do not embed a self-referential final hash in this file.

Earlier plan-time evidence recorded `origin/main` at `aab23f6afb924828a6f3b3c43bf069b304b6585e`, tree `7202b54750a84d9b525fc0af04974f92bf2c6a25`, one clean worktree on main, no open PRs, and successful canonical CI run `39775551050`. These are historical observations. Future implementation starts from then-current accepted `origin/main`, records its exact SHA, and verifies concrete prerequisites there. Old pins do not impose a separate admission gate.

The following are resolved facts, with regression checks retained in Tasks 0 and 10:

```text
SUBSCRIPTION_AGGREGATE_VERSION_EXISTS=YES
SURFACE_NAMING_SCANS_REGISTERED_FACADE_MODULES_ONLY=YES
```

`Subscription.aggregate_version` is a non-null integer with default 1. `check.surface_naming` iterates the registry's facade modules and their exports. Unregistered internal modules are permitted.

The pinned Ash query-input bulk path can fall back to streaming if full atomicity fails. `strategy: [:atomic]` alone is insufficient evidence. Require a successful `fully_atomic_changeset` precheck, query input, atomic-only options, and SQL telemetry tests. With `return_records?: false`, the pinned atomic result does not provide a reliable affected count. That is an accepted decision, not an open reviewer gate.

```text
AFFECTED_COUNT_AVAILABLE=NO
RETURN_RECORDS_PRODUCTION_USE=NO
SOURCE_CARDINALITY_BOUND=UNMEASURED
SOURCE_CARDINALITY_CAP_ADDED=NO
```

## File map

Create:

- `lib/store/entitlements/inputs/subscription_source_convergence_input.ex`
- `lib/store/entitlements/types/source_convergence_result.ex`
- `lib/store/entitlements/source_convergence.ex`, pure derivation and final-shape validator, internal and unregistered
- `lib/store/subscriptions/access_effect_currentness_fence.ex`, internal and unregistered
- `test/store/entitlements/inputs/subscription_source_convergence_input_test.exs`
- `test/store/entitlements/types/source_convergence_result_test.exs`
- `test/store/entitlements/entitlement_grant_convergence_actions_test.exs`
- `test/store/entitlements/source_convergence_test.exs`
- `test/store/entitlements/source_convergence_validator_test.exs`
- `test/store/entitlements/projection_guard_test.exs`
- `test/store/subscriptions/access_effect_fingerprint_status_test.exs`
- `test/store/subscriptions/access_effect_effective_recovery_test.exs`
- `test/store/subscriptions/access_effect_currentness_fence_test.exs`
- `test/store/subscriptions/source_fence_contention_test.exs`
- Generated migration under `priv/repo/migrations/` and generated AccessEffect snapshot under `priv/resource_snapshots/repo/access_effects/`

Modify:

- `lib/store/entitlements/entitlement_grant.ex`, add the two dedicated actions
- `lib/store/entitlements/facade.ex`, convergence function and projection transaction guard
- `lib/store/subscriptions/access_effect.ex`, classifier, read action and index
- `lib/store/support/governance/surface_registry.ex`, exactly one new facade export
- `test/test_helper.exs`, exclude real-connection tests from ordinary runs
- `.github/workflows/ci.yml`, isolated `real_connections_required` job

Do not modify `lib/store/subscriptions/facade.ex`, error-code registries, existing migrations, or existing entitlement temporal-read behavior.

## Immutable convergence input

`Store.Entitlements.Inputs.SubscriptionSourceConvergenceInput` has `new/1`, an enforced struct, and this type:

```elixir
@type t :: %__MODULE__{
  subscription_id: Ecto.UUID.t(),
  user_id: Ecto.UUID.t(),
  disposition: :effective | :non_effective,
  entitlement_kind: :membership_access | :digital_library | :discount_tier | nil,
  entitlement_scope_key: String.t() | nil,
  valid_from_at: DateTime.t() | nil,
  valid_until_at: DateTime.t() | nil,
  reason: String.t(),
  access_effect_id: Ecto.UUID.t(),
  source_version: pos_integer(),
  target_fingerprint: String.t()
}
```

All listed keys are required, including keys whose exact persisted value can be nil. Validate UUIDs, disposition, existing kind, positive source version, required caller-supplied reason, and required persisted fingerprint. Follow existing typed-input error construction with `VALIDATION_ERROR`. Never derive or replace the evidence, validity dates, fingerprint, or reason from mutable policy.

The input field is `reason`. The revoke action maps it to persisted `revoked_reason`.

Target rules:

- An EFFECTIVE pair has both kind and scope present, mandatory user ID, mandatory DateTime start, and an exact DateTime or nil end. Compare start against end only when an end exists. Reject start greater than or equal to end.
- An EFFECTIVE empty target has kind=nil and scope=nil, mandatory user ID, nil start, and the exact persisted end, which may be nil.
- A NON_EFFECTIVE target has kind=nil and scope=nil, mandatory user ID, nil start, and the exact persisted end, which may be nil.
- Reject half-pairs, NON_EFFECTIVE pairs, and empty targets with a populated start.
- Pair identity depends on kind/scope, never on the end date. A nil end does not make a pair empty.

Preserve timestamp microseconds. Use nil-aware equality for ends: nil equals nil; two DateTimes compare with `DateTime.compare/2`; nil and a DateTime differ.

## Exact-effect currentness fence

The internal `Store.Subscriptions.AccessEffectCurrentnessFence.prove/1` takes only the exact candidate `access_effect_id`. It never starts a transaction or caches evidence. Its result is valid only while the caller's outer transaction holds the source lock. Intended future callers are the F1/F2 executors within the Subscription context. There is no new registered Subscription facade function and no web reference.

Execute this order:

```text
Repo.in_transaction? guard
→ bounded unlocked AccessEffect lookup by exact effect_id, selecting subscription_id only
→ Subscription FOR UPDATE by that subscription_id
→ exact candidate AccessEffect FOR UPDATE by effect_id
→ verify candidate.subscription_id == locked_subscription.id
→ candidate.source_version <= locked_subscription.aggregate_version
→ fingerprint integrity
→ target executability
→ latest AccessEffect read for the Subscription
→ latest.id == candidate.id ? CURRENT : STALE
```

Outside a transaction return `VALIDATION_ERROR` with zero queries. Missing lookup, source, or locked candidate returns `NOT_FOUND`. A changed/mismatching source identity or candidate version greater than aggregate returns `INTERNAL_ERROR`, without stale/current classification. A missing latest row for an existing candidate is `INTERNAL_ERROR`.

Use a private plain Subscription filter plus `FOR UPDATE`, equivalent to `fetch_subscription_for_renewal_locked/1`. Do not load Plan or PlanRevision, reuse mutable policy/status reasoning, or use the raw SQL PlanRevision join in `lock_access_effect_subscription/1`.

The locked candidate is fetched by exact ID, never reconstructed from subscription/version. Re-read the full immutable evidence after acquiring the source lock. Latest read filters that Subscription, sorts source_version descending, limits to 1, and selects id/source_version.

Currentness law:

```text
candidate.source_version > subscription.aggregate_version => FAIL CLOSED
candidate.source_version <= subscription.aggregate_version => MAY continue
latest_effect.id != candidate.id => STALE
latest_effect.id == candidate.id => CURRENT
```

Never substitute aggregate equality or latest source-version equality. Successful evidence includes only the source identity needed by future executors, taken from the already locked Subscription row:

```elixir
{:ok,
 %{
   status: status,
   source: %{
     subscription_id: locked_subscription.id,
     user_id: locked_subscription.user_id
   },
   access_effect: locked_candidate,
   latest_access_effect_id: latest.id
 }}
```

`status` is `:current` or `:stale`. Return this source shape for both successful classifications. Do not expose Plan state or a full mutable Subscription struct. F1/F2 construct the immutable convergence input exclusively from `fence.source`, `fence.access_effect`, and caller-supplied reason. No extra Subscription or Plan read is needed; success remains four SELECTs.

Fingerprint integrity runs v2 first. `persisted_fingerprint_status/1` on AccessEffect returns `:v2_match`, `:v1_legacy_match`, or `:mismatch`. Accept v1 only when the persisted start is nil and its v1 fingerprint matches. A non-nil start matching only v1 is a mismatch. Never reconstruct a legacy start. Mismatch returns `INTERNAL_ERROR`.

Executability runs before latest-ID classification. Reject half-pairs. An EFFECTIVE pair with nil start is `VALIDATION_ERROR`, even when v1 integrity passes. An EFFECTIVE pair may have nil end. Apply the input target-shape and interval rules to persisted evidence, including nil kind/scope for empty and NON_EFFECTIVE targets.

The successful path has four bounded SELECTs and zero DML: lookup, source lock, exact candidate lock, latest read. Count database statements in telemetry, excluding transaction-control statements. Error paths may stop earlier.

## Convergence transaction and result

`Store.Entitlements.Facade.converge_subscription_source_grants_for_system/1` takes exactly one argument, `SubscriptionSourceConvergenceInput`. Its internal Ash calls use explicit `context: %{system?: true}` with the existing system authorization conventions. Do not add an arity-2 facade function or caller-supplied context parameter. Require a caller-owned transaction or return `VALIDATION_ERROR` with zero queries. The caller must first obtain CURRENT evidence from `prove(input.access_effect_id)` in the same transaction and construct the immutable input exclusively from `fence.source`, `fence.access_effect`, and caller-supplied reason, with no extra Subscription or Plan read. A stale result grants no mutation authority. Do not expose a standalone check-then-act-later API.

Ordered convergence steps:

1. Validate the typed input and transaction guard before mutations.
2. Read and lock all grants with `source_kind=:subscription` and `source_id=input.subscription_id`, ordered by database UUID id with `FOR UPDATE`. Select the fields needed for identity, status, interval and revocation evidence. This is one indexed exact-source read and the only cardinality-dependent materialization.
3. In `Store.Entitlements.SourceConvergence`, derive the matching target row, active non-target IDs, expected revoke cardinality, and projection user IDs from those locked rows. Always include `input.user_id`, even for empty targets with zero locked grants. Deduplicate IDs; any in-memory UUID ordering uses binary UUID bytes, never UUID string ordering.
4. In pair mode only, execute the dedicated target upsert. If the exact identity existed, require the returned target ID to equal its locked ID. Prove the returned target's complete state listed below. A mismatch fails closed and rolls back.
5. When active non-target IDs exist, construct the exact revoke action/change, require a successful fully atomic changeset precheck, then run one query-input bulk UPDATE. No active non-target rows means no UPDATE.
6. Select active same-source rows with `limit 2`, including all final-proof fields. Pass the selected rows into the deterministic internal validator. Require the exact pair or empty shape below. A mismatch returns `INTERNAL_ERROR` and rolls back the caller-owned transaction.
7. Return the result derived from the locked rows and target. Do not return until the final proof succeeds. No cache, PubSub, email, enqueue, or notifier delivery occurs here.

`SourceConvergenceResult` contains `mode: :pair | :empty`, `subscription_id`, `target_grant_id` or nil, `revoked_grant_ids`, and `projection_user_ids`. Revoke IDs come from the previously locked active non-target set. They do not require returned revoke records. Projection users always contain the input owner.

The caller must roll back on any error after mutation. Exercise that transaction contract in integration tests. If any added Ash writes emit notifications, use the shared post-commit wrapper, collect `return_notifications?: true` inside the transaction, and deliver only after commit. Keep `config :ash, :missed_notifications, :raise`.

### Dedicated target action

Add `:converge_source_target` using existing identity `:unique_user_scope_source`. Its create and conflict paths establish exactly:

```text
source_kind=:subscription
source_id=input.subscription_id
user_id=input.user_id
kind=input.entitlement_kind
scope_key=input.entitlement_scope_key
status=:active
valid_from_at=exact input.valid_from_at
valid_to_at=exact input.valid_until_at
revoked_at=nil
revoked_reason=nil
```

Force active status and cleared revocation fields in the dedicated action. Include `:status`, `:valid_from_at`, `:valid_to_at`, `:revoked_at`, `:revoked_reason`, and `:updated_at` in its upsert fields. Require start only; do not require end. Explicit nil end must clear an old end on conflict. Empty targets never invoke this action, so the existing non-null start/default stays unchanged.

Verify one bounded INSERT/upsert can clear both revocation fields. If Ash cannot do this, STOP. Do not change generic `:issue` or add a follow-up per-target repair UPDATE.

### Dedicated revoke action and completeness

Add atomic-only `:revoke_for_source_convergence`, accepting persisted `revoked_reason`, setting status revoked and revoked_at through atomic-compatible changes. The facade supplies `%{revoked_reason: input.reason}`.

Run `Ash.Changeset.fully_atomic_changeset/4` with this exact resource/action/change and the same domain/system context as the bulk call. A valid `%Ash.Changeset{}` is required. Invalid or `{:not_atomic, reason}` means rollback with `INTERNAL_ERROR` before bulk execution.

Use query input filtered by exact source and active status, excluding target ID in pair mode. Bulk options include:

```elixir
strategy: [:atomic],
return_records?: false,
return_errors?: true,
authorize?: false,
domain: Store.Entitlements,
context: %{system?: true}
```

Require `%Ash.BulkResult{status: :success}`. Partial success or error rolls back. No stream or per-record fallback is permitted. SQL telemetry must prove one grant UPDATE for a non-empty revoke set, zero for an empty set, and no revoke-record fetch or streaming batches.

No affected count is required. Completeness evidence combines successful bulk status, one-UPDATE telemetry, and the exact bounded final active-set proof. Expected locked revoke cardinality remains useful test evidence.

### Pure final-set validator

`Store.Entitlements.SourceConvergence.validate_final_active_set/3` accepts input, target ID or nil, and the selected rows. It is pure, deterministic, internal, unregistered, and performs no database access. It returns `:ok` or an existing `INTERNAL_ERROR` value.

Pair success requires exactly one row with exact target ID, user/kind/scope/source identity, start, nil-aware end, active status, nil revoked_at, and nil revoked_reason. Empty success requires zero active same-source rows. Every other shape fails.

The facade owns the `limit 2` SELECT and passes its rows to this validator. No Process dictionary switch, Mix.env test branch, production test hook, or public facade test seam is permitted.

## Legacy-writer residual

F0 serializes writers that participate in the Subscription mutex. Existing locked grants resist conflicting writes until commit. An unfenced legacy writer can insert a new exact-source row after F0's post-check and before commit. The final SELECT and contention test do not close that window.

```text
LEGACY_WRITER_WINDOW_EXPLICITLY_UNRESOLVED=YES
LEGACY_WRITER_WINDOW_CLOSED_BY_F0=NO
CONTENTION_HARNESS_PROVES_NEW_FENCED_PATH_SERIALIZATION_ONLY=YES
LOCAL_TRANSACTION_IDEMPOTENCE=YES
GLOBAL_SOURCE_CONVERGENCE_IDEMPOTENCE=NOT_YET_PROVEN
GLOBAL_CONVERGENCE_CLAIM=PROHIBITED
```

This is accepted residual debt until JC-300. Do not claim global convergence.

## Implementation tasks after approval

Each code task starts with the specified failing tests, runs them to confirm the failure, implements the smallest change, then reruns them. All F0 commits must be signed. Commit focused changes only during the future authorized implementation session, after the first signed plan-only commit has frozen the approved bytes. This correction pass does none of those actions.

### Task 0: Linear admission, current main, and local preflight

- [ ] Obtain plan approval, then have the human supply/create the dedicated F0 Linear issue. Confirm its acceptance criteria and concrete prerequisites in Linear. Stop before branch creation if no canonical F0 issue exists. Do not use a temporary branch awaiting later rename.
- [ ] In the existing worktree, fetch origin, switch main, pull fast-forward only, check status, and record `git rev-parse origin/main` and tree. Confirm prerequisites exist on accepted main. Preserve the approved untracked plan; do not discard unrelated changes. Review any unexpected worktree state before proceeding.
- [ ] If current accepted origin/main differs from reviewed architecture base `aab23f6afb924828a6f3b3c43bf069b304b6585e`, inspect the full reviewed-base-to-current-main delta. STOP for plan re-review if it touches any named authority/spec, AGENTS.md, performance/scaling authority, mix.lock or relevant Ash/Ecto dependency configuration, Entitlements/Subscription files in the file map or current-code assumptions, surface_registry.ex or relevant error governance, config/test.exs, test/test_helper.exs, .github/workflows/ci.yml, or relevant schema/migrations affecting AccessEffect or EntitlementGrant. Unrelated accepted-main changes alone do not block F0. Record the comparison and decision.
- [ ] Create the short-lived issue-specific branch using the actual Linear ID. Record base SHA and issue ID. Use one worktree and one active issue.
- [ ] Before any implementation edit, hash this plan file and require equality with the human-approved `APPROVED_PLAN_SHA256`. If it differs, STOP for review. Stage only this plan file. Require the staged path list to contain exactly this file and the branch to have no commits after the recorded base.
- [ ] Make the FIRST branch commit a signed plan-only commit with `git commit -S`. No implementation change may share it. Verify the signature with `git verify-commit HEAD`, verify its parent equals the recorded base, and verify its changed path list contains only this plan file. Read the committed blob with `git show HEAD:docs/superpowers/plans/2026-10-22-access-effect-f0-shared-convergence-implementation-plan.md`, hash its exact bytes including final newline, and require equality with `APPROVED_PLAN_SHA256`. Recheck the working-file hash as well. STOP on any mismatch or signature failure. Only then begin Task 1 implementation. No separate plan PR is required.
- [ ] Preserve the approved committed plan bytes while coding. Any required plan change stops the affected work for exact-byte re-review before execution resumes.
- [ ] Read `.devcore/project.conf` and `.devcore/render-map.tsv`. Run `devcore-project doctor`. If state is missing/stale, run `devcore-project plan`, `devcore-project activate`, then doctor again. Do not print or request credentials.
- [ ] Recheck aggregate_version and registry-only naming behavior as regressions, not unresolved decisions. Run the baseline suite through DevCore and stop on failure.

```bash
devcore-project run test -- mix test --max-failures 1
```

### Task 1: Immutable typed input

- [ ] Create the input test file and exercise the complete contract above. A baseline fixture includes valid subscription/user/effect UUIDs, positive source version, persisted fingerprint, reason, EFFECTIVE kind/scope, exact start/end.
- [ ] Accept a complete pair with nil end. Accept EFFECTIVE empty and NON_EFFECTIVE empty by explicitly setting kind=nil, scope=nil, start=nil, retaining user ID and exact persisted end. Cover both nil and populated end for empty targets.
- [ ] Reject missing/nil user and each missing required evidence field; malformed UUID/version/fingerprint/reason; each kind/scope half-pair; NON_EFFECTIVE pair; empty with start; pair without start; start=end and start>end when end exists. Prove timestamp precision survives.
- [ ] Run RED, implement `new/1` and the enforced struct following existing typed-input patterns, then run GREEN.

```bash
devcore-project run test -- mix test test/store/entitlements/inputs/subscription_source_convergence_input_test.exs
```

### Task 2: Result and deterministic validator

- [ ] Create result struct and pure helper tests. Prove projection users include the input owner when no rows are locked, for both empty dispositions. Cover multiple locked users and binary UUID ordering when sorting is used.
- [ ] Test final-set success for exact pair with finite and nil end, and zero-row empty success. Reject zero-row pair, two active rows, wrong ID/user/kind/scope/source, wrong start/end, inactive status, populated revoked_at, or populated revoked_reason. Test each failed field independently.
- [ ] Run RED, implement the result and pure helper, then run GREEN. The production validator contains no test-specific behavior.

```bash
devcore-project run test -- mix test test/store/entitlements/types/source_convergence_result_test.exs test/store/entitlements/source_convergence_validator_test.exs
```

### Task 3: Dedicated grant actions

- [ ] Capture the existing generic `:issue`, `:revoke`, and start attribute bytes as review evidence. Test unchanged generic action metadata and resource default.
- [ ] Write the reactivation regression. Seed the exact target identity revoked, with old start/end and populated revoked_at/revoked_reason. Upsert its new exact interval and assert same ID, active status, new start/end, and both revocation fields nil. Repeat with nil new end to prove clearing.
- [ ] Test the dedicated revoke action's fully atomic precheck on a real locked row and its persisted reason mapping.
- [ ] Run RED, add only dedicated actions, then run GREEN. Stop if a bounded upsert cannot clear both revocation fields.

```bash
devcore-project run test -- mix test test/store/entitlements/entitlement_grant_convergence_actions_test.exs
```

### Task 4: Facade convergence and SQL evidence

- [ ] Test zero-query transaction refusal, pair creation, exact replay, changed target identity, revoked-target reactivation, finite-to-nil end, EFFECTIVE empty, NON_EFFECTIVE empty, and source isolation.
- [ ] For empty targets with zero locked grants, assert result projection users still include the owner. For multiple users, assert union of locked users and owner.
- [ ] For source sizes 1, 5, 25, capture calling-process `[:store, :repo, :query]` SQL. Prove one UPDATE for non-empty revokes, at most one target upsert, no per-row mutation/fetch, and a final active-set SELECT bounded to 2. Compare equivalent repetitions before making bounded repeatability claims.
- [ ] Test caller transaction rollback after a successful convergence followed by an intentional caller error. Test invalid final shapes directly through the Task 2 validator, without inserting a test execution branch into the facade.
- [ ] Run RED, implement the ordered function, run GREEN. Require atomic precheck before bulk execution and `%Ash.BulkResult{status: :success}` before final proof. Propagate errors into caller rollback.

```bash
devcore-project run test -- mix test test/store/entitlements/source_convergence_test.exs test/store/entitlements/source_convergence_validator_test.exs
```

### Task 5: Post-commit projection guard

- [ ] Trace Cachex invalidation and PubSub calls. Inside a transaction, require failure before any projection call. Outside it, require user A Cachex before user A PubSub and user B Cachex before user B PubSub.
- [ ] Run RED, add only the transaction refusal to `invalidate_subscription_source_users_after_commit_for_system/2`, then GREEN. Preserve the existing per-user loop and error behavior. Do not invalidate all users first and broadcast afterward.

```bash
devcore-project run test -- mix test test/store/entitlements/projection_guard_test.exs
```

### Task 6: EFFECTIVE recovery selector and stable index proof

- [ ] Test disposition effective and statuses required/pending/failed_retryable only, through_updated_at bound, updated_at/id keyset cursor with tied timestamps, ascending updated_at/id order, no gaps/duplicates, limits 1 and 500 accepted, 0 and 501 rejected.
- [ ] Test PostgreSQL catalog evidence for `access_effects_effective_recovery_index`: exists on AccessEffect table, indisvalid=true, indisready=true, key columns exactly updated_at then id, and partial predicate exactly EFFECTIVE plus the recoverable status set. Compare PostgreSQL-normalized predicate structure, accounting for casts/parentheses without allowing extra or missing conditions.
- [ ] Run RED. Mirror the existing NON_EFFECTIVE read action and index, changing only disposition/index name. Generate migration and snapshot through Ash tooling. Review that the migration adds only this index.
- [ ] Migrate and run GREEN plus existing AccessEffect tests. EXPLAIN may be recorded diagnostically. Never require a particular index or plan node, and never disable sequential scans to force test success.

```bash
devcore-project run dev -- mix ash_postgres.generate_migrations --name f0_access_effect_effective_recovery_index
devcore-project run dev -- mix ash_postgres.migrate
devcore-project run dev -- mix ash_postgres.generate_migrations --check
devcore-project run test -- mix test test/store/subscriptions/access_effect_effective_recovery_test.exs test/store/subscriptions/access_effect_test.exs
```

### Task 7: Fingerprint classifier

- [ ] Test v2 match first, nil-start v1 match, mismatch, non-nil-start v1 rejection, and corruption. Include v1 integrity-valid EFFECTIVE pair with nil start as integrity-valid but not executable in Task 8.
- [ ] Run RED, add pure `persisted_fingerprint_status/1` with `@doc false` on AccessEffect, then GREEN. Use existing v2/v1 hash functions without changing fingerprint encoding or persisted evidence.

```bash
devcore-project run test -- mix test test/store/subscriptions/access_effect_fingerprint_status_test.exs
```

### Task 8: Exact-effect internal fence

- [ ] Write tests that pass candidate effect IDs, not source/version pairs. Assert zero-query refusal outside transaction; missing exact ID; current with aggregate equal; current with aggregate strictly greater; stale with a different latest ID; source-version gaps; candidate greater than aggregate; fingerprint mismatch; and executable-shape rejection before stale classification.
- [ ] Test EFFECTIVE pair with nil start fails even under matching v1 fingerprint, pair with nil end succeeds, half-pairs fail, and empty targets depend on nil kind/scope. Verify identity after candidate re-lock against the locked source. Assert returned source.subscription_id and source.user_id equal the already locked Subscription row's identity, for CURRENT and STALE. Construct an input from only returned source/effect plus reason and assert no additional Subscription/Plan query is issued.
- [ ] Capture SQL to prove lookup by exact ID, Subscription lock before candidate lock, no PlanRevision query, four SELECTs on success and zero DML. Do not reduce the count by reconstructing candidate identity.
- [ ] Run RED, implement `prove(effect_id)` in the unregistered module according to the exact sequence, then GREEN. Return transaction-scoped locked evidence only. Add no production caller in F0.

```bash
devcore-project run test -- mix test test/store/subscriptions/access_effect_currentness_fence_test.exs test/store/subscriptions/access_effect_test.exs
```

### Task 9: Real connections and hosted CI

- [ ] Create a tagged `:real_connections`, async=false ExUnit module without DataCase. Fail preflight unless effective Repo pool size is at least 3. Insufficient capacity fails; it never skips.
- [ ] Exclude this tag in the default test-helper configuration. Run this file alone in a separate process/database. In that isolated process use pinned Ecto Sandbox `:auto` mode so independent transaction tasks obtain independent connections. Restore manual mode on exit. Never change global Sandbox mode in the ordinary suite process.
- [ ] Seed committed subscriptions X/Y and exact candidate effects. Guard cleanup by the dedicated test database name. Track and clean only fixtures created by this isolated test. Never touch schema_migrations or another process's database.
- [ ] A begins a transaction and `prove(effect_x.id)`, reports pg_backend_pid, and waits with a bounded receive while holding the lock. B reports a distinct backend PID then calls the same exact effect ID in its transaction. C runs `prove(effect_y.id)` independently.
- [ ] Require `pg_blocking_pids(B)` to include A, require C to finish while A holds X, release A, then require B to finish CURRENT. Use bounded polling, task timeouts, and cleanup that releases/terminates outstanding tasks on assertion failure. Timing alone is not proof.
- [ ] Run the isolated file twice in separate local processes through DevCore. Configure both `STORE_BENCH_POOL_SIZE=4` and `STORE_BENCH_WRITER_POOL_SIZE=4` so either existing role branch has capacity. Still assert the effective Repo pool size.

```bash
STORE_BENCH_POOL_SIZE=4 STORE_BENCH_WRITER_POOL_SIZE=4 devcore-project run test -- mix test --only real_connections test/store/subscriptions/source_fence_contention_test.exs
STORE_BENCH_POOL_SIZE=4 STORE_BENCH_WRITER_POOL_SIZE=4 devcore-project run test -- mix test --only real_connections test/store/subscriptions/source_fence_contention_test.exs
```

- [ ] Add hosted job `real_connections_required` by mirroring `test_pr_strict` setup in `.github/workflows/ci.yml`: checkout, setup BEAM from .tool-versions, system clients, Hex/Rebar, dependency cache/fetch, Postgres service and least-privilege test role, any existing Redis/test prerequisites, database create/migrate. Use that job's ordinary hosted test environment. Do not assume DevCore exists on GitHub runners.
- [ ] Set MIX_ENV=test, STORE_BENCH_POOL_SIZE=4 and STORE_BENCH_WRITER_POOL_SIZE=4 explicitly at job level. Run these as two separate steps/processes after database setup:

```bash
mix test --only real_connections test/store/subscriptions/source_fence_contention_test.exs
```

- [ ] Require both job repetitions green for implementation review. Record the job URL/result and observed contention evidence. Do not edit branch protection/rulesets. Whether this status becomes mandatory in repository rules is a separate human governance decision.

The claim is serialization of the new fenced path only. It says nothing about bypassing legacy writers or global convergence.

### Task 10: Registry and documentation checks

- [ ] Register exactly `{:converge_subscription_source_grants_for_system, 1}` on Store.Entitlements.Facade. Leave all existing exports/allowed consumers unchanged. Register neither internal helper and add no Subscription facade export.
- [ ] Run naming, documentation and web-boundary checks. Recheck registry-only scan scope as a regression. Ensure no web references to either internal module.

```bash
devcore-project run test -- mix check.surface_naming
devcore-project run test -- mix check.moduledoc
devcore-project run test -- mix check.subscriptions_docs_sync
devcore-project run test -- mix check.web_no_ash_query
```

### Task 11: Whole-branch verification and human review

- [ ] Run the required local format/static checks, migration/snapshot drift check, full default tests, and type checks below. Do not change generated files by hand. Also run the Task 9 real-connection proof twice in separate processes. Performance acceptance remains mandatory through `performance_smoke_required` and `performance_smoke_chaos_required` on both the exact reviewed PR head and exact merge push CI. Do not duplicate or guess the isolated performance environment. A performance script that skips its suite must never be reported as PASS.

```bash
devcore-project run test -- mix format --check-formatted
devcore-project run test -- mix check
devcore-project run dev -- mix ash_postgres.generate_migrations --check
devcore-project run test -- mix test --max-failures 1
devcore-project run test -- mix check.types
```

- [ ] Repeat isolated contention twice as Task 9 requires. Review exact base/head SHAs, changed files, acceptance criteria, lifecycle, database invariants, concurrency, replay, rollback, security and performance. Verify the generic issue/revoke/start-default bytes remain unchanged.
- [ ] Review the diff for no executor/producer implementation, production test branch, planner-choice assertion, returned revoke records, source cap, or global convergence claim. Confirm no direct web domain persistence was introduced.
- [ ] Verify every F0 commit from recorded base through PR head is signed, including the first plan-only commit. Run `git verify-commit` on each commit and require success. Run `git diff --check` on the full base-to-head diff and working changes. Record exact `git rev-parse HEAD` and `git rev-parse 'HEAD^{tree}'`.
- [ ] Only in the future authorized implementation session, push the actual Linear issue branch and create the focused PR targeting main. Include the reviews below and all required CI results. Link the PR to the thread when supported. Human merge is required; do not auto-merge or mark Linear Done before merge.
- [ ] Before requesting human merge, require the following evidence on the exact reviewed PR head. Any new commit invalidates the previous head/tree/check evidence and requires fresh verification.

```text
SIGNED_HISTORY=PASS
GIT_DIFF_CHECK=PASS
PR_HEAD_SHA=<exact reviewed head>
PR_HEAD_TREE=<exact reviewed tree>
CHECK_STATIC=PASS
TEST_PR_STRICT=PASS
DIALYZER_REQUIRED=PASS
PERFORMANCE_SMOKE_REQUIRED=PASS
PERFORMANCE_SMOKE_CHAOS_REQUIRED=PASS
REAL_CONNECTIONS_REQUIRED=PASS
```

The six job names are `check_static`, `test_pr_strict`, `dialyzer_required`, `performance_smoke_required`, `performance_smoke_chaos_required`, and `real_connections_required`. Require all six green for the exact reviewed head. The real-connections job is a manual F0 review gate even if repository rules do not require it. Do not change repository rules automatically.

- [ ] After human merge, fetch and record the exact merge SHA, tree and parents. Verify its signature with `git verify-commit`, compare its resulting tree/diff against the approved PR result, and verify expected parent relationships. Do not infer acceptance from the PR's merged flag alone. STOP on an unexpected result or invalid signature.
- [ ] Require canonical post-merge push CI on that exact merge SHA, with all six jobs above PASS. PR-head CI is insufficient. STOP if canonical push CI is red, missing, or belongs to a different SHA. Do not mark Linear Done.
- [ ] After exact-merge acceptance, return the same physical worktree to main, fetch and fast-forward, and prove local main equals origin/main and the worktree is clean. If main advanced again, inspect the delta and record which accepted merge was verified; do not substitute another SHA's CI for the F0 merge's CI.
- [ ] Retire only the F0 issue branch with expected-SHA protection. Record its expected reviewed head. Require both local and remote branch tips to match that expected SHA before deletion. Use a remote deletion lease for the exact expected SHA, and an atomic local ref deletion with the expected old SHA. STOP if either tip changed. Do not delete an unexpected or unrelated branch.
- [ ] Verify WORKTREE_COUNT=1, BRANCHES=main, WORKTREE_CLEAN=YES, and local/remote persistent branch=main. Verify branch retirement succeeded, then and only then mark the F0 Linear issue Done. Report branch, exact base/head/merge evidence, PR/CI/review status, validation and blockers at session close.

## Performance & Scaling Review

The convergence/fence functions are future hot paths; F0 adds no production caller. The projection guard affects an existing warm helper.

Fence success costs four bounded SELECTs and zero DML. Convergence costs one exact-source locked read, at most one target INSERT/upsert, zero or one revoke UPDATE, and one final SELECT limited to 2. There is no N+1 query or per-grant write. The lock read and result/projection ID derivation still cost memory and CPU proportional to source cardinality. Constant statement count does not imply constant resource cost.

Use the existing source_kind/source_id index for grant queries, existing identity for target upsert, effect primary key for exact candidate lookup, and recovery indexes for bounded selectors. Verify stable index structure, not optimizer choice.

No correctness cache is added. Preserve existing post-commit per-user Cachex then PubSub behavior and existing TTL. No new Oban job, uniqueness contract, or telemetry event is added. Tests capture repository query telemetry without mutation.

```text
SOURCE_CARDINALITY_BOUND=UNMEASURED
SOURCE_CARDINALITY_CAP_ADDED=NO
RETURN_RECORDS_PRODUCTION_USE=NO
AFFECTED_COUNT_AVAILABLE=NO
```

Do not certify 100k rows/source, capacity, or global source convergence. Record measured test sizes and observed SQL counts only.

## Runtime Resource Safety Review

The exact-source lock read materializes matching grant rows once. Derived revoke/projection ID lists also grow with source size. No second copy of revoked records is returned. The final proof materializes at most two rows. Memory and GC at large source cardinality remain UNMEASURED, so do not claim runtime capacity or safety from bounded SQL counts.

F0 adds no long-lived process, mailbox, or correctness cache. Real-connection tests use bounded receives/waits, release locks and terminate tasks on failure, restore Sandbox mode, and clean their dedicated committed fixtures. Caller transactions own connection and lock cleanup. Notifications/projection run only after commit.

Post-load convergence and no-accumulation evidence are UNMEASURED. A single run is diagnostic. Any relevant repeatability/convergence claim needs at least two equivalent bounded repetitions and remains limited to the measured dimension. No global convergence claim is permitted before JC-300.

## Stop conditions

Stop the affected implementation and report if any step requires:

- Changing generic EntitlementGrant `:issue`, existing `:revoke`, or the start resource default.
- Adding an error code without separate review.
- Implementing F0.5/F1/F2/F3, NewYou target composition, or Redis/ETS correctness state.
- A per-record revoke fallback, streamed revoke batches, returned revoke records, or more than one revoke UPDATE per call.
- Proceeding after a failed/invalid atomic precheck or incomplete target upsert.
- A production test-only branch or public test seam.
- An exact PostgreSQL planner-choice dependency.
- Projection within a transaction or changed per-user ordering.
- A global convergence claim before JC-300.
- Branch creation without approved plan and dedicated F0 Linear identity.
- Implementation before the first signed plan-only commit, failed approved-plan hash/signature verification, or unreviewed relevant main drift.
- Unsigned F0 history, failed exact-head six-job gate, or failed exact-merge signature/result/six-job verification.
- Marking Linear Done before canonical post-merge acceptance and expected-SHA-protected branch retirement.

Also stop on a failed baseline, missing accepted prerequisite, unexpected migration drift, absent currentness regression prerequisite, final-set failure on a valid path, inadequate real-connection pool, or failure to observe actual blocking. Diagnose DevCore bootstrap/service failures without asking for credentials. Never weaken a required check to continue.

## Correction-pass review status

This plan preserves the reviewed architecture and adds locked source identity in fence evidence, a first signed plan-only commit with approved-hash verification, relevant main-drift review, signed history, exact-head and exact-merge six-job gates, and expected-SHA-protected branch retirement before Linear Done. Source-cardinality cap and affected-count alternatives are resolved decisions. Legacy writers remain an explicit residual.

```text
IMPLEMENTATION_PERFORMED=NO
PLAN_COMMITTED=NO
F0_PLAN_VERDICT=READY_FOR_REVIEW
NEXT_ACTION=STOP_FOR_FINAL_EXACT_BYTE_REVIEW
```
