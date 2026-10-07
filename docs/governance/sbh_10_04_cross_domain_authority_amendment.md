# SBH-10-04 cross-domain authority amendment

Status: governance amendment for later, separately admitted implementation.

This record assigns bounded authority to the owning surfaces needed by SBH-10-04. It changes no runtime code, tests, migrations, Ash snapshots, dunning policy, or JC-223 dependency edge. It does not admit SBH-10-04 for implementation or assign a `task_base_sha`.

## Authority pins

- Canonical governance base: `main = 1fb29528e63a255cf86f1810d99b2372a55923cc`.
- Accepted SUBS evidence tip: `hardening/subscriptions = c66fb843beeb25e4943ceb6119b1ed7de3999964`.
- The evidence at `c66...` records SBH-10-04 as `BLOCKED_SHARED_AUTHORITY`, SBH-10-05 as dependency-blocked, one immutable RenewalAttempt and one renewal Order, and the need for a later cross-domain decision. See `c66...:docs/hardening/subscriptions/SUBSCRIPTION_HARDENING_MASTER_REGISTER.md`, especially §§23.3, 24, and 47, and `c66...:docs/governance/payment_provider_contract.md`, §4.

The accepted checkpoint-B contract remains attached to one RenewalAttempt occurrence. It binds `subscription_id`, the Subscription aggregate version/evidence boundary, `plan_revision_id`, `variant_id`, `quantity`, `amount_minor`, `currency`, `period_start_at`, `period_end_at`, nullable `contract_change_id`, and the immutable commercial/access-policy snapshot or equivalent canonical serialized/versioned evidence. Collection attempts do not create another RenewalAttempt or Order.

The frozen JC-223 edges remain exactly as recorded at `c66...:docs/hardening/subscriptions/SUBSCRIPTION_HARDENING_MASTER_REGISTER.md`, §23.3. In particular:

| Row | Existing dependency |
|---|---|
| `SBH-10-03` | `SBH-10-02` + `SBH-20-01` + `SBH-10-06` |
| `SBH-10-04` | `SBH-10-03` |
| `SBH-10-05` | `SBH-10-03` + `SBH-10-04` |

No dependency row changes in this amendment. Queue order and the authority decisions below do not add or remove JC-223 edges.

## Existing-source proof

### Payments can retain terminal intent history and create a later intent

At the canonical base, `Store.Payments.Interlocks` accepts an explicit `payment_intent_key` for its create-or-reuse operation. Its preflight query selects an intent with that key, or a same-Order intent in `succeeded`, `submitted`, or `requires_action`. A different key therefore reaches the existing create-or-reuse resource action when the prior same-Order intent is `failed` or `cancelled`. The global unique key prevents key reuse, while the partial unique Order index covers `submitted` and `requires_action` rows. The key is not unique by Order for all historical intents. See [`interlocks.ex`](../../lib/store/payments/interlocks.ex), [`payment_intent.ex`](../../lib/store/payments/payment_intent.ex), [the Phase 14 interlock migration](../../priv/repo/migrations/20260225190004_phase_14_checkout_interlocks.exs), and [the Phase 14 index correction](../../priv/repo/migrations/20260225191111_phase_14_interlock_upsert_index_fix.exs).

Existing tests prove same-key replay, rejection while a prior intent is submitted, and rejection after a prior intent succeeds: [`checkout_interlocks_test.exs`](../../test/store/governance/checkout_interlocks_test.exs). A focused two-case probe against the pinned runtime source also created a second explicit key for the same Order after a failed intent and after a cancelled intent; both cases passed. The probe was temporary and left no test file in the PR. The later SBH-10-04 implementation must retain this as a regression test. The generic `create_intent_for_order` path continues to derive the existing Order-based checkout key. A typed renewal entry through `Store.Payments` is part of the bounded future authority below.

### PaymentApplication stores the exact Order and PaymentIntent

`Store.Orders.PaymentApplication` requires both `order_id` and `payment_intent_id`, and its apply-once identity is the Order-level `application_key`. The payment interlock supplies the exact successful `payment_intent.id` when it inserts the application row. A focused probe against the pinned runtime source read back the inserted `payment_intent_id` and matched it to the successful intent. See [`payment_application.ex`](../../lib/store/orders/payment_application.ex) and [`interlocks.ex`](../../lib/store/payments/interlocks.ex). This is sufficient for one paid application per renewal Order while retaining the exact PaymentIntent evidence. No PaymentApplication migration is authorized.

The later renewal path must validate the PaymentIntent-to-collection-to-RenewalAttempt relationship before renewal-specific application or inventory behavior. The order-level application key can remain unchanged.

### Reservation history and InventoryAdmission identity

The current Orders schema has a global unique `reservation_key` and a unique `(order_id, variant_id)` identity. The generic key is `order:<order_id>:sku:<variant_id>`. The generic reservation path adjusts an active row and returns `RESERVATION_CONFLICT` for terminal rows; it does not reactivate them. See [`inventory_reservation.ex`](../../lib/store/orders/inventory_reservation.ex), [`inventory_reservations.ex`](../../lib/store/orders/inventory_reservations.ex), and [the Phase 11 migration](../../priv/repo/migrations/20260224201500_phase_11_inventory_reservations.exs).

