# SBH-50 Entitlements shared-authority amendment

Status: governance amendment for later, separately admitted implementation.

This record assigns the smallest Entitlements-owned authority needed for JC-245
and JC-246 to use one stale-safe AccessEffect convergence boundary. It changes
no production code, tests, dependencies, schemas, migrations, Ash snapshots,
configuration, workers, lifecycle states, generic event or outbox
infrastructure, JC-223 edges, the SUBS Master Register, or Linear state. It
does not admit JC-245, JC-246, or JC-300 for implementation and does not assign
an implementation `task_base_sha`.

## Authority pins

- Canonical main base: `a74d3f05a5f250300d0c2293f294e77785f6818f`.
- Accepted SUBS evidence tip: `ec3a4d75175732b6ce95f3f288783591a1b1504b`.
- Accepted SUBS evidence tree: `7d4022e61054842183deb943c2019a99cab07d7c`.
- SUBS Master Register: v0.1.32, section 52.
- JC-300 is `Backlog`, `CONTRACT_FROZEN`, with `READY = No`, and has no
  implementation authority or task base. SBH-50-07 implementation/proof is
  `BLOCKED_DEPENDENCY / No`, and its separate Entitlements gate is
  `BLOCKED_SHARED_AUTHORITY / unassigned`. Its relations remain
  informational.
- JC-245 and JC-246 remain `Backlog` and non-executable. Their existing
  `JC-289` prerequisite and other relations remain unchanged. This record adds
  no relation and changes no JC-223 edge.

The accepted SUBS contract keeps the ownership split:

```text
Subscription / AccessEffect = desired Commerce access target and source order
Store.Entitlements          = actual grant authority
```

The future authority below is for the common Subscription-source grant
convergence seam only. It does not give Entitlements Subscription lifecycle or
policy authority, and it does not give SUBS generic Entitlements ownership.

## Evidence consulted

The current canonical main files inspected for this amendment were:

- `lib/store/entitlements/facade.ex`
- `lib/store/entitlements/cache.ex`
- `lib/store/entitlements/entitlement_grant.ex`
- `lib/store/entitlements/types/entitlement_set.ex`
- `lib/store/repo.ex`
- `docs/hardening/03_invariant_registry.md`
- `docs/governance/side_effects_quarantine.md`
- [`SBH-10-04 cross-domain authority amendment`](sbh_10_04_cross_domain_authority_amendment.md)

The accepted SUBS evidence at `ec3a4d7...` was read at
`docs/hardening/subscriptions/SUBSCRIPTION_HARDENING_MASTER_REGISTER.md` §52.
The live Linear records for JC-300, JC-245, and JC-246 were also checked on
2026-09-30. The issue statuses and relation facts in this document are a
governance snapshot, not a request to change Linear.

