# Store Blueprint Commerce Extraction Gates

Status: S0-08 closure contract
Date: 2026-08-27
Scope: documentation-only discovery synthesis

## 1. Purpose

S0-08 closes Phase S0 discovery. It converts the evidence in S0-01 through S0-07,
the current implementation, migrations, tests, CI, and governance records into
objective gates for future extraction work.

These gates do not mean that extraction starts now. They define when a named
capability is allowed to enter a controlled extraction slice. A gate is evidence-based:
the implementation, its tests, and its operating evidence must satisfy the stated
criterion.

No commerce capability may be labelled extraction-ready merely because existing
feature tests pass.

The implementation remains the source of truth. The S0 documents are evidence and
decision records, not substitutes for source inspection. No application behavior,
test behavior, schema, policy, CI behavior, cache, Redis structure, provider, or
tenant model is changed by this document.

The long-term target is a reusable commerce capability with explicit boundaries such
as Commerce Core, Catalog, Cart, Checkout orchestration, Order evidence, Payment
core, provider adapters, Subscriptions, Entitlements, and Inventory reservations.
S0-08 does not approve those exact boundaries.

## 2. Gate Status Model

Every applicable gate has exactly one current status:

- `PASS`: required evidence exists and satisfies the criterion.
- `FAIL`: available evidence proves that the criterion is not satisfied.
- `BLOCKED`: the criterion cannot currently be evaluated because required environment,
  artifact, or evidence is unavailable.
- `NOT APPLICABLE`: the gate is explicitly excluded by a recorded capability or
  consumer decision.

`BLOCKED` is never treated as `PASS`. A capability is not `READY` when an applicable
blocking gate is `FAIL` or `BLOCKED`. A missing test or missing source proof is a
`FAIL` when the repository demonstrates that the behavior or test does not exist; it
is `BLOCKED` only when the required check cannot be run or the required external
artifact is unavailable.

For this document, `Severity` means the consequence of allowing the gate to remain
unsatisfied:

- `CRITICAL`: extraction is prohibited because financial truth, lifecycle authority,
  replay safety, authorization, or data integrity is not proven.
- `HIGH`: extraction is prohibited for the affected capability because its operation
  can fail under normal concurrency, provider, or recovery conditions.
- `MEDIUM`: the capability can be measured or documented, but it is not a substitute
  for a critical or high correctness gate.

## 3. Global Extraction Gate Summary

This is the executive extraction decision surface. The detailed definitions and
source links follow in Sections 4 through 20.

| Gate ID | Category | Requirement | Current Status | Severity | Blocks Extraction |
|---|---|---|---|---|---|
| GOV-001 | Governance | Authoritative lifecycle and invariant records match executable behavior | FAIL | CRITICAL | Yes |
| GOV-002 | Governance | Lifecycle-bearing state has one approved mutation authority | FAIL | CRITICAL | Yes |
| GOV-003 | Governance | Each extracted resource and action has an identifiable owning domain | FAIL | CRITICAL | Yes |
| GOV-004 | Governance | Postgres remains durable commerce truth and IDs/order laws are preserved | PASS | CRITICAL | Yes if violated |
| LIFE-001 | Lifecycle | Every candidate lifecycle has complete state, transition, guard, side-effect, terminal, replay, and forbidden-transition evidence | FAIL | CRITICAL | Yes |
| LIFE-002 | Lifecycle | Product, Variant, and SubscriptionPlan lifecycle authority is explicit | FAIL | HIGH | Yes |
| LIFE-003 | Lifecycle | Cart and CheckoutDraft lifecycle authority is explicit | FAIL | HIGH | Yes |
| LIFE-004 | Lifecycle | Order and PaymentIntent lifecycle authority and drift are explicit | FAIL | CRITICAL | Yes |
| LIFE-005 | Lifecycle | InventoryReservation lifecycle authority is explicit | FAIL | CRITICAL | Yes |
| LIFE-006 | Lifecycle | WebhookReceipt, ProviderEvent, PaymentAttempt, RefundAttempt, and StoredPaymentMethod evidence lifecycles are explicit | FAIL | CRITICAL | Yes |
| LIFE-007 | Lifecycle | Subscription and RenewalAttempt lifecycle authority is explicit | FAIL | CRITICAL | Yes |
| LIFE-008 | Lifecycle | EntitlementGrant lifecycle authority is explicit | FAIL | CRITICAL | Yes |
| DATA-001 | Financial | Money is integer minor units with explicit currency and no floating-point truth | PASS | CRITICAL | Yes if violated |
| DATA-002 | Financial | Historical order and subscription evidence cannot be silently recomputed from mutable catalog state | FAIL | CRITICAL | Yes |
| DATA-003 | Financial | One logical payment produces one complete set of commercial effects | FAIL | CRITICAL | Yes |
| DATA-004 | Financial | Successful refunds cannot exceed captured/refundable value | PASS | CRITICAL | Yes if violated |
| DATA-005 | Financial | Renewal billing uses explicit frozen contract values | FAIL | CRITICAL | Yes |
| CONC-001 | Concurrency | Last-unit and popular-variant races cannot oversell | FAIL | CRITICAL | Yes |
| CONC-002 | Concurrency | Reservation retry, consume, release, and expiry are idempotent and exactly once | FAIL | CRITICAL | Yes |
| CONC-003 | Concurrency | Multi-row lock order is deterministic and uses binary UUID ordering | PASS | HIGH | Yes if violated |
| CONC-004 | Concurrency | Concurrency evidence is repeated deterministically across the required matrix | FAIL | CRITICAL | Yes |
| CONC-005 | Concurrency | Subscription renewal races have deterministic outcomes | FAIL | CRITICAL | Yes |
| CONC-006 | Concurrency | Payment and webhook races cannot double-apply or regress state | FAIL | CRITICAL | Yes |
| PAY-001 | Payment | Provider adapters build, verify, and normalize without mutating commerce state | PASS | HIGH | Yes if violated |
| PAY-002 | Payment | Webhooks verify raw bytes and headers before canonical processing | PASS | CRITICAL | Yes if violated |
| PAY-003 | Payment | Durable receipt identity and provider-event lineage are complete | FAIL | CRITICAL | Yes |
| PAY-004 | Payment | Replaying the same provider event N times creates one commercial effect | FAIL | CRITICAL | Yes |
| PAY-005 | Payment | Stale and out-of-order events cannot regress terminal state | FAIL | CRITICAL | Yes |
| PAY-006 | Payment | Worker crash and retry cannot double-apply or lose required post-commit effects | FAIL | CRITICAL | Yes |
| PAY-007 | Payment | Payment evidence resources have explicit processing, retry, and terminal authority | FAIL | CRITICAL | Yes |
| PAY-008 | Payment | Stripe has complete independently passing contract certification | FAIL | HIGH | Yes for Stripe extraction |
| PAY-009 | Payment | Each non-Stripe provider has independent production evidence | FAIL | HIGH | Yes for that provider |
| SUB-001 | Subscription | One source order line creates at most one subscription | PASS | CRITICAL | Yes if violated |
| SUB-002 | Subscription | Activation requires valid paid or approved commercial truth | PASS | CRITICAL | Yes if violated |
| SUB-003 | Subscription | One logical billing period creates one charge attempt and effect | FAIL | CRITICAL | Yes |
| SUB-004 | Subscription | Dunning and retry state is deterministic | FAIL | HIGH | Yes |
| SUB-005 | Subscription | Cancellation cannot race into unwanted future billing | FAIL | CRITICAL | Yes |
| SUB-006 | Subscription | Plan and variant pending changes promote exactly once at the defined boundary | FAIL | CRITICAL | Yes |
| SUB-007 | Subscription | Renewal and payment-method changes have deterministic ordering | FAIL | CRITICAL | Yes |
| SUB-008 | Subscription | Expiry, past_due, and late provider success have explicit outcomes | FAIL | CRITICAL | Yes |
| SUB-009 | Subscription | Subscription state and entitlement state synchronize correctly | FAIL | CRITICAL | Yes |
| ENT-001 | Entitlement | Issue is idempotent and durable | PASS | CRITICAL | Yes if violated |
| ENT-002 | Entitlement | Revoke is idempotent and durable | FAIL | CRITICAL | Yes |
| ENT-003 | Entitlement | Expiry is deterministic and authorized | FAIL | CRITICAL | Yes |
| ENT-004 | Entitlement | Access decisions do not require a provider call | PASS | CRITICAL | Yes if violated |
| ENT-005 | Entitlement | Cache invalidation and multi-node behavior preserve access truth | FAIL | CRITICAL | Yes |
| ENT-006 | Entitlement | Signed URL lifetime and revocation window are proven for digital access | FAIL | HIGH | Yes for digital extraction |
| SEC-001 | Security | Ownership checks prevent cross-user reads and mutations | PASS | CRITICAL | Yes if violated |
| SEC-002 | Security | Guest cart bearer capability is explicitly accepted and hardened | FAIL | CRITICAL | Yes |
| SEC-003 | Security | System context and `authorize?: false` paths are unreachable from untrusted input | FAIL | CRITICAL | Yes |
| SEC-004 | Security | Step-up consumers have an end-to-end trusted producer | FAIL | CRITICAL | Yes for sensitive actions |
| SEC-005 | Security | Extracted APIs use explicit allowlists; `public?` is not API exposure policy | FAIL | CRITICAL | Yes |
| SEC-006 | Security | Forged, stale, duplicate, and malformed webhook inputs are tested | FAIL | CRITICAL | Yes |
| SEC-007 | Security | Secrets, client secrets, provider credentials, and PII cannot leak through logs or serializers | FAIL | CRITICAL | Yes |
| SEC-008 | Security | Financially and privilege-sensitive actions have defined durable audit evidence | FAIL | HIGH | Yes |
| TEN-001 | Tenancy | Single-tenant assumptions are explicit and not misrepresented | PASS | HIGH | No |
| TEN-002 | Tenancy | A multi-tenant consumer has an approved tenancy architecture | BLOCKED | CRITICAL | Yes for multi-tenant target |
| PERF-001 | Performance | Architectural hot, warm, and cold classification preserves Postgres authority | PASS | HIGH | Yes if violated |
| PERF-002 | Performance | Every extracted hot path has a complete performance card | FAIL | HIGH | Yes |
| PERF-003 | Performance | Query shape, indexes, N+1 behavior, and analytics isolation meet a measured budget | FAIL | HIGH | Yes |
| PERF-004 | Performance | Cache TTL, invalidation, stampede, and multi-node behavior are proven | FAIL | HIGH | Yes when cache is used |
| PERF-005 | Performance | Oban fan-out, backpressure, rate limits, and retry amplification are bounded | FAIL | HIGH | Yes |
| PERF-006 | Performance | 100k-concurrency behavior is supported by measured load evidence | BLOCKED | HIGH | Yes for capacity claims |
| TEST-001 | Testing | Unit coverage protects extracted rules | PASS | MEDIUM | Yes if absent |
| TEST-002 | Testing | Property coverage protects general invariants and time calculations | FAIL | HIGH | Yes |
| TEST-003 | Testing | Every invariant maps to a test and CI tier | FAIL | CRITICAL | Yes |
| TEST-004 | Testing | Integration and provider contract tests cover the extraction slice | FAIL | HIGH | Yes |
| TEST-005 | Testing | Lifecycle, replay, concurrency, and security suites cover failure paths | FAIL | CRITICAL | Yes |
| TEST-006 | Testing | PR performance smoke detects gross regressions deterministically | PASS | MEDIUM | Yes if absent |
| TEST-007 | Testing | Nightly representative stress produces thresholded evidence | BLOCKED | HIGH | Yes |
| TEST-008 | Testing | Scheduled soak produces thresholded sustained-run evidence | BLOCKED | HIGH | Yes |
| TEST-009 | Testing | Failure injection and chaos cover dependency and worker failures | FAIL | HIGH | Yes |
| CI-001 | CI | Format and warnings-as-errors compilation pass | PASS | HIGH | Yes |
| CI-002 | CI | Static, governance, and documentation gates pass | PASS | HIGH | Yes |
| CI-003 | CI | Migration alignment is checked in the required CI path | BLOCKED | HIGH | Yes |
| CI-004 | CI | Lifecycle, invariant, replay, security, and performance suites are required CI gates | FAIL | CRITICAL | Yes |
| CI-005 | CI | The Dialyzer job fails on new unignored findings | FAIL | HIGH | Yes |
| CI-006 | CI | Required CI pipelines fail on failed commands and do not mask results | FAIL | HIGH | Yes |
| DEP-001 | Supply chain | Dependency audit has no unresolved applicable critical/high advisory | PASS | HIGH | Yes if violated |
| DEP-002 | Supply chain | Lockfile and dependency resolution are reproducible | BLOCKED | HIGH | Yes |
| DEP-003 | Supply chain | Dependency and provider API changes have compatibility evidence | FAIL | HIGH | Yes |
| EXT-001 | Extraction | Every source component has a KEEP/RENAME/REWRITE/REJECT manifest | FAIL | CRITICAL | Yes |
| EXT-002 | Extraction | Each extracted capability has a bounded slice, API owner, and consumer validation | FAIL | CRITICAL | Yes |
| EXT-003 | Extraction | Checkout, payment, and subscription facade coupling is frozen and documented | FAIL | CRITICAL | Yes |

