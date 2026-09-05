# Store Blueprint Commerce Test Strategy

This is the S0-05 test-strategy inventory for the subscription-commerce vertical slice. It records the test and CI posture observed in the repository on 2026-08-27. Source code, test code, test configuration, and workflow commands are the evidence for current behaviour.

This document is documentation only. It does not add tests, change test configuration, or define an implementation target. “Confidence” and “coverage level” are qualitative assessments of test artifacts found in the repository. No line-coverage or branch-coverage measurement is configured in the inspected `mix.exs`, test configuration, or workflows.

## 1. Purpose

Feature tests demonstrate that a user-visible path can complete. Commerce correctness tests demonstrate that money, ownership, lifecycle, replay, concurrency, durable evidence, and access rules remain true when the path is retried, interrupted, or executed concurrently. Extraction needs the second kind of confidence because moving a facade or resource can preserve a happy path while changing a transition guard, a uniqueness boundary, or a post-commit side effect.

The current test suite contains both kinds of tests. This strategy records which behaviours are protected today, which are only indirectly exercised, and which have no verified test evidence. Future hardening and extraction gates are stated separately from current facts.

## 2. Current Test Inventory

The counts below are directory-local test declarations found during inspection. Governance and web tests are listed as additional evidence where they protect the same domain; the counts are not intended as a line-coverage metric.

| Area | Existing Tests | Confidence | Missing |
|---|---|---|---|
| Catalog | 7 focused tests in [`test/store/catalog`](../../test/store/catalog); catalog lifecycle, variant, option, availability, public-read, and cache tests in [`test/store/governance/catalog_phase_19_test.exs`](../../test/store/governance/catalog_phase_19_test.exs), [`test/store/governance/catalog_phase_25_test.exs`](../../test/store/governance/catalog_phase_25_test.exs), and LiveView tests | Moderate | No focused SubscriptionPlan lifecycle suite; no complete product/variant/plan transition matrix; no test proving the effect of every catalog retirement case on existing subscriptions |
| Cart | 7 facade tests in [`test/store/carts/facade_test.exs`](../../test/store/carts/facade_test.exs); cart and checkout LiveView tests; checkout interlock tests | Moderate to high for current cart mutations | No cart expiration suite; no formal `Cart` state-transition suite; no broad multi-process cart merge/mutation race suite |
| Checkout | 13 domain tests in [`test/store/checkout/domain_test.exs`](../../test/store/checkout/domain_test.exs); subscription-only checkout tests; checkout LiveView tests; interlock and pricing/tax/shipping governance tests | High for start/finalize interlocks and snapshot evidence | No executable `CheckoutDraft` consumed/expired transition suite; no complete interrupted-checkout recovery matrix; no provider-independent full flow against a real external boundary |
| Orders | 5 focused tests in [`test/store/orders`](../../test/store/orders); state-machine, snapshot, uniqueness, refund, inventory, and provider-setup governance tests | High for explicit order states, snapshots, and selected interlocks | No exhaustive transition/terminal-state matrix; no blanket test that every mutable order field is rejected after payment; no production-provider integration test |
| Payments | 37 focused tests across create-intent, provider task/fault, provider adapters, and refund tests in [`test/store/payments`](../../test/store/payments); webhook controller/worker tests; payment governance tests | High for Stripe-stubbed replay, provider fault isolation, and refund bounds | No real-provider contract run; no complete out-of-order/concurrent callback matrix; no dedicated immutable-evidence suite for every payment evidence resource |
| Subscriptions | 27 focused tests in [`test/store/subscriptions`](../../test/store/subscriptions), 3 StreamData properties in [`scheduler_property_test.exs`](../../test/store/subscriptions/scheduler_property_test.exs), worker tests, policy/uniqueness governance tests, and subscription performance tests | Moderate to high for selected renewal and dunning paths | No complete state-transition matrix; no focused term-end, resume, or cancellation-at-period-end matrix; no renewal-versus-cancellation/plan-change race suite; no all-provider runtime renewal suite |
| Entitlements | 5 focused facade tests in [`test/store/entitlements/facade_test.exs`](../../test/store/entitlements/facade_test.exs); subscription, digital, refund-revocation, policy, and LiveView tests | Moderate to high for grant/revoke/cache paths | No complete access matrix for every subscription state and plan policy; no grant-versus-revoke race suite; no multi-node cache invalidation test |
| Inventory | 7 reservation governance tests in [`test/store/governance/inventory_reservations_test.exs`](../../test/store/governance/inventory_reservations_test.exs), checkout tests, subscription renewal tests, and expiry worker tests | High for tested reservation races and replay cases | No systematic expiry-versus-reserve race matrix; no stress evidence for many variants/orders beyond the performance smoke scenarios; no separate database-constraint-only suite |
| Workers | 19 tests in [`test/store/workers`](../../test/store/workers), plus worker assertions in payment, subscription, comms, and digital tests; Oban is tested in manual mode | Moderate to high for named worker paths | No production-like Oban execution test with real queues/plugins; no broad retry/backoff/dead-letter verification; no distributed worker/cache failure test |
| Cross-cutting security and governance | 141 governance tests in [`test/store/governance`](../../test/store/governance), policy tests, controller tests, support tests, and web-layer static gates | Moderate to high for declared rules | No coverage report, mutation testing, secret-scanning job, fuzzing campaign, or tenant-isolation suite; tenant isolation is not a current concept because the application is single-tenant |
| Performance | 9 unit/reporting tests in [`test/store/perf`](../../test/store/perf), 3 subscription query/cache tests in [`test/store/subscriptions/performance_test.exs`](../../test/store/subscriptions/performance_test.exs), and the standalone [`priv/repo/performance_smoke_test.exs`](../../priv/repo/performance_smoke_test.exs) | Moderate for configured smoke scenarios | No generic webhook, entitlement, or renewal soak; no long-running queue/backlog test; no multi-node or production-scale external-service test |