InventoryAdmission's current typed Request derives only the generic four-part key, hashes it into logical identity, and rejects caller-supplied keys. Its parser rejects the renewal-generation key form. Operation descriptors carry the derived generic key; the current Lease value carries only its identity digest. S0-ARCH-01 requires PostgreSQL reconciliation by the exact `reservation_key`, while Redis remains a bounded coordination and fencing layer. The architecture can be extended around that existing identity seam, but the current request, operation, and Lease code does not yet carry renewal-generation keys. See [`request.ex`](../../lib/store/orders/inventory_admission/request.ex), [`operation.ex`](../../lib/store/orders/inventory_admission/operation.ex), [S0-ARCH-01](../hardening/s0_inventory_reservation_admission_architecture.md), and [the S0 implementation plan](../hardening/s0_inventory_reservation_admission_implementation_plan.md).

At this base, the full InventoryAdmission PostgreSQL recovery worker and recovery service remain planned work. The S0 architecture amendment defines the target exact-key identity contract; a separate S0 governance/task admission must authorize the minimum typed path and exact-key propagation before SBH-10-04 can be marked `READY`. This amendment does not certify that current code supports renewal keys or that runtime recovery is complete. Later SUBS re-admission must verify the then-current S0 source and stop if the required recovery path is absent or needs authority beyond this grant.

## Subscription collection-attempt authority

The later SBH-10-04 task may add one Subscription-owned durable resource under the existing RenewalAttempt. `RenewalCollectionAttempt` is the semantic name; the module name may be refined before implementation. No new Domain is authorized.

The resource must persist before PaymentIntent creation or provider work. It owns:

- a UUIDv7 collection identity and its parent RenewalAttempt;
- a collection ordinal unique and monotonic within that RenewalAttempt, separate from `RenewalAttempt.attempt_no`;
- the exact PaymentIntent association once one exists;
- dispatch state separate from financial outcome;
- financial outcome separate from dispatch state;
- the current reservation generation identity needed for exact release, replay, and consumption.

The same resource also owns a durable monotonic `dispatch_epoch`, initialized to `1`, and `fenced_through_epoch`, initialized to `0`. Store the current epoch's dispatch state and retain `last_fence_event_id` and `last_fenced_at` as durable pre-submission evidence. `fenced_through_epoch` is a monotonic high-water mark: epochs are never skipped, and every epoch at or below it is permanently fenced. This prefix is the durable evidence for all prior fenced epochs; a later resume must not erase it. Each released generation also remains as a terminal Orders row under its exact reservation key, preserving the collection and generation IDs after the collection advances to a new generation. The last-fence fields identify the latest fence transition.

Use separate state axes:

| Dispatch state | Meaning |
|---|---|
| `not_started` | No provider dispatch claim has begun. A worker may still need to be fenced before any hold is released. |
| `may_have_been_reached` | A worker durably claimed dispatch before making the provider request. Provider contact is possible, including when the worker dies before sending bytes. |
| `not_submitted` | A successful pre-submission fence proves that no worker can submit this collection. This is dispatch evidence, not a financial result. |

| Financial outcome | Meaning |
|---|---|
| `unresolved` | No verified terminal financial result exists. |
| `requires_action` | Provider authentication or customer action is required. The collection remains unresolved. |
| `verified_success` | Canonical provider evidence proves success for this exact PaymentIntent and collection. |
| `verified_terminal_financial_non_success` | Canonical provider/payment evidence proves a final decline or provider-confirmed cancellation that cannot later succeed. |

The database must enforce the collection concurrency invariant. Use a unique `(renewal_attempt_id, collection_ordinal)` identity and a partial unique index allowing at most one row per RenewalAttempt whose financial outcome is `unresolved` or `requires_action`. Collection creation must lock the parent RenewalAttempt, reject creation after any `verified_success`, and allow a later ordinal only when the preceding collection has `verified_terminal_financial_non_success` and current dunning policy permits another collection. A `not_submitted` row still has an unresolved financial outcome and retains the one-active-collection slot.

### Dispatch epoch and pre-submission fence

All dispatch and fence transitions are compare-and-set operations scoped to the exact `collection_attempt_id` and `dispatch_epoch`:

1. The provider worker may transition only `(epoch = N, dispatch_state = not_started)` to `may_have_been_reached`. Commit this transition before making the external request. The worker may submit only after that exact transition succeeds and only for the active reservation generation recorded on the collection.
2. A pre-submission fence may transition only `(epoch = N, dispatch_state = not_started)` to `not_submitted`. The same transaction records `fenced_through_epoch = N` plus the fence event and releases only the exact active generation. If either write fails, both roll back.
3. If the state is `may_have_been_reached`, fencing fails. Keep the hold and reconcile the same collection and PaymentIntent.
4. To resume after a successful fence, first lock the collection, advance `dispatch_epoch` from N to N+1, set the new epoch to `not_started`, and persist a new reservation-generation ID. Only then may the new generation become dispatchable. `fenced_through_epoch` remains N.