The summary is intentionally conservative. Current passing local tests do not cancel
blocking failures in lifecycle authority, replay, race coverage, security boundaries,
facade coupling, or measured operating evidence.

## 4. Governance and Authority Gates

| Gate ID | Category | Requirement | Evidence required | Current Status | PASS condition | FAIL condition | BLOCKED condition | Severity | Blocks extraction | Applies to | Source/evidence links |
|---|---|---|---|---|---|---|---|---|---|---|---|
| GOV-001 | Governance | Authoritative lifecycle and invariant records match executable behavior | Side-by-side review of registry, governance docs, resource DSLs, facades, raw SQL, and tests | FAIL | No unresolved state or transition drift for the extraction slice | A documented state, transition, guard, or terminal rule differs from code | Required source or authority record cannot be inspected | CRITICAL | Yes | Every capability | [`02_lifecycle_registry.md`](02_lifecycle_registry.md), [`02_1_lifecycle_registry_gaps.md`](02_1_lifecycle_registry_gaps.md), [`03_invariant_registry.md`](03_invariant_registry.md), [`state_machines.md`](../governance/state_machines.md) |
| GOV-002 | Governance | Lifecycle-bearing state has one approved mutation authority | Call-site audit for Ash actions, direct `Repo.update_all`, SQL updates, generic updates, workers, and facades | FAIL | All state changes use declared transitions or an explicitly approved atomic boundary with the same guards | Any unapproved writer can bypass a declared transition or terminal rule | Writer inventory cannot be completed | CRITICAL | Yes | Every lifecycle resource, especially InventoryReservation and payment evidence | [`inventory_reservation.ex`](../../lib/store/orders/inventory_reservation.ex), [`inventory_reservations.ex`](../../lib/store/orders/inventory_reservations.ex), [`02_1_lifecycle_registry_gaps.md`](02_1_lifecycle_registry_gaps.md) |
| GOV-003 | Governance | Each extracted resource and action has an identifiable owning domain | Resource/action ownership map plus cross-domain call graph | FAIL | One domain owns each public action, state transition, side effect, and recovery path | Ownership is split between a resource, facade, interlock, worker, or direct SQL path without a frozen contract | A cross-domain call cannot be traced to an owner | CRITICAL | Yes | Catalog, Cart, Checkout, Payments, Inventory, Subscriptions, Entitlements | [`04_dependency_map.md`](04_dependency_map.md), [`checkout/domain.ex`](../../lib/store/checkout/domain.ex), [`payments/interlocks.ex`](../../lib/store/payments/interlocks.ex), [`subscriptions/facade.ex`](../../lib/store/subscriptions/facade.ex) |
| GOV-004 | Governance | Postgres is durable truth and identity/order laws are preserved | Schema/resource audit, cache audit, UUID law tests, and extraction review of tie-break and lock ordering | PASS | Financial, lifecycle, reservation, payment, subscription, and entitlement truth is in Postgres; caches are derived; UUIDv7 and binary UUID ordering are preserved | Durable commercial truth is placed in cache/Redis/ETS, or UUID string ordering is used for a required hash, tie-break, or lock order | Required identity or storage audit cannot be completed | CRITICAL | Yes if violated | Every capability | [`06_performance_data_map.md`](06_performance_data_map.md), [`id_laws_test.exs`](../../test/store/governance/id_laws_test.exs), [`binary_uuid_sort.ex`](../../lib/store/support/id/binary_uuid_sort.ex), [`inventory_reservations.ex`](../../lib/store/orders/inventory_reservations.ex) |

The current implementation proves durable Postgres authority and selected binary UUID
ordering, but not complete authority parity. `InventoryReservation` declares an
AshStateMachine while checkout and release/consume/expiry code writes state through
direct SQL updates. `WebhookReceipt` has processing actions without a state machine or
claim CAS. `Subscription` transitions use `lock_attribute: nil`. These are failures
of extraction authority, not reasons to alter behavior during S0.

## 5. Domain Lifecycle Gates

For every extraction candidate, the evidence package must contain a row-level lifecycle
contract with: states, legal transitions, guards, side effects, terminal states,
replay behavior, forbidden transitions, owning facade/domain, and the exact tests that
prove each item. A lifecycle is not ready while mutation authority is ambiguous.

| Gate ID | Category | Requirement | Evidence required | Current Status | PASS condition | FAIL condition | BLOCKED condition | Severity | Blocks extraction | Applies to | Source/evidence links |
|---|---|---|---|---|---|---|---|---|---|---|---|
| LIFE-001 | Lifecycle | Every candidate lifecycle has complete state, transition, guard, side-effect, terminal, replay, and forbidden-transition evidence | Completed lifecycle contract for all named candidates and executable call-site review | FAIL | Every required lifecycle field is present, source-backed, and tested | Any field is absent, inferred, or contradicted by source | Required source, test, or runtime evidence is unavailable | CRITICAL | Yes | Product, Variant, SubscriptionPlan, Cart, CheckoutDraft, Order, PaymentIntent, InventoryReservation, WebhookReceipt, Subscription, RenewalAttempt, EntitlementGrant | [`02_lifecycle_registry.md`](02_lifecycle_registry.md), [`02_1_lifecycle_registry_gaps.md`](02_1_lifecycle_registry_gaps.md), [`state_machines_test.exs`](../../test/store/governance/state_machines_test.exs) |
| LIFE-002 | Lifecycle | Catalog lifecycle authority is explicit | Product, Variant, Plan, and attachment state graph, generic update audit, archive/read guards, and tests | FAIL | Catalog state changes have one transition owner and archived/disabled records cannot re-enter active commercial paths without an approved transition | Generic updates can mutate lifecycle state, plan archive does not define dependent behavior, or active filtering differs by caller | Catalog call-site or test inventory is incomplete | HIGH | Yes | Catalog subset | [`product.ex`](../../lib/store/catalog/product.ex), [`variant.ex`](../../lib/store/catalog/variant.ex), [`subscription_plan.ex`](../../lib/store/subscriptions/subscription_plan.ex), [`01_domain_map.md`](01_domain_map.md) |
| LIFE-003 | Lifecycle | Cart and CheckoutDraft lifecycle authority is explicit | State graph, cart version/CAS rules, draft creation/consume/expire writers, and forbidden transition tests | FAIL | Active/abandoned and open/consumed/expired behavior has one owner and replay rules | Cart or draft status can be changed through generic paths, or declared draft terminal transitions have no writer | Draft lifecycle source or expiry behavior cannot be evaluated | HIGH | Yes | Cart, Checkout | [`cart.ex`](../../lib/store/carts/cart.ex), [`checkout_draft.ex`](../../lib/store/checkout/checkout_draft.ex), [`checkout/domain.ex`](../../lib/store/checkout/domain.ex) |
| LIFE-004 | Lifecycle | Order and PaymentIntent lifecycle authority and documentation are explicit | State graph comparison, version/transition tests, provider failure call sites, and terminal-state tests | FAIL | Code and governance list the same states and all callers use guarded transitions | Governance omits executable states such as `pending_provider_setup`, `payment_failed`, or `requires_action`, or a provider failure path bypasses the declared Order transition | Payment/provider failure evidence cannot be replayed in the required environment | CRITICAL | Yes | Orders, Payments core, Checkout | [`order.ex`](../../lib/store/orders/order.ex), [`payment_intent.ex`](../../lib/store/payments/payment_intent.ex), [`state_machines.md`](../governance/state_machines.md), [`state_machines_test.exs`](../../test/store/governance/state_machines_test.exs) |
| LIFE-005 | Lifecycle | InventoryReservation lifecycle authority is explicit | State machine, every raw SQL update, expected-state predicate/version rule, and terminal replay tests | FAIL | Active to consumed/expired/cancelled is controlled by one guarded authority and all callers use it | Direct `Repo.update_all` can set reservation state without expected prior state/version or declared transition | Concurrent DB evidence cannot be executed | CRITICAL | Yes | InventoryReservation | [`inventory_reservation.ex`](../../lib/store/orders/inventory_reservation.ex), [`inventory_reservations.ex`](../../lib/store/orders/inventory_reservations.ex), [`inventory_reservations_test.exs`](../../test/store/governance/inventory_reservations_test.exs) |
| LIFE-006 | Lifecycle | Payment evidence resources have explicit processing, retry, and terminal authority | Resource action graph and worker claim/retry tests for receipt, provider event, payment attempt, refund attempt, and stored method | FAIL | Each evidence row has identity, owner, state/immutability rule, claim semantics, retry semantics, terminal behavior, and lineage | A duplicate can be claimed twice, an immutable record has undefined outcome ownership, or a sequence/lineage rule is not atomic | Provider evidence or worker execution environment is unavailable | CRITICAL | Yes | Payments core and provider adapters | [`webhook_receipt.ex`](../../lib/store/payments/webhook_receipt.ex), [`provider_event.ex`](../../lib/store/payments/provider_event.ex), [`payment_attempt.ex`](../../lib/store/payments/payment_attempt.ex), [`refund_attempt.ex`](../../lib/store/payments/refund_attempt.ex), [`stored_payment_method.ex`](../../lib/store/subscriptions/stored_payment_method.ex) |
| LIFE-007 | Lifecycle | Subscription and RenewalAttempt lifecycle authority is explicit | Subscription state graph, renewal attempt claim/terminal graph, period boundary rules, and race tests | FAIL | Renewal, dunning, cancellation, pending change, expiry, and late-success states have one guarded owner | Subscription creation writes `active` outside the declared initial transition, subscription transitions have no lock attribute, or RenewalAttempt generic updates bypass a graph | Required provider or clock-controlled renewal environment is unavailable | CRITICAL | Yes | Subscriptions | [`subscription.ex`](../../lib/store/subscriptions/subscription.ex), [`renewal_attempt.ex`](../../lib/store/subscriptions/renewal_attempt.ex), [`facade.ex`](../../lib/store/subscriptions/facade.ex), [`scheduler_test.exs`](../../test/store/subscriptions/scheduler_test.exs) |
| LIFE-008 | Lifecycle | EntitlementGrant lifecycle authority is explicit | Issue/revoke/expire graph, validity model, idempotency, actor/system rules, and access tests | FAIL | Issue, revoke, and expiry are guarded, replay-safe, and have deterministic access semantics | Generic updates, ignored revoke failures, or missing expiry workers can leave access state ambiguous | Access invalidation or time-controlled evidence is unavailable | CRITICAL | Yes | Entitlements and Digital access | [`entitlement_grant.ex`](../../lib/store/entitlements/entitlement_grant.ex), [`entitlements/facade.ex`](../../lib/store/entitlements/facade.ex), [`entitlement_set.ex`](../../lib/store/entitlements/types/entitlement_set.ex) |

### Candidate lifecycle evidence snapshot

This snapshot records observed implementation facts. It is not approval of any
lifecycle.

| Candidate | Observed states | Observed authority and current risk | Extraction condition |
|---|---|---|---|
| Product | `draft`, `published`, `archived` | Publish/archive actions exist, but versioning and universal terminal enforcement are not proven | Freeze the state graph, owner, archive read guards, and forbidden transitions |
| Variant | `active`, `archived` | Generic update can set status; no common transition/version authority is proven | Route every lifecycle mutation through one guarded owner |
| SubscriptionPlan | `active`, `archived`; attachment has `active` | Generic updates and caller-specific active filtering exist; archive cascade semantics are not defined | Define plan and attachment transitions and the behavior of existing subscriptions |
| Cart | `active`, `abandoned`; version | Merge can abandon a cart; no complete expire/consume graph and generic status bypass risk remain | Define version, ownership, merge, expiry, and terminal replay rules |
| CheckoutDraft | Declared `open`, `consumed`, `expired` | Open creation is observed; complete consume/expire writers are not | Add source-backed transition ownership and tests in the later hardening phase |
| Order | `pending_payment`, `pending_provider_setup`, `paid`, `payment_failed`, `cancelled`, `refunded`; version | Ash transitions and replay no-op tests exist; governance omits two states and normal provider failure does not uniformly call `mark_payment_failed` | Reconcile registry and code and prove all provider failure paths |
| PaymentIntent | `created`, `submitted`, `requires_action`, `succeeded`, `failed`, `cancelled`; version | Formal state machine exists; governance omits `requires_action` | Reconcile documentation and prove provider ordering/terminal rules |
| InventoryReservation | Declared `active`, `consumed`, `expired`, `cancelled`; version | Service inserts and directly updates state via SQL without expected-state predicate/version | Make the approved transition boundary and SQL atomicity explicit and test it |
| WebhookReceipt | Verification and processing statuses are strings | `mark_processing` special-cases only `processed`; no state machine/version/CAS claim is shown | Define claim, retry, terminal, and duplicate ownership |
| ProviderEvent | Immutable provider/event identity | Upsert uniqueness exists, but no processing state or receipt lineage and duplicate result is not a clear no-op boundary | Define immutable evidence lineage and duplicate worker behavior |
| PaymentAttempt | Immutable outcome record | Identity/upsert exists, but no dedicated lifecycle or focused test set | Define outcome owner and attempt replay semantics |
| RefundAttempt | Outcome and sequence evidence | Sequence uses `MAX + 1` separately from create; concurrent distinct events can collide | Define atomic sequence and replay behavior |
| StoredPaymentMethod | Active/inactive/revoked | Generic status mutation has no state graph/version | Define ownership, transitions, and renewal ordering |
| Subscription | `pending`, `active`, `past_due`, `canceled`, `expired` | Creation path writes `active`; transitions use `lock_attribute: nil`; period-end cancellation is a flag only | Freeze activation, cancellation, expiry, and late-success rules |
| RenewalAttempt | `pending`, `processing`, `succeeded`, `failed` | Claim has timestamp/status CAS, later updates are generic and race matrix is incomplete | Define one claim/terminal owner and test all renewal races |
| EntitlementGrant | `active`, `revoked`, `expired` | Issue is upserted; revoke/expire are generic updates; subscription calls can skip/ignore errors | Define lifecycle authority, failure policy, and access truth |