### Test harness facts

- [`mix.exs`](../../mix.exs) maps `test` through `mix ecto.create --quiet`, `mix ecto.migrate --quiet`, and `mix test`. The `check` alias also runs formatting, compile warnings as errors, dependency audit, repository governance gates, Credo strict, documentation checks, and tests.
- [`config/test.exs`](../../config/test.exs) uses PostgreSQL on port `5433`, configures both `Store.Repo` and `Store.DirectRepo` with `Ecto.Adapters.SQL.Sandbox`, runs Oban in `:manual` mode with plugins and queues disabled, enables Stripe through `Req.Test`, uses the fake digital storage provider, and uses Swoosh’s test adapter.
- [`test/test_helper.exs`](../../test/test_helper.exs) puts both repositories in sandbox manual mode, flushes the configured Redis test database, and fails startup when Redis is unavailable. It also keeps `config :ash, :missed_notifications, :raise` active.
- [`test/support/data_case.ex`](../../test/support/data_case.ex) starts sandbox owners for both repositories. Database tests generally use `async: false`, so concurrent behaviour is created explicitly with `Task` inside a test rather than by running the database suite in parallel.
- Provider HTTP behaviour is stubbed through [`test/support/stripe_api_stub.ex`](../../test/support/stripe_api_stub.ex) and `Req.Test`. The test suite does not call live Stripe, PayFast, Paystack, Peach Payments, or Yoco services.
- Fixtures are concentrated in [`test/support/test_fixtures.ex`](../../test/support/test_fixtures.ex), [`test/support/order_fixtures.ex`](../../test/support/order_fixtures.ex), and [`test/support/subscriptions_fixtures.ex`](../../test/support/subscriptions_fixtures.ex). This makes the main flows repeatable, but means fixture defaults are not evidence that every production configuration is tested.
- Fresh verification for this inventory completed with `3 properties, 453 tests, 0 failures`; Credo reported no issues and documentation generation succeeded.

## 3. Lifecycle Test Coverage

The table records states and transitions that have direct or indirect test evidence. A state being accepted by an enum or migration is not counted as transition coverage. “Not proven” means that repository search did not find a test that asserts the behaviour.

