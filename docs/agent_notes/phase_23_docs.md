# Phase 23 — Email, Receipts, and Notification Delivery Spine

## GOAL

Implement Phase 23 end-to-end as a deterministic, replay-safe transactional email spine for:

- `order_receipt`
- `refund_requested`
- `refund_processed`

with:

- DB-enforced idempotency/uniqueness
- async worker delivery only
- provider determinism (chosen at enqueue)
- PII-minimized persisted payloads
- admin inspect-only outbox visibility

## LINKS CONSULTED

### Project docs

- `AGENTS.md`
- `docs/phases/phase_22_shipping_fulfillment_physical_products.md`
- `docs/phases/phase_23_email_receipts_notifications_spine.md`
- `docs/phases/phase_24_digital_products_download_grants.md`
- `docs/governance/side_effects_quarantine.md`
- `docs/governance/outbound_http.md`
- `docs/governance/idempotency.md`
- `docs/governance/checkout_interlocks.md`
- `docs/governance/error_codes.md`
- `docs/governance/enforcement_gates.md`
- `docs/governance/observability_slos.md`
- `docs/governance/audit_and_pii.md`
- `docs/governance/performance_scaling.md`
- `docs/governance/policy_matrix.md`
- `docs/governance/route_inventory.md`
- `docs/agent_notes/phase_21_docs.md`
- `docs/agent_notes/phase_22_docs.md`

### Key implementation files reviewed

- `lib/store/comms/domain.ex`
- `lib/store/comms/email_outbox.ex`
- `lib/store/workers/deliver_email_outbox_worker.ex`
- `lib/store/payments/interlocks.ex`
- `lib/store/payments/refunds.ex`
- `lib/store/payments/refund.ex`
- `lib/store/support/governance/uniqueness_registry.ex`
- `test/store/governance/uniqueness_gates_test.exs`
- `lib/store_web/live/admin/fulfillment/index_live.ex`

### External references

- https://hexdocs.pm/oban/Oban.Worker.html
- https://hexdocs.pm/oban/unique_jobs.html
- https://hexdocs.pm/ash/create-actions.html
- https://hexdocs.pm/swoosh/Swoosh.html
- https://microservices.io/patterns/data/transactional-outbox

## DECISIONS / PINS

1. `EmailOutbox.template_kind` is enum-backed (`Store.Comms.Types.EmailTemplateKind`):
   - `:order_receipt | :refund_requested | :refund_processed`
2. `EmailOutbox.provider` is enum-backed (`Store.Comms.Types.EmailProvider`):
   - `:swoosh | :req_postmark`
3. Provider adapter behavior is strict:
   - `{:ok, provider_message_id}`
   - `{:error, :transient, reason}`
   - `{:error, :permanent, reason}`
4. Provider is resolved and persisted at enqueue time, never re-resolved in delivery worker.
5. Canonical idempotency keys are fixed:
   - `order_receipt:order:<order_id>`
   - `refund_requested:refund:<refund_id>`
   - `refund_processed:refund:<refund_id>`
6. DB uniqueness model (must all exist):
   - unique `(order_id, template_kind)` where `refund_id IS NULL`
   - unique `(refund_id, template_kind)` where `refund_id IS NOT NULL`
   - unique `(idempotency_key)` global
7. Coherence law (DB + Ash must match):
   - `refund_id IS NULL` => `template_kind = order_receipt`
   - `refund_id IS NOT NULL` => `template_kind in (refund_requested, refund_processed)`
8. `template_assigns` is minimal-PII only:
   - IDs and minor-unit/currency evidence only
   - full rendering loads immutable order/refund evidence at send-time
9. CAS claim is mandatory for delivery:
   - atomic `pending -> processing` claim before send
   - increment `attempt_count` only after successful claim
10. Stale-processing reclaim is mandatory:
    - persist `processing_started_at`
    - reset/requeue stale `processing` rows via periodic worker
11. Refund source of truth remains canonical `Store.Payments.Refund` and its transitions.
12. No resend UI in Phase 23; inspect-only admin outbox surface.

## MIGRATION SAFETY PIN (STRING -> ENUM)

Migration sequence is pinned:

1. Create enum type `email_template_kind`.
2. Add nullable `template_kind_v2` enum column.
3. Backfill with strict mapping:
   - `order_receipt` -> `order_receipt`
   - `refund_requested` -> `refund_requested`
   - `refund_processed` -> `refund_processed`
   - unknown values fail migration.
4. Set `template_kind_v2` `NOT NULL`.
5. Drop old constraints/indexes tied to old string `template_kind`.
6. Rename old/new columns:
   - `template_kind` -> `template_kind_legacy`
   - `template_kind_v2` -> `template_kind`
   - drop `template_kind_legacy`
7. Recreate partial uniques + coherence check on new enum column.
8. Coherence check uses Postgres enum literals:
   - `'order_receipt'::email_template_kind`
   - `'refund_requested'::email_template_kind`
   - `'refund_processed'::email_template_kind`

## PREVIOUS/NEXT PHASE BOUNDARY CHECK

### Previous phase (22) protections

- No shipping quote behavior, fulfillment state machine rules, or checkout shipping snapshot semantics are changed.
- Phase 23 only consumes existing immutable order/refund evidence for email rendering.

### Next phase (24) protections

- No digital grants, signed URLs, revocation, or digital download access in Phase 23.
- No product-type branching is introduced into Orders/Payments semantics.

## PLAN

1. Implement `EmailOutbox` schema migration + backfill + constraints + enum conversions.
2. Refactor `Store.Comms` into:
   - typed enqueue functions per email kind
   - dual adapters behind strict provider behavior
   - CAS claim + stale reclaim flow
3. Implement deterministic template renderer from immutable domain evidence.
4. Wire payment/refund triggers:
   - payment success -> `order_receipt`
   - refund request -> `refund_requested`
   - refund success -> `refund_processed`
5. Add admin inspect-only outbox facade/query/liveview surfaces.
6. Add governance/integration tests and run full `mix check`.

## DONE

- Phase 23 bead tree created under `store_blueprint-7yf.15.*`.
- `store_blueprint-7yf.15.1` claimed.
- Docs-first Phase 23 note created with decision-complete pins.

## NEXT

1. Implement migration/resource changes (`15.2`).
2. Implement templates/renderer (`15.3`).
3. Implement provider adapters + worker hardening (`15.4`).
4. Wire payment/refund triggers (`15.5`).
5. Build admin outbox inspect surface (`15.6`).
6. Add tests/gates/closure (`15.7`).

## BLOCKERS

- None.

## COMMANDS RUN

- `bd dolt test`
- `bd status`
- `bd ready`
- `bd create ...` (`store_blueprint-7yf.15` + `store_blueprint-7yf.15.1` to `.15.7`)
- `bd --sandbox dep add ...` (phase dependency graph)
- `bd update store_blueprint-7yf.15.1 --claim`
- `bd show store_blueprint-7yf.15`
- `bd show store_blueprint-7yf.15.1`

## GATES

- Docs-first note exists before code edits.
- Phase 23 pins include canonical idempotency key formats and migration safety.

## PERFORMANCE & SCALING REVIEW

### Hot / warm / cold

- Hot:
  - payment success enqueue path
  - refund request/finalize enqueue paths
  - outbox delivery worker claim/send/update
- Warm:
  - admin outbox list/status queries
- Cold:
  - historical outbox records and delivery audit trail

### Query count + N+1 risk

- Worker should fetch outbox row and required evidence in bounded reads.
- Admin list uses paginated typed query to avoid unbounded scans.
- No per-row provider config lookups at send time (provider stored on row).

### Indexes

- Partial unique indexes for order/refund template invariants.
- `idempotency_key` unique index.
- Indexes on `(state, inserted_at)`, `(template_kind, inserted_at)`, and `refund_id`.

### Caching / TTL / invalidation

- No cache required for correctness in Phase 23.
- Optional phase-29 optimization: cached template compilation and short-lived evidence caching.

### Oban uniqueness/idempotency

- Delivery jobs unique on row id.
- CAS claim prevents double-send even under retries/overlap.
- Stale-processing reclaim ensures operational recovery without manual DB edits.

### Telemetry/logging

- Emit enqueue and delivery attempt telemetry with kind/provider/outcome.
- Do not log raw email bodies or full recipient addresses.