## 6. Financial Integrity Gates

The financial gates are blocking. A passing local pricing test is evidence for a
specific rule only; it is not certification of the complete payment, refund, or
renewal workflow.

| Gate ID | Category | Requirement | Evidence required | Current Status | PASS condition | FAIL condition | BLOCKED condition | Severity | Blocks extraction | Applies to | Source/evidence links |
|---|---|---|---|---|---|---|---|---|---|---|---|
| DATA-001 | Financial | Money is integer minor units with explicit currency and no floating-point financial truth | Resource attributes, pure pricing contract, arithmetic audit, and automated pricing/tax tests | PASS | All financial values are integers paired with explicit currency, and tests reject invalid/non-integral inputs without using float truth | Any financial source uses float, omits currency, or recomputes truth from display values | Required arithmetic/test audit cannot be run | CRITICAL | Yes if violated | Catalog pricing, Checkout, Orders, Payments, Subscriptions, Refunds | [`pricing/contract.ex`](../../lib/store/pricing/contract.ex), [`pricing/evaluator.ex`](../../lib/store/pricing/evaluator.ex), [`order_line_item.ex`](../../lib/store/orders/order_line_item.ex), [`pricing_determinism_test.exs`](../../test/store/governance/pricing_determinism_test.exs), [`tax_shipping_determinism_test.exs`](../../test/store/governance/tax_shipping_determinism_test.exs) |
| DATA-002 | Financial | Historical order and subscription evidence cannot be silently recomputed from mutable catalog state | Append-only snapshot actions, paid-order mutation audit, subscription contract fields, and tests after catalog changes | FAIL | Paid order lines/adjustments and renewal obligations retain all required historical values and reads return stored evidence | Paid commercial history or renewal amount can change because Product, Variant, Plan, or mutable Order fields are re-read without an explicit contract | Historical source or migration evidence is unavailable | CRITICAL | Yes | Orders, Payments, Subscriptions, Catalog-derived checkout | [`order_line_item.ex`](../../lib/store/orders/order_line_item.ex), [`order_adjustment.ex`](../../lib/store/orders/order_adjustment.ex), [`order.ex`](../../lib/store/orders/order.ex), [`immutable_snapshots_test.exs`](../../test/store/governance/immutable_snapshots_test.exs), [`snapshot_read_immutability_test.exs`](../../test/store/governance/snapshot_read_immutability_test.exs), [`subscription.ex`](../../lib/store/subscriptions/subscription.ex) |
| DATA-003 | Financial | One logical payment produces one complete set of commercial effects | Payment application uniqueness, post-commit outbox/handoff, duplicate/retry tests, and failure injection | FAIL | One stable payment identity atomically protects all required financial/lifecycle effects and durably retries every required post-commit effect | PaymentApplication protects the transaction but a duplicate or post-commit enqueue failure can skip or repeat fulfillment, digital, subscription, or communication effects | Provider replay or worker-failure environment is unavailable | CRITICAL | Yes | Payments, Orders, Inventory, Fulfillment, Digital, Subscriptions, Comms | [`payments/interlocks.ex`](../../lib/store/payments/interlocks.ex), [`payment_application.ex`](../../lib/store/orders/payment_application.ex), [`post_commit_notifications_test.exs`](../../test/store/governance/post_commit_notifications_test.exs), [`04_dependency_map.md`](04_dependency_map.md) |
| DATA-004 | Financial | Successful refunds cannot exceed captured/refundable value | Locked refundable-balance calculation, refund amount/currency checks, refund state transitions, and automated over-refund tests | PASS | Every successful local refund is bounded by the captured/refundable amount and currency and concurrent requests serialize or conflict safely | Aggregate successful refunds can exceed captured value, currency can mismatch, or a retry bypasses the remaining-balance check | Provider result or refund ledger evidence is unavailable | CRITICAL | Yes if violated | Payments and Orders | [`refunds.ex`](../../lib/store/payments/refunds.ex), [`refund.ex`](../../lib/store/payments/refund.ex), [`refund_semantics_test.exs`](../../test/store/governance/refund_semantics_test.exs), [`refunds_digital_revocation_test.exs`](../../test/store/payments/refunds_digital_revocation_test.exs) |
| DATA-005 | Financial | Renewal billing uses explicit frozen contract values | Subscription creation/update source, renewal pricing path, plan/variant mutation tests, and historical billing assertions | FAIL | Renewal amount, currency, quantity, interval, and applicable tax/shipping contract are explicit and immutable or versioned for the billing period | Mutable catalog administration silently rewrites a customer obligation or the renewal path depends on current plan values without a frozen contract | Required historical billing fixture or provider evidence is unavailable | CRITICAL | Yes | Subscriptions, Payments, Checkout, Pricing | [`subscription.ex`](../../lib/store/subscriptions/subscription.ex), [`subscriptions/facade.ex`](../../lib/store/subscriptions/facade.ex), [`subscription_scheduling_terms.md`](../governance/subscription_scheduling_terms.md), [`subscriptions_phase_26_test.exs`](../../test/store/governance/subscriptions_phase_26_test.exs) |

The current implementation has strong integer/minor-unit and snapshot components.
The blocking result comes from the boundary: the full paid Order is still mutable,
subscription plan/variant history is not uniformly frozen for renewal, and the
payment application key does not itself provide a durable retry handoff for every
post-commit effect.

## 7. Inventory and Concurrency Gates

Concurrency certification must assert post-run database invariants, not only job
return values. The required repeated suite runs each scenario at least 100 times
across at least three deterministic seeds, records every failure, and starts each
run from isolated database state. The suite must cover one hot variant, multiple
variants, duplicate callers, worker retries, and interleavings between checkout,
renewal, payment success, release, and expiry.

| Gate ID | Category | Requirement | Evidence required | Current Status | PASS condition | FAIL condition | BLOCKED condition | Severity | Blocks extraction | Applies to | Source/evidence links |
|---|---|---|---|---|---|---|---|---|---|---|---|
| CONC-001 | Concurrency | Last-unit and popular-variant races cannot oversell | Repeated concurrent reserve tests with final `stock_on_hand`, `reserved_count`, active reservations, and `allow_oversell` assertions | FAIL | Across the required repetitions, no non-oversell variant has `reserved_count > stock_on_hand` and each accepted reservation has a matching durable row | Any invariant violation, unexplained deadlock, or race result that depends on timing | PostgreSQL concurrency environment is unavailable | CRITICAL | Yes | InventoryReservation, Cart, Checkout, Subscription renewals | [`inventory_reservations_test.exs`](../../test/store/governance/inventory_reservations_test.exs), [`inventory_reservations.ex`](../../lib/store/orders/inventory_reservations.ex), [`06_performance_data_map.md`](06_performance_data_map.md) |
| CONC-002 | Concurrency | Reservation retry, consume, release, and expiry are idempotent and exactly once | Duplicate/retry tests plus final row/counter assertions for all terminal paths | FAIL | Repeating any operation N times yields one reservation identity, one counter effect, one terminal state, and no negative or leaked counter | A replay changes a terminal result, decrements/increments twice, or bypasses a terminal state | Required worker/DB replay environment is unavailable | CRITICAL | Yes | InventoryReservation | [`inventory_reservations.ex`](../../lib/store/orders/inventory_reservations.ex), [`inventory_reservations_test.exs`](../../test/store/governance/inventory_reservations_test.exs), [`expire_inventory_reservations_worker_test.exs`](../../test/store/workers/expire_inventory_reservations_worker_test.exs) |
| CONC-003 | Concurrency | Multi-row lock order is deterministic and uses binary UUID ordering | Source audit and tests for lock sequence across all multi-row reservation, cart, refund, and renewal paths | PASS | All multi-row locks use one documented order and binary UUID comparison; deadlock retry behavior is explicit | Any lock path orders UUIDs as strings or acquires rows in an undocumented order | A full extraction-slice lock audit cannot be completed | HIGH | Yes if violated | Inventory, Cart, Payments, Subscriptions | [`binary_uuid_sort.ex`](../../lib/store/support/id/binary_uuid_sort.ex), [`inventory_reservations.ex`](../../lib/store/orders/inventory_reservations.ex), [`id_laws_test.exs`](../../test/store/governance/id_laws_test.exs) |
| CONC-004 | Concurrency | Concurrency evidence is repeated deterministically across the required matrix | CI/nightly artifacts with repetition count, seeds, invariant checks, lock waits, deadlocks, and cleanup checks | FAIL | At least 100 repetitions per scenario across at least three seeds pass with retained artifacts and zero unexplained failures | Only one example run exists, cases are capped to one, or outcomes are not checked against database invariants | Required runner, database, or artifact store is unavailable | CRITICAL | Yes | All hot concurrent paths | [`05_test_strategy.md`](05_test_strategy.md), [`nightly-hardening.yml`](../../.github/workflows/nightly-hardening.yml), [`06_performance_data_map.md`](06_performance_data_map.md) |
| CONC-005 | Concurrency | Subscription renewal races have deterministic outcomes | Matrix tests for renewal vs cancellation, plan change, variant change, payment-method change, retry vs webhook, and expiry vs late success | FAIL | Each pair has one documented winner/boundary and repeated runs leave one valid subscription period, one charge effect, and correct entitlement state | Any pair can double charge, bill after cancellation, lose a pending change, or produce ambiguous late-success outcome | Provider/clock/queue environment needed for the matrix is unavailable | CRITICAL | Yes | Subscriptions, Payments, Entitlements | [`replay_concurrency_test.exs`](../../test/store/subscriptions/replay_concurrency_test.exs), [`subscriptions/facade.ex`](../../lib/store/subscriptions/facade.ex), [`02_lifecycle_registry.md`](02_lifecycle_registry.md) |
| CONC-006 | Concurrency | Payment and webhook races cannot double-apply or regress state | Concurrent duplicate/out-of-order worker tests, receipt claim tests, provider-event tests, and final state assertions | FAIL | N duplicate deliveries and conflicting orderings produce one monotonic terminal outcome and one downstream effect set | Two workers claim one receipt, duplicate provider evidence reaches application, or a stale event regresses a terminal resource | Provider/worker concurrency environment is unavailable | CRITICAL | Yes | Payments, Orders, Inventory, Fulfillment, Digital, Subscriptions | [`webhook_receipt.ex`](../../lib/store/payments/webhook_receipt.ex), [`payments/facade.ex`](../../lib/store/payments/facade.ex), [`payments/interlocks.ex`](../../lib/store/payments/interlocks.ex), [`process_webhook_receipt_worker_test.exs`](../../test/store/workers/process_webhook_receipt_worker_test.exs) |

The current tests prove useful selected cases, including one last-unit race, repeated
reservation operations, and a two-task renewal tick. They do not satisfy the repeated
matrix requirement, and the raw reservation update path remains an authority failure
even where its counter logic is correct.

## 8. Payment and Webhook Gates

Payment return and cancel routes are read-only and cannot be payment proof. Provider
adapters may build payloads, verify signatures, and normalize receipts. They may not
write commerce state, call `Repo`, call `Ash`, enqueue Oban, or apply business rules.

