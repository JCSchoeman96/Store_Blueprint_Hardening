# Phase 24 — Digital Products, Download Grants, and Signed URLs

## GOAL

Implement Phase 24 end-to-end with:

- Digital asset catalog linkage (`product` and `variant` aware)
- Replay-safe post-payment grant issuance
- Short-lived signed URL issuance for authorized users
- Scope-aware refund revocation policies
- Admin CRUD and customer download surfaces

without contaminating Orders/Payments resource semantics.

## LINKS CONSULTED

### Project docs

- `AGENTS.md`
- `docs/phases/phase_23_email_receipts_notifications_spine.md`
- `docs/phases/phase_24_digital_products_download_grants.md`
- `docs/phases/phase_25_variable_products_variants.md`
- `docs/governance/side_effects_quarantine.md`
- `docs/governance/idempotency.md`
- `docs/governance/checkout_interlocks.md`
- `docs/governance/refund_semantics.md`
- `docs/governance/error_codes.md`
- `docs/governance/policy_matrix.md`
- `docs/governance/enforcement_gates.md`
- `docs/governance/performance_scaling.md`
- `docs/governance/observability_slos.md`
- `docs/governance/route_inventory.md`
- `docs/governance/time.md`
- `docs/agent_notes/phase_22_docs.md`
- `docs/agent_notes/phase_23_docs.md`

### Key implementation files reviewed

- `lib/store/payments/interlocks.ex`
- `lib/store/payments/refunds.ex`
- `lib/store/orders/order_line_item.ex`
- `lib/store/orders/facade.ex`
- `lib/store/fulfillment/facade.ex`
- `lib/store/workers/ensure_fulfillment_for_paid_order_worker.ex`
- `lib/store/support/governance/surface_registry.ex`
- `lib/store/support/governance/uniqueness_registry.ex`
- `lib/store/support/errors/error_codes.ex`
- `lib/store_web/router.ex`

### External references

- https://docs.aws.amazon.com/AmazonS3/latest/userguide/using-presigned-url.html
- https://hexdocs.pm/ex_aws_s3/ExAws.S3.html#presigned_url/5
- https://hexdocs.pm/oban/unique_jobs.html
- https://hexdocs.pm/phoenix/Phoenix.Controller.html#redirect/2
- https://docs.wasabi.com/docs/how-do-i-use-pre-signed-urls

## DECISIONS / PINS

1. Refund revocation is policy-driven and scope-aware.
2. Default revocation policy is `:strict_line_scoped`.
3. Shipping-only refunds must never revoke digital grants.
4. Supported policies for this phase:
   - `:strict_line_scoped` (default)
   - `:strict_order_scoped`
   - `:threshold` (configurable, off by default)
5. Guest checkout for digital-linked items is disallowed in Phase 24.
6. Signed URL adapter strategy is S3-compatible presigning with fake adapter for tests.
7. Redirect safety is mandatory:
   - signed URL scheme must be `https`
   - signed URL host must match configured allowlist
8. Deterministic asset resolution is pinned:
   - union product and variant links
   - dedupe by `digital_asset_id`
   - variant link wins if duplicated
   - stable order by `position ASC`, then `digital_asset.key ASC`
9. Download limit semantics are Option A:
   - keep `max_downloads` and `download_count` fields
   - no enforcement in Phase 24
   - do not increment `download_count` in Phase 24
10. To avoid accidental schema enforcement drift under Option A:
   - no `download_count <= max_downloads` check constraint in Phase 24
   - keep `max_downloads` default `NULL`
11. Performance seam required now:
   - introduce `Store.Support.RateLimit` behavior
   - ETS backend for dev/test
   - Redis backend seam optional and non-forcing
12. Worker placement pin:
   - domain worker module under `lib/store/digital/workers/`
   - module `Store.Digital.Workers.IssueGrantsForPaidOrderWorker`

## PREVIOUS/NEXT PHASE BOUNDARY CHECK

### Previous phase (23) protections

- Reuse post-payment fan-out pattern but do not alter Comms outbox semantics.
- Do not change provider-email delivery contracts from Phase 23.

### Next phase (25) protections

- Do not implement variant option/value modeling in Phase 24.
- Keep digital linkage compatible with current `product`/`variant` identity only.

### Additional anti-creep pins

- No subscription lifecycle behavior (Phase 26+).
- No DRM/watermarking/client-side download manager.
- No multi-tenant behavior.

## PLAN