The pinned dependency versions are Ash 3.32.3, AshPostgres 2.13.0, Ecto
3.14.2, and Cachex 4.1.1. The transaction statements were checked against the
official documentation for [`Ecto.Repo.in_transaction?/0`](https://ecto.hexdocs.pm/Ecto.Repo.html#in_transaction?/0),
[`Ash actions`](https://ash.hexdocs.pm/actions.html),
[`Ash create actions`](https://ash.hexdocs.pm/create-actions.html), and
[`AshPostgres.Repo`](https://ash-postgres.hexdocs.pm/AshPostgres.Repo.html).

## Current defects this amendment records

`Store.Entitlements.Facade.issue_subscription_entitlement_for_system/2` is not
the JC-245 or JC-246 execution boundary. It accepts mutable-looking
Subscription and Plan maps, derives kind and scope from the Plan, derives the
end boundary from current Subscription state, assigns `valid_from_at` from
`DateTime.utc_now/0`, writes the grant, and immediately requests cache and
PubSub work.

`revoke_subscription_entitlements_for_system/2` is also not that boundary. It
reads every grant for the Subscription source, updates grants one at a time,
converts an individual update error to `false`, and returns a successful count
even when the source has only partially converged. It then requests invalidation
after the loop.

`Store.Entitlements.Cache.invalidate_and_broadcast_post_commit/3` does not
prove an outer commit. It deletes the Cachex key, ignores the deletion result,
broadcasts, and returns `:ok` immediately. Its name is not transaction
evidence.

`EntitlementSet` is a cached read and LiveView projection. Cachex and PubSub
are derived state. The inspected Store slice does not prove that this cache is
the sole global authorization gate for every protected capability.

`EntitlementGrant.valid_from_at` is required and currently has a worker-time
default. The accepted AccessEffect contract persists `valid_until_at` but does
not provide an explicit target start boundary. These facts make worker-time
validity inference unsafe.

## Bounded authority grant

The later implementation may modify only these surfaces:

- `lib/store/entitlements/facade.ex`
- `lib/store/entitlements/cache.ex`
- a task-local typed input under `lib/store/entitlements/inputs/`, if needed;
- a task-local result type under `lib/store/entitlements/types/`, if needed;
- focused tests under `test/store/entitlements/**`.

The grant is limited to a Subscription-source convergence function and its
post-commit projection helper. It does not authorize `domain.ex`, a new
Entitlements resource, an `EntitlementGrant` schema change, a migration, an
Ash snapshot, a new Entitlements lifecycle state, or generic event, outbox,
Redis, ETS, or process-memory correctness machinery.

The implementation must preserve this rule:

```text
Entitlements owns actual grant rows.
Subscription owns commercial lifecycle and target derivation.
AccessEffect owns desired-target execution state.
```

## Transactional convergence contract

The semantic operation is:

```text
converge the exact Subscription-source entitlement target
inside a caller-owned PostgreSQL transaction
```

The final function name may change during implementation, but its contract may
not widen.

### Transaction ownership

The caller starts and commits the authoritative outer `Store.Repo` transaction.
The Entitlements function must not start, commit, or replace that transaction.
It must fail closed when called outside the required explicit caller-owned
transaction. `Store.Repo` is an `AshPostgres.Repo` and therefore exposes the
Ecto Repo transaction API, including `in_transaction?/0`; that check is a
guard, not source-order proof.

The executor must enter the explicit outer Repo transaction before calling the
function. An Ash create or update action's own transaction and its
`after_transaction` hook are not evidence that the outer Subscription/
AccessEffect transaction committed. The implementation must not use an Ash
action hook as a substitute for the outer commit boundary.

The function must consume immutable target evidence supplied by the already-
fenced caller. It must not fetch a Plan or mutable Subscription state to
rediscover the target, derive a target from Subscription status, decide
`access_on_cancel` or `access_on_past_due`, decide whether an AccessEffect is
current, mark an AccessEffect `APPLIED`, perform external I/O, publish PubSub,
or invalidate Cachex inside the transaction.

### Typed input

The input must be a typed value containing only facts needed to converge the
Subscription source, such as:

- exact Subscription/source UUID;
- user UUID;
- desired disposition, `:effective` or `:non_effective`;
- zero or one entitlement kind and scope pair for the effective target;
- exact durable validity evidence, including `valid_to_at` and any permitted
  start evidence;
- revocation reason or other mutation reason where required;
- AccessEffect identity, source version, or target fingerprint for diagnostics,
  if useful.

It must not contain a mutable Plan, a Plan lookup instruction, or a request to
infer commercial policy. The caller remains responsible for source-target
serialization, current-effect validation, and marking that exact effect
`APPLIED` only after complete convergence.

### Validity boundary

Entitlements may not invent business validity from worker execution time.

- For an existing grant, preserve its durable `valid_from_at` when it remains
  the correct start boundary.
- For a new grant, require `valid_from_at` from durable source evidence supplied
  by the caller. Do not call `DateTime.utc_now/0` as the business authority.
- AccessEffect establishment or source evidence may supply the start only when
  the source contract proves that it is the correct effective-from boundary.
- Use the exact frozen target boundary for `valid_to_at`. Do not read mutable
  Subscription or Plan state to replace it.
- If a source case requires an earlier or historical exact start that the
  current AccessEffect contract cannot represent or derive deterministically,
  stop at SUBS target authority and request the smallest AccessEffect contract
  amendment. Do not hide the gap in Entitlements.

### Exact-source convergence

The function operates on the complete grant set with:

```text
source_kind = :subscription
source_id   = exact subscription_id
```

It must lock the relevant source rows inside the caller-owned transaction, or
prove an equivalent PostgreSQL-safe exact-source mutation. Other source kinds
and other Subscription IDs remain untouched.

For an `EFFECTIVE` target:

- the exact target kind and scope become active;
- the target validity matches the supplied immutable evidence;
- `revoked_at` and `revoked_reason` are cleared where the target requires it;
- every other active grant for the same Subscription source becomes
  non-effective or revoked;
- historical rows may remain as historical rows;
- a scope A to scope B change leaves B effective and A non-effective;
- replay of the exact target is a no-op or the same complete result.

For a `NON_EFFECTIVE` target, no active Subscription-source grant remains for
that exact source. The function revokes every active row for the source,
including rows whose validity has already expired or is not yet effective,
atomically within the outer transaction. Rows already non-active may remain as
historical rows. It does not revoke grants held by another Subscription or by
another source.

The result must distinguish complete convergence from failure. It may include
the user, whether anything changed, the desired grant identity, changed grant
identities or counts, and an after-commit invalidation descriptor. No individual
write error may become `false` and disappear inside an apparently successful
count. Any mutation error must return an error that prevents the enclosing
authoritative transaction from committing.

## Shared source-target fence

JC-245 and JC-246 retain their separate active and non-effective execution
responsibilities, but they must use one source-target fence:

```text
begin caller-owned PostgreSQL transaction
lock or serialize the Subscription source target
read the current AccessEffect
prove that exact effect and target are still current
call the Entitlements exact-source convergence function
revalidate as required
mark that exact effect APPLIED
commit
```

A newer target must defeat an older worker at the Entitlements mutation
boundary. A preflight-only currentness check is not sufficient. Neither
executor may choose the current AccessEffect, infer policy from status, or use
queue order, worker order, cache state, PubSub delivery, or process memory as
the fence.

## Post-commit cache and PubSub projection

The transaction result carries only the data needed for later projection repair.
After the outer `Store.Repo` transaction returns success, an
Entitlements-owned post-commit function must:

```text
invalidate the local EntitlementSet cache
then broadcast entitlements_invalidated
```

No cache deletion or PubSub publication may run before the outer commit. An
outer rollback emits no successful invalidation or broadcast. The projection
function must be idempotent and must not add an AccessEffect lifecycle state.

Cache invalidation failure must not be discarded. The function must return or
report the failure sufficiently for the executor or job to retry projection
repair. The post-commit helper must invalidate Cachex before it broadcasts, and
must make broadcast failure observable to the caller or retry path. The
executor or job that owns the convergence result owns projection retry; this
does not authorize a new outbox.

If a process crashes after the database commit and before projection repair,
retry must be able to repeat the idempotent invalidation and broadcast without
rerunning or undoing the grant mutation. A retry must not require the exact
AccessEffect to be moved out of `APPLIED`, and it must not add a generic outbox
without a separate authority decision.

## Cache authority boundary

Cachex and PubSub remain read projections. No grant correctness or target
ordering decision may depend on cache contents, PubSub delivery, process
memory, worker state, or queue order. A future protected access path that needs
strict fail-closed revocation semantics beyond this post-commit retry contract
requires a separate access-boundary review. This amendment does not certify
possibly stale EntitlementSet data as a global security authority.

## Existing APIs and production cutover

`issue_subscription_entitlement_for_system/2` and
`revoke_subscription_entitlements_for_system/2` may remain temporarily for
legacy callers. This amendment does not bless either function as a JC-245 or
JC-246 executor.

SBH-50-07 must prove that every relevant production Subscription path stops
bypassing AccessEffect source ordering before executor production eligibility.
That proof remains separate from this authority grant. Entitlements does not
acquire Subscription lifecycle, cancellation, dunning, suspension, or policy
selection. Do not add `PAST_DUE`, `SUSPENDED`, `CANCELED`, or `PROCESSING` to
Entitlements.

## Required implementation proof

The later implementation and focused tests must prove all of the following:

1. A call outside an explicit caller-owned transaction fails closed and makes
   no mutation.
2. Rolling back the outer transaction after successful convergence leaves every
   grant unchanged.
3. Replaying an exact `EFFECTIVE` target is idempotent.
4. Replaying an exact `NON_EFFECTIVE` target is idempotent.
5. Scope A to scope B leaves B effective and A non-effective atomically.
6. Any grant mutation failure prevents partial source convergence from
   committing.
7. A `NON_EFFECTIVE` target removes active exact-source rows even when their
   validity window is expired or not yet effective.
8. Independent grants from another source remain untouched.
9. Stale-worker protection comes from the caller's locked current-AccessEffect
   fence at the mutation boundary.
10. No Plan or mutable Subscription state is loaded to rediscover the target.
11. No worker-time timestamp replaces required immutable validity evidence.
12. Cache invalidation and PubSub do not run before the outer commit.
13. An outer rollback emits no successful invalidation or broadcast.
14. A successful outer commit permits post-commit invalidation and broadcast.
15. Cache invalidation failure is surfaced rather than discarded.
16. The post-commit helper invalidates Cachex before PubSub and propagates a
    failure from either projection step.
17. A retry after Cachex failure, PubSub failure, or a crash after database
    commit can repair projections without repeating or undoing grant truth.
18. Redis, ETS, PubSub, Oban, queue order, and process memory remain outside
    the correctness authority.

## Ownership and exclusions

| Owner | Bounded authority or responsibility | Exclusion |
|---|---|---|
| `Store.Entitlements` | The typed Subscription-source convergence function and the post-commit cache/PubSub projection helper in the paths listed above. | No new resource, schema, migration, snapshot, lifecycle state, policy, or generic infrastructure. |
| JC-245 | Active/effective AccessEffect execution and recovery through the common fence. | No Plan interpretation, cancellation or dunning policy, or source ordering authority. |
| JC-246 | Non-effective AccessEffect execution and recovery through the common fence. | No status-derived target selection, policy interpretation, or cross-source revocation. |
| Subscription source owners | Source transitions, immutable target evidence, and source ordering. | No generic Entitlements ownership and no direct grant mutation that bypasses the fence. |
| JC-300 / SBH-50-07 | Source-coverage matrix and production cutover proof. | No source transition, target policy, or Entitlements execution authority. |
| JC-247 | Purchased `access_on_past_due` and `access_on_cancel` policy derivation at the owning source transition. | No Entitlements execution. |

This grant does not modify `docs/agent_rules/active_workstreams.md`, the SUBS
Master Register, current-state invariant registries, JC-223 edges, Linear
issues, or any later-phase authority.

## Stop conditions

Stop implementation and request a fresh authority decision if any of these
conditions appears:

- canonical `main` moves before this amendment is reviewed or merged;
- the target needs an Entitlements resource, schema, migration, Ash snapshot,
  or generic domain change;
- a caller cannot prove one outer PostgreSQL source-target fence for JC-245 and
  JC-246;
- exact `valid_from_at` evidence is missing or requires a historical boundary
  that AccessEffect cannot represent;
- the implementation needs cache, PubSub, Redis, ETS, Oban, or process state as
  correctness authority;
- a partial mutation must be treated as success, or cache failure cannot be
  surfaced and retried;
- a request would mark JC-245, JC-246, JC-300, or SBH-50-07 `READY`, assign a
  task base, or change JC-223 edges;
- production cutover requires changing an excluded source owner or lifecycle
  contract.

## Performance and scaling review

- **Hot:** The future executor transaction locks the exact Subscription-source
  grant set and performs bounded convergence writes. The implementation must
  report query counts, row-lock scope, and N+1 risk. It must not hide per-grant
  failures behind an aggregate count.
- **Warm:** `EntitlementSet` remains a Cachex read projection with the existing
  60-second TTL. Invalidation happens only after commit. No new Redis, ETS,
  cache stampede mechanism, or authorization cache is authorized here.
- **Cold:** A committed grant mutation with failed projection repair is retried
  through the idempotent post-commit helper. Projection retry must not rerun the
  grant mutation. No generic outbox is added by this amendment.
- **Indexes:** Use the existing EntitlementGrant source index and grant
  identity. No index or migration change is authorized. The implementation
  must state whether exact-source row locking uses these indexes without a
  broad user scan.
- **Oban and idempotency:** Oban may trigger executor work, but this amendment
  changes no worker uniqueness. A projection retry must be safe after an
  already-`APPLIED` AccessEffect.
- **Telemetry and logging:** The later implementation must record the source
  identity, target fingerprint, convergence result, outer-transaction result,
  cache invalidation result, broadcast result, and projection retry outcome.
- **Capacity claim:** This docs-only amendment makes no latency, throughput, or
  high-concurrency certification claim.

## Later admission and verification

This branch is governance only. Before a future implementation is admitted:

1. This amendment must pass independent review, exact-head CI, and human merge
   to canonical `main`.
2. The merge commit and tree must be independently verified.
3. SUBS must consume the canonical main authority in a separate bounded register
   or admission update. That update must keep JC-300, JC-245, and JC-246
   non-READY until their own dependency and coverage gates pass.
4. Any implementation branch must restate the exact allowed files, typed input,
   transaction owner, validity evidence, source convergence result, and
   post-commit retry contract before code changes begin.

The requested governance PR must verify the exact main-base diff, changed paths,
absence of runtime/test/schema/dependency changes, unchanged JC-223 edges, no
READY or task-base language, explicit fail-closed validity-start handling, and
the bounded authority grant. It must pass `git diff --check`, available
documentation and governance gates, and full `mix check` when the environment
provides the dependencies. It must open a PR against `main` and must not merge
it.