| Gate ID | Category | Requirement | Evidence required | Current Status | PASS condition | FAIL condition | BLOCKED condition | Severity | Blocks extraction | Applies to | Source/evidence links |
|---|---|---|---|---|---|---|---|---|---|---|---|
| PAY-001 | Payment | Provider adapters build, verify, and normalize without mutating commerce state | Static provider module audit and negative boundary tests | PASS | Adapter modules contain only provider I/O/payload/signature/normalization behavior and return canonical data | Adapter writes a resource, enqueues a job, applies a transition, or contains commerce business rules | Provider source or boundary test cannot be inspected | HIGH | Yes if violated | All payment providers | [`behavior.ex`](../../lib/store/payments/providers/behavior.ex), [`providers/stripe.ex`](../../lib/store/payments/providers/stripe.ex), [`payment_provider_contract.md`](../governance/payment_provider_contract.md) |
| PAY-002 | Payment | Webhooks verify raw bytes and headers before canonical processing | Forged, stale, malformed, and valid raw-body signature tests for each provider | PASS | Signature is checked over the exact raw body and headers before receipt persistence or enqueue | JSON is re-encoded before verification, stale signatures pass, or unverified input reaches a worker | Provider signing fixtures or test environment is unavailable | CRITICAL | Yes if violated | Webhook ingress, Stripe adapter, each future provider | [`webhook_controller.ex`](../../lib/store_web/controllers/webhook_controller.ex), [`payment_callback_controller.ex`](../../lib/store_web/controllers/payment_callback_controller.ex), [`providers/stripe.ex`](../../lib/store/payments/providers/stripe.ex), [`webhook_controller_test.exs`](../../test/store_web/controllers/webhook_controller_test.exs) |
| PAY-003 | Payment | Durable receipt identity and provider-event lineage are complete | Receipt uniqueness, provider-event identity, receipt-to-event lineage, payload hash, and attempt links | FAIL | `(provider, provider_event_id)` prevents duplicate receipts and every canonical application points to durable receipt/event/attempt evidence | Identity exists but duplicate result, receipt lineage, or attempt linkage is lost or ambiguous | Required provider payload lineage is unavailable | CRITICAL | Yes | Payments and provider adapters | [`webhook_receipt.ex`](../../lib/store/payments/webhook_receipt.ex), [`provider_event.ex`](../../lib/store/payments/provider_event.ex), [`payment_attempt.ex`](../../lib/store/payments/payment_attempt.ex), [`payment_provider_contract.md`](../governance/payment_provider_contract.md) |
| PAY-004 | Payment | Replaying the same provider event N times creates one commercial effect | N-replay tests for receipt, event, attempt, PaymentIntent, Order, reservation, subscription, entitlement, fulfillment, digital, and email effects | FAIL | Every replay returns a no-op or the same durable result and creates no duplicate effect | Duplicate event reaches downstream application or retry after a commit loses required fan-out | Provider replay runner or durable effect inspection is unavailable | CRITICAL | Yes | Payments, Orders, Inventory, Subscriptions, Entitlements, Fulfillment, Digital, Comms | [`payments/interlocks.ex`](../../lib/store/payments/interlocks.ex), [`payment_application.ex`](../../lib/store/orders/payment_application.ex), [`idempotency_transitions_test.exs`](../../test/store/governance/idempotency_transitions_test.exs) |
| PAY-005 | Payment | Stale and out-of-order events cannot regress terminal state | Ordered and reversed event fixtures for success, failure, cancellation, refund, and late events | FAIL | State transitions are monotonic or resolve through a documented reconciliation rule; terminal state cannot regress | A stale failure/cancel/refund or late success changes a terminal state incorrectly | Provider ordering fixtures are unavailable | CRITICAL | Yes | PaymentIntent, Order, Refund, Subscription | [`payments/interlocks.ex`](../../lib/store/payments/interlocks.ex), [`state_machines.md`](../governance/state_machines.md), [`payment_provider_contract.md`](../governance/payment_provider_contract.md) |
| PAY-006 | Payment | Worker crash and retry cannot double-apply or lose required post-commit effects | Failure injection at receipt claim, evidence write, transaction commit, notification, and each enqueue boundary | FAIL | A crash before commit rolls back, a crash after commit resumes durably, and all required effects are eventually represented exactly once | Post-commit enqueue errors are logged and returned as success without a durable retry handoff, or a retry repeats a commercial effect | Crash-injection runner or production-like Oban is unavailable | CRITICAL | Yes | Payment webhook and all payment fan-out | [`payments/interlocks.ex`](../../lib/store/payments/interlocks.ex), [`process_webhook_receipt_worker.ex`](../../lib/store/workers/process_webhook_receipt_worker.ex), [`04_dependency_map.md`](04_dependency_map.md) |
| PAY-007 | Payment | Payment evidence resources have explicit processing, retry, and terminal authority | State/immutability matrix and concurrent claim/retry tests for five evidence resources | FAIL | Receipt claim is compare-and-set, immutable evidence has explicit outcome semantics, refund sequence is atomic, and stored methods have guarded transitions | Receipt claim is non-CAS, ProviderEvent duplicate result is not a worker stop boundary, attempts lack tests, or RefundAttempt sequence can collide | A required evidence table or worker cannot be exercised | CRITICAL | Yes | Payments core | [`webhook_receipt.ex`](../../lib/store/payments/webhook_receipt.ex), [`provider_event.ex`](../../lib/store/payments/provider_event.ex), [`payment_attempt.ex`](../../lib/store/payments/payment_attempt.ex), [`refund_attempt.ex`](../../lib/store/payments/refund_attempt.ex), [`stored_payment_method.ex`](../../lib/store/subscriptions/stored_payment_method.ex) |
| PAY-008 | Payment | Stripe has complete independently passing contract certification | Stripe create/setup/off-session/refund/verify/normalize contract tests, stable idempotency keys, and failure fixtures | FAIL | All supported Stripe operations, including refund completion boundary, pass deterministic contract tests and the extracted slice has no untested Stripe behavior | Stripe has no refund callback/operation in the provider behavior and tests cover only the implemented subset; a Req.Test stub is mistaken for full provider certification | Stripe contract environment is unavailable | HIGH | Yes | Stripe adapter and Payments core | [`providers/stripe.ex`](../../lib/store/payments/providers/stripe.ex), [`behavior.ex`](../../lib/store/payments/providers/behavior.ex), [`stripe_subscriptions_test.exs`](../../test/store/payments/providers/stripe_subscriptions_test.exs) |
| PAY-009 | Payment | Each non-Stripe provider has independent production evidence | Per-provider intent, webhook, normalization, recurring, refund, failure, replay, and contract suite | FAIL | A provider is marked production candidate only after its own contract and operational evidence passes | Capability declarations or resolver presence are used as proof while methods return not-implemented/disabled errors | Provider sandbox or contract artifacts are unavailable | HIGH | Yes for that provider | PayFast, Paystack, Yoco, Peach Payments, and any future provider | [`providers/payfast.ex`](../../lib/store/payments/providers/payfast.ex), [`providers/paystack.ex`](../../lib/store/payments/providers/paystack.ex), [`providers/yoco.ex`](../../lib/store/payments/providers/yoco.ex), [`providers/peach_payments.ex`](../../lib/store/payments/providers/peach_payments.ex), [`providers_resolver_test.exs`](../../test/store/payments/providers/providers_resolver_test.exs) |

The current webhook controllers verify, normalize, persist when configured, and
enqueue one job for a new receipt. Duplicate receipt ingestion returns a duplicate
result and does not enqueue a new job. The processing boundary still has material
gaps: `WebhookReceipt.mark_processing` is not a compare-and-set claim, the
`ProviderEvent` duplicate result is not a clear downstream no-op, post-commit enqueue
failures are logged, and the payment callback route has different refund routing than
the webhook route. These facts keep the replay and evidence gates failed.

## 9. Subscription Gates

Subscription extraction requires the commercial contract, scheduler, payment method,
provider result, and entitlement outcome to be tested as one bounded system. Renewal
uniqueness by itself is not enough.

| Gate ID | Category | Requirement | Evidence required | Current Status | PASS condition | FAIL condition | BLOCKED condition | Severity | Blocks extraction | Applies to | Source/evidence links |
|---|---|---|---|---|---|---|---|---|---|---|---|
| SUB-001 | Subscription | One source order line creates at most one subscription | Unique source-line identity, concurrent create test, and result inspection | PASS | Repeating or concurrently submitting the same paid source line returns one subscription identity | More than one open subscription is created for one source line | Required DB uniqueness or concurrency environment is unavailable | CRITICAL | Yes if violated | Subscription creation | [`subscriptions/facade.ex`](../../lib/store/subscriptions/facade.ex), [`subscription.ex`](../../lib/store/subscriptions/subscription.ex), [`subscriptions_uniqueness_test.exs`](../../test/store/governance/subscriptions_uniqueness_test.exs) |
| SUB-002 | Subscription | Activation requires valid paid or approved commercial truth | Paid-order/payment-intent checks, worker path, and negative unpaid/guest tests | PASS | Activation is possible only after the approved local paid evidence is present and the source order line is eligible | A return URL, mutable request parameter, unpaid order, or unapproved actor can activate a subscription | Required provider or activation fixture is unavailable | CRITICAL | Yes if violated | Subscription creation and activation | [`subscriptions/facade.ex`](../../lib/store/subscriptions/facade.ex), [`ensure_subscriptions_for_paid_order_worker.ex`](../../lib/store/workers/ensure_subscriptions_for_paid_order_worker.ex), [`subscriptions_phase_26_test.exs`](../../test/store/governance/subscriptions_phase_26_test.exs) |
| SUB-003 | Subscription | One logical billing period creates one charge attempt and effect | Renewal key uniqueness, concurrent worker replay, provider idempotency key, order/payment/application assertions | FAIL | One `(subscription, renewal_key)` has one attempt, one provider charge identity, one applied commercial effect, and one period advance | Retry, duplicate tick, webhook, or crash creates two charge/effect identities or advances twice | Provider/Oban production-like replay environment is unavailable | CRITICAL | Yes | Subscription renewal, Payments | [`renewal_attempt.ex`](../../lib/store/subscriptions/renewal_attempt.ex), [`subscriptions/facade.ex`](../../lib/store/subscriptions/facade.ex), [`replay_concurrency_test.exs`](../../test/store/subscriptions/replay_concurrency_test.exs) |
| SUB-004 | Subscription | Dunning and retry state is deterministic | Time-controlled failure matrix, retry schedule assertions, attempt terminal tests, and queue replay tests | FAIL | The same failure at the same period produces the same attempt status, retry time, subscription status, and entitlement outcome | Retry amplification, non-deterministic attempt status, or a failed update silently loses dunning state | Clock-controlled provider or queue environment is unavailable | HIGH | Yes | Subscription renewal and dunning | [`subscription.ex`](../../lib/store/subscriptions/subscription.ex), [`subscriptions/facade.ex`](../../lib/store/subscriptions/facade.ex), [`scheduler_property_test.exs`](../../test/store/subscriptions/scheduler_property_test.exs), [`subscription_scheduling_terms.md`](../governance/subscription_scheduling_terms.md) |
| SUB-005 | Subscription | Cancellation cannot race into unwanted future billing | Renewal-vs-cancel matrix, period-end worker evidence, due-query assertions, and entitlement assertions | FAIL | Immediate and period-end cancellation have one documented boundary and no due worker can charge after the effective cancellation | `cancel_at_period_end` only suppresses due selection while the active row remains without a proven period-end transition, or renewal wins unexpectedly | Time and scheduler environment is unavailable | CRITICAL | Yes | Subscription renewal and cancellation | [`subscription.ex`](../../lib/store/subscriptions/subscription.ex), [`subscriptions/facade.ex`](../../lib/store/subscriptions/facade.ex), [`subscription_scheduling_terms.md`](../governance/subscription_scheduling_terms.md) |
| SUB-006 | Subscription | Plan and variant pending changes promote exactly once at the defined boundary | Pending plan/variant fixture, concurrent renewal/change tests, period-boundary assertions, and idempotent promotion tests | FAIL | A pending plan and variant change has one effective boundary, one promotion, and one contract price/entitlement result | Renewal, plan change, or variant change can overwrite, double-promote, or silently use the wrong price/variant | Required catalog, clock, or renewal fixture is unavailable | CRITICAL | Yes | Subscriptions, Catalog, Pricing, Entitlements | [`subscription.ex`](../../lib/store/subscriptions/subscription.ex), [`subscriptions/facade.ex`](../../lib/store/subscriptions/facade.ex), [`02_lifecycle_registry.md`](02_lifecycle_registry.md) |
| SUB-007 | Subscription | Renewal and payment-method changes have deterministic ordering | Concurrent stored-payment-method update and renewal tests, ownership checks, provider reference assertions | FAIL | Renewal uses exactly one approved method version and a concurrent update has one documented winner/retry outcome | Renewal uses a revoked or stale method, loses a valid update, or charges twice during method replacement | Provider method-update environment is unavailable | CRITICAL | Yes | Subscriptions, StoredPaymentMethod, Payments | [`stored_payment_method.ex`](../../lib/store/subscriptions/stored_payment_method.ex), [`stored_payment_method_test.exs`](../../test/store/subscriptions/stored_payment_method_test.exs), [`subscriptions/facade.ex`](../../lib/store/subscriptions/facade.ex) |
| SUB-008 | Subscription | Expiry, past_due, and late provider success have explicit outcomes | Late-success fixtures after grace expiry, state/period/entitlement assertions, and webhook ordering tests | FAIL | A late success is reconciled to one documented outcome without reviving an invalid period or granting unintended access | A late success revives an expired subscription ambiguously, duplicates a period, or leaves payment and access inconsistent | Provider delay and controlled-time environment is unavailable | CRITICAL | Yes | Subscriptions, Payments, Entitlements | [`subscription.ex`](../../lib/store/subscriptions/subscription.ex), [`payments/interlocks.ex`](../../lib/store/payments/interlocks.ex), [`entitlements/facade.ex`](../../lib/store/entitlements/facade.ex), [`02_lifecycle_registry.md`](02_lifecycle_registry.md) |
| SUB-009 | Subscription | Subscription state and entitlement state synchronize correctly | Activation, renewal success, cancellation, refund, expiry, and failure tests with durable grant assertions | FAIL | Every approved subscription boundary has one entitlement issue/revoke/renew outcome and a retryable durable handoff | Initial entitlement issue is after a separate transaction and errors may be skipped; cancellation ignores revoke results; direct subscription-to-entitlement calls have no stable event boundary | Required entitlement/worker evidence is unavailable | CRITICAL | Yes | Subscriptions and Entitlements | [`subscriptions/facade.ex`](../../lib/store/subscriptions/facade.ex), [`entitlements/facade.ex`](../../lib/store/entitlements/facade.ex), [`entitlement_grant.ex`](../../lib/store/entitlements/entitlement_grant.ex), [`04_dependency_map.md`](04_dependency_map.md) |