| Resource | States tested | Transitions/guards tested | Terminal states tested | Current evidence and gaps |
|---|---|---|---|---|
| `Product` | `draft`, `published`, `archived` | Publish, unpublish, archive, archived publish rejection, public visibility; admin policy path | Archived publish rejection is tested; exhaustive terminal behaviour is not | [`catalog_phase_19_test.exs`](../../test/store/governance/catalog_phase_19_test.exs) covers the main product lifecycle. It does not provide an exhaustive forbidden-transition table or version/race coverage. |
| `Variant` | `active`, `archived` | Active completeness, archive, archive-to-active update path, selection-signature and sellability validation | No exhaustive terminal-state assertions | [`catalog_phase_25_test.exs`](../../test/store/governance/catalog_phase_25_test.exs) covers active configuration and archive/reactivation-related behaviour. `Variant` has no AshStateMachine, so tests do not exercise a common transition API. |
| `SubscriptionPlan` | The type declares `active` and `archived`; active is used by fixtures, while archived is not exercised by a focused test | Plan creation, variant-plan attachment, pricing/term validation, and active-plan selection are exercised; activate/archive transitions are not in a focused test | Not proven | Subscription tests use active plans and archived catalog variants. A direct plan retirement and existing-subscription effect test was not found. |
| `Cart` | Active cart paths; abandoned is exercised as a merge result | Add/update/remove version changes, no-op update, guest-to-user merge, ownership, and membership blockers | No cart terminal/expiration assertion | [`facade_test.exs`](../../test/store/carts/facade_test.exs) is the main evidence. Cart has `active`/`abandoned` status but no formal state machine, and no expired state was found. |
| `CheckoutDraft` | `open` creation and lookup/attachment paths | Same cart-version/key idempotency and ownership guards; no draft transition action | `consumed` and `expired` are not tested as executable transitions | [`domain_test.exs`](../../test/store/checkout/domain_test.exs) verifies draft/order creation and ownership. The resource/migration declare `open`, `consumed`, and `expired`, but no writer or test for the latter two was found. |
| `Order` | `pending_payment`, `pending_provider_setup`, `paid`, `payment_failed`, `refunded`; cancellation is exercised by stale provider-setup worker paths | Direct state tests cover payment success, payment failure, provider setup and return, refund, forbidden movement, replay; worker tests cover stale setup cancellation | Refund and cancelled are treated as terminal by the exposed transition graph; all terminal rejection paths are not tested | [`state_machines_test.exs`](../../test/store/governance/state_machines_test.exs), [`expire_pending_provider_setup_orders_worker_test.exs`](../../test/store/workers/expire_pending_provider_setup_orders_worker_test.exs), and payment worker tests. Governance lists fewer states than the resource. |
| `PaymentIntent` | Direct state tests cover `created`, `submitted`, and `failed`; success is asserted in webhook-worker paths; `requires_action` and `cancelled` are not directly asserted as transition results | Submit/failed, forbidden transition, replay no-op, provider success, provider-reference recovery, and selected cancellation fixtures are covered; direct requires-action/cancel transition coverage is not proven | Succeeded/failed/cancelled are terminal in the exposed graph; complete terminal matrix is not tested | [`state_machines_test.exs`](../../test/store/governance/state_machines_test.exs), provider-fault tests, webhook worker tests, and Stripe provider tests. Direct state tests do not cover every enum state. |
| `WebhookReceipt` | `new`, `processing`, `processed`, `failed` appear in controller/facade/worker assertions | Ingest duplicate no-op, verification gate, mark-processing/processed/failed worker paths, replay, and evidence purge | `processed`/`failed` are processing outcomes, not Ash terminal states; no formal state machine | [`webhook_controller_test.exs`](../../test/store_web/controllers/webhook_controller_test.exs), [`payment_callback_controller_test.exs`](../../test/store_web/controllers/payment_callback_controller_test.exs), and webhook worker tests. Status is a string field with update actions and no version guard. |
| `InventoryReservation` | `active`, `consumed`, `expired`, `cancelled` | Reserve, quantity delta, consume replay, release replay, expiry, expired-consume rejection, last-unit race | Consumed, expired, and cancelled are treated as non-releasable/non-consumable by service code; direct terminal rejection matrix is not complete | [`inventory_reservations_test.exs`](../../test/store/governance/inventory_reservations_test.exs), checkout tests, subscription renewal tests, and expiry worker tests. The service uses row locks and raw Ecto updates in addition to the Ash resource transitions. |
| `Subscription` | `pending`, `active`, `past_due`, and `expired` are asserted; `canceled` is represented in the type and facade path but a successful cancellation transition result is not proven by a focused test | Paid-order creation/activation, past-due transitions, grace expiration, renewal period reconciliation, cancellation authorization paths, plan/variant queueing, and stored-payment-method guard | `expired` has no outgoing transition; `canceled` has no outgoing transition in the resource graph. No explicit resume test was found, although `extend_period` allows active/past-due movement | [`facade_test.exs`](../../test/store/subscriptions/facade_test.exs), [`replay_concurrency_test.exs`](../../test/store/subscriptions/replay_concurrency_test.exs), and subscription policy tests. No single suite proves every allowed and forbidden transition. |
| `RenewalAttempt` | `pending`, `processing`, `succeeded`, `failed` | Create/reuse, claim, success, failure, renewal reconciliation, worker replay and uniqueness | No explicit terminal-state rejection matrix | [`subscriptions_uniqueness_test.exs`](../../test/store/governance/subscriptions_uniqueness_test.exs), subscription facade/worker tests, and replay concurrency tests. Claim uses an `updated_at` compare-and-set; there is no version attribute. |
| `EntitlementGrant` | `active`, `revoked`, `expired` | Issue/upsert, validity evaluation, revoke, expiration through subscription grace expiry/worker paths, refund line revocation | Revoked/expired access rejection is tested through evaluation; no complete terminal update matrix | [`test/store/entitlements/facade_test.exs`](../../test/store/entitlements/facade_test.exs), subscription facade tests, digital facade tests, and refund digital revocation tests. The resource has no AshStateMachine and `expire` is an update action. |

### Supporting payment-evidence objects

`ProviderEvent` and `PaymentAttempt` are tested through payment interlock, uniqueness, webhook, and worker paths rather than through lifecycle suites. `ProviderEvent` has an ingest upsert keyed by `(provider, provider_event_id)` and no state field. `PaymentAttempt` has append-only-looking create evidence with uniqueness on provider-event and attempt keys and no state field. `RefundAttempt` records outcome and sequence evidence but has no status transition API. `StoredPaymentMethod` has `active`, `inactive`, and `revoked` values, with a focused create/reuse test but no transition matrix. These objects have useful identity tests, but their evidence and retry contracts are not tested as a unified suite.

## 4. Invariant Test Coverage