A stale worker must provide its expected epoch for every claim and transition. Epoch N work therefore cannot change epoch N+1 state or submit after the fence. Advancing an epoch without a successful fence is forbidden. A fence proves only that the corresponding provider request was not started; it is not a financial outcome and does not permit a later collection attempt.

The collection resource requires one task-specific Subscription migration and its Ash snapshot. `payment_intent_id` is nullable until intent creation, references `PaymentIntent`, and has a unique index so a PaymentIntent can belong to at most one collection and webhook lookup is indexed. The resource must not repurpose `RenewalAttempt.attempt_no` or redefine the legacy `RenewalAttempt.payment_intent_id`. That field remains unresolved compatibility/state evidence until the separate SBH-10-05 decision.

## PaymentIntent and provider identity

Each collection uses this deterministic local PaymentIntent key and provider idempotency key:

```text
renewal-collection:<collection_attempt_id>
```

An ambiguous replay of the same collection reuses the same PaymentIntent and key. Each later dunning collection has a new durable collection ID and therefore a new key. `renewal_key` remains occurrence metadata. Each PaymentIntent must be attributable to its exact collection and RenewalAttempt.

The existing Payments data model is sufficient. The later task may add the typed renewal create-or-reuse path needed to pass the explicit key. It may not add a Payments resource or PaymentIntent schema migration solely for sequential collections. The current `submitted` and `requires_action` interlocks and the `succeeded` preflight rejection remain in force.

The renewal provider request must carry all of these fields:

- `renewal_key`
- `collection_attempt_id`
- `renewal_attempt_id`
- `order_id`
- `local_intent_id`
- `subscription_id`

For the normal renewal create request, adapter changes are limited to payload/redirect construction, signature verification, and canonical normalization needed to carry that identity. It must use `renewal-collection:<collection_attempt_id>` as the provider create idempotency key. Status retrieval and cancellation are authorized only by the bounded contract below; unrelated provider requests remain unchanged.

### Renewal collection status recovery and cancellation

The later SBH-10-04 implementation may add renewal-scoped `retrieve_renewal_collection_intent` and `cancel_renewal_collection_intent` operations to `Store.Payments.Providers.Behaviour`, the `Store.Payments.Providers` wrapper, the typed Payments facade, and only the provider adapters needed for an admitted renewal provider. These operations must target one exact collection PaymentIntent. They are not general PaymentIntent retrieve/cancel APIs. Adapters that cannot support exact retrieval or safe cancellation return an explicit unsupported result; the renewal remains unresolved and fails closed.

Status retrieval must identify the exact provider intent using its durable provider ID or an exact provider-supported lookup bound to both `collection_attempt_id` and `local_intent_id`. Zero matches, multiple matches, mismatched IDs/metadata, unknown status, timeout, transport failure, provider 5xx, or unsupported lookup are ambiguous and leave the financial outcome unresolved. Normalize only authenticated provider responses into canonical collection status; the adapter performs no domain transition, Repo/Ash access, or Oban enqueue.

Provider cancellation must target only the exact retrieved provider intent. A cancel request or its immediate response is not terminal evidence. Follow it with status retrieval, or accept a canonical verified webhook, and classify `verified_terminal_financial_non_success` only when provider evidence proves the intent cannot later succeed. A retrieved success must route through exact PaymentIntent-to-collection validation. A still-actionable, processing, unknown, or ambiguous status remains unresolved with its hold active.

The existing local authentication deadline may trigger bounded status reconciliation and a cancellation request for a `requires_action` collection. The deadline, local PaymentIntent state, or provider cancel acknowledgement alone never releases inventory or permits a new collection. Reuse the same collection and PaymentIntent during reconciliation; do not use replay of the provider create idempotency key as proof of current status. After bounded automatic reconciliation is exhausted, retain `unresolved`, keep the reservation generation active, and escalate for operator review. A later collection still requires verified terminal financial non-success and permission under the existing dunning policy.

## Physical renewal reservation generations

Generic checkout keeps its key and behavior:

```text
order:<order_id>:sku:<variant_id>
```

For physical renewal holds, the later task may derive this server-owned generation key:

```text
order:<order_id>:sku:<variant_id>:renewal_collection:<collection_attempt_id>:generation:<reservation_generation_id>
```

`reservation_generation_id` is a server-generated UUIDv7 persisted with the collection before its reservation operation. The same generation ID may identify the hold set for that collection across its Order variants. The key is the durable generation identity and remains stable through ambiguous database outcomes. A pre-submission fence may release that generation while keeping the same collection and PaymentIntent. If the same collection resumes, it gets a new generation ID and new reservation keys, while its collection, PaymentIntent, and provider idempotency identities remain unchanged.

The Orders migration and Ash snapshot may remove the unconditional `unique_order_variant` Ash identity and database index, then add a unique partial index on `(order_id, variant_id) WHERE state = 'active'`. Keep the global unique `reservation_key` Ash identity and index; do not represent the partial active-row rule as a global Ash identity. The snapshot must reflect removal of the pair identity and retention of the key identity. This permits terminal historical generations and at most one active generation per Order/variant. `consumed`, `expired`, and `cancelled` rows remain terminal. A later generation inserts a new row; it never reactivates an old row.