## 10. Entitlement and Access Gates

Postgres grants remain durable access truth. A cache may accelerate a read but cannot
authorize access after a missed invalidation without a documented, accepted stale
window. Provider calls are not an access-check dependency.

| Gate ID | Category | Requirement | Evidence required | Current Status | PASS condition | FAIL condition | BLOCKED condition | Severity | Blocks extraction | Applies to | Source/evidence links |
|---|---|---|---|---|---|---|---|---|---|---|---|
| ENT-001 | Entitlement | Issue is idempotent and durable | Unique grant identity, repeated issue tests, and post-commit retry evidence | PASS | Repeating issue for the same source/effective grant returns one durable grant and preserves the valid period | Duplicate active grants or non-durable issue results can be produced | Grant DB or worker environment is unavailable | CRITICAL | Yes if violated | Entitlements, Subscriptions, Digital | [`entitlement_grant.ex`](../../lib/store/entitlements/entitlement_grant.ex), [`entitlements/facade.ex`](../../lib/store/entitlements/facade.ex), [`entitlements/facade_test.exs`](../../test/store/entitlements/facade_test.exs) |
| ENT-002 | Entitlement | Revoke is idempotent and durable | Repeated revoke, concurrent revoke, failure retry, and final access assertions | FAIL | Revoke N times produces one terminal grant state, one durable reason, and no effective access | Revoke errors are ignored, a revoked grant can be reactivated without authority, or concurrent revokes diverge | Required grant concurrency environment is unavailable | CRITICAL | Yes | Entitlements, Digital | [`entitlements/facade.ex`](../../lib/store/entitlements/facade.ex), [`entitlement_grant.ex`](../../lib/store/entitlements/entitlement_grant.ex), [`refunds_digital_revocation_test.exs`](../../test/store/payments/refunds_digital_revocation_test.exs) |
| ENT-003 | Entitlement | Expiry is deterministic and authorized | Time-controlled expiry tests, state transition tests, and access checks before/at/after expiry | FAIL | Expiry occurs at the defined instant through an approved authority and reads consistently deny access after it | Validity is computed differently by caller, no durable expiry writer exists, or expiry can be bypassed by generic update | Controlled clock or expiry worker environment is unavailable | CRITICAL | Yes | Entitlements and Digital | [`entitlement_grant.ex`](../../lib/store/entitlements/entitlement_grant.ex), [`entitlement_set.ex`](../../lib/store/entitlements/types/entitlement_set.ex), [`entitlements/facade.ex`](../../lib/store/entitlements/facade.ex) |
| ENT-004 | Entitlement | Access decisions do not require a provider call | Access path trace, provider outage test, and Postgres grant read assertions | PASS | Access uses durable local grant state and validity; provider outage does not become an authorization dependency | A provider call is required to decide access or a cache substitutes for durable grant truth | Provider outage fixture or access path cannot be exercised | CRITICAL | Yes if violated | Entitlements, Digital | [`entitlements/facade.ex`](../../lib/store/entitlements/facade.ex), [`entitlement_set.ex`](../../lib/store/entitlements/types/entitlement_set.ex), [`07_security_model.md`](07_security_model.md) |
| ENT-005 | Entitlement | Cache invalidation and multi-node behavior preserve access truth | Cache hit/miss, issue/revoke/expiry invalidation, missed-message, multi-node, and cache-outage tests | FAIL | Local invalidation and PubSub behavior are proven across nodes; a missed message is bounded by an accepted TTL and cannot grant beyond policy | Multi-node behavior is untested, invalidation can be missed without a tested bound, or stale data grants access after revocation | Multi-node or shared PubSub environment is unavailable | CRITICAL | Yes when cache is used | Entitlements and any extracted access projection | [`entitlements/cache.ex`](../../lib/store/entitlements/cache.ex), [`entitlements/facade.ex`](../../lib/store/entitlements/facade.ex), [`06_performance_data_map.md`](06_performance_data_map.md) |
| ENT-006 | Entitlement | Signed URL lifetime and revocation window are proven for digital access | On-demand signing tests, expiry/revocation timing, replay/counter tests, and storage-provider contract | FAIL | Access is through a DownloadGrant, signed URLs are short-lived and generated on demand, and the accepted revocation window is measured and documented | Direct asset URL is exposed, revocation can be bypassed for an undocumented period, or signed URL/counter behavior is not replay-safe | Storage provider or time/load evidence is unavailable | HIGH | Yes for digital extraction | Digital fulfillment and Entitlements | [`download_grant.ex`](../../lib/store/digital/download_grant.ex), [`digital/facade.ex`](../../lib/store/digital/facade.ex), [`storage_provider.ex`](../../lib/store/digital/storage_provider.ex), [`07_security_model.md`](07_security_model.md) |

## 11. Security Gates

Every sensitive-state gate must record the trust boundary, authorization owner,
actor/system requirement, replay risk, data exposure risk, and audit requirement.
The current application is single-tenant, but single tenancy does not remove
ownership, bearer-capability, system-context, provider, or serializer boundaries.

| Gate ID | Category | Requirement | Evidence required | Current Status | PASS condition | FAIL condition | BLOCKED condition | Severity | Blocks extraction | Applies to | Source/evidence links |
|---|---|---|---|---|---|---|---|---|---|---|---|
| SEC-001 | Security | Ownership checks prevent cross-user reads and mutations | Policy matrix tests, facade tests, parent-order scoping, guest/user merge tests, and negative cases | PASS | An actor can read or mutate only owned resources or explicitly role-authorized resources, with parent ownership enforced | Any public action accepts an unrelated user/order/cart/subscription/grant, or a child resource escapes parent scope | Required auth/database environment is unavailable | CRITICAL | Yes if violated | Cart, Checkout, Orders, Payments, Subscriptions, Entitlements, Digital | [`policy_matrix.md`](../governance/policy_matrix.md), [`policy_matrix_test.exs`](../../test/store/governance/policy_matrix_test.exs), [`cart.ex`](../../lib/store/carts/cart.ex), [`order_line_item.ex`](../../lib/store/orders/order_line_item.ex) |
| SEC-002 | Security | Guest cart bearer capability is explicitly accepted and hardened | Token signing/validation design, malformed/tampered token tests, rotation/revocation decision, and merge abuse tests | FAIL | The extraction contract states that the token is a bearer capability, validates signed tokens only, limits scope/lifetime, and proves guest merge cannot cross cart ownership | `EnsureCartToken` falls back from an invalid signed cookie to a raw cookie, or raw token becomes extracted security authority without explicit acceptance | Required browser/session and abuse test environment is unavailable | CRITICAL | Yes | Guest Cart, Checkout | [`ensure_cart_token.ex`](../../lib/store_web/plugs/ensure_cart_token.ex), [`cart.ex`](../../lib/store/carts/cart.ex), [`merge_cart_on_auth.ex`](../../lib/store_web/plugs/merge_cart_on_auth.ex), [`07_security_model.md`](07_security_model.md) |
| SEC-003 | Security | System context and `authorize?: false` paths are unreachable from untrusted input | Call graph, actor/context construction audit, negative public-boundary tests, and worker-only entrypoint tests | FAIL | Only trusted workers or explicit system facades can manufacture system context; public params cannot select `system?: true` or disable authorization | A public caller can pass or influence system context, directly call an internal facade, or reach `authorize?: false` without an authenticated trust boundary | Full deployment boundary or worker isolation cannot be evaluated | CRITICAL | Yes | All workers, facades, payments, subscriptions, entitlements, digital access | [`payments/facade.ex`](../../lib/store/payments/facade.ex), [`subscriptions/facade.ex`](../../lib/store/subscriptions/facade.ex), [`entitlements/facade.ex`](../../lib/store/entitlements/facade.ex), [`process_webhook_receipt_worker.ex`](../../lib/store/workers/process_webhook_receipt_worker.ex), [`07_security_model.md`](07_security_model.md) |
| SEC-004 | Security | Step-up consumers have an end-to-end trusted producer | Producer route/action, session issuance, freshness check, consumer list, and forged-context tests | FAIL | Sensitive refund/provider/pricing actions receive a recent step-up value produced only by trusted reauthentication/MFA and reject absent/stale/forged values | Consumers accept a test-injected or session-parsed value without a proven producer, or a caller can manufacture freshness | Required authentication/MFA integration environment is unavailable | CRITICAL | Yes for sensitive actions | Refunds, provider config, sensitive pricing/admin actions | [`step_up_recent.ex`](../../lib/store/support/governance/checks/step_up_recent.ex), [`role_with_step_up.ex`](../../lib/store/support/governance/checks/role_with_step_up.ex), [`refunds.ex`](../../lib/store/payments/refunds.ex), [`live_user_auth.ex`](../../lib/store_web/live_user_auth.ex), [`step_up.md`](../governance/step_up.md) |
| SEC-005 | Security | Extracted APIs use explicit allowlists; `public?` is not API exposure policy | ash_json_api routes, serializer allowlists, sensitive-attribute review, and API contract tests | FAIL | API exposure is explicitly allowlisted per action and role; provider refs, client secrets, billing details, raw evidence, and PII are excluded unless deliberately approved | A public Ash attribute or generic serializer exposes sensitive state, or API fields are inherited from resource `public?` flags | API consumer/serializer contract environment is unavailable | CRITICAL | Yes | Public API, Orders, Payments, Subscriptions, Digital | [`payment_intent.ex`](../../lib/store/payments/payment_intent.ex), [`subscription.ex`](../../lib/store/subscriptions/subscription.ex), [`webhook_receipt.ex`](../../lib/store/payments/webhook_receipt.ex), [`api_v1_forward_only_test.exs`](../../test/store/governance/api_v1_forward_only_test.exs), [`07_security_model.md`](07_security_model.md) |
| SEC-006 | Security | Forged, stale, duplicate, and malformed webhook inputs are tested | Raw signature fixtures, timestamp tolerance, duplicate receipt/event, malformed JSON, out-of-order event, and replay tests | FAIL | Every invalid input is rejected or quarantined without state change; valid duplicates are one logical effect; stale events cannot regress state | Any forged/stale/malformed input reaches state application, duplicate worker claims occur, or invalid data is logged/exposed unsafely | Provider signing fixtures or worker environment is unavailable | CRITICAL | Yes | Webhooks and Payments | [`webhook_controller_test.exs`](../../test/store_web/controllers/webhook_controller_test.exs), [`payment_callback_controller_test.exs`](../../test/store_web/controllers/payment_callback_controller_test.exs), [`providers/stripe.ex`](../../lib/store/payments/providers/stripe.ex), [`payment_provider_contract.md`](../governance/payment_provider_contract.md) |
| SEC-007 | Security | Secrets, client secrets, provider credentials, and PII cannot leak through logs or serializers | Logger metadata review, secret scanning, serializer contract tests, raw-body retention review, and redacted failure fixtures | FAIL | Sensitive values are excluded from logs and generic serializers, raw evidence retention is bounded, and client secrets are only sent to the intended trusted boundary | A public resource field, `inspect`/error path, telemetry tag, or log contains a credential, client secret, raw secret, or excessive PII | Secret scanning or serializer runtime is unavailable | CRITICAL | Yes | Payments, Webhooks, Orders, Subscriptions, Comms | [`payment_intent.ex`](../../lib/store/payments/payment_intent.ex), [`providers/stripe.ex`](../../lib/store/payments/providers/stripe.ex), [`payment_provider_contract.md`](../governance/payment_provider_contract.md), [`audit_and_pii.md`](../governance/audit_and_pii.md) |
| SEC-008 | Security | Financially and privilege-sensitive actions have defined durable audit evidence | Audit policy map, append-only audit resource, action-to-event mapping, and negative audit tests | FAIL | Refunds, provider changes, entitlement changes, role changes, and other listed sensitive actions produce durable actor/action/time/result evidence | There is no audit record, audit is mutable, or the action-to-audit requirement is undefined | Audit storage or retention environment is unavailable | HIGH | Yes | Payments, Subscriptions, Entitlements, Admin | [`audit_and_pii.md`](../governance/audit_and_pii.md), [`policy_matrix.md`](../governance/policy_matrix.md), [`role_assignment.ex`](../../lib/store/admin/role_assignment.ex) |

## 12. Multi-Tenancy Gate

**CURRENT ARCHITECTURE: SINGLE TENANT.** The implementation has no `tenant_id`, tenant
routing, tenant-qualified cache namespace, PostgreSQL RLS policy, marketplace model,
or tenant-aware worker context. That is a current architecture fact, not a defect
against the single-tenant extraction target.

