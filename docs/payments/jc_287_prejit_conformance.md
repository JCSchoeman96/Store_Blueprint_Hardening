# JC-287 NewYou and Commerce compatibility review

This review checks shared Payments mechanisms against the NewYou Commerce Pre-JIT working inputs. Those inputs remain compatibility tests. They do not define generic Store product policy. Provider observations remain evidence for downstream Commerce reconciliation.

| Compatibility property | JC-287 mechanism or proof | Result |
| --- | --- | --- |
| PAY-INV-001, PAY-INV-017 | Observation API records evidence and returns eligibility. It does not apply an order, subscription, or entitlement consequence. | Pass |
| PAY-INV-003 | Observations require a known local `PaymentIntent`; provider reference remains a separate field. | Pass |
| PAY-INV-004, PAY-INV-018 | Provider errors return errors; pending and unknown statuses map to unresolved or unknown evidence. | Pass |
| PAY-INV-005 | No browser callback is used by the observation API. | Pass |
| PAY-INV-006 | The reconciliation entry point loads one `PaymentIntent` and uses its stored provider reference. | Pass |
| PAY-INV-007 | Deterministic `attempt_key` upsert stores an exact replay once; different outcomes retain separate rows. | Pass |
| PAY-INV-008, PAY-INV-028 | A durable PaymentIntent ID and provider reference are enough to invoke observation again. | Pass |
| PAY-INV-009 | Validator checks provider, reference, bound transaction ID, integer minor amount, currency, and supplied environment. | Pass |
| PAY-INV-010, PAY-INV-025 | `ProviderObservation` uses a bounded normalized class and retains raw status separately. | Pass |
| PAY-INV-015 | Observation schema uses an integer amount and currency string. No float conversion exists. | Pass |
| PAY-INV-019 | Stripe metadata is not copied into the observation. Only opaque local intent ID and provider customer/payment-method references are retained. | Pass |
| PAY-INV-024 | Observation uses GET. Existing POST paths still set `retry: false`. | Pass |

## Test evidence

`ProviderObservationTest` checks exact provider, reference, transaction, amount, currency, environment, and outcome eligibility. `StripeObservationTest` checks provider retrieval, unsupported adapters, and an unknown status. `ProcessWebhookReceiptWorkerTest` checks structured webhook chronology and verifies that replaying one verification result creates one row while a later success remains alongside an earlier failure.

## Scope boundary

This change does not decide final Commerce precedence, renewal collection identity, cancellation or grace policy, refund/dispute/settlement behavior, or entitlement changes. JC-282 is required to interpret a later success after an earlier failure without relying on arrival order. JC-281, JC-265, JC-272, and JC-284 remain separate work. Paystack transaction observation and production certification remain unsupported here.