| Invariant | Test proving it | Current evidence | Gap |
|---|---|---|---|
| Money uses deterministic integer-minor-unit calculations and does not lose pennies | [`pricing_determinism_test.exs`](../../test/store/governance/pricing_determinism_test.exs), [`tax_shipping_determinism_test.exs`](../../test/store/governance/tax_shipping_determinism_test.exs) | Pure pricing, discount allocation, tax/shipping tie-breaks, and snapshot values are tested for repeatability and integer remainder allocation | No broad property suite for every renewal/proration/currency combination; catalog-plan mutation effects on all historical subscriptions are not covered |
| Finalized commercial totals and historical snapshots are preserved | [`immutable_snapshots_test.exs`](../../test/store/governance/immutable_snapshots_test.exs), [`snapshot_read_immutability_test.exs`](../../test/store/governance/snapshot_read_immutability_test.exs), checkout domain tests | Checkout finalization is idempotent, snapshot reads use stored evidence, and snapshot resources have no update/destroy actions | The full `Order` record still has mutable update actions; no invariant test covers every mutable order field after payment |
| One logical checkout/payment intent is not duplicated by retry | [`checkout_interlocks_test.exs`](../../test/store/governance/checkout_interlocks_test.exs), checkout domain tests, payment create-intent tests | Checkout keys, cart-version keys, payment-intent keys, in-flight payment uniqueness, and apply-once payment application are tested | No full cross-process duplicate-submit test from HTTP through worker; no test covers every key mismatch/reuse combination |
| Provider evidence is preserved and replay is harmless | [`idempotency_transitions_test.exs`](../../test/store/governance/idempotency_transitions_test.exs), uniqueness gates, webhook worker tests | Duplicate receipt/provider-event ingest and payment/refund worker replay are covered; verified receipts gate reconciliation | PaymentAttempt/RefundAttempt immutability and concurrent duplicate callbacks are not comprehensively proven |
| Cart and subscription ownership is enforced | [`accounts_policy_test.exs`](../../test/store/governance/accounts_policy_test.exs), [`subscriptions_policy_matrix_test.exs`](../../test/store/governance/subscriptions_policy_matrix_test.exs), checkout domain tests, policy matrix tests | Customer reads are actor-scoped; cross-account subscription cancellation, guest token matching, checkout ownership, and privileged roles are tested | Guest tokens remain bearer credentials; no separate abuse/rate test for cart/checkout ownership paths |
| Inventory cannot be oversold by tested concurrent reservations | [`inventory_reservations_test.exs`](../../test/store/governance/inventory_reservations_test.exs), expiry worker tests, performance smoke | Last-unit race, idempotent retry, quantity delta, consume/release/expiry replay, and reservation row/inventory locking are tested | Expiry versus reserve/consume races and high-volume mixed operations are not covered by the focused suite |
| Entitlements are unique, valid, and cacheable | [`test/store/entitlements/facade_test.exs`](../../test/store/entitlements/facade_test.exs), subscription uniqueness, digital/refund tests | Grant upsert, validity-at-read, revoke, cache invalidation, single-flight cache miss, and targeted refund revocation are tested | No exhaustive subscription-status/access-policy matrix; grant/revoke concurrency and multi-node invalidation are not tested |
| Privileged refund operations require role, step-up, amount, and currency checks | [`refund_semantics_test.exs`](../../test/store/governance/refund_semantics_test.exs), refund worker and digital revocation tests | Admin/step-up, idempotency, refundable bounds, currency, payment-intent locking, webhook replay, and digital line allocation are covered | No live provider confirmation test and no test of every partial-failure path between provider result and order adjustment |

The suite therefore proves several important invariants at targeted boundaries, but it does not provide a single end-to-end invariant harness that runs all downstream effects under duplicate, failure, and concurrent delivery.

## 5. Payment Testing Strategy

### Current evidence

- `Store.Payments.Interlocks` and the webhook facade persist a `WebhookReceipt`, normalize verified provider data, ingest a deduplicated `ProviderEvent`, record a `PaymentAttempt`, and apply local payment state through domain actions. The controller tests verify raw-body/signature handling, receipt persistence, and enqueue-only behaviour.
- [`process_webhook_receipt_worker_test.exs`](../../test/store/workers/process_webhook_receipt_worker_test.exs) covers successful payment application, metadata fallback when the provider reference is not yet persisted, disabled-provider failure, setup-intent success, immediate past-due retry, and release of renewal inventory on recurring failure.
- [`provider_fault_isolation_test.exs`](../../test/store/payments/provider_fault_isolation_test.exs) covers slow, timeout, error, and crash provider paths, local recovery when provider references already exist, and stranded-intent handling. [`provider_task_test.exs`](../../test/store/payments/provider_task_test.exs) covers task shutdown and timeout races.
- Stripe normalization and setup/charge paths are exercised with `Req.Test`. PayFast, Paystack, Peach Payments, and Yoco recurring capabilities are tested as disabled or unsupported and fail closed; those tests are not provider integration tests.
- Refund request, concurrency, webhook replay, threshold-to-order-refund, and digital line revocation are covered by [`refund_semantics_test.exs`](../../test/store/governance/refund_semantics_test.exs), [`process_refund_webhook_receipt_worker_test.exs`](../../test/store/workers/process_refund_webhook_receipt_worker_test.exs), and [`refunds_digital_revocation_test.exs`](../../test/store/payments/refunds_digital_revocation_test.exs).

### Required payment scenarios before extraction

