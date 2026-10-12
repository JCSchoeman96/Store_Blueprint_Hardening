# JC-282 NewYou and Commerce compatibility review

This review checks payment outcome precedence against the NewYou Commerce Pre-JIT inputs. Those inputs are compatibility cases. They do not define generic Store policy.

## Truth layers

| Layer | Meaning | Durable or authoritative representation |
| --- | --- | --- |
| Provider observation | What one verified callback or provider read reported. | Immutable `PaymentAttempt` evidence. |
| Provider finality | Whether the provider says this exact transaction can still progress. | Adapter classification from `Store.Payments.Providers`. |
| Commerce outcome | What Store may apply to an order and its existing paid side effects. | `PaymentOutcomeResolver` plus the exact `PaymentApplication` fence. |

An observation timestamp records when evidence was seen. It does not decide which outcome wins.

## Compatibility matrix

| Invariant | Proof | Result |
| --- | --- | --- |
| PAY-INV-001, PAY-INV-017 | `observe_payment_intent_for_system/1` records evidence and returns eligibility without changing payment or order state. Applying that result requires the separate explicit system API. | Pass |
| PAY-INV-004, PAY-INV-018 | Provider errors remain errors. Non-terminal and unknown results do not mark payment failure or release renewal inventory. | Pass |
| PAY-INV-007, PAY-INV-008 | Replay identity includes provider facts, provider occurrence time, source, and exact local `PaymentIntent` identity. Local `observed_at` remains stored chronology and does not split replays. | Pass |
| PAY-INV-009 | Success requires exact provider, typed reference, bound transaction ID, integer minor amount, currency, and expected provider environment. Invalid success remains reconciliation-required. | Pass |
| PAY-INV-010, PAY-INV-025 | Provider outcome and finality are separate values. Unknown statuses stay unknown. | Pass |
| PAY-INV-028 | Payment applications preserve the exact `payment_intent_id`; an existing application for another intent blocks a second payer assignment. | Pass |

## Hostile event ordering

For the same PaymentIntent, apply these events in either order:

```text
pending or unknown
→ failure-looking evidence
→ delayed authoritative success
→ replay of older failure evidence
→ reconciliation read
```

Stripe `requires_payment_method`, `requires_action`, `requires_confirmation`, `requires_capture`, and `processing` remain non-terminal. They do not release the renewal inventory hold. A later exact `succeeded` observation may apply success once, including when the local intent was already marked failed. A late failure replay cannot regress an applied success. If evidence does not identify the exact target or the provider finality is unknown, Store leaves Commerce unchanged and returns `reconciliation_required`.

An eligible `requires_payment_method` or `payment_failed` observation can precede a later exact success. A certified terminal Stripe `canceled` observation and a success claim for the same PaymentIntent remain durable and resolve to `reconciliation_required`, regardless of evidence insertion order. A success already applied through its exact `PaymentApplication` remains applied when late cancellation or failure evidence arrives. Paystack and adapters without certified finality return `unknown`; JC-282 does not infer Paystack semantics.

If a renewal occurrence remains `processing` after dispatch, its next due run claims that existing occurrence with an `updated_at` compare-and-set, reads its exact persisted PaymentIntent through JC-287, and applies only the resulting persisted evidence. It does not issue another charge POST. A missing provider transaction identity remains unresolved.

## Performance and scaling review

Hot path: payment outcome application and off-session renewal charging. Warm path: webhook receipt processing. Cold path: explicit operator or scheduled reconciliation reads.

One successful direct renewal measured 78 SQL queries end to end in the changed-contract renewal fixture after adding the exact-`PaymentIntent` evidence history read. The test budget remains 80. Direct-charge observations use the returned Stripe PaymentIntent amount, currency, ID, status, and `livemode`; Store's expected amount, currency, and environment remain comparison values. Missing or mismatched returned evidence cannot apply Commerce success. The renewal attempt performs one provider charge request; recovery uses one GET for the persisted transaction and does not repeat that POST.

Each outcome check reads at most two `PaymentApplication` rows for the exact order and at most 101 `PaymentAttempt` rows for the exact PaymentIntent, using the existing `payment_intent_id` index. Histories over 100 rows fail closed to reconciliation. There is no global evidence scan. Existing indexes cover `payment_applications(payment_intent_id)` and `payment_applications(order_id)`. The apply transaction locks one order followed by one PaymentIntent, then rechecks the application identity inside the transaction. The unique application key and existing Oban uniqueness/replay behavior preserve one paid application and one renewal reconciliation. No cache, TTL, invalidation, stampede protection, migration, or polling loop was added. Telemetry remains on the existing renewal attempt and webhook paths.

The 78-query count includes the full single-renewal orchestration and its certified direct-success application; it is not a per-observation query count. CI performance smoke checks remain required on the exact PR head.

JC-229 still owns renewal collection identity and admission. JC-230, JC-281, JC-265, JC-272/290, and JC-284 keep their existing scope. JC-284 remains responsible for Paystack certification.
