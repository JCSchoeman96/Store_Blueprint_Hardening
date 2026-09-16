# Subscription scheduling, terms, access and dunning

**Status:** Governance law, Stage B aligned
**Last updated:** 2026-09-16

This document defines the scheduling and policy terms for Store subscriptions:

- cadence and billing anchors
- fixed and open-ended terms
- access during payment recovery and cancellation
- retry and failed-payment suspension
- notifications and replay safety
- concurrency and performance expectations

It applies to physical product subscriptions and membership or entitlement
subscriptions. Orders and Payments remain product-type agnostic. Subscription
logic is orchestration and commercial authority.

The canonical lifecycle and race map is
`docs/hardening/01_domain_map.md`. This document must remain consistent with that
map.

## 1. Core concepts

Every Subscription must model these independently:

1. cadence, which defines how often a billing period is formed;
2. anchor, which defines when that period is due;
3. term, which defines when recurring authority ends;
4. access policy, which defines source-specific access during recovery and after a
   terminal decision;
5. dunning, which defines retry and failed-payment suspension;
6. notifications, which communicate upcoming and failed events.

Do not infer one concept from another or from a date alone.

## 2. Cadence

Plans define:

- interval_unit: :day | :month | :year
- interval_count: an integer of at least 1, defaulting to 1

Examples:

```text
daily        = {:day, 1}
every 3 days = {:day, 3}
monthly      = {:month, 1}
quarterly    = {:month, 3}
yearly       = {:year, 1}
```

Cadence determines the length of a billing period. Use it consistently for period
windows, next_renewal_at, and fixed-cycle term consumption.

## 3. Billing anchors

Anchoring is explicit. Supported modes are:

- anchor_mode: :start_anniversary | :fixed_day_of_month
- anchor_day_of_month: 1 through 31 when fixed-day mode is used
- billing_timezone: an IANA timezone string

For :start_anniversary, billing follows the start or first paid activation time.
For :fixed_day_of_month, billing follows the configured day regardless of the
signup date.

If the requested day is absent in the target month, use the last day of that
month. All timestamps are stored in UTC. Compute the anchor in the billing
timezone before converting it to UTC.

## 4. Terms

Term is separate from cadence. Supported term concepts are:

- term_mode: :until_canceled | :fixed_cycles | :fixed_end_at
- term_cycles: at least 1 for fixed-cycle terms
- term_end_at: required for fixed-end terms

A fixed-cycle term consumes one cycle only after a successful period extension. A
fixed-end term reaches its governed completion when the term end is authoritative.

Term completion uses:

```text
→ EXPIRED
```

EXPIRED ends recurring authority, prevents future provider starts, and ends
source-specific access at the governed term boundary. Dunning does not replace term
expiry, and a failed-payment boundary does not invent another paid period.

## 5. Access policy

Access is source-specific and derived from Subscription authority. It is not a
second Subscription lifecycle, and an access worker may not mutate Subscription
truth.

### Access during payment recovery

The two supported policies for PAST_DUE are:

```text
KEEP_DURING_GRACE
REMOVE_IMMEDIATELY
```

KEEP_DURING_GRACE may keep the affected recurring-source effect effective through
the governed recovery window. At SUSPENDED, that effect becomes non-effective.

REMOVE_IMMEDIATELY makes the affected recurring-source effect non-effective when
ACTIVE → PAST_DUE commits. The Subscription remains PAST_DUE while recovery is
possible.

For SUSPENDED, the affected recurring-source effect is non-effective. Do not add
an Entitlements SUSPENDED business state solely to mirror Commerce. Other valid
entitlement sources remain independently valid.

Access-on-past-due and access-on-cancel are independent policy dimensions. One
must not be inferred from the other.

### Access after cancellation

The two supported cancellation policies are:

```text
KEEP_UNTIL_PERIOD_END
REMOVE_IMMEDIATELY
```

KEEP_UNTIL_PERIOD_END uses only the already-funded authoritative paid period. It
does not extend the recovery window, create a period, turn a failed renewal into
paid coverage, or extend beyond fixed-term completion.

REMOVE_IMMEDIATELY creates a source-specific non-effective target after the
cancellation decision.

### Physical subscriptions

For a physical Subscription, removing access does not mean removing shipping.
A failed or unpaid renewal must not create a paid renewal order, and the system
must never ship without paid status.

## 6. Cancellation

