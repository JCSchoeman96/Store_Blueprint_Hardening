# SBH-10-04 Renewal Collection Lifecycle

This note records the Subscription-owned durable foundation implemented for JC-229. It does not add provider dispatch, payment-success orchestration, a reconciliation worker, or a new Domain.

## Authority consulted

- [Subscription hardening register](SUBSCRIPTION_HARDENING_MASTER_REGISTER.md), v0.1.34, section 54, at task base `8a21739555de1dde8f448bfd7e1172b1caeb54c3`.
- [SBH-10-04 cross-domain authority amendment](../../governance/sbh_10_04_cross_domain_authority_amendment.md).
- [Phase 27 notes](../../agent_notes/phase_27_docs.md).
- [Checkout interlocks](../../governance/checkout_interlocks.md), [payment provider contract](../../governance/payment_provider_contract.md), and [inventory reservations](../../governance/inventory_reservations.md).
- The repository pins Ash `3.32.3` and AshPostgres `2.13.0` in [mix.lock](../../../mix.lock). The migration and snapshot were generated with the installed `mix ash_postgres.generate_migrations` task. See the [Ash changelog](https://ash-project.github.io/ash/changelog.html) and [AshPostgres 2.13.0 package](https://hex.pm/packages/ash_postgres/2.13.0).

## Plan and decisions

This increment adds only the durable Subscription-owned collection record and its lifecycle boundary. The record is persisted before later PaymentIntent/provider work. The existing `RenewalAttempt` remains the bound-contract and occurrence anchor; the collection owns its own ordinal, PaymentIntent association, dispatch evidence, financial outcome, and reservation-generation evidence. No new Domain or Payments resource is introduced.

Dispatch and financial outcome remain separate axes. PostgreSQL owns ordinal uniqueness and the one-active-financial-outcome invariant. Service creation locks the Subscription and RenewalAttempt in the existing order; state changes lock the collection and apply expected-state/expected-epoch Ash filters. Exact reservation operations use the already authorized Orders APIs. The later JC-229 increment owns provider submission and reconciliation wiring.

## Durable record

`RenewalCollectionAttempt` is a child of one immutable, bound `RenewalAttempt`. Its UUIDv7 `id` is the collection identity. `collection_ordinal` is monotonic within the parent and independent of `RenewalAttempt.attempt_no`.

The record stores two independent axes:

- Dispatch: `not_started`, `may_have_been_reached`, or `not_submitted`.
- Financial outcome: `unresolved`, `requires_action`, `verified_success`, or `verified_terminal_financial_non_success`.

It also stores the nullable exact `payment_intent_id`, current `reservation_generation_id`, `dispatch_epoch`, `fenced_through_epoch`, and the last fence event ID and timestamp. A successful payment outcome requires an exact PaymentIntent association. PaymentIntent keys are `renewal-collection:<collection_attempt_id>`; replay of a collection uses that same key.

PostgreSQL enforces the unique `(renewal_attempt_id, collection_ordinal)` pair, one active financial outcome per parent with a partial unique index, one collection per non-null PaymentIntent, valid axis values, and epoch/fence consistency. In particular, `not_submitted` requires `fenced_through_epoch = dispatch_epoch`; all other dispatch states require `dispatch_epoch = fenced_through_epoch + 1`. A nonzero fence requires both event ID and timestamp.

## Dispatch transitions

Every operation compares `collection_attempt_id` and the caller's expected `dispatch_epoch`. The resource row is locked and the Ash update also filters by the expected state and epoch.

| From | To | Guard | Durable side effect |
| --- | --- | --- | --- |
| `(N, not_started)` | `(N, may_have_been_reached)` | Exact epoch CAS; the stored PaymentIntent ID, parent Order, and deterministic key are revalidated | Commit the claim before the caller can submit. No provider request occurs in this increment. |
| `(N, not_started)` | `(N, not_submitted)` | Exact epoch CAS; provider submission has not started | Record `fenced_through_epoch = N`, fence event ID and time; release only the exact active reservation generation. The successful release and fence update share the Subscription Repo transaction. |
| `(N, not_submitted)` | `(N+1, not_started)` | Successful fence evidence; unresolved financial outcome; fresh generation when the old epoch had one | Advance by exactly one and set the new current generation. Preserve fence evidence through N. |

`may_have_been_reached` cannot be fenced or claimed again for that collection; it remains the dispatch evidence while the exact PaymentIntent is reconciled. The reservation hold stays active. `not_submitted` is not a financial terminal state: its unresolved outcome continues to occupy the one-active-collection slot. Replaying the same fence event or resume input returns the already persisted result. Replaying an already claimed dispatch is rejected, which prevents a second submission through this boundary. A stale epoch is rejected. Missing, mismatched, or unresolved exact reservation evidence fails closed.

Virtual renewals without a physical hold keep a nil reservation generation. Their pre-submission fence records dispatch evidence without calling Orders. Physical renewals must record the exact generation returned by the existing Orders API before using the fence path. The Subscription claim still checks the generation through an unlocked Orders recovery read. A concurrent exact release can race that read and the collection CAS, so this PR remains blocked until a separately admitted S0/Orders capability makes the check atomic.

## Financial outcome transitions

The outcome refresh reads the exact associated PaymentIntent, checking its ID, deterministic key, and parent Order. `created`, `submitted`, `cancelled`, and `failed` leave the outcome unresolved. A local `failed` state does not prove that the provider can no longer succeed. `requires_action` maps to the matching nonterminal outcome, and `succeeded` maps to `verified_success`.

| From | To | Guard | Terminal? |
| --- | --- | --- | --- |
| `unresolved` | `requires_action` | Exact PaymentIntent is `requires_action`; dispatch was claimed | No |
| `unresolved` | `verified_success` | Exact PaymentIntent is `succeeded`; dispatch was claimed | Yes |
| `unresolved` | `verified_terminal_financial_non_success` | Canonical verified provider/payment evidence proves the submitted intent cannot later succeed; dispatch was claimed | Yes |
| `requires_action` | `verified_success` | Exact PaymentIntent is `succeeded`; dispatch was claimed | Yes |
| `requires_action` | `verified_terminal_financial_non_success` | Canonical verified provider/payment evidence proves the submitted intent cannot later succeed; dispatch was claimed | Yes |

The terminal-evidence transitions are reserved for canonical provider/payment evidence and are not wired to the local PaymentIntent snapshot in this increment. The only side effect of an allowed transition is recording the collection's financial evidence. Transitions do not release or consume inventory, mutate `RenewalAttempt`, create another order, or apply commercial paid-renewal reconciliation. The collection row lock and expected-outcome Ash filter serialize updates; the partial unique index continues to protect the parent active slot. Refreshing the same outcome is idempotent. No transition returns to `unresolved`, changes one terminal outcome into the other, or maps a pre-submission fence to financial non-success. Terminal outcomes never regress; conflicting terminal PaymentIntent evidence fails closed.

## Collection creation and retry rules

Creation locks the Subscription and then its RenewalAttempt, matching the existing renewal lock order. The parent must contain a complete bound contract. The service reads and locks that parent's collection history, fails on gaps or contradictory active history, and allocates the next ordinal while holding the parent lock. The partial unique index independently prevents two active outcomes even if a writer bypasses the service.

- The first collection is ordinal 1, with epoch 1, fence-through 0, dispatch `not_started`, and financial outcome `unresolved`.
- A collection in `unresolved` or `requires_action` is returned on replay. This remains true when dispatch is `not_submitted`.
- No collection may be added after any `verified_success`.
- A later ordinal requires the previous ordinal to be `verified_terminal_financial_non_success`, and the current Subscription dunning state must permit and be due for another retry under the bound snapshot policy. The guard mirrors the canonical due predicate, including `cancel_at_period_end == false`; the current dunning attempt count must also remain below the bound `max_retry_attempts`.
- A later ordinal gets a new UUIDv7 identity and therefore a new PaymentIntent key. It does not create another RenewalAttempt or Order, and it does not change `attempt_no`.

The parent lock serializes service callers. Unique database indexes enforce ordinal identity and the one-active rule. Collection creation is idempotent while an active outcome exists; a later retry becomes eligible only after terminal financial evidence and due dunning state are present. There is no queue-order, UUID-order, timestamp-order, cache, or process-state winner selection.

## Recovery boundary

If a dispatch claim committed, the request may have reached the provider. Keep the same collection, PaymentIntent key, PaymentIntent, and exact reservation generation until reconciliation establishes a financial outcome. Do not release or advance that epoch based on a timeout or worker retry.

If a pre-submission fence committed, the provider request for that epoch was not started, but the financial outcome is still unresolved. Resume the same collection at the next epoch only after the new exact generation is available; reuse the same PaymentIntent identity for the collection. The fence path first recovers the exact generation and proceeds only when it is active. If release returns an ambiguous database outcome, it recovers again before any further mutation; only exact `cancelled` evidence completes the fence. An initially cancelled generation, an active result after an ambiguous release, missing or contradictory evidence, or an unavailable recovery fails closed. Reconciliation scheduling and provider orchestration remain for the next JC-229 increment.

## Performance & Scaling Review

Focused tests assert Repo telemetry in the isolated PostgreSQL test database:

| Path | Measured Repo queries |
| --- | ---: |
| First collection creation | 8 |
| Active collection replay/lookup | 7 |
| Next ordinal allocation after terminal failure | 9 |
| Dispatch claim CAS, virtual/no generation | 7 |
| Dispatch claim CAS, physical generation | 8 |
| Pre-submission fence, physical generation | 14 |
| Ambiguous exact-release fence attempt | 8 |

These counts include row locks, Ash reads/writes, exact PaymentIntent validation, and exact Orders recovery. They are per one parent with at most one prior collection; they are not throughput benchmarks. The physical dispatch claim adds one exact Orders recovery query. Ordinal allocation reads that parent's history in one query ordered by ordinal. There is no N+1 query pattern, though the history read grows with the number of dunning collections. Existing bounded dunning policy limits that history.

The composite `(renewal_attempt_id, collection_ordinal)` index supports the parent-history filter and ordering used by creation. The partial active index enforces the one-active invariant; the current creation flow scans that parent's short ordinal history so it can also detect gaps, prior success, or contradictory evidence. The nullable unique PaymentIntent index supports reverse lookup by exact PaymentIntent. No cache was added.

No Oban job or uniqueness rule is added in this increment. Existing `RepoStats` telemetry is used for measurement; no new production metric or log event is emitted here. The collection start and transition writes are on the renewal hot path and use a bounded number of database calls. No Redis/ETS/cache acceleration is justified for correctness or this initial query shape.

## Deferred scope

Provider submission, Payments/provider orchestration, PaymentIntent creation, reservation creation/recovery/consumption orchestration, webhook routing, reconciliation workers, commercial paid-renewal reconciliation, generic Orders/Inventory behavior, and JC-230 remain outside this increment.