| Scenario | Current protection/evidence | Testing requirement |
|---|---|---|
| Duplicate webhook | Receipt and provider-event uniqueness; sequential worker replay tests | Execute duplicate delivery concurrently and assert one provider application, one order transition, one downstream enqueue set, and one durable attempt outcome |
| Replay after worker failure | Worker returns durable receipt status and has Oban retry configuration; successful replay is tested | Inject failure after each durable write and before each downstream effect, then replay the same receipt and assert recovery without duplication |
| Provider retry | Provider fault tests cover transport retry/idempotent local intent creation; selected webhook retries are covered | Cover provider retry with same and changing payload hashes, repeated provider event IDs, and delayed provider references |
| Failed payment | Payment intent/order failure paths and recurring failure inventory release are tested | Verify every failed status maps to the intended local state, renewal attempt, order, reservation, entitlement, and notification result |
| Successful payment | Apply-once interlock, paid order, initial subscription worker, and entitlement issuance are tested | Verify the complete payment-success graph under duplicate and out-of-order arrival, including a failure in each downstream worker |
| Refund | Admin/step-up, amount/currency bounds, provider receipt replay, order threshold, and digital line scope are tested | Add coverage for partial provider failure, repeated provider refund IDs, refund attempt evidence, and recovery between requested/submitted/final states |
| Partial failure | Provider fault isolation and selected worker failures are tested | Exercise transaction rollback and retry when order, inventory, subscription, entitlement, or notification side effects fail independently |
| Out-of-order events | Provider references and event deduplication exist; no complete ordering suite was found | Deliver failed/succeeded/requires-action/refund events in every relevant order and assert stale events cannot regress local state |

The current system uses durable Postgres evidence as the payment test fixture authority. It does not test live provider behaviour, provider rate limits, provider signature implementations against live services, or external network recovery.

## 6. Subscription Testing Strategy

### Current evidence

- Creation from a paid order is replay-safe by source order line. The paid-order worker and facade tests assert subscription and entitlement creation on duplicate runs.
- Activation and initial payment are exercised through the payment webhook worker and subscription facade. A return URL is not used as payment proof in the tested path.
- Cancellation is exposed through user/admin facade tests and policy tests. The resource has separate `cancel_at_period_end` and immediate cancellation actions; a complete state/side-effect matrix for both modes was not found.
- Dunning tests cover missing/inactive stored payment methods, disabled providers, payment failure, physical shipping cost blockers, physical out-of-stock retryability, synchronous decline inventory release, grace expiration, and entitlement revocation.
- Renewal tests cover deterministic schedule keys, end-of-month clamping, grace days, one attempt under concurrent renewal ticks, pending locked pricing promotion, worker jitter, and payment reconciliation. [`performance_test.exs`](../../test/store/subscriptions/performance_test.exs) also checks bounded due-job and entitlement reads.
- Plan and variant changes are tested as queued pending snapshots. Stored payment method create/reuse is tested by provider/customer/payment-method identity. A setup-purpose payment intent is tested for card updates.

### Required subscription scenarios before extraction

| Scenario | Current evidence | Testing requirement |
|---|---|---|
| Creation | Paid-order worker replay and source-line uniqueness | Assert one subscription per source line across concurrent paid-order worker runs and partial downstream failures |
| Activation | Payment success worker and facade tests | Test activation from every permitted source state and reject activation after terminal state; assert exact period/pricing/entitlement outcomes |
| Cancellation | Cross-account/role policy tests and facade path | Test immediate and period-end cancellation, repeated cancellation, cancellation versus renewal, and the access/notification/renewal consequences |
| Expiry | Grace expiry test revokes entitlements | Test term end and grace expiry separately, repeated expiry, expiry versus payment recovery, and no subsequent renewal scheduling |
| Renewal | Scheduler, facade, worker, replay/concurrency, and reconciliation tests | Test one logical billing-period outcome under duplicate jobs, provider callbacks, worker retries, cancellation, plan change, and inventory expiry |
| Retry/dunning | Missing method, disabled provider, payment failure, shipping and stock branches | Test retry count boundaries, suppression, recovery to active, notification idempotency, and all configured access-on-past-due policies |
| Payment failure | Past-due/failure worker paths | Test failed, requires-action, timeout, and late-success provider events against the same renewal attempt |
| Plan/variant changes | Pending snapshot calculation and promotion | Test change before renewal, during payment, after failure, after cancellation, and after plan retirement |
| Stored payment method | Identity-based create/reuse and setup webhook update | Test active/inactive/revoked transitions, replacement, ownership, concurrent replacement, and renewal selection |

The most important current testing gap is not the absence of renewal tests. It is the absence of a complete, independently readable lifecycle contract that combines subscription state, renewal-attempt state, payment state, inventory state, entitlement state, and notification outcomes for every retry and race.

## 7. Concurrency Testing Strategy