| Gate ID | Category | Requirement | Evidence required | Current Status | PASS condition | FAIL condition | BLOCKED condition | Severity | Blocks extraction | Applies to | Source/evidence links |
|---|---|---|---|---|---|---|---|---|---|---|---|
| TEN-001 | Tenancy | Single-tenant assumptions are explicit and not misrepresented | Architecture statement, schema/policy/cache/worker audit, and consumer contract | PASS | The extraction manifest states `single tenant`, makes no tenant-safety claim, and preserves the absence of tenant routing and keys | A consumer assumes tenant isolation exists or the extracted API implies multi-tenant safety without evidence | Repository tenancy audit cannot be completed | HIGH | No | Current Store Blueprint and single-tenant consumers | [`00_current_state.md`](00_current_state.md), [`07_security_model.md`](07_security_model.md), [`06_performance_data_map.md`](06_performance_data_map.md) |
| TEN-002 | Tenancy | A multi-tenant consumer has an approved tenancy architecture | Target requirements plus a decision covering tenant identity, uniqueness, FKs, Ash policies, worker context, provider identity, cache/Redis keys, PubSub, analytics, migrations, backup/restore, and rate limits | BLOCKED | A separate architecture decision is approved before a multi-tenant consumer is accepted | A multi-tenant target extracts this capability without that decision and evidence | The target tenancy requirement or architecture decision is not available | CRITICAL | Yes for multi-tenant target | Any multi-tenant consumer | [`00_current_state.md`](00_current_state.md), [`07_security_model.md`](07_security_model.md) |

No PostgreSQL tenancy strategy is prescribed here. A later architecture decision may
choose a shared-schema discriminator, PostgreSQL prefix/schema, or separate database
based on actual target requirements.

## 13. Performance and Scaling Gates

Performance has two separate decisions:

1. **Architectural readiness:** source-of-truth, data temperature, cache boundaries,
   invalidation, queue shape, and concurrency model are documented.
2. **Measured certification:** representative load, stress, soak, and failure evidence
   meets explicit thresholds.

Static architecture does not certify 100k concurrent users.

| Gate ID | Category | Requirement | Evidence required | Current Status | PASS condition | FAIL condition | BLOCKED condition | Severity | Blocks extraction | Applies to | Source/evidence links |
|---|---|---|---|---|---|---|---|---|---|---|---|
| PERF-001 | Performance | Architectural hot, warm, and cold classification preserves Postgres authority | Data temperature map, authority map, cache/queue inventory, and concurrency model | PASS | Hot paths, warm history, and cold evidence are classified; financial/lifecycle truth stays in Postgres | A derived cache, Redis value, ETS hint, or dashboard becomes commerce truth or temperature is not recorded | Required source or topology cannot be inspected | HIGH | Yes if violated | Catalog, Cart, Checkout, Payments, Inventory, Renewals, Entitlements | [`06_performance_data_map.md`](06_performance_data_map.md), [`performance_scaling.md`](../governance/performance_scaling.md), [`phase_29_performance_architecture_optimizations.md`](../phases/phase_29_performance_architecture_optimizations.md) |
| PERF-002 | Performance | Every extracted hot path has a complete performance card | For each path: HOT/WARM/COLD, source, current cache, TTL, invalidation, Redis structure, PubSub, indexes, query budget, concurrency model, stream/batch rule, and 100k expected behavior | FAIL | The card is complete and reviewed before extraction; unknown values are explicitly marked unknown | Query budget, invalidation, cache, queue, or concurrency behavior is omitted or inferred | Required cardinality, topology, or EXPLAIN data is unavailable | HIGH | Yes | Catalog, Cart, Checkout, Payment webhooks, Inventory, Renewals, Entitlements | [`06_performance_data_map.md`](06_performance_data_map.md), [`performance_scaling.md`](../governance/performance_scaling.md) |
| PERF-003 | Performance | Query shape, indexes, N+1 behavior, and analytics isolation meet a measured budget | EXPLAIN plans, cardinalities, query counts, N+1 checks, index evidence, and analytics workload separation | FAIL | No peak-path unbounded scan or accidental N+1 exists; indexes cover measured predicates; analytics uses bounded/materialized/read-replica/derived paths | Public search, admin filtering, grant cardinality, renewal fan-out, refund folds, or other paths exceed a reviewed budget or large analytics scans peak tables | Representative cardinality or database plan environment is unavailable | HIGH | Yes | All hot paths | [`06_performance_data_map.md`](06_performance_data_map.md), [`repo_stats.ex`](../../lib/store/support/telemetry/repo_stats.ex), [`performance_smoke_test.exs`](../../priv/repo/performance_smoke_test.exs), [`phase_29_performance_architecture_optimizations.md`](../phases/phase_29_performance_architecture_optimizations.md) |
| PERF-004 | Performance | Cache TTL, invalidation, stampede, and multi-node behavior are proven | Cache hit/miss, TTL, invalidation trigger, missed-message, stampede, outage, and multi-node tests | FAIL | Cache is derived, TTL is explicit, invalidation is tied to durable commit, stampede protection is adequate, and stale security behavior is accepted | Cache failure changes correctness, invalidation is local-only when distributed use is claimed, or hot misses create an unbounded herd | Multi-node/cache topology is unavailable | HIGH | Yes when cache is used | Catalog, Availability, Entitlements, Rate limits | [`product_list_cache.ex`](../../lib/store/catalog/product_list_cache.ex), [`entitlements/cache.ex`](../../lib/store/entitlements/cache.ex), [`06_performance_data_map.md`](06_performance_data_map.md) |
| PERF-005 | Performance | Oban fan-out, backpressure, rate limits, and retry amplification are bounded | Queue limits, unique options, batch sizes, lag thresholds, provider rate limits, retry tests, and backlog telemetry | FAIL | Fan-out is bounded, rate limiting/backpressure is explicit, retry amplification has a ceiling, and backlog alerts/actions are proven | Provider/webhook/renewal bursts can create unbounded jobs, queue lag, retries, or mailbox growth | Production-like queue/provider environment is unavailable | HIGH | Yes | Payment webhooks, Inventory expiry, Fulfillment, Digital, Renewals, Email | [`06_performance_data_map.md`](06_performance_data_map.md), [`config.exs`](../../config/config.exs), [`nightly-hardening.yml`](../../.github/workflows/nightly-hardening.yml) |
| PERF-006 | Performance | 100k-concurrency behavior is supported by measured load evidence | Mixed workload load report with p50/p95/p99, error rate, DB/Redis/Oban/BEAM/lock metrics, and thresholds | BLOCKED | The agreed workload meets its thresholds with retained reproducible reports and no correctness violation | A measured run misses thresholds or exposes a correctness/queue/cache failure | No production-like load result, environment, or accepted capacity report exists | HIGH | Yes for capacity claims | Any capability making a 100k claim | [`06_performance_data_map.md`](06_performance_data_map.md), [`performance_scaling.md`](../governance/performance_scaling.md) |

Required performance fields for each current hot path are recorded below. The values
are current architecture facts, not capacity results.

| Hot path | Temperature | Source of truth | Current cache and TTL | Invalidation / PubSub | Redis structure | Required index/query evidence | Stream/batch and concurrency rule | Expected behavior at 100k concurrency |
|---|---|---|---|---|---|---|---|---|
| Catalog browse/detail | HOT read projection; warm source rows | Postgres products, variants, options, images, inventory | Cachex product list 2 minutes; Redis warm catalog key about 1800 seconds; ETS availability 300 seconds; stock hint 5 seconds | Catalog mutation clears local and Redis product-list prefix and broadcasts; inventory/catalog changes clear local availability/stock hints | `cache:catalog:product_list:<key>` for product-list warm values | Publication/status/slug/variant indexes exist; `ILIKE` search and detail cardinality need EXPLAIN/query counts | Bounded page reads; public reads may use cache; inventory decision never uses hint as authority | Caches can absorb some public traffic; primary DB and popular inventory rows still limit checkout |
| Cart | HOT | Postgres carts and cart items | No general authoritative cache | Cart writes are durable; display cache, if later proposed, must not decide ownership/quantity | None for current cart truth | Cart/token/user/variant uniqueness and lock query require measured EXPLAIN | Cart-row serialization, CAS/version, bounded item merge | Rapid multi-tab/client writes contend on cart rows and pool |
| Checkout | HOT while active; warm/cold after | Postgres cart, draft, order, snapshots, reservations | No general authoritative checkout cache | Durable writes and reservation transaction; catalog/stock hints invalidate locally | None for current checkout truth | Cart/draft/order/reservation indexes and query/lock duration need measured budgets | One transaction locks cart/items/order and reserves inventory; no unbounded line fan-out | Primary DB, pool, cart/order rows, and hot variants are bottlenecks |
| Payment webhook | HOT in-flight; warm/cold after settlement | Provider remote result plus local Postgres receipt/event/attempt/application/state | No payment-state cache | Durable transaction plus post-commit queue handoff; current enqueue failure is logged | None for payment truth | Provider/event/receipt/attempt/application indexes; branch-dependent query counts need measurement | One receipt job per ingress; bounded queue/retry and provider rate limit required | Webhook bursts saturate queue, DB pool, locks, and downstream fan-out before catalog cache |
| Inventory | HOT | Postgres inventory counters/reservations under row locks | ETS stock/availability hints only; 5 seconds and 300 seconds as above | Local hint invalidation after reserve/consume/release/expiry; no distributed authority | None for inventory truth | Inventory variant and active reservation state/expiry indexes; lock waits and deadlocks must be measured | Ordered row locks; checkout CTE all-or-nothing; expiry batch 500 | Popular variant row lock sets throughput; correctness depends on every writer using approved boundary |
| Subscription renewal | HOT due/past_due; warm history | Postgres subscription/attempt/order/payment/reservation plus provider result | No general subscription-state cache; plan/config reads are only candidates | Period/entitlement/reservation updates invalidate relevant derived values | None for subscription truth | Partial due/retry indexes, renewal identity, and per-renewal query counts/lock durations | Due read max 100 default/500 max; Oban fan-out with jitter; provider and DB backpressure required | Shared billing anchors create queue/provider/DB/inventory bursts |
| Entitlement access | HOT read; grants warm-to-hot | Postgres entitlement grants | Per-user Cachex `user:<id>`, 60 seconds, lazy sweep 30 seconds | Local delete plus PubSub topic `store:entitlements:<user_id>` after issue/revoke; missed message leaves TTL window | No Redis entitlement cache | User/status/validity/source indexes and per-user grant cardinality need measurement | Per-user keyed fetch; no browser cache; multi-node subscription must be proven | Warm hits reduce DB load; cold users, many grants, and invalidation waves hit primary DB |

## 14. Test Gates

For every extraction capability, the required mapping is:

`Invariant -> Test -> CI tier -> retained evidence -> failure owner`

No invariant may be marked protected because a similarly named feature test exists.

