# JC-233 renewal versus ContractChange implementation plan

> **For agentic workers:** Use `superpowers:subagent-driven-development` and red/green verification. Human merge is required.

**Goal:** Make future plan and variant changes deterministically order after checkpoint-B renewal binding and preserve exact N+1 targets through paid reconciliation.

**Architecture:** Serialize typed queue intent inside the PostgreSQL Subscription aggregate lock. Resolve current target authority as queued ContractChange → exact current complete RenewalAttempt → live Subscription. Re-evaluate original typed intent on bounded stale retries. Allow JC-230 reconciliation to preserve only a coherent queued N+1 target.

**Tech stack:** Elixir, Ash 3.x, AshPostgres, Ecto/PostgreSQL, ExUnit, Oban.

**Spec:** `docs/superpowers/specs/2026-10-14-jc-233-renewal-vs-contract-change-design.md`

## Base and constraints

- Base: `92a5c5758d7bc92453191488d2924a593377548f`.
- Branch: `jcschoeman123/jc-233-sbh-20-03-renewal-vs-contract-variant-change`.
- Preserve JC-229 charged-contract immutability, JC-230 exact payment evidence, JC-231 aggregate-version protection, and JC-265/281 cancellation and suspension precedence.
- No Redis/cache/process authority, new future-target resource, migration, or NewYou product policy.
- Human merge only.

## Implementation progress

- [x] Prove the three post-B composition defects with correct expected results.
- [x] Move queue target composition behind Subscription serialization and pass original typed intent.
- [x] Resolve queue-before-B, then exact current B-bound RenewalAttempt, then live Subscription.
- [x] Re-evaluate typed intent after stale aggregate-version retries, with a bounded retry count.
- [x] Certify queue-before-B and B-before-queue with deterministic task/DB barriers; prove B-bound changes stay bound.
- [x] Allow exact same-Subscription queued N+1 targets through JC-230 reconciliation while retaining the generic future-target guard.
- [x] Verify renewal retry, exact reconciliation replay, and crash recovery preserve N+1 target identity and fields.
- [x] Verify concurrent queue writers and PostgreSQL rollback/retry recovery.
- [x] Capture query counts against canonical main and reuse resolved Subscription/ContractChange/revision authority reads.
- [x] Update the SBH-10-03 regression so a post-B plan is available for the variant in the immutable bound attempt and assert N+1 survives paid reconciliation.
- [x] Pass 2: replace the direct-parent N+1 check with bounded ContractChange ancestry validation; preserve all existing supersession history.
- [x] Pass 2: prove the original direct-parent failure on reviewed head `29e0507c05e0240709ab48832c006efcd6baa39b`, then cover multi-generation reconciliation, exact replay, and three corrupted-lineage failures.

## Performance & Scaling Review

- **Hot:** Renewal reconciliation applies a charged occurrence in one PostgreSQL transaction; subscription plan/variant queueing mutates a locked aggregate.
- **Warm:** Administrative queue inspection and exact ContractChange history reads.
- **Cold:** No backfill, analytics, or bulk migration path is added.
- **Query counts, same fixtures and measured operations:** ordinary plan queue 18 on main / 18 on branch; ordinary variant queue 18 / 18; post-B plan queue 18 / 19; post-B variant queue 18 / 18; supersession 20 / 19. The post-B plan path performs the additional exact attempt/revision authority read. No ceilings were raised.
- **Reconciliation:** One-target N+1 reconciliation measured 21 queries; multi-generation X→Y→Z reconciliation measured 19; exact multi-generation replay measured 13. The ancestry path uses one Subscription-scoped `ordering_version` range read for any lineage depth, then validates links and lifecycle states in memory. It adds no query per superseded row. No query ceiling was raised.
- **Indexes and query shape:** The bounded lineage read filters by Subscription ID and the inclusive range from bound X through queued target Z, then sorts ascending by `ordering_version`; the existing unique `(subscription_id, ordering_version)` index supports it. Subscription locks and exact ContractChange/PlanRevision lookups use primary keys. RenewalAttempt lookup remains constrained by subscription ID and period start, limited to two rows to detect ambiguous evidence, and uses the existing subscription ID index. No migration was added.
- **Caching:** None. PostgreSQL remains authoritative; no TTL, invalidation, or stampede path was added.
- **Oban:** Existing renewal-key uniqueness and idempotency remain unchanged.
- **Telemetry/logging:** Existing renewal and reconciliation telemetry remains. The queue persistence barrier event includes subscription ID and intent kind; it is used to make concurrency tests deterministic.
- **Local smoke evidence:** Normal `ci_gate` passed 14 scenarios on isolated PostgreSQL 18 and Redis services; the domain thundering-herd observer recorded lock-wait ratio `0.56` and pool utilization `0.40` and passed. The `mobile_realistic` chaos profile passed 14 scenarios on the same isolated services. No thresholds changed. Exact-head CI remains the required performance certification.

## Required verification

- [x] `test/store/subscriptions/sbh_20_03_renewal_vs_contract_change_test.exs`: 12 tests, 0 failures.
- [x] `test/store/subscriptions/sbh_10_06_contract_change_test.exs`: 16 tests, 0 failures.
- [x] `test/store/subscriptions/sbh_10_05_charged_contract_reconciliation_test.exs`: 17 tests, 0 failures, including broken predecessor, invalid intermediate lifecycle, and wrong boundary cases.
- [x] `test/store/subscriptions/optimistic_aggregate_version_test.exs`: 10 tests, 0 failures.
- [x] `test/store/subscriptions/renewal_collection_attempts_test.exs`: 53 tests, 0 failures.
- [x] `test/store/subscriptions/cancellation_renewal_authority_test.exs`: 27 tests, 0 failures on an isolated database; the canonical main facade also passes on a fresh isolated database.
- [x] `test/store/subscriptions/sbh_10_03_renewal_contract_snapshot_test.exs`: 14 tests, 0 failures, including X→Y→Z first reconciliation and exact replay.
- [x] `mix format --check-formatted`, `git diff --check`, `mix ash_postgres.generate_migrations --check`, `mix check.types`, strict Credo, and repository documentation/static gates.
- [x] Final clean-suffix `mix check`: 3 properties, 1,110 tests, 0 failures; Credo reported no issues.
- [x] Local `ci_gate` normal performance smoke: 14 tests, 0 failures on dedicated isolated services.
- [x] Local `mobile_realistic` chaos performance smoke: 14 tests, 0 failures on dedicated isolated services.
- [ ] Push the correction head and require exact-head `check_static`, `test_pr_strict`, `dialyzer_required`, `performance_smoke_required`, and `performance_smoke_chaos_required` green.
- [ ] Stop before merge and hand the exact PR head to independent re-review.

## Pass 2 red proof

On the untouched production code from `29e0507c05e0240709ab48832c006efcd6baa39b`, the new X→Y→Z paid reconciliation regression passed its setup and exact provider/payment success checks, then returned `VALIDATION_ERROR` with message `subscription commercial contract is unresolved`. The test-only proof was committed before the production correction as `daf6c79`.

The correction reads all same-Subscription ContractChanges from X's ordering version through current queued Z's ordering version in one ordered query. It requires exact X/Z endpoints, an allowed X lifecycle (`bound_to_renewal` or `applied` replay), a queued Z, strictly increasing versions, every row on the same Subscription, each later predecessor pointing to the prior row, and `superseded` intermediate rows. Existing no-bound reconciliation logic is unchanged. The X→Y→Z regression verifies X applies while Y stays superseded and Z remains the same queued/current target; exact replay is a no-op. Corruption tests fail closed before changing Subscription, attempt, or ContractChange snapshots.