| Area | Current protection and evidence | Missing concurrency coverage | Future test requirement |
|---|---|---|---|
| Checkout | Cart/item and order paths use Postgres locks and uniqueness; parallel `start_from_cart` is tested; performance smoke runs concurrent checkout flows | Duplicate finalization and concurrent cart mutation during finalization are not covered as a dedicated matrix | Run simultaneous start, finalize, duplicate submit, and cart mutation against the same cart/version. Assert one order/snapshot/hold/payment-intent outcome and stable stale errors. |
| Inventory | Reservation service locks inventory and order/variant rows, uses ordered UUID lock acquisition, and has last-unit and replay tests | Reservation expiry racing with reserve, consume, and release is not fully tested | Run reserve/expire/consume/release in overlapping tasks for the same variant and order; assert no negative counters, no oversell, and one terminal reservation result. |
| Payments | Unique payment intent/provider-event/application keys, payment-intent version, and receipt processing worker protect selected replay paths | No dedicated concurrent duplicate webhook/callback suite; out-of-order callback behaviour is not established | Deliver identical and conflicting callbacks concurrently and in reverse order. Assert durable evidence is retained and local state cannot regress or double-apply. |
| Subscriptions | Renewal key uniqueness, Oban uniqueness, renewal-attempt `updated_at` compare-and-set, and one concurrent tick test | Renewal versus cancellation, renewal versus plan/variant change, retry versus webhook, and success versus expiry are not covered together | Execute each race with barriers around durable writes and provider responses. Assert one billing-period key, no duplicate charge/order, deterministic terminal state, and correct entitlement result. |
| Entitlements | Cachex single-flight cache miss and post-commit invalidation are tested | Grant versus revoke and cache read during invalidation are not tested concurrently; no multi-node test | Run grant/revoke/expire and entitlement reads concurrently and verify a read never authorizes from a stale terminal grant after the invalidation boundary. |

The database tests are mostly non-async because shared SQL sandbox ownership is used. This gives deterministic isolation but does not by itself simulate independent application nodes or independent database transactions; the race tests explicitly create tasks and must remain separate extraction gates.

## 8. Soak and Stress Testing

### Current implementation

The standalone [`priv/repo/performance_smoke_test.exs`](../../priv/repo/performance_smoke_test.exs) is enabled only with `STORE_PERF_SMOKE=true`. It has local, `ci_gate`, and `full_stress` profiles and records JSON/performance artifacts under `tmp/perf/`. Current scenarios include:

- Benchee microbenchmarks for the stock fast path and Redis hash, sorted-set, and HyperLogLog operations.
- Hot ETS stock reads, warm Redis operations, and cold Postgres stock reads. The default API mean target is 100ms.
- Concurrent checkout flows with query-step telemetry, p99 checkout target defaulting to 5 seconds, Postgres observer samples, lock-wait ratios, and pool utilization.
- Slow, timeout, error, and provider-incident fault scenarios with database-share, lock-wait, and pool-utilization measurements.
- Redis seat-hold concurrency, high-velocity seat-map updates, domain and Redis thundering-herd tests, single-flight cache stampede tests, cold-path saturation, write-through mirror consistency, and HyperLogLog relative-error checks.

The smoke harness defaults to Stripe through the test stub, disables Oban plugins and queues for its run, and uses direct database/Redis connections. It measures selected queue and query timings but does not exercise a production Oban queue or a live payment provider.

The nightly workflow [`nightly-hardening.yml`](../../.github/workflows/nightly-hardening.yml) runs the full test suite for seeds 101, 202, and 303, focuses scheduler properties/replay concurrency/subscription performance, repeats the renewal replay test three times, and runs the full-stress provider-incident smoke profile. The run blocks use `tee` and do not declare `set -o pipefail`; the workflow source therefore does not make pipe-failure propagation explicit for those logged commands.

### Future soak and stress requirements

| Load scenario | Measurements required |
|---|---|
| Checkout spike | Request latency p50/p95/p99, errors by canonical code, Postgres query count/time/queue time, row-lock waits, pool saturation, reservation conflicts, and queue depth |
| Subscription renewal batch | Tick duration, due-job batch size, Oban queue depth/age, renewal-attempt duplication, provider latency/error distribution, database contention, dunning backlog, and entitlement invalidation lag |
| Webhook storm | Receipt ingest throughput, signature failures, duplicate ratio, worker queue depth/age, processing latency, retry count, database writes, and downstream duplicate side effects |
| Entitlement reads | Cold/warm hit ratio, Cachex single-flight contention, Postgres fallback query count, invalidation-to-read latency, stale-read observations, and memory growth |
| Mixed commerce load | Checkout, payment confirmation, renewal, and entitlement reads together, with provider latency injected and Redis/Postgres resource pressure measured independently |

Soak requirements are future test requirements, not claims that the current repository has already met them. No long-running generic queue soak or multi-node cache/PubSub test was found.

## 9. Security Testing

### Current controls and test evidence

- Ash policies and facade ownership rules are exercised in [`policy_matrix_test.exs`](../../test/store/governance/policy_matrix_test.exs), [`accounts_policy_test.exs`](../../test/store/governance/accounts_policy_test.exs), [`subscriptions_policy_matrix_test.exs`](../../test/store/governance/subscriptions_policy_matrix_test.exs), and the catalog/checkout tests. Customer reads are actor-scoped; support can read selected admin surfaces but cannot perform subscription lifecycle or provider-setting mutations.
- Admin role assignment is restricted and audited in [`admin_rbac_audit_test.exs`](../../test/store/governance/admin_rbac_audit_test.exs). Refund and provider configuration mutations require an admin role and recent step-up evidence in [`refund_semantics_test.exs`](../../test/store/governance/refund_semantics_test.exs) and [`policy_matrix_test.exs`](../../test/store/governance/policy_matrix_test.exs).
- Webhook tests cover raw request body/header signature verification, missing/invalid signatures, unknown providers, receipt persistence, and enqueue-only controller behaviour. The worker and payment interlock require a verified receipt before provider reconciliation. Return/cancel tests do not treat query parameters as payment proof.
- Rate-limit tests exist for signed digital download access. Test configuration defaults the rate-limit backend to Redis, with an ETS option. No equivalent checkout or webhook endpoint rate-limit test was found.
- `mix deps.audit` runs in the static check. No dedicated secret scanner or source-level credential leak scanner is configured in the inspected workflows. Test secrets are static test values in `config/test.exs` and provider stubs.
- Audit tests cover role assignment and webhook-evidence purge metadata. No general audit assertion was found for every payment, subscription, entitlement, or inventory lifecycle change.
- This repository is single-tenant by rule and implementation: there is no `tenant_id`, tenant routing, or marketplace boundary. A tenant-isolation test is therefore not current-scope coverage. If tenancy is introduced during extraction, it becomes a separate security gate rather than an inferred guarantee.