| Gate ID | Category | Requirement | Evidence required | Current Status | PASS condition | FAIL condition | BLOCKED condition | Severity | Blocks extraction | Applies to | Source/evidence links |
|---|---|---|---|---|---|---|---|---|---|---|---|
| TEST-001 | Testing | Unit coverage protects extracted rules | Named unit tests for pricing, state guards, ownership, identity, and pure scheduling rules | PASS | Each extracted rule has direct deterministic unit coverage and failures identify the owner | A rule relies only on an incidental integration test or has no direct assertion | Required test dependencies cannot be installed | MEDIUM | Yes if absent | All capabilities | [`test`](../../test), [`05_test_strategy.md`](05_test_strategy.md) |
| TEST-002 | Testing | Property coverage protects general invariants and time calculations | StreamData properties for money, period advancement, idempotency keys, allocation, and state predicates | FAIL | General invariants hold across the declared generated domain and shrink to useful failures | Only three current scheduler properties exist or generated domains omit a financial/concurrency invariant | Property runner or required generator is unavailable | HIGH | Yes | Pricing, Subscriptions, Payments, Inventory | [`scheduler_property_test.exs`](../../test/store/subscriptions/scheduler_property_test.exs), [`05_test_strategy.md`](05_test_strategy.md) |
| TEST-003 | Testing | Every invariant maps to a test and CI tier | Maintained invariant-to-test-to-CI matrix with pass artifacts | FAIL | Every invariant in the registry has at least one targeted test and a required CI tier | An invariant is listed as protected without a test, or a test is not required by CI | Matrix source or CI artifact is unavailable | CRITICAL | Yes | All capabilities | [`03_invariant_registry.md`](03_invariant_registry.md), [`05_test_strategy.md`](05_test_strategy.md), [`ci.yml`](../../.github/workflows/ci.yml) |
| TEST-004 | Testing | Integration and provider contract tests cover the extraction slice | Domain integration tests, Stripe contract tests, per-provider negative/positive suites, and API contract tests | FAIL | Every cross-domain seam and supported provider operation has an independent contract test | Stubbed or capability-declaration tests are used as proof of an unimplemented provider or missing seam | Required DB/provider/API environment is unavailable | HIGH | Yes | Checkout, Payments, Stripe, Subscriptions | [`checkout_interlocks_test.exs`](../../test/store/governance/checkout_interlocks_test.exs), [`stripe_subscriptions_test.exs`](../../test/store/payments/providers/stripe_subscriptions_test.exs), [`open_api_contract_test.exs`](../../test/store/governance/open_api_contract_test.exs) |
| TEST-005 | Testing | Lifecycle, replay, concurrency, and security suites cover failure paths | Duplicate, delayed, conflicting, out-of-order, unauthorized, crash/retry, and terminal-state tests | FAIL | Required matrices pass repeatedly and assert durable final state and side effects | Current tests cover selected examples but not the complete lifecycle/race/security matrix | Required worker/provider/multi-node environment is unavailable | CRITICAL | Yes | All blocking capabilities | [`05_test_strategy.md`](05_test_strategy.md), [`test/store/governance`](../../test/store/governance), [`test/store/workers`](../../test/store/workers) |
| TEST-006 | Testing | PR performance smoke detects gross regressions deterministically | Small deterministic smoke suite with thresholds and CI artifacts | PASS | PR smoke is reproducible, bounded, thresholded, and fails on gross query/lock/pool regressions | Smoke is absent, non-deterministic, or only reports without failing thresholds | Required local DB/Redis environment is unavailable | MEDIUM | Yes if absent | Hot paths | [`performance_smoke_test.exs`](../../priv/repo/performance_smoke_test.exs), [`ci.yml`](../../.github/workflows/ci.yml) |
| TEST-007 | Testing | Nightly representative stress produces thresholded evidence | Cart burst, checkout concurrency, webhook storm, renewal fan-out, entitlement pressure, hot inventory workload, and retained metrics | BLOCKED | Nightly workload passes explicit thresholds with p50/p95/p99, error, pool, lock, Redis, Oban, scheduler, BEAM, and mailbox metrics | A nightly run exceeds a threshold or violates a correctness invariant | No retained representative report or required load environment exists | HIGH | Yes | All hot paths | [`nightly-hardening.yml`](../../.github/workflows/nightly-hardening.yml), [`05_test_strategy.md`](05_test_strategy.md) |
| TEST-008 | Testing | Scheduled soak produces thresholded sustained-run evidence | Soak duration, workload, periodic checkpoints, leak/backlog/cache/retry/cardinality checks, and retained report | BLOCKED | Initial hardening soak runs at least 2–4 hours; production-grade release profile runs 6–12 hours and remains within thresholds | Memory, ETS, mailbox, connection, queue, stale-cache, retry, or telemetry cardinality growth exceeds threshold | No soak runner, environment, or retained report exists | HIGH | Yes | All capabilities making sustained-operation claims | [`05_test_strategy.md`](05_test_strategy.md), [`performance_scaling.md`](../governance/performance_scaling.md) |
| TEST-009 | Testing | Failure injection and chaos cover dependency and worker failures | Provider timeout, Redis failure, DB contention, Oban outage, notification failure, worker crash, stale event, and recovery tests | FAIL | Each injected failure has a documented safe state, bounded retry, and observable recovery | Existing chaos smoke does not cover the required failure boundary or hides a failed command | Required dependency fault harness is unavailable | HIGH | Yes | Payments, Renewals, Inventory, Entitlements, Outbox | [`ci.yml`](../../.github/workflows/ci.yml), [`05_test_strategy.md`](05_test_strategy.md), [`06_performance_data_map.md`](06_performance_data_map.md) |

## 15. Stress and Soak Certification Gates

The three required certification levels are separate from ordinary feature tests.

### PR Performance Smoke

This is small and deterministic. It detects gross regressions in query count, lock
duration, pool occupancy, p99 smoke latency, and selected cache/queue behavior. It is
not a capacity claim.

### Nightly Stress

The representative workload must include:

- cart burst and merge pressure;
- concurrent checkout on a hot variant;
- webhook storm with duplicate and out-of-order events;
- renewal fan-out and retry wave;
- entitlement read and invalidation pressure;
- DB/Redis/Oban/provider fault profiles.

The report must include p50, p95, p99, error rate, DB pool saturation, lock waits and
deadlocks, Redis latency/failures, Oban queue depth/lag, scheduler utilization, BEAM
memory, and mailbox growth.

### Scheduled Soak

The initial hardening requirement is at least 2–4 hours before an initial extraction
certification. A later production-grade release profile is 6–12 hours. Neither
profile is recorded as passed here.

The soak must detect memory leaks, ETS growth, mailbox growth, connection leaks, queue
backlog, stale Redis/cache records, retry amplification, and telemetry cardinality
explosion. A workflow command or a `tee` log without a thresholded retained result is
not certification evidence.

## 16. CI Gates

The required CI path must fail when any required command fails. The extraction gate
does not accept an advisory job as required evidence.

| Gate ID | Category | Requirement | Evidence required | Current Status | PASS condition | FAIL condition | BLOCKED condition | Severity | Blocks extraction | Applies to | Source/evidence links |
|---|---|---|---|---|---|---|---|---|---|---|---|
| CI-001 | CI | Format and warnings-as-errors compilation pass | Fresh `mix format --check-formatted` and `mix compile --warnings-as-errors` results | PASS | Both commands exit zero for the extraction revision | Either command fails or generated source drift is present | Mix/dependency environment cannot be started | HIGH | Yes | All capabilities | [`mix.exs`](../../mix.exs) |
| CI-002 | CI | Static, governance, and documentation gates pass | Fresh `mix check` result plus workflow required-job configuration | PASS | Static scans, Credo strict, docs, governance, tests, and docs generation exit zero | Any required static/governance/docs/test command fails | Required dependency/database service is unavailable | HIGH | Yes | All capabilities | [`mix.exs`](../../mix.exs), [`ci.yml`](../../.github/workflows/ci.yml), [`enforcement_gates.md`](../governance/enforcement_gates.md) |
| CI-003 | CI | Migration alignment is checked in the required CI path | `ash_postgres.generate_migrations --check`, generated-drift check, and fresh DB migration result | BLOCKED | Migration alignment and generated drift checks pass in the extraction revision | Resource/migration drift is detected or generated files change | This local session did not run the DB migration-alignment command | HIGH | Yes | Resource-backed capabilities | [`ci.yml`](../../.github/workflows/ci.yml), [`priv/repo/migrations`](../../priv/repo/migrations) |
| CI-004 | CI | Lifecycle, invariant, replay, security, and performance suites are required CI gates | Named CI jobs/commands and retained pass artifacts for each category | FAIL | Each required category runs and fails the required job on failure | A category exists only as an unrequired test file, a partial smoke, or a documentation claim | CI configuration or artifact retention cannot be inspected | CRITICAL | Yes | All capabilities | [`ci.yml`](../../.github/workflows/ci.yml), [`nightly-hardening.yml`](../../.github/workflows/nightly-hardening.yml), [`05_test_strategy.md`](05_test_strategy.md) |
| CI-005 | CI | The Dialyzer job fails on new unignored findings | Direct Dialyzer command without ignored exit status and baseline policy | FAIL | A new unignored Dialyzer issue makes the required job fail | Required path still invokes `--ignore-exit-status` or treats findings as advisory | Dialyzer cannot run in the required environment | HIGH | Yes | All extracted Elixir modules | [`mix.exs`](../../mix.exs), [`ci.yml`](../../.github/workflows/ci.yml), [`phase_00_docs.md`](../agent_notes/phase_00_docs.md) |
| CI-006 | CI | Required CI pipelines fail on failed commands and do not mask results | Shell options, pipe status, job dependency, and failure-artifact review | FAIL | Every test/stress/perf pipeline propagates command exit status, including piped logs | A `tee` pipeline can return success after the test command fails, or a required job masks a failure | Runner shell behavior or workflow execution is unavailable | HIGH | Yes | CI and nightly certification | [`nightly-hardening.yml`](../../.github/workflows/nightly-hardening.yml), [`ci.yml`](../../.github/workflows/ci.yml) |

Current local evidence for CI is recorded in Section 23. The source still proves that
`mix check.types` expands to `dialyzer --format short --ignore-exit-status`. The
observed run emitted 178 Dialyzer findings and exited zero, so the type-safety gate is
not a PASS even though the command completed.

## 17. Dependency and Supply-Chain Gates

No dependency is updated by S0-08. These gates describe release evidence only.

| Gate ID | Category | Requirement | Evidence required | Current Status | PASS condition | FAIL condition | BLOCKED condition | Severity | Blocks extraction | Applies to | Source/evidence links |
|---|---|---|---|---|---|---|---|---|---|---|---|
| DEP-001 | Supply chain | Dependency audit has no unresolved applicable critical/high advisory | Fresh `mix deps.audit`, lockfile review, and release advisory record | PASS | The extraction lockfile has no unresolved applicable critical/high advisory and the audit exits zero | An applicable critical/high advisory remains unresolved or the audit fails | Advisory database/network is unavailable | HIGH | Yes if violated | All capabilities | [`mix.exs`](../../mix.exs), [`mix.lock`](../../mix.lock) |
| DEP-002 | Supply chain | Lockfile and dependency resolution are reproducible | Clean resolution in a pinned toolchain, lockfile verification, and repeat install artifact | BLOCKED | Two clean resolutions use the committed lockfile and produce the same dependency graph/artifact hashes | Resolution is not locked/reproducible or a dependency is silently upgraded | Clean network/toolchain/artifact environment or retained repeat-install evidence is unavailable | HIGH | Yes | All capabilities | [`mix.lock`](../../mix.lock), [`.tool-versions`](../../.tool-versions), [`ci.yml`](../../.github/workflows/ci.yml) |
| DEP-003 | Supply chain | Dependency and provider API changes have compatibility evidence | Upgrade compatibility tests, provider API contract fixtures, and release review | FAIL | Every dependency/provider contract change has passing compatibility evidence for the extracted slice | An upgrade or provider API change is accepted without compatibility evidence | Required upstream contract environment is unavailable | HIGH | Yes | Payments, adapters, Ash domains, workers | [`mix.exs`](../../mix.exs), [`payment_provider_contract.md`](../governance/payment_provider_contract.md), [`providers_resolver_test.exs`](../../test/store/payments/providers/providers_resolver_test.exs) |

## 18. Extraction Architecture Gates

Before moving files, renaming modules, or copying a resource, the extraction record
must classify every source component as exactly one of:

- `KEEP`: behavior and dependencies are accepted unchanged for the target;
- `RENAME`: only identity changes, with behavior and contracts preserved;
- `REWRITE`: behavior or boundary must be deliberately reimplemented;
- `REJECT`: the component must not cross the extraction boundary.

| Gate ID | Category | Requirement | Evidence required | Current Status | PASS condition | FAIL condition | BLOCKED condition | Severity | Blocks extraction | Applies to | Source/evidence links |
|---|---|---|---|---|---|---|---|---|---|---|---|
| EXT-001 | Extraction | Every source component has a KEEP/RENAME/REWRITE/REJECT manifest | Component list with classification, source assumptions, target assumptions, dependencies, edits, forbidden inherited behavior, lifecycle obligations, invariants, security, performance, tests, and supported slice | FAIL | Every copied or referenced module has a reviewed classification and manifest entry | Any module is copied because it appears reusable, without documenting assumptions or forbidden inherited behavior | Target requirements or source dependency graph is unavailable | CRITICAL | Yes | All extraction components | [`04_dependency_map.md`](04_dependency_map.md), [`00_current_state.md`](00_current_state.md) |
| EXT-002 | Extraction | Each extracted capability has a bounded slice, API owner, and consumer validation | Capability contract, public facade/input/output structs, resource list, dependency closure, consumer fixture, and target acceptance report | FAIL | The slice has one public owner, explicit inputs/outputs, no accidental web/API exposure, and a validated consumer | A capability includes a hidden dependency, oversized orchestration hub, undocumented side effect, or unvalidated consumer assumption | Target consumer or dependency environment is unavailable | CRITICAL | Yes | Catalog subset, Cart, Checkout, Orders, Payments, Stripe, Inventory, Subscriptions, Entitlements | [`04_dependency_map.md`](04_dependency_map.md), [`05_test_strategy.md`](05_test_strategy.md) |
| EXT-003 | Extraction | Checkout, payment, and subscription facade coupling is frozen and documented | Public API ownership, cross-domain side-effect map, transaction boundaries, lock order, idempotency identities, and compatibility wrapper decision | FAIL | The coupling contract is frozen before movement; any split has a compatibility wrapper and a complete side-effect handoff | `Store.Checkout`, `Store.Payments.Interlocks`, or `Store.Subscriptions.Facade` is split or copied without freezing these contracts | A complete call graph or target wrapper decision is unavailable | CRITICAL | Yes | Checkout, Payments, Subscriptions | [`checkout/domain.ex`](../../lib/store/checkout/domain.ex), [`payments/interlocks.ex`](../../lib/store/payments/interlocks.ex), [`subscriptions/facade.ex`](../../lib/store/subscriptions/facade.ex), [`04_dependency_map.md`](04_dependency_map.md) |

No module is classified as extraction-ready by S0-08. The classification is a
required artifact for a later phase, not an instruction to move code now.

## 19. Facade and Coupling Gates

The current orchestration hubs are evidence of coupling, not approved boundaries:

| Component | Observed responsibility | Extraction decision required |
|---|---|---|
| `Store.Checkout` / `Store.Checkout.Domain` | Cart and catalog reads, plan resolution, pricing, shipping/tax, order/draft reuse, snapshot writes, inventory reservation, and checkout locks | Freeze transaction, ownership, lock, and idempotency contracts before any split |
| `Store.Payments.Interlocks` / Payments facade | Receipt verification, provider/event/attempt evidence, payment intent and Order transitions, reservation consumption, and post-commit fan-out | Separate financial application from downstream effects only with a durable handoff contract |
| `Store.Subscriptions.Facade` | Paid-order creation, subscription record, stored method, renewal attempt, pricing/shipping/tax, provider charge, dunning, entitlements, communications, and Oban | Define the subscription owner and compatibility wrapper before decomposition |

