# JC-265 Pre-JIT Conformance Record

> Historical conformance snapshot. This record predates the accepted JC-238 and
> JC-239 runtime changes. Its retry-exhaustion-to-suspension statement is
> superseded: retry exhaustion now keeps the Subscription `past_due` with
> retries suppressed, and the separate `failed_payment_boundary_at` governs
> suspension. See [current scheduling terms](../../governance/subscription_scheduling_terms.md)
> and the retry-exhaustion and failed-payment-boundary tests. The remaining
> JC-265 evidence below records the behavior and scope at the time of that work.

This implementation record covers the NewYou CER-PT-006 retry-exhaustion and late-provider-success pressure test. Store behavior remains provider-independent; NewYou's grace duration and future Paystack recurring mechanics are not defined here.

## Lifecycle

| State | Meaning | Automatic collection | Current access |
|---|---|---|---|
| `active` | Current paid period is authoritative. | Due at `next_renewal_at`. | Valid through the granted period boundary. |
| `past_due` | Renewal is unresolved and configured grace/dunning remains. | Only while existing retry policy permits it. | Existing entitlement policy and validity apply. |
| `suspended` | Recovery boundary is exhausted; the commercial contract remains open. | None. | Exact subscription-source grants are revoked in the same database transaction as suspension. |
| `canceled` | Continuation authority was withdrawn. | None. | Revoked according to cancellation policy. |
| `expired` | True terminal expiry. | None. | Not recoverable. |

Retry exhaustion or an observed grace boundary moves `active`/`past_due` to `suspended`. Suspension keeps `ended_at`, `canceled_at`, and `canceled_reason` nil, clears retry scheduling, and leaves duplicate-membership fences active. A suspended Subscription can be canceled by its customer or an authorized administrator.

## Authority and late success

- Provider observations are evidence. They do not directly change Subscription or Entitlement state.
- Commerce payment truth requires the exact existing PaymentIntent and a durable `PaymentApplication` for its Order.
- Recovery requires the exact Subscription, RenewalAttempt, Order, PaymentIntent, and PaymentApplication chain. Suspension does not create a replacement collection or provider reference.
- The existing renewal reconciliation installs `RenewalAttempt.period_start_at` and `period_end_at`. Reconciliation time does not shift the paid period, including when its end is already in the past.
- Entitlements remains the access authority. Suspension changes Subscription and strictly revokes every active grant for its exact subscription source in one `Store.Repo` transaction. Any required grant mutation failure rolls back the suspension and all earlier grant mutations; cache invalidation, Ash notification delivery, and membership communications happen after commit. Paid reconciliation restores its exact source in a short transaction that locks and checks the current Subscription before Entitlements issues/upserts the grant. If cancel-now has committed first, reconciliation leaves the grant revoked. If recovery acquires the lock first, cancel-now serializes after the grant write and its cancellation consequence revokes it. Cache invalidation and Ash notifications run after the grant transaction commits. Replaying reconciliation after Subscription repair converges grant state without another PaymentApplication.
- JC-281 precedence remains in force: cancellation-first withdraws renewal authority and routes a later applied payment to remediation; payment-first preserves payment history and never reactivates a cancel-now Subscription.

## Status sets and schema

Commercially open membership is `pending`, `active`, `past_due`, or `suspended` with `ended_at` nil. Both the application admission guard and `subscriptions_unique_open_membership_key_index` include `suspended`. The database status check also permits `suspended`.

Automatic due selection and provider dispatch remain `active`/`past_due`. Plan and variant changes remain unavailable while suspended. The new state adds no table or column; the migration replaces the partial-index predicate and status check constraint.

## Verification evidence

- Lifecycle/version tests cover direct active and past-due suspension, cleared retry scheduling, exact paid extension from suspended, cancellation from suspended, and terminal rejection from canceled/expired.
- Facade tests cover retry exhaustion, grace suspension, access revocation, telemetry, and scheduler exclusion.
- Renewal authority tests cover unresolved provider-transaction exclusion, exact late-success repair, historical period preservation, replay, entitlement convergence after restart, JC-281 cancellation precedence, and both recovery/cancel-now access orderings. A telemetry barrier pauses recovery after the Subscription period commit and before grant reactivation; cancel-now commits first, then the stale recovery worker resumes and leaves the grant revoked. The opposite ordering restores the grant first, then cancel-now leaves it revoked without refunding the applied payment.
- Suspension access convergence tests inject a failure during exact-source grant revocation, prove the suspension and all grant writes roll back, then rerun due processing to converge. They cover a still-valid grant at the failure boundary, multiple grants with one failed mutation, an untouched grant from another Subscription source, and replay without provider calls or new renewal/payment identities. This proves the suspension-to-revocation direction alongside the existing payment-application-to-entitlement-restoration restart proof.
- Membership uniqueness tests cover the admission guard and PostgreSQL partial unique index.
- Query-contract tests allow `suspended` filtering for user and admin indexes.

## Performance & Scaling Review

Renewal and reconciliation are hot paths; subscription detail and admin filtering are warm paths; the conformance record is cold. Suspension adds one indexed exact-source grant read and one update per active grant within the transaction; it does not scan unrelated grants. Recovery adds one Subscription primary-key read with `FOR UPDATE` and one indexed plan read while it restores the exact source. The source index is `(source_kind, source_id)`, and grant updates use UUID primary keys. Due selection remains bounded and uses existing status/time indexes. The membership admission fence uses the existing `(user_id, membership_key)` lookup and partial unique index; the updated predicate adds `suspended`.

No cache was added. Entitlements uses its existing per-user Cachex invalidation and PubSub notification after the authoritative transaction commits. RenewalAttempt and Oban uniqueness/idempotency are unchanged; exact renewal and PaymentApplication identities continue to protect replay. Existing dunning telemetry reports the resulting status as a low-cardinality value. Renewal reconciliation emits a low-cardinality boundary event before the access sync. The targeted renewal fixture remains subject to `RENEWAL_PERF_QUERY_BUDGET=80`; the budget did not change.

## Scope

This change does not create post-suspension collection UX, a new payment outcome resource, `RenewalCollectionAttempt`, a new Entitlements resource, or provider-specific retry rules. JC-229, JC-230, JC-272, JC-284, and JC-290 remain separate.