### Immediate cancellation

Immediate cancellation ends recurring authority immediately:

```text
→ CANCELED
```

It forbids future provider starts, automatic retries, and unbound future changes.
Already-in-flight provider activity remains an external occurrence to reconcile
under the A/B/C/D checkpoint law.

PAST_DUE → CANCELED and SUSPENDED → CANCELED do not wait for another paid
boundary.

PENDING → CANCELED is allowed only before authoritative activation or payment
evidence establishes ACTIVE. It starts no dunning episode and creates no paid
period.

### Scheduled cancellation

Scheduled cancellation means:

```text
DO_NOT_RENEW
```

The current funded paid term may continue. At the actual paid-period boundary, the
Subscription becomes CANCELED. Do not create an extra period after the last paid
period has ended.

A current DO_NOT_RENEW instruction before RenewalAttempt checkpoint B blocks that
renewal boundary. If checkpoint B commits first, the bound occurrence remains
immutable and the later instruction targets the next eligible uncommitted boundary.

### Rescission

Before terminalization, an authenticated current-version rescission creates:

```text
RENEW_UNCHANGED(current live contract)
```

It does not resurrect an older hidden target. After CANCELED, the customer must
start a new Subscription rather than resubscribe through a resurrection transition.

## 7. Dunning and retry law

Dunning is a recovery episode, not an alternate terminal lifecycle.

### Required concepts

Plan or Subscription policy must define:

- grace_period_days, which determines the governed recovery window, default 7;
- max_retry_attempts, default 3, whose meaning is the number of retries after
  initial collection;
- retry_schedule_hours, a list of non-negative offsets such as [0, 24, 72];
- access_on_past_due, one of the supported access policies above.

Subscription evidence must include:

- past_due_since_at;
- a billing status reason such as payment failure or missing payment method.

### Attempt numbering

```text
initial collection = attempt 1
retries = attempts 2+
```

The retry budget is not the total number of collections. The existing field name
max_retry_attempts does not authorize a schema rename or a different interpretation.

### Retry offsets

Retry offsets are measured from the first retryable failure. Offset 0 is valid.
Do not clamp it to a later time. Use the final configured offset once and do not
repeat it indefinitely.

The first retryable failure performs:

```text
ACTIVE → PAST_DUE
past_due_since_at = first retryable failure time
```

Only the first retryable failure sets past_due_since_at. Retries do not reset the
episode clock.

### Retry exhaustion

If the retry budget is exhausted before the failed-payment boundary:

```text
remain PAST_DUE
stop automatic retries
```

Retry exhaustion is not relationship termination. It does not mean CANCELED,
EXPIRED, or SUSPENDED by itself.

At the governed failed-payment boundary:

```text
PAST_DUE → SUSPENDED
```

unless successful recovery or a separate terminal event wins first. SUSPENDED is
nonterminal and extant, but new automatic recurring capability is suspended.

There is no current generic rule that turns a grace or dunning boundary into
CANCELED. A historical reference to an older rule is not current authority.

### Missing payment method and other blockers

If no authorized payment method exists, do not create a provider payment intent or
start collection. Enter PAST_DUE with the relevant reason and send the
payment-method notification.

Inventory, variant, shipping, and other physical blockers must not charge a renewal
that cannot be fulfilled. They enter the governed recovery episode or a separately
authorized terminal path; they do not invent a new Subscription state.

## 8. Stored payment methods

The conceptual lifecycle is:

```text
ACTIVE ↔ INACTIVE

ACTIVE   → REVOKED
INACTIVE → REVOKED

REVOKED = terminal
```

REVOKED → ACTIVE and REVOKED → INACTIVE are forbidden. Replacement and
revocation are different operations.

Replacement changes the Subscription's durable method binding under current aggregate
authority. It does not create a new RenewalAttempt or automatically revoke the old
method globally.

Immediately before provider checkpoint C, the current payment-method authority must
be checked. If replacement or revocation committed first, the stale method is not
used. If C occurred first, the in-flight request remains an occurrence to reconcile.

## 9. Contract changes and grandfathering

Keep these eligibility decisions separate:

```text
NEW-SALE ELIGIBILITY
CHANGE ELIGIBILITY
EXISTING-RENEWAL ELIGIBILITY
```

A retired or publicly unavailable PlanRevision may remain valid evidence for an
existing renewal. Existing-renewal evaluation uses:

```text
Subscription
+ bound immutable current contract
+ applicable grandfathering policy
+ renewal occurrence
```

A new sale uses new-sale eligibility. A queued ContractChange uses change
eligibility. An extant PAST_DUE or SUSPENDED Subscription may recover the same
authorized renewal occurrence without becoming a new sale.

Terminal CANCELED and EXPIRED Subscriptions cannot be revived by grandfathering.

## 10. Scheduling

Renewal and notification scheduling are Oban-driven.

Allowed patterns include:

1. an Oban Cron tick that selects due work; or
2. a self-scheduling tick that re-enqueues after completion.

Scheduling must preserve the authority laws:

- queue existence grants no collection authority;
- every retry re-reads current Subscription authority before C;
- due selection and worker start time do not decide precedence;
- a current DO_NOT_RENEW, terminal state, or revoked payment-method binding
  blocks a new provider start;
- one logical renewal key reuses one RenewalAttempt;
- provider idempotency and reconciliation protect operations that may have crossed C.

Due selection must be batched and indexed. The worker must avoid N+1 loads and must
not use cache or queue state as the lifecycle authority.

## 11. Idempotency and concurrency

Every billing boundary has a deterministic renewal_key, for example:

```text
renewal_key = "sub:{subscription_id}:end:{period_end_iso8601}"
```

Required protections remain:

- durable uniqueness for Subscription and renewal key;
- Oban uniqueness using Subscription and renewal key;
- provider idempotency for external collection;
- durable provider-event or payment-occurrence deduplication;
- apply-once period extension, access effect, notification, and order/payment
  application.

If two workers claim the same renewal, one logical RenewalAttempt wins and the other
reuses it. Retries do not re-resolve current Plan state or a newer ContractChange.

Material Subscription writes use optimistic version/CAS or equivalent PostgreSQL
authority. A stale writer fails and re-evaluates current authority. Redis locks,
node-local mutexes, and worker serialization are not correctness authority.

## 12. Required indexes

These are governance expectations for later implementation, not schema authorization.

### Subscriptions

- (status, next_renewal_at)
- (user_id)
- (plan_id)

### Renewal attempts

- unique (subscription_id, renewal_key)
- (inserted_at)

### Entitlement grants, if applicable

- (user_id, valid_to_at, revoked_at)
- source-specific grant identity uniqueness

## 13. Notifications

Notifications go through the Comms outbox and workers. Each notification uses a
deterministic idempotency key, such as:

```text
(subscription_id, notification_kind, target_period_end_at)
```

At minimum, support:

- upcoming renewal reminders;
- payment failure and payment-method action;
- recovery window reminders;
- cancellation or expiry messaging;
- membership access-ended messaging when access is removed.

A notification does not change Subscription truth.

## 14. Governance checks required once implemented

These checks are future implementation acceptance criteria:

1. Anchor correctness for end-of-month clamping and timezone-aware anniversaries.
2. Term correctness for fixed cycles, fixed end, and open-ended subscriptions.
3. Access correctness for both recovery policies and both cancellation policies.
4. Dunning correctness for attempt numbering, offset 0, bounded retries,
   fixed episode clock, retry exhaustion, and the PAST_DUE → SUSPENDED boundary.
5. Idempotency under duplicate renewal claims, callback replay, and worker retry.
6. Concurrency for cancellation, ContractChange, payment-method authority, expiry,
   suspension, successful recovery, and late provider evidence.
7. Notification idempotency under replay.

## 15. Implementation note

Plan and contract fields live in the Subscription-owned commercial model. Pure
scheduling calculations and domain transitions belong behind Subscription domain
facades. Renewal execution, reconciliation, access effects, and notifications use
durable workers.

This section describes future implementation placement only. It does not authorize
source code, schema, migrations, provider integration changes, Entitlements,
Payments, Orders, infrastructure, Batch 001, or rollout.

## Appendix: Conceptual reason labels

Reason labels are governance concepts, not a schema change. Current law includes:

```text
billing_status_reason =
  payment_failed
  missing_payment_method
  out_of_stock
  variant_unavailable

canceled_reason =
  user_request
  admin_override
  provider_canceled

expired_reason =
  term_ended
  paid_period_completed
```

A generic failed-payment boundary is represented by PAST_DUE → SUSPENDED, not by a
dunning-specific cancellation reason.