The observed source sizes are approximately 2,020 lines for Checkout.Domain, 1,031
lines for Payments.Interlocks, and 3,341 lines for Subscriptions.Facade. Size alone
is not a failure, but the cross-domain call graph and direct `Repo`/Ash/Oban use make
the ownership and side-effect contracts mandatory extraction evidence.

## 20. Provider Readiness Matrix

The matrix uses actual provider modules and tests. A capability declaration is not
evidence that an operation works.

| Provider | Intent/Create | Webhook Verify | Normalize | Recurring Charge | Refund | Contract Tests | Readiness |
|---|---|---|---|---|---|---|---|
| Stripe | Implemented | Implemented | Implemented | Implemented | Not implemented in provider behavior | Partial: Req.Test covers implemented intent/setup/off-session and webhook fixtures; no refund certification | PARTIAL |
| PayFast | Scaffold/error | Scaffold/error | Scaffold/error | Not implemented | Not implemented | Negative/error-path tests only | SCAFFOLD ONLY |
| Paystack | Scaffold/error | Scaffold/error | Scaffold/error | Not implemented | Not implemented | Negative/error-path tests only | SCAFFOLD ONLY |
| Yoco | Scaffold/error | Scaffold/error | Scaffold/error | Not implemented | Not implemented | Negative/error-path tests only | SCAFFOLD ONLY |
| Peach Payments | Scaffold/error | Scaffold/error | Scaffold/error | Not implemented | Not implemented | Negative/error-path tests only | SCAFFOLD ONLY |

Stripe is the only implemented provider boundary. The provider behavior has no
refund callback, and refund completion is expected from inbound evidence. That makes
Stripe a `PARTIAL` candidate for future certification, not a production-ready
provider extraction. Non-Stripe adapters must be independently certified before use.

## 21. Capability Extraction Readiness Matrix

The component statuses use the gate model. `Overall` uses the requested capability
model: `READY`, `PARTIAL`, or `NOT READY`. A capability cannot be `READY` while an
applicable blocking gate is `FAIL` or `BLOCKED`.

| Capability | Governance | Lifecycle | Invariants | Tests | Security | Performance | Coupling | Overall |
|---|---|---|---|---|---|---|---|---|
| Catalog subset | FAIL | FAIL | FAIL | PASS | FAIL | PASS | FAIL | NOT READY |
| Cart | FAIL | FAIL | FAIL | PASS | FAIL | FAIL | FAIL | NOT READY |
| Checkout | FAIL | FAIL | FAIL | PASS | FAIL | FAIL | FAIL | NOT READY |
| Orders | FAIL | FAIL | FAIL | PASS | FAIL | FAIL | FAIL | NOT READY |
| Payments core | FAIL | FAIL | FAIL | FAIL | FAIL | FAIL | FAIL | NOT READY |
| Stripe adapter | PASS | FAIL | FAIL | FAIL | FAIL | FAIL | FAIL | PARTIAL |
| InventoryReservation | FAIL | FAIL | FAIL | FAIL | FAIL | FAIL | FAIL | NOT READY |
| Subscriptions | FAIL | FAIL | FAIL | FAIL | FAIL | FAIL | FAIL | NOT READY |
| Entitlements | FAIL | FAIL | FAIL | FAIL | FAIL | FAIL | FAIL | NOT READY |

`Stripe adapter` is `PARTIAL` only because its provider-specific boundary has working
intent, recurring-charge, verification, and normalization code. It is not
extraction-ready: the capability still depends on failed payment evidence, security,
coupling, refund, and measured certification gates.

## 22. S0 Closure Decision

1. **Is the repository ready for immediate extraction?** No. No commerce capability
   has an overall `READY` status. Immediate extraction is prohibited by failed
   authority, lifecycle, financial, concurrency, replay, subscription, security,
   coupling, and/or measured-certification gates.

2. **What categories block it?** The blocking categories are governance/code parity,
   state-transition authority, historical financial evidence, payment/webhook replay,
   subscription race outcomes, inventory concurrency certification, entitlement
   synchronization and cache behavior, guest/system/step-up/API security boundaries,
   facade coupling, provider certification, CI type-safety semantics, and stress/soak/
   capacity evidence.

3. **Is the repository strong enough to begin hardening rather than rebuilding from
   scratch?** Yes. The source has explicit domain facades, UUIDv7 identities, integer
   money, immutable line/adjustment evidence, selected state machines, unique
   idempotency anchors, Postgres row-lock reservation logic, a Stripe adapter, Oban
   workers, policy tests, cache boundaries, telemetry, and a passing ordinary `mix
   check` run in this checkout. These strengths are foundations, not extraction
   approval.

4. **What should the first implementation-hardening phase address?** First establish
   one authoritative lifecycle/invariant contract and make the required CI truth
   visible, then harden the financial/payment replay boundary. This means closing
   documentation/code drift, identifying every state writer, deciding the durable
   post-commit handoff, and proving the payment, refund, reservation, and renewal
   invariants with repeatable tests. It does not authorize implementation changes in
   S0-08 and is not a full implementation plan.

The S0 decision is therefore:

```text
S0 discovery:                 PASS
Immediate extraction:        NO
Controlled hardening:         YES
Multi-tenant extraction:      BLOCKED pending a separate architecture decision
```

The empty [`01_domain_map.md`](01_domain_map.md) did not create a material authority
contradiction because the implementation and the remaining S0 maps provide the
source-backed domain evidence. It is not rewritten by S0-08.

## 23. Ordered Hardening Gate Backlog

This is a short ordered list of gate groups, not an implementation task list.

### P0

- Governance and lifecycle/code parity: `GOV-001`, `GOV-002`, `LIFE-001` through
  `LIFE-008`.
- CI truth and type-safety semantics: `CI-001` through `CI-006`, especially
  `CI-005` and `CI-006`.
- Financial correctness and payment evidence: `DATA-002` through `DATA-005`,
  `PAY-003` through `PAY-007`.

### P1

- Lifecycle-authority and concurrency closure: `CONC-001` through `CONC-006`.
- Security boundaries: `SEC-002` through `SEC-008`.
- Subscription race matrix and durable entitlement synchronization: `SUB-003`
  through `SUB-009`, `ENT-002` through `ENT-006`.

### P2

- Facade ownership and coupling contracts: `GOV-003`, `EXT-002`, `EXT-003`.
- Performance architecture measurement and load certification: `PERF-002` through
  `PERF-006`, `TEST-006` through `TEST-009`.

### P3

- Extraction manifests and target-consumer validation: `EXT-001`, `EXT-002`,
  `DEP-002`, `DEP-003`, plus provider-specific `PAY-008` and `PAY-009`.

## 24. Cross-Gate Performance and Scaling Review

The performance record for every hot-path gate must include all of the following:

- `HOT`, `WARM`, or `COLD` classification;
- required index and query-plan evidence;
- current cache rule and TTL, if any;
- Redis structure, if any;
- invalidation trigger and PubSub rule;
- Postgres authority;
- stream/batch requirement;
- concurrency and backpressure model;
- expected behavior at 100k concurrency without calling it certification.

The current values are recorded in Section 13 and [`06_performance_data_map.md`](06_performance_data_map.md).
The current gaps are measured query budgets, EXPLAIN/cardinality evidence, complete
N+1 checks, cache-stampede and multi-node tests, bounded queue/backpressure evidence,
and measured 100k mixed-load behavior. No static source review is used as a substitute
for those results.

## 25. Cross-Gate Security Review

| Gate family | Trust boundary | Authorization owner | Actor/system requirement | Replay risk | Data exposure risk | Audit requirement |
|---|---|---|---|---|---|---|
| Checkout and Cart | Browser/session, guest token, authenticated user | `Store.Carts` / `Store.Checkout` policies and facades | User actor or explicitly scoped guest capability; no system context from params | Duplicate cart writes, guest merge, checkout reuse | Bearer token exposes cart capability; owner fields are nullable in parts of the graph | Record sensitive ownership/merge decisions where policy requires |
| Payment ingress | Provider signature to controller, receipt worker, Payments interlock | `Store.Payments` provider boundary and worker system context | Verified raw body, canonical receipt, trusted worker actor | Duplicate/stale/forged event and worker retry | Raw body, headers, provider refs, client secret, PII | Durable receipt/event/attempt and financial application evidence |
| Refunds and provider configuration | Admin/support actor plus recent step-up | Payments refund facade and policy matrix | Admin/super_admin plus trusted step-up producer; no test-only context | Duplicate request and provider callback | Amounts, provider refs, payment details, secrets | Append-only actor/action/result audit |
| Subscription renewal | Oban scheduler/worker, provider, user cancellation/update | `Store.Subscriptions` facade with Payments/Entitlements contracts | Explicit system worker context and stable renewal key | Renewal/cancel/change/retry/webhook/late-success races | Billing history, stored method refs, entitlement scope | Durable attempt, charge, subscription, and entitlement evidence |
| Entitlement and Digital | Authenticated user, grant row, cache, storage signer | `Store.Entitlements` / `Store.Digital` facades | User actor for read; trusted worker for issue/revoke; DownloadGrant for URL | Replay URL, stale cache, duplicate grant, counter race | Access scopes, signed URL, digital asset location | Grant and revocation evidence; signed URL issuance telemetry without secrets |
| Public API serialization | API client to Ash JSON API serializer | Explicit per-action API allowlist | Public actor only receives approved fields | Replayed API mutation or leaked durable id | `public?` attributes can include sensitive fields | Audit sensitive API mutations and denied access |

These security fields are required in each capability extraction manifest. The current
security findings keep the affected gates failed even where a narrower policy test
passes.

## 26. Critical Finding Coverage Map

| S0 finding | Gate coverage |
|---|---|
| Lifecycle governance/code drift | `GOV-001`, `LIFE-001` through `LIFE-004`, `CI-004` |
| InventoryReservation writable outside declared transition authority | `GOV-002`, `LIFE-005`, `CONC-002`, `CONC-004` |
| Incomplete payment evidence lifecycle authority | `LIFE-006`, `PAY-007`, `CONC-006` |
| Payment success is a broad orchestration point | `DATA-003`, `PAY-006`, `EXT-003`, `SUB-009` |
| Subscription facade coupling | `GOV-003`, `SUB-003` through `SUB-009`, `EXT-003` |
| Checkout orchestration coupling | `GOV-003`, `PERF-003`, `EXT-002`, `EXT-003` |
| Subscription to Entitlement direct coupling | `SUB-009`, `ENT-002`, `ENT-005`, `EXT-003` |
| Financial and webhook replay/idempotency | `DATA-003`, `PAY-003` through `PAY-007`, `CONC-006` |
| Subscription renewal races | `CONC-005`, `SUB-003` through `SUB-008` |
| Inventory reservation concurrency | `CONC-001` through `CONC-004` |
| Guest-cart bearer capability | `SEC-001`, `SEC-002` |
| Step-up consumer without proven producer | `SEC-004` |
| Trusted worker/system context and `authorize?: false` | `SEC-003` |
| Public resource attributes and API exposure | `SEC-005`, `SEC-007` |
| Entitlement cache and signed URL staleness | `ENT-005`, `ENT-006`, `PERF-004` |
| Single-tenant architecture | `TEN-001`, `TEN-002` |
| Provider maturity | `PAY-008`, `PAY-009`, Section 20 |
| CI, tests, performance, stress, and soak limitations | `TEST-001` through `TEST-009`, `CI-001` through `CI-006`, `PERF-001` through `PERF-006` |
| Dependency and security audit requirements | `DEP-001` through `DEP-003`, `SEC-006`, `SEC-007` |
| Dialyzer ignored exit status | `CI-005`, `CI-006` |

## 27. Validation Record

The following checks were run during S0-08. They do not change the application or
test behavior.

| Command | Result | Interpretation |
|---|---|---|
| `mix format --check-formatted` | PASS | No format drift in the checkout before this documentation change |
| `mix compile --warnings-as-errors` | PASS | 369 files compiled and the Store application was generated |
| `mix deps.audit` | PASS | Current advisory database reported no vulnerabilities; the earlier S0-01 historical audit failure remains historical evidence and was not rewritten |
| `mix check` | PASS | 453 tests, 3 properties, 0 failures; static checks, Credo strict, and docs generation completed |
| `mix check.types` | FAIL as an extraction gate | Command exited zero only because the alias uses `--ignore-exit-status`; Dialyzer emitted 178 findings, including `Store.Subscriptions.Facade`, payment, inventory, cache, and performance findings |
| `git diff --check` | PASS | No whitespace errors after the extraction-gates document was written |
| Performance smoke / nightly stress / scheduled soak | BLOCKED | Not run as part of this documentation synthesis; no measured stress/soak or 100k result is claimed |

The current ordinary `mix check` pass is therefore recorded as test evidence, not as
extraction approval. The Dialyzer command result is recorded as a gate failure because
the required CI semantics allow findings without failing the job.
