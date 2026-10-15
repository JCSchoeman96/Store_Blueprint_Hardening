# JC-233 renewal versus ContractChange design

## Goal and authority

JC-233 makes plan and variant queue commands order deterministically with renewal checkpoint B. PostgreSQL remains the serialization authority. The existing Subscription aggregate lock and `aggregate_version` check protect each command. No process memory, cache, new resource, or migration becomes an authority.

The implementation starts from `origin/main` at `92a5c5758d7bc92453191488d2924a593377548f`. It preserves JC-229's immutable charged-contract evidence, JC-230's exact collection and payment reconciliation, JC-231's aggregate-version checks, and JC-265/281 cancellation, suspension, and late-success precedence.

## Queue command serialization

Plan and variant queue calls pass typed business intent and the requested plan or variant ID into persistence. They do not pass a previously materialized target map.

Within one transaction, persistence locks and reloads the Subscription, verifies the caller's expected aggregate version, resolves the current target authority, materializes the requested change, and persists it. Resolution uses this precedence:

1. The current queued ContractChange.
2. The exact current complete RenewalAttempt whose `subscription_id` matches and whose `period_start_at` equals the locked Subscription's `current_period_end_at`.
3. The live Subscription.

The RenewalAttempt must contain complete charged-contract evidence. Its immutable revision, variant, quantity, amount, and currency supply the commercial base; the future target uses `effective_at = attempt.period_end_at`. More than one matching attempt is ambiguous evidence and fails closed.

Checkpoint B consumes and binds the queue target that committed first. A queue command serialized after B composes from the bound attempt and targets N+1. A B-bound ContractChange is never superseded. If the aggregate version changes, a bounded retry reloads the Subscription and evaluates the same typed intent against fresh PostgreSQL authority. It never replays a stale target map. Exhausted retries return normalized `STALE_RECORD`.

## Paid reconciliation with an N+1 target

JC-230's generic future-target guard remains in force. Paid reconciliation may proceed with a queued N+1 ContractChange only when it belongs to the same Subscription, remains `queued`, has `effective_at == attempt.period_end_at`, and all other current-authority checks pass. A target at the already-bound attempt boundary still fails closed.

The current Subscription pointer must resolve to that queued row. When a ContractChange is bound to occurrence N, the current queued N+1 target must descend from that exact bound row through an unbroken ContractChange predecessor chain. Superseded intermediate rows remain part of the lineage. Reconciliation reads the Subscription's inclusive `ordering_version` range from the bound row through the queued target in one ordered query, then validates the endpoints, adjacent predecessor links, same-Subscription ownership, increasing versions, bound/applied replay state, superseded intermediate states, and queued final state in memory. It does not flatten or rewrite supersession history. If there is no bound row, the existing predecessor check against the latest earlier ContractChange for that Subscription by `ordering_version`, or `nil` when no earlier history exists, remains unchanged. The compatibility projection must match the target's plan, variant, amount, currency, and effective time: `pending_subscription_plan_id`, `pending_variant_id`, `pending_renewal_amount_minor`, `pending_renewal_currency`, and `change_effective_at`. Plan and variant projections are `nil` when they already match the live Subscription values.

On reconciliation, Subscription commercial fields are applied from occurrence N's RenewalAttempt, the period advances, and bound ContractChange X becomes `applied`. Queued target Y retains its identity, target fields, status, compatibility projection, and Subscription pointer; its effective time is the new Subscription period end. Exact replay, renewal retry, and a crash after the commercial commit cannot consume, rewrite, duplicate, or bind Y to N.

## Persistence and scope

- Keep PostgreSQL and the Subscription aggregate lock as the only serialization authority.
- Keep `ContractChange`, `RenewalAttempt`, and `Subscription` as the existing durable records.
- Do not weaken generic future-target validation.
- Preserve post-commit Ash notification handling.
- Add no migration or NewYou-specific product policy.
- Keep all renewal work on Oban and retain the existing renewal-key idempotency rules.

## Verification coverage

The regression suite covers B-before-queue and queue-before-B ordering, unchanged renewal plus plan change, bound ContractChange plus plan/variant changes, stale typed-intent retry, exact paid reconciliation with N+1, multi-generation supersession through paid reconciliation and exact replay, fail-closed broken predecessor/intermediate-lifecycle/wrong-boundary cases, retries and crash recovery, concurrent queue commands, and PostgreSQL rollback/retry recovery. Existing contract-change, charged-reconciliation, optimistic-version, renewal-collection, cancellation, and suspension coverage remains required.