The current Orders implementation has pair-only reservation lookups, so the future change must also disambiguate its bounded query paths. Generic checkout reserve/release/consume helpers must resolve only the canonical generic key `order:<order_id>:sku:<variant_id>`; their order-wide enumeration must exclude renewal-generation keys. `maybe_reload_reservation` and `lock_order_variant_reservation` must not query by `(order_id, variant_id)` alone. Renewal reserve/release/consume operations must target the full exact `reservation_key` and validate its Order/variant. This amendment authorizes only that minimal key-based query change needed by the new history; it does not authorize a general Orders redesign. The renewal path must never call a generic pair-only helper.

Every new active generation must lock the PostgreSQL inventory row and check current stock again. Provider work must wait until every required physical hold for that collection is active. A verified failure may release only that collection's active generation. A successful collection may consume only the generation whose exact reservation key is linked to that collection. The existing globally unique reservation key can carry this relationship; no second inventory authority or new reservation resource is authorized.

## InventoryAdmission amendment

S0-ARCH-01 is amended only to admit the server-derived physical renewal generation key above. The generic Request continues to derive `order:<order_id>:sku:<variant_id>` without accepting caller-provided reservation keys.

The renewal-specific typed path must treat the full server-derived generation key as the durable logical-operation identity. It must carry that exact key through request identity, request fingerprint, operation descriptors, Lease values, Redis recovery fences, and PostgreSQL recovery. The Lease may also retain its identity digest for coordination. Admission still gates by variant for `K_v`; the global `B_total` budget remains unchanged. Recovery must query PostgreSQL by the exact reservation key and compare the operation's trusted PRE/POST facts. Redis must not decide whether a reservation exists or whether stock is available.

All existing ambiguous-database-outcome fences remain in force. Lease expiry, Redis loss, or missing recovery evidence cannot authorize a second durable mutation. An unresolved operation retains its fence and fails closed. This is a bounded identity amendment, not a redesign of InventoryAdmission.

## Requires-action and release authority

The accepted SUBS source at `c66...` records that current renewal failure handling releases reservations on both failure and `requires_action`. That runtime behavior is unsafe and remains unchanged until an implementation is separately admitted.

The later SBH-10-04 implementation must keep the active reservation generation for `requires_action`. It must keep the same collection attempt and PaymentIntent while action remains unresolved. An authentication deadline, local TTL, transport timeout, process death, network error, provider 5xx, or local cancellation after possible submission does not permit another collection. The local authentication deadline may trigger the renewal-scoped provider retrieval/cancellation sequence above, but release still requires verified terminal provider/payment non-success.

A hold may be released before financial resolution only when a durable pre-submission fence proves that the provider was not reached and no worker can still submit. Otherwise, release requires verified terminal financial non-success. A released generation stays terminal. The same collection may resume with a new reservation generation after a proven pre-submission fence. A later collection requires verified terminal financial non-success and permission under the current dunning policy.

The dispatch epoch and pre-submission fence follow the CAS and high-water-mark contract above. If an epoch reached `may_have_been_reached`, the fence cannot prove non-submission; retain the hold and reconcile the same PaymentIntent and key through the renewal-scoped provider status operation. When the same collection resumes after `not_submitted`, advance the epoch and persist a new reservation generation while retaining the prior fenced-epoch prefix.

`verified_terminal_financial_non_success` requires verified evidence that the submitted attempt cannot later succeed. A local PaymentIntent `failed` or `cancelled` value alone does not establish that outcome when provider submission may have started.

Immediately before every provider dispatch, revalidate the current stored payment method and use the existing provider selection. Do not freeze the payment-method binding at checkpoint B. If no authorized stored method exists, do not start provider work. Preserve the SBH-80-03 ownership of payment-method replacement and revocation races; this amendment changes no race semantics.

## Exact successful-collection evidence

The bounded renewal success orchestration must validate the local collection relationship before it enters payment-application or inventory behavior. It must prove:

1. Canonical success belongs to the exact local PaymentIntent.
2. That PaymentIntent is associated with the exact RenewalCollectionAttempt.
3. The collection belongs to the exact RenewalAttempt and its one renewal Order.
4. For a physical renewal with holds, derive the expected key set from the collection's `reservation_generation_id`, Order, and physical variant lines; prove that every expected key is active and that the Order has no other active reservation key. Virtual renewals without physical holds do not require a reservation generation.

The current generic payment-success path consumes reservations by Order. The later Payments implementation must route renewal success through a bounded renewal-specific transaction that does not call that order-wide consume operation. For a physical renewal, that transaction must validate the exact collection and generation, then consume only the validated exact generation keys through a bounded Orders API before or alongside the paid-Order transition. The collection-to-generation relation is established from the durable collection/generation IDs and the server-derived reservation keys; an order-wide active-hold assumption is insufficient. It must also retain PaymentApplication's apply-once insert, compare an existing application's exact `payment_intent_id` before treating a replay as applied, and roll back on a mismatch. For virtual renewals, no reservation consume is required. Generic checkout keeps its existing order-wide path and behavior.

