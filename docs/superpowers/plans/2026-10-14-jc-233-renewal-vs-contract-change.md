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

## Performance & Scaling Review

- **Hot:** Renewal reconciliation applies a charged occurrence in one PostgreSQL transaction; subscription plan/variant queueing mutates a locked aggregate.
- **Warm:** Administrative queue inspection and exact ContractChange history reads.
- **Cold:** No backfill, analytics, or bulk migration path is added.
- **Query counts, same fixtures and measured operations:** ordinary plan queue 18 on main / 18 on branch; ordinary variant queue 18 / 18; post-B plan queue 18 / 19; post-B variant queue 18 / 18; supersession 20 / 19. The post-B plan path performs the additional exact attempt/revision authority read. No ceilings were raised.
- **Reconciliation:** N+1 reconciliation succeeds in 20 branch queries. Canonical main rejects that operation after 9 queries, so the outcomes are not an equivalent query-count comparison. JC-230 unchanged reconciliation and exact replay each measured 15 queries; first application measured 19.
- **Indexes and query shape:** Subscription locks and exact ContractChange/PlanRevision lookups use primary keys. RenewalAttempt lookup is constrained by subscription ID and period start, limited to two rows to detect ambiguity, and uses the existing subscription ID index. No N+1 reads were observed. No migration was added.
- **Caching:** None. PostgreSQL remains authoritative; no TTL, invalidation, or stampede path was added.
- **Oban:** Existing renewal-key uniqueness and idempotency remain unchanged.
- **Telemetry/logging:** Existing renewal and reconciliation telemetry remains. The queue persistence barrier event includes subscription ID and intent kind; it is used to make concurrency tests deterministic.
- **Local smoke evidence:** The normal `ci_gate` smoke failed its domain thundering-herd observer on the workstation (`peak_unexpected_lock_wait_ratio=0.4103`, pool utilization `0.975`, limits `0.1` and `0.95`). The `mobile_realistic` chaos profile passed locally. Do not raise thresholds. Exact-head CI remains the required performance certification.

## Required verification

- [x] `test/store/subscriptions/sbh_20_03_renewal_vs_contract_change_test.exs`: 12 tests, 0 failures.
- [x] `test/store/subscriptions/sbh_10_06_contract_change_test.exs`: 16 tests, 0 failures.
- [x] `test/store/subscriptions/sbh_10_05_charged_contract_reconciliation_test.exs`: 14 tests, 0 failures.
- [x] `test/store/subscriptions/optimistic_aggregate_version_test.exs`: 10 tests, 0 failures.
- [x] `test/store/subscriptions/renewal_collection_attempts_test.exs`: 53 tests, 0 failures.
- [x] `test/store/subscriptions/cancellation_renewal_authority_test.exs`: 27 tests, 0 failures on an isolated database; the canonical main facade also passes on a fresh isolated database.
- [x] `test/store/subscriptions/sbh_10_03_renewal_contract_snapshot_test.exs`: 13 tests, 0 failures after the post-B N+1 expectation update.
- [x] `mix format --check-formatted`, `git diff --check`, `mix ash_postgres.generate_migrations --check`, `mix check.types`, strict Credo, and repository documentation/static gates.
- [x] Final clean-suffix `mix check`: 3 properties, 1,106 tests, 0 failures; static, security, Credo, Sobelow, and docs checks passed.
- [x] Local `ci_gate` normal performance smoke attempted; observer failed at the limits recorded above.
- [x] Local `mobile_realistic` chaos performance smoke passed.
- [ ] Push draft PR and require exact-head `check_static`, `test_pr_strict`, `dialyzer_required`, `performance_smoke_required`, and `performance_smoke_chaos_required` green.
- [ ] Stop before merge and hand the exact PR head to independent review.