### Future security test requirements

Future extraction testing must include authorization tests for every public and privileged facade, cross-account ownership attempts, admin/support separation, step-up-sensitive refunds and provider settings, raw-body webhook verification, replayed signed receipts, untrusted provider status/amount/reference inputs, and secret-handling checks. These are test requirements; no security implementation is added by this document.

## 10. CI/CD Testing Requirements

### Current workflow behaviour

The pull-request workflow [`ci.yml`](../../.github/workflows/ci.yml) uses strict versions from [`.tool-versions`](../../.tool-versions), PostgreSQL 16, Redis 7, and separate jobs for:

- `check_static`: creates/migrates the database, checks generated migration alignment, runs `mix deps.audit`, `mix check`, and checks for generated drift.
- `test_pr_strict`: creates/migrates the database and runs `mix test --max-failures 1`.
- `performance_smoke_required`: runs the `ci_gate` performance smoke profile with a configured Postgres pool of 40.
- `performance_smoke_chaos_required`: runs the mobile-realistic chaos profile with the same performance smoke harness.
- `dialyzer_required`: runs `mix check.types` without database or Redis services. The `check.types` alias uses `--ignore-exit-status`, so the job name alone is not evidence that Dialyzer findings fail the build.

The workflow executes dependency audit, static governance checks, tests, Dialyzer, and performance smoke. It does not publish test coverage, run mutation testing, run a dedicated security scanner, test live external providers, test multi-node PubSub/Redis behaviour, or run a generic soak test. The test and performance jobs use stubs, manual Oban mode, test mail, and isolated PostgreSQL/Redis services, so external-service and production-queue behaviour remains outside CI.

The nightly workflow adds multiple seeds, replay/property/performance focus, a renewal replay loop, and full-stress provider-incident performance smoke. It does not add coverage reporting or live provider integration.

### Required future CI gates

Before extracting a commerce domain, CI needs explicit jobs or suites for the lifecycle matrix, invariant matrix, concurrent race matrix, payment evidence replay, provider contract fixtures, security ownership/privilege checks, and extraction boundary integration tests. The existing static and performance checks remain useful evidence, but their names do not substitute for the missing suites described above.

## 11. Extraction Testing Gates

The classifications below describe test evidence readiness, not production implementation readiness.

| Gate | Current status | Evidence required before extraction |
|---|---|---|
| Lifecycle coverage | `PARTIAL` | Every scoped lifecycle-bearing resource has a checked-in state/transition table, allowed and forbidden transition tests, guard tests, terminal-state tests, and replay semantics. Current enum-only and string-status resources remain gaps. |
| Invariant coverage | `PARTIAL` | Money, snapshot, ownership, idempotency, inventory, payment evidence, subscription, and entitlement invariants each have direct tests and failure-consequence assertions. Current tests cover important subsets but not one complete cross-domain contract. |
| Concurrency coverage | `PARTIAL` | Checkout, inventory, payment callbacks, renewal/cancellation, renewal/plan change, and entitlement grant/revoke races run against independent transactions and assert one durable outcome. Current focused race tests cover only selected cases. |
| Payment replay safety | `PARTIAL` | Duplicate, delayed, conflicting, and out-of-order provider events are tested through receipt, event, attempt, intent, order, subscription, entitlement, inventory, and notification effects. Current replay tests are strong but not exhaustive. |
| Worker failure recovery | `PARTIAL` | Every worker has retry, crash, timeout, duplicate, and post-write failure tests, including queue/backlog observability. Current worker tests use manual Oban and cover named happy/failure paths, not a complete failure matrix. |
| Security boundary coverage | `PARTIAL` | Actor, role, step-up, ownership, webhook trust, provider-input, replay, and secret-handling tests are required at every extracted entrypoint. Current policies and webhook tests cover selected boundaries. |
| Performance evidence | `PARTIAL` | Hot-path checkout, payment confirmation, entitlement lookup, and renewal tests record latency, query/queue pressure, cache behaviour, and resource contention under representative load. Current smoke tests cover selected paths and profiles. |
| CI enforcement | `PARTIAL` | Required lifecycle/invariant/concurrency/replay/security suites must fail the PR independently of broad test-suite success. Current CI has strong static, test, type, and smoke jobs but no coverage or dedicated extraction suites. |

No scoped domain is classified `READY` for extraction solely from the current test inventory. This is a testing-confidence statement, not a claim that the domain code cannot be reused.