PaymentApplication remains the paid-Order apply-once authority with its order-level key and exact `payment_intent_id` evidence. Its resource, schema, and identity do not gain Subscription semantics. On an existing application row, the renewal orchestration must verify that its `payment_intent_id` equals the exact successful PaymentIntent before treating the application as a replay; a mismatch fails closed. If the approved collection and reservation identities cannot prove the exact PaymentIntent-to-generation relation without changing PaymentApplication's identity model, stop and return to governance.

## Order totals and SBH-10-05 boundary

Shipping and tax are not checkpoint-B RenewalAttempt evidence. Once occurrence A's renewal Order has finalized payable totals, every collection retry uses those durable totals. A later dunning collection must not re-quote or rewrite shipping or tax. Catalog fulfillment inputs do not become checkpoint-B evidence.

This amendment authorizes Subscription renewal orchestration to load the finalized Order totals for the occurrence and reuse them for every later collection. Initial Order creation keeps its existing quote and finalization flow. A later collection must not requote shipping/tax or rewrite the Order totals.

This amendment does not implement SBH-10-05. That future work must reconcile from the exact successful PaymentApplication PaymentIntent and collection evidence, while preserving every earlier collection attempt. The meaning of `RenewalAttempt.payment_intent_id` remains an explicit SBH-10-05 decision.

## Authority by owning surface

| Owner | Future authority granted for SBH-10-04 | Limit |
|---|---|---|
| Subscriptions | One `RenewalCollectionAttempt` resource, one task-specific migration and Ash snapshot, including the nullable foreign key and unique index for its exact PaymentIntent association; collection concurrency, monotonic dispatch epoch/fence evidence, bounded status-reconciliation scheduling, and exact reservation-generation links. Before each dispatch, revalidate the current stored method and existing provider selection. Renewal retries read finalized totals from the existing Order. | One immutable RenewalAttempt and one Order remain. Dunning policy and the legacy `payment_intent_id` meaning do not change. Keep payment-method replacement/revocation race semantics under SBH-80-03. |
| Payments | A typed renewal create-or-reuse path using the collection-derived key, bounded `requires_action` handling, renewal-only provider retrieve/reconcile and cancel wrappers, and a renewal-specific paid transaction that validates through Subscriptions and consumes exact Orders keys without calling the generic order-wide consume operation. | Reuse PaymentIntent and PaymentApplication. No new Payments resource or schema migration. Generic checkout remains unchanged. |
| Provider adapters | Carry the six renewal identities and use the collection-derived idempotency key; add exact renewal-collection status retrieval and cancellation for adapters that can support it. | Renewal collection intents only. No general intent lookup/cancel API, Repo/Ash/Oban access, business transitions, or unrelated provider expansion. |
| Orders | One task-specific migration and Ash snapshot for historical reservation generations, removing the global pair identity and adding the partial active index; key-disambiguated generic helpers; and exact reserve/release/consume operations. Renewal generations bypass generic TTL cleanup. | Keep `reservation_key` globally unique. No terminal-row reactivation, second inventory authority, or generic checkout behavior change. |
| InventoryAdmission / S0 | Amend the S0 architecture contract for a separate server-owned typed renewal-generation admission path keyed by the exact `reservation_key`. | This does not reopen frozen IA-01 `Request`, `Operation`, or `Lease` contracts or authorize their code changes. A separate S0 governance/task admission covering the new typed contract and exact-key recovery must be canonical before SBH-10-04 can be marked `READY`. Preserve `K_v`, `B_total`, PostgreSQL authority, lease safety, recovery fencing, and fail-closed behavior. No Redis business authority or redesign. |
| PaymentApplication | No schema or identity change. Preserve its exact PaymentIntent evidence and order-level apply-once identity. | It does not own Subscription commercial matching. |
| Catalog, Shipping, and Tax | No implementation change. Reuse the finalized payable totals on the existing renewal Order. | No requote, totals rewrite, or Catalog fulfillment input in checkpoint B. |
| Entitlements | No authority assigned. | Outside SBH-10-04. |
| Payment-method replacement and revocation | No authority assigned; SBH-80-03 retains this race. | Stop if implementation needs a change here. |
| SBH-10-05 | No implementation authority. Preserve a future exact-evidence reconciliation requirement. | No paid-reconciliation changes in this task. |

## Explicit exclusions

This amendment changes no Entitlements behavior, generic checkout behavior beyond the approved renewal reservation exception and key-based helper disambiguation, unrelated provider behavior, dunning policy, payment-method replacement or revocation race, Redis authority, RenewalAttempt charged-contract schema, or JC-223 edge. It does not implement SBH-10-05.

## Later admission sequence

This governance merge does not resume PR #78. After the merge, an independent reviewer must verify the exact merge commit and tree. Next, complete a separate S0 governance/task admission for the typed renewal-key and exact-key recovery work, including any S0-scoped implementation required by that admission. That S0 work must pass its required review, merge, and receive independent post-merge commit/tree verification. Only then may a separate SUBS governance re-admission amendment use the then-current accepted `hardening/subscriptions` tip and recheck source compatibility for every authority above.

