# JC-232 renewal vs immediate cancellation implementation plan

**Goal:** Preserve the caller's original `cancel now` intent across one Subscription aggregate-version conflict, while keeping the accepted renewal dispatch, reconciliation, terminality, and remediation behavior unchanged.

**Authority:** Section 55 of `docs/hardening/subscriptions/SUBSCRIPTION_HARDENING_MASTER_REGISTER.md`.

**Base:** `4f1721620ed2b13de4920fa6dc5afb1d0d8c5fdc`.

**Branch:** `subs-task/sbh-20-02-renewal-cancellation-race`.

## Constraints

- Keep aggregate-version enforcement unchanged in the Subscription resource.
- Retry the original `:now` command at most once, only after `STALE_RECORD`.
- Reload through the same user or admin authorization path.
- Return current-state lifecycle errors when refreshed state rejects immediate cancellation.
- Preserve duplicate cancel-now behavior without adding lifecycle transitions.
- Do not change Payments, Orders, Entitlements, providers, schemas, migrations, snapshots, or generic Support.
- Use PostgreSQL state for race authority. Do not add caches, distributed locks, queue ordering, or process state.

## Steps

1. Inspect cancellation reads, transaction boundaries, aggregate-version updates, existing concurrency tests, and available database or telemetry barriers.
2. Add a deterministic user-path test for B committing after cancel-now reads version V but before its stale write. Run it before production changes and record the expected `STALE_RECORD` failure.
3. Add the smallest Facade orchestration that reloads through the original actor surface and re-evaluates the same `:now` command once.
4. Prove current-state rejection, a second stale conflict, user authorization, admin authorization if it has a separate reload path, and duplicate immediate cancellation behavior.
5. Run the inherited cancellation and renewal collection regression suites without rewriting their mechanics.
6. Review query counts, transaction attempts, lock scope, N+1 risk, and provider I/O boundaries. Confirm no schema or snapshot drift.
7. Run the requested Subscription, reconciliation, formatting, repository, type, migration, and performance checks.
8. Open a draft PR against `hardening/subscriptions`, link it to this T3 thread, confirm required CI on the exact head, and request independent review. Do not merge or mark JC-232 Done.

## Expected files

- Production: `lib/store/subscriptions/facade.ex`.
- Focused proof: `test/store/subscriptions/sbh_20_02_renewal_immediate_cancellation_test.exs`.
- This plan: `docs/superpowers/plans/2026-10-17-jc-232-renewal-vs-immediate-cancellation.md`.

## TDD record

- Red proof: commit `934b43e5350507c384c3185cf62a9ea922f787ad` added the deterministic checkpoint-B race test before the Facade change.
- The pre-fix focused run reached the assertion after B committed and returned `STALE_RECORD` instead of a successful `cancel now`, confirming the intent-loss defect.
- The implementation and replay-bound tests now pass in the focused suite.

Any need to change another production surface, schema, migration, snapshot, provider contract, or shared domain boundary stops this task for a new authority decision.