## Performance Review

The current test strategy treats financial and lifecycle truth as Postgres-backed. Cache and queue observations are tested as supporting behaviour, not as billing authority.

| Hot path | Current source of truth | Current cache/queue evidence | Testing requirement |
|---|---|---|---|
| Checkout | Postgres cart, order, snapshots, and inventory reservation transactions | `StockFastPath` uses ETS with a five-second default TTL as a precheck; checkout smoke captures query and lock/pool metrics; no checkout state cache was found | Measure checkout latency and p99 under stale-cart, duplicate-submit, reservation conflict, and Postgres pool pressure. Assert cache prechecks never override durable reservation results. |
| Payment confirmation | Postgres `WebhookReceipt`, `ProviderEvent`, `PaymentAttempt`, `PaymentIntent`, `PaymentApplication`, and order state | Oban receipt workers are manually tested; no payment confirmation cache was found; provider calls are stubbed | Measure receipt throughput, worker queue age, duplicate ratio, database pressure, and downstream job latency under webhook storms and provider retries. |
| Entitlement lookup | Postgres `EntitlementGrant` rows | Cachex hot cache has a 60-second TTL, single-flight fetch, local invalidation, and Phoenix PubSub invalidation; cold/warm query bounds and concurrent misses are tested | Measure cold/warm hit ratio, invalidation lag, stale-read windows, Cachex contention, memory, and multi-node PubSub behaviour. |
| Subscription renewal | Postgres subscription, renewal attempt, order, payment intent, reservation, and entitlement records | Oban-only tick/renewal workers; renewal due query and subscription detail query counts are tested; no renewal cache was found | Measure batch latency, query/lock/pool pressure, Oban queue age, provider fault impact, renewal-key duplicate rate, and dunning backlog under renewal spikes. |

Other observed cache layers remain outside these four hot paths: catalog availability and stock use ETS TTLs of 300 and 5 seconds respectively; the product-list cache uses Cachex with a two-minute hot TTL, Redis with an approximately 30-minute warm TTL, and PubSub invalidation. Those layers are covered by catalog/performance tests, but they are not evidence that checkout, payment, subscription, or entitlement truth has moved out of Postgres.

## Evidence Index

Primary test/configuration and workflow evidence consulted for this strategy:

- [`mix.exs`](../../mix.exs), [`.tool-versions`](../../.tool-versions), [`config/test.exs`](../../config/test.exs), [`test/test_helper.exs`](../../test/test_helper.exs), [`test/support/data_case.ex`](../../test/support/data_case.ex), and [`test/support/conn_case.ex`](../../test/support/conn_case.ex)
- [`test/store/checkout/domain_test.exs`](../../test/store/checkout/domain_test.exs), [`test/store/governance/checkout_interlocks_test.exs`](../../test/store/governance/checkout_interlocks_test.exs), and [`test/store/governance/state_machines_test.exs`](../../test/store/governance/state_machines_test.exs)
- [`test/store/payments`](../../test/store/payments), [`test/store_web/controllers/webhook_controller_test.exs`](../../test/store_web/controllers/webhook_controller_test.exs), [`test/store_web/controllers/payment_callback_controller_test.exs`](../../test/store_web/controllers/payment_callback_controller_test.exs), [`test/store/workers/process_webhook_receipt_worker_test.exs`](../../test/store/workers/process_webhook_receipt_worker_test.exs), and [`test/store/workers/process_refund_webhook_receipt_worker_test.exs`](../../test/store/workers/process_refund_webhook_receipt_worker_test.exs)
- [`test/store/subscriptions`](../../test/store/subscriptions), [`test/store/entitlements`](../../test/store/entitlements), [`test/store/governance/inventory_reservations_test.exs`](../../test/store/governance/inventory_reservations_test.exs), and [`test/store/governance/refund_semantics_test.exs`](../../test/store/governance/refund_semantics_test.exs)
- [`test/store/governance`](../../test/store/governance), [`test/store_web/controllers`](../../test/store_web/controllers), and [`test/store_web/live`](../../test/store_web/live)
- [`.github/workflows/ci.yml`](../../.github/workflows/ci.yml), [`.github/workflows/nightly-hardening.yml`](../../.github/workflows/nightly-hardening.yml), and [`priv/repo/performance_smoke_test.exs`](../../priv/repo/performance_smoke_test.exs)
- [`docs/governance/state_machines.md`](../../docs/governance/state_machines.md), [`docs/governance/idempotency.md`](../../docs/governance/idempotency.md), [`docs/governance/checkout_interlocks.md`](../../docs/governance/checkout_interlocks.md), [`docs/governance/inventory_reservations.md`](../../docs/governance/inventory_reservations.md), [`docs/governance/payment_provider_contract.md`](../../docs/governance/payment_provider_contract.md), [`docs/governance/refund_semantics.md`](../../docs/governance/refund_semantics.md), [`docs/governance/subscription_scheduling_terms.md`](../../docs/governance/subscription_scheduling_terms.md), [`docs/governance/performance_scaling.md`](../../docs/governance/performance_scaling.md), and [`docs/governance/policy_matrix.md`](../../docs/governance/policy_matrix.md)
