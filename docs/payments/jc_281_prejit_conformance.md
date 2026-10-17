# JC-281 renewal cancellation conformance

This review covers the generic Store lifecycle when cancellation meets an unresolved subscription renewal. Payment truth and renewal authority remain separate.

## Durable ordering

Cancellation locks the Subscription aggregate, then serializes on the exact renewal Order and PaymentIntent using the same Order → PaymentIntent lock order as `apply_payment_success_once`. It inspects the exact `PaymentApplication` while those locks are held. A different PaymentIntent application, duplicate application, or incomplete identity fails closed.

- **Payment first:** the exact `PaymentApplication` exists when cancellation obtains the Order lock. The renewal remains commercially paid. Period-end cancellation stays scheduled and delayed reconciliation applies the bound period. Cancel-now marks the renewal attempt historically succeeded before terminating access, so later reconciliation cannot reactivate the Subscription. No refund is inferred from cancellation.
- **Cancellation first:** no exact application exists when cancellation obtains the Order lock. The exact unresolved `RenewalAttempt` is failed with `RENEWAL_AUTHORITY_WITHDRAWN`. Generic retry handling cannot overwrite that disposition, and claim SQL will not reclaim it. A late exact payment success preserves PaymentIntent, Order, and PaymentApplication truth, leaves the Subscription canceled, and requests one full refund for that Order and PaymentIntent.

A terminal `PAYMENT_FAILED` classification remains intact when cancellation follows a final provider failure. Cancellation marks unresolved attempts as withdrawn; it does not rewrite a completed provider failure.

For physical renewals, cancellation releases active generic inventory reservations for the exact renewal Order in the same transaction that withdraws the attempt. Reservation admission takes fresh Subscription, Order, and RenewalAttempt locks before reserving, then commits before any provider request. If reservation commits first, the serialized cancellation releases it; if cancellation commits first, stale preparation cannot reserve stock. A cancelled reservation remains historical evidence but carries no stock authority, so later PaymentApplication can preserve real collection truth without consuming inventory.

Payment-success fanout resolves the exact RenewalAttempt by Order and PaymentIntent on first application and authoritative replay. A replay already recognized as applied retries only renewal reconciliation enqueue, without repeating payment effects. Multiple attempts bound to one Order fail closed. Lookup and enqueue errors propagate to the observation worker for retry; Oban uniqueness keeps insertion idempotent.

Provider status, callback arrival time, webhook time, and wall-clock guesses do not decide precedence. The durable application row and the serialized Order lock do.

## Cancellation timing

When the currently paid period is still active, period-end cancellation preserves its Entitlement and sets `cancel_at_period_end`. Any unresolved next renewal is withdrawn; the current paid period is not revoked. When the paid boundary has ended and no exact application exists, period-end cancellation uses the existing terminal cancellation transition immediately, clears retry scheduling, handles a queued ContractChange through the existing transaction, and revokes access through the existing cancellation path.

An exact PaymentApplication already present takes precedence even when the previous paid boundary has passed. The paid renewal is applied to its original bound period and period-end cancellation remains scheduled for the next boundary.

## Provider dispatch and late collection

Immediately before `charge_off_session`, Store runs one fresh database transaction that checks the current Subscription state, cancellation flags, current period boundary, exact `RenewalAttempt`/Order/PaymentIntent identity, charged version evidence, and active stored payment method. The transaction locks the Subscription and attempt, then commits before the provider request. No database transaction spans the provider POST.

A cancellation that wins before this check prevents the provider request. A cancellation after this validated dispatch boundary does not imply the provider request was prevented. Later authoritative evidence is applied to the exact PaymentIntent/Order by the JC-282 payment path. The withdrawn RenewalAttempt reconciliation then requests a full refund with reason `renewal_collected_after_cancellation`. The stable idempotency key is `renewal-cancel-remediation:<renewal_attempt_id>:<payment_intent_id>`. Replays reuse the existing Refund, including after it settles. The same exact attempt lookup suppresses digital grant jobs for a withdrawn renewal, so access is not granted while the refund is pending.

Cancellation does not mutate provider evidence or payment outcome. A collection that never becomes authoritative does not create a Refund. No automatic reactivation occurs. No grace duration is hardcoded; the charged PlanRevision snapshot continues to own retry and grace evidence.

## NewYou / Commerce PreJIT matrix

| Sequence | Commerce / Subscription result |
| --- | --- |
| Paid current period → cancel before next boundary | Current paid period and Entitlement remain; future renewal authority is withdrawn. |
| Period ended → unresolved renewal → cancel | Renewal authority is withdrawn immediately; Subscription is terminally canceled. |
| Cancel → stale renewal worker | Worker exits without a provider mutation. |
| Bound attempt → cancel → dispatch check | Fresh authority check refuses the provider mutation. |
| Provider request crossed boundary → cancel → late success | Payment truth remains; Subscription stays canceled; no entitlement or digital grant is issued; one exact remediation Refund is requested. |
| Physical reservation → cancellation before dispatch | Reservation is cancelled; reserved count returns to zero; stock is unchanged; provider POST is refused. |
| Cancellation → stale physical reservation preparation | No active reservation is created; stock and reserved count remain unchanged. |
| Physical cancellation → late authoritative success | Payment truth and one full Refund use the exact Order and PaymentIntent; stock remains unconsumed. |
| Payment first → physical period-end cancellation | Reservation is consumed once; stock decrements once; no cancellation remediation Refund is created. |
| Exact PaymentApplication → period-end cancel → delayed renewal reconcile | Original paid period is applied; cancellation stays scheduled; no refund. |
| Exact PaymentApplication → cancel-now → delayed renewal reconcile | Paid history remains; Subscription stays canceled; access stays revoked; no refund. |
| Cancel first → duplicate late success | One PaymentApplication and one remediation Refund; replays are idempotent. |
| Cancel first → late failure or no collection | No remediation Refund is created. |

## Scope and performance

Schema change: **No**. The implementation uses `RenewalAttempt`, `PaymentApplication`, existing Subscription transitions, inventory reservation state, and the existing Refund lifecycle. Refund eligibility uses the finalized Order grand total, including shipping, for full refunds. It adds no payment outcome resource and no `RenewalCollectionAttempt`.

Hot path: due renewal dispatch and payment application. Warm path: delayed payment/renewal reconciliation and Refund creation. Cold path: explicit cancellation and operator investigation. Physical renewal reservation admission adds three bounded row-lock checks keyed by exact Subscription, Order, and RenewalAttempt identity, only on physical-renewal preparation. The physical renewal fixture measures 77 SQL queries; the changed-contract renewal fixture measures 80, both within the existing 80-query budget. The final provider-dispatch authority check replaces the pre-dispatch stored-payment-method query. No global scan, N+1, polling loop, extra virtual-renewal query, or provider retry is added. Existing Oban uniqueness and the exact Refund idempotency key preserve replay safety. Telemetry records the reservation and pre-dispatch authority checks; existing payment telemetry remains in place.

JC-265 recoverable suspension, JC-229 collection identity, JC-230 charged-contract application, JC-272 payment-method replacement races, JC-284 Paystack certification, and JC-290 collection-attempt work remain downstream scope.