Only the separate SUBS re-admission amendment may transition `SBH-10-04` from `BLOCKED_SHARED_AUTHORITY` to `READY`, and only after the S0 admission has merged and passed independent post-merge verification, all grants are canonical, and current source compatibility checks pass. The SUBS amendment must not infer `READY` from PR #80 alone. A new implementation `task_base_sha` may be assigned only after the re-admission amendment merges and passes independent post-merge commit/tree verification.

## Performance & Scaling Review

- **Hot:** Future renewal collection creation, physical reservation, payment dispatch, provider status/cancel reconciliation, webhook success, and exact reservation consumption. This governance PR adds no production query. The later implementation must report measured queries for collection creation, each inventory variant, PaymentIntent create-or-reuse, recovery, and exact consumption. It must state the N+1 risk and keep collection-history reads bounded.
- **Warm:** No new ETS or Redis cache is authorized. Stock and availability projections remain read-only; PostgreSQL decides reservation and stock truth. Generic checkout TTL and post-commit invalidation stay unchanged. Unresolved physical renewal generations bypass generic TTL cleanup until exact release evidence exists. No cache stampede protection is added to this admission path; database row locks and uniqueness constraints remain the concurrency controls.
- **Cold:** Provider ambiguity and database recovery use bounded, idempotent reconciliation; exhaustion leaves the hold active and requires operator review. Oban uniqueness for occurrence scheduling stays keyed by the existing subscription and `renewal_key`; collection recovery jobs are unique by durable collection ID and dispatch epoch.
- **Indexes:** Retain unique `payment_intent_key`, the existing partial same-Order active-payment index, unique `reservation_key`, and add the authorized active-reservation partial index. Remove the global pair identity and retain the global reservation key identity. The Subscription migration must add unique `(renewal_attempt_id, collection_ordinal)`, a unique nullable `payment_intent_id` index, and the partial one-active-collection index.
- **Idempotency:** One collection ID maps to one PaymentIntent key and provider key. One reservation generation key maps to one durable reservation row. A new key requires a new approved collection or generation identity.
- **Telemetry and logs:** The later implementation must record collection ID, renewal key, local intent ID, order ID, reservation key, dispatch epoch, fenced-through epoch, dispatch state, financial outcome, provider retrieval/cancel result, recovery result, and application result. It must distinguish an attempted provider call from provider evidence and Order application.
- **Capacity claim:** This amendment makes no latency, throughput, or 100,000-user certification claim.

## JC-229 dispatch atomicity correction

This governance proposal addresses only the physical-generation read-to-dispatch
race. JC-229 / SBH-10-04 remains `BLOCKED_AUTHORITY -> STOP`. PR #127 remains draft
and stopped. This record supersedes prior READY/task-start evidence for JC-229
without modifying the SUBS Master Register or granting JC-230 authority.

### Verified evidence and race

The 2026-10-04 live fetch and GitHub inspection confirmed:

| Authority | Observed state |
| --- | --- |
| canonical main | `43b2927b3fd4689c68bf8ec4f631d8ab0c5c2d8c` |
| accepted SUBS | `8a21739555de1dde8f448bfd7e1172b1caeb54c3` |
| accepted S0 | `f2d3ed27476d1d8bfdda2a28dcdbfe6a1d02e2d9` |
| PR #127 | open, draft, `c409a440dbb5f2ea2fb39e79e0f9b11787d38422` |
| PR #128 | open, `91807522468a138047fd78408aedcf361ed7a3f0` |

PR #117 accepted exact-generation operations into S0. PR #119 reconciled them into
SUBS. PR #121 re-admitted JC-229 at the accepted SUBS tip, and PR #122 recorded its
original task base. Those grants permit use of accepted APIs; they do not authorize
JC-229 to add Orders locking behavior.

At PR #127 head, `renewal_collection_attempts.ex` lines 389-405 locks the collection,
checks its epoch, calls `ensure_current_generation_active`, validates its exact
PaymentIntent, and updates `:claim_dispatch`. Lines 534-553 use
`Orders.recover_exact_generation` to validate the key, Order, variant, quantity,
and active state. The enclosing transaction at lines 964-975 does not add an Orders
row lock. Accepted S0 `inventory_reservations.ex` lines 222-230 reads the key with
`Repo.one` and no lock. That file is byte-identical at S0, SUBS, and PR #127 head.

A concrete permitted database interleaving is:

1. Dispatch transaction A locks the collection and reads active generation G.
2. A pauses before its collection transition.
3. Exact release transaction B locks InventoryItem, then G, cancels G, and commits.
4. A changes `not_started` to `may_have_been_reached` and commits using its prior read.

B never requests A's collection lock. A never locks G. The resulting dispatch claim
therefore outlives its active physical hold. This is a source-level concurrency
proof, not a claim that a production incident or a new executable race test occurred.
The existing same-collection pre-submission fence locks the collection and therefore
cannot itself perform step 3 concurrently with A. Release must independently satisfy
its governing business evidence; this correction grants no arbitrary caller release.