1. Add Digital domain/resources/migrations and constraints.
2. Add digital facade contracts and storage provider adapters.
3. Add rate-limit seam and signed URL safety guardrails.
4. Integrate idempotent grant issuance worker into payment interlocks.
5. Add scope-aware revocation integration in refund success flow.
6. Add guest digital checkout gate.
7. Add admin/customer web surfaces using typed params and facades.
8. Add governance/integration tests and update docs/registries.

## DONE

- Session start protocol complete (`bd dolt test`, `bd status`, `bd ready`).
- Closed retroactive docs bead `store_blueprint-7yf.15.9` after verifying canonical idempotency wording and running `mix check`.
- Created and structured Phase 24 bead tree (`store_blueprint-7yf.16` + children `16.1` to `16.7`).
- Implemented digital schema/resources and migration set:
  - `digital_assets`
  - `product_digital_links`
  - `download_grants`
  - refund scope metadata migration (`scope_kind`, `line_item_ids`) for line-scoped revocation correctness.
- Implemented storage + security seams:
  - fake + S3-compatible signing adapters
  - strict redirect guard (`https` + allowlisted host)
  - `Store.Support.RateLimit` seam with ETS backend and Redis backend interface.
- Implemented domain worker/facade flows:
  - `Store.Digital.Workers.IssueGrantsForPaidOrderWorker`
  - deterministic link resolution (variant+product union, dedupe by asset, stable sort)
  - payment interlock enqueue for digital grant issuance.
- Implemented policy-driven refund revocation:
  - default `:strict_line_scoped`
  - shipping refunds no-op
  - line-scoped revoke only targeted grants
  - full-refund condition revokes all order grants.
- Implemented guest digital checkout gate at payment-intent creation boundary.
- Implemented web surfaces:
  - admin digital assets CRUD
  - admin product-digital-links CRUD
  - customer downloads listing + signed URL request/redirect controller path.
- Updated governance docs for Phase 24 drift:
  - `docs/governance/error_codes.md`
  - `docs/governance/policy_matrix.md`
  - `docs/governance/route_inventory.md`.
- Added test coverage for:
  - rate-limit seam
  - redirect guard
  - storage provider adapter behavior
  - grant issuance idempotency + deterministic link precedence
  - signed URL denial for revoked/expired grants + rate-limit
  - guest digital checkout denial
  - refund webhook-driven line-scoped revoke + shipping no-revoke.

## NEXT

1. Run full `mix check` and fix remaining gate drift.
2. Close remaining Phase 24 beads with final notes and outcomes.
3. Push git + beads DB and complete closure protocol.

## BLOCKERS

- None.

## COMMANDS RUN

- `bd dolt test`
- `bd status`
- `bd ready`
- `mix check`
- `bd close store_blueprint-7yf.15.9 ...`
- `bd create ...` (`store_blueprint-7yf.16` through `store_blueprint-7yf.16.7`)
- `bd --sandbox dep add ...` (phase dependency graph)
- `bd update store_blueprint-7yf.16.1 --claim`
- `mix deps.get`
- `mix compile`
- `elixir -S mix format`
- `mix test test/store/digital ...`
- `mix test test/store/payments/refunds_digital_revocation_test.exs`
- `mix test test/store/payments/create_intent_for_order_test.exs`

## GATES

- Docs-first note created before implementation changes.
- Canonical idempotency wording pin uses `provider:provider_event_id`.
- Option A download counter semantics are explicit and non-contradictory.

## PERFORMANCE & SCALING REVIEW

### Hot / warm / cold

- Hot:
  - Signed URL authorization path
  - Paid-order grant issuance fan-out
  - Refund revocation application
- Warm:
  - Customer downloads listing
  - Admin digital asset/link listing
- Cold:
  - Historical grants and archived assets

### Query count + N+1 risk

- Signed URL request must perform bounded read path (grant + asset) and one optional rate-limit write.
- Issuer/revoker workers must batch by order and avoid per-row redundant reads.

### Indexes

- Unique `(order_line_item_id, digital_asset_id)` grants.
- Indexes on `download_grants.actor_user_id`, `download_grants.order_id`, `download_grants.expires_at`.
- Unique link constraints for product/variant + asset identities.

### Caching / TTL / invalidation

- No mandatory Redis cache in Phase 24.
- Signed URL TTL short (60..300s, default 120s).
- Rate-limit seam introduced now, ETS backend active.

### Oban uniqueness/idempotency

- Domain worker unique on order args.
- DB uniqueness and upsert/no-op semantics for grant issuance and revoke replay.

### Telemetry/logging

- Emit digital telemetry for grant issuance and signed URL outcomes.
- Emit rate-limit allow/deny signals.
- Avoid logging object keys and credentials.