### Orders contract and cross-domain order

Section 5.2 of [inventory governance](inventory_reservations.md#52-exact-renewal-generation-transaction-guard)
freezes the capability semantics. No arbitrary function name is frozen. Prefer one
additive guard implementation in `Store.Orders.InventoryReservations`. Cross-domain
callers must retain the accepted `Store.Orders` facade boundary, supply trusted typed
identity and explicit system/actor authority, and never access Orders tables through
Subscription Repo code. Current `domain.ex` forwards the existing exact-generation
APIs explicitly and has no guard entry yet. Cross-domain callers must never call
`InventoryReservations` directly.

The 2026-10-07 source-compatibility admission explicitly authorizes one additive
`Store.Orders` facade forwarding entry for the exact-generation transaction guard.
The frozen future implementation boundary is exactly:

```text
lib/store/orders/inventory_reservations.ex
lib/store/orders/domain.ex
test/store/orders/inventory_reservation_generation_test.exs
```

No arbitrary public function name is frozen. Freeze the behavioral contract:
`Store.Orders` (public/internal facade) → additive exact-generation transaction
guard → `InventoryReservations` implementation. Do not bypass that facade or alter an
existing recovery API to expose the guard.

For a physical dispatch, the exact collection epoch N in `not_started`, exact
PaymentIntent evidence, and the exact active physical generation under the guard
are all required before the transition to epoch N in `may_have_been_reached`.
The guard survives the CAS commit or rollback. A virtual renewal without a physical
generation does not use this guard. The guard alone never authorizes provider work. The fresh resume path also uses an
unlocked generation read before its epoch CAS. Resume does not authorize dispatch;
it remains stopped with PR #127 and must receive an independent fail-closed review
at JC-229 re-admission. This amendment grants no new resume or recovery semantics.

Accepted exact reserve at lines 293-320, release at 371-389, and consume at 404-427
lock InventoryItem before the reservation. Generic bulk and expiry paths likewise
lock inventory first and exclude renewal keys. None acquires a collection lock.
A reservation-only dispatch guard introduces no wait back to InventoryItem.
An exact mutation can wait for that guard while holding InventoryItem, but dispatch
can finish without requesting that item. For fence operations, retain collection,
InventoryItem, reservation order. Prohibit inventory mutation after a reservation-only
guard and prohibit Orders-to-collection reverse acquisition. These restrictions
prevent the new reservation-to-inventory edge that would otherwise form a cycle.
A caller must not hold earlier Orders locks when it starts collection locking.
A future authoritative writer that violates this graph blocks implementation.

### Prerequisite admission (2026-10-07)

Objective: protect one exact physical generation through a governed caller's outer
transaction, without writing inventory, Subscription state, or new durable evidence.
The owner is S0 / Orders inventory concurrency, in one dedicated temporary task
branch/worktree. This is a separate prerequisite, not JC-229 or IA-04 Slice 2.

**Governance parent:** canonical `origin/main` at
`b0a6c07637258659eb561e9863ea88667d1f96ae` (governance branch
`governance/s0-jc229-generation-guard-admission`).

**Accepted S0 task base (implementation parent):**

```text
commit = da0a369b9f99ecca6db940a802257cea4e69b2b8
tree   = 6227effe919509d71fe0450234792831d7d13240
ref    = origin/hardening/s0-baseline
```

Provenance: PR #128 Slice 2 merged and post-merge verified; PR #132 DevCore
reconciliation merged as `da0a369...` with zero IA implementation/test drift on the
guard surfaces. Source-compatibility review at this base: `PASS`. Relevant main/S0
runtime divergence on the three guard surfaces is S0-ahead exact-generation history;
it does not require importing unrelated main application history before implementing
on S0. `BLOCKED_BASE_RECONCILIATION` and `BLOCKED_FACADE_AUTHORITY` are resolved.

**Prerequisite lifecycle:**

```text
JC-229 EXACT-GENERATION GUARD PREREQUISITE = AUTHORIZED / NOT STARTED
```

```text
implementation branch  = NOT CREATED YET
implementation worktree = NOT CREATED YET
integration target     = hardening/s0-baseline
```

Writable files for the future implementation task only:

```text
lib/store/orders/inventory_reservations.ex
lib/store/orders/domain.ex
test/store/orders/inventory_reservation_generation_test.exs
```

Every other file is forbidden in that implementation task. In particular, no
`inventory_reservation.ex` resource change, migration, Ash snapshot, new resource or
Domain, `inventory_admission.ex`, `InventoryAdmission.Redis`, generic checkout,
workers, Subscription runtime, Payments, providers, dependency, configuration, stock
authority, or IA-05 recovery change is admitted. Any need for additional files
requires STOP and another authority decision. Existing APIs remain unchanged;
recovery-after-ambiguous-mutation compliance in PR #127's fence path remains that
stopped task's separate responsibility. The guard does not add recovery semantics.

Do not branch the implementation from `main` alone (lacks accepted PR #117 runtime)
or use PR #127 / `hardening/s0-ia04` as implementation authority. If the task base
moves before implementation starts, STOP and re-evaluate.

### IA-04 isolation and sequencing

PR #128 Slice 2 is `PASS / ACCEPTED / FROZEN` (merge `f5131e39801c1633b79d04cacd30202b0823e48d`
into `hardening/s0-baseline`). Its cumulative diff contained accepted Slice-1
configuration/startup files plus the two Slice-2 Redis files only; neither guard
surface appeared in that diff. Slice 2 makes no PostgreSQL calls or Orders routing
changes. Redis lifecycle fences remain coordination; the new PostgreSQL guard neither
replaces them nor changes their known/unknown outcome, capacity-retention, or timeout
rules.

The guard prerequisite must use its own branch/worktree and S0's explicit bounded
ownership assignment. No guard implementation may be added to the historical
`hardening/s0-ia04` line.

IA-04 Slice 1 = `PASS / ACCEPTED / FROZEN`. IA-04 Slice 3 = `SERIAL-BLOCKED ON JC-229
GUARD PREREQUISITE` (not authorized to start). IA-05+ = `NOT AUTHORIZED`.

Reserve the three-file guard boundary exclusively to the prerequisite until it is
merged and independently verified on S0. Later IA-04 slices touching
`inventory_reservations.ex` must wait for prerequisite S0 merge/verification, then
reconcile the accepted guard before coding. No parallel competing implementation is
permitted. If later-slice work already started, STOP for a new sequencing decision.
S0 architecture remains unchanged; this completes the Orders exact-generation
concurrency contract and does not amend the InventoryAdmission architecture file.

### Acceptance and concurrency proof

Use separate PostgreSQL backend sessions, explicit message/barrier synchronization,
and database lock-wait evidence. Sleeps and task non-completion alone are not proof.
The focused Orders tests must prove:

1. An exact active generation under the guard allows the governed caller to proceed.
2. A missing generation fails closed.
3. Each terminal state fails closed.
4. Wrong Order, variant, full key, and required quantity fail closed, including
   contradictory stored identity.
5. A release that wins first commits terminal evidence; a later guard rejects it.
6. A guard that wins first prevents exact release from committing until the outer
   guarded transaction finishes. Prove the backend wait dependency, then prove release
   proceeds after commit. Include consume and every applicable terminal writer.
7. Outer rollback releases the lock and leaves reservation facts and counters unchanged.
8. Generic reserve/replay/release/consume/expiry behavior remains unchanged.
9. An unrelated renewal generation remains independently mutable, including a different
   Order on the same variant. The read-only guard must not lock the InventoryItem.
10. No second stock ledger or inventory authority exists.
11. Calls outside the required transaction, or on a different connection, fail closed;
    database errors/timeouts cannot produce permission to dispatch.

Tests must verify row/counter facts before and after, transaction connection identity,
lock lifetime, and both race winners. Orders tests may model a governed caller's
transaction without modifying Subscription production code or tests. Later JC-229
must independently prove the real guard-through-dispatch-CAS composition.

### Performance & Scaling Review

This amendment adds zero production queries. The future guard is on the hot physical
renewal dispatch path. Measure its query count separately from BEGIN/COMMIT and from
the caller CAS, including success, missing, terminal, invalid input, and uncertainty.
The target is one indexed full-key locking SELECT and zero inventory queries or
association loads. Report the actual count rather than treating this target as measured.
Verify the retained unique reservation-key index and an EXPLAIN plan using a realistic
table population; no index migration is authorized. Recheck row identity after lock
acquisition. A single generation creates no N+1 loop.

Measure uncontended latency and contended lock-wait duration, pool occupancy, and
bounded timeout behavior. Review the complete lock graph and deadlock evidence.
Keep the caller transaction short; provider HTTP must occur after commit. No cache,
Redis, ETS, or GenServer serialization is allowed. TTL and invalidation stay unchanged.
No Oban job or uniqueness policy changes. Use existing Repo telemetry for query counts,
lock waits, and errors; add no logging of complete keys or payment evidence.

### Merge and re-admission gates

The governance admission PR requires exact-head CI, independent review, human merge
into `main`, and independent post-merge commit/tree verification. It implements no
capability. After that admission merges, the prerequisite implementation requires
focused deterministic tests and neighbouring regressions, measured performance proof,
`mix check`, required exact-head CI, and fresh independent review. Its integration
target is `hardening/s0-baseline`, using a normal bounded merge, followed by independent
post-merge commit/tree and test verification. No force push is authorized.

Before JC-229 can be re-admitted, the accepted prerequisite must be reconciled into
SUBS in a separate bounded integration with explicit source SHAs, exact-head CI,
independent integration review, merge, and post-merge verification. Then a separate
SUBS governance re-admission must verify all canonical grants, current source
compatibility, and real dispatch-CAS composition and assign a fresh accepted task base.
Until all these gates complete, JC-229 remains `BLOCKED_AUTHORITY -> STOP` and PR #127
remains draft. JC-230 stays dependency-blocked. This task never merges either runtime PR.
