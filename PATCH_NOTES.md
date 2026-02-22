# Patch Notes — v4 (Single-Tenant hardening)
## Changes
- Converted blueprint explicitly to **single-tenant** (removed tenant routing / tenant_id language).
- Added **Single-tenant invariants** section:
  - global uniqueness constraints MUST be enforced (slugs, SKUs, coupons, order_ref, idempotency keys).
- Updated performance scaling doc:
  - removed tenant-prefixed Redis key requirement.
- Updated TOON prompts:
  - removed tenant-related scaffolding
  - added a **single-tenant uniqueness gate** prompt (schema/index test).
- Added Phase doc for uniqueness gates (P0).

## v5 additions
- Added governance doc: docs/governance/policy_matrix.md (pinned role/action matrix)
- Added phase doc: docs/phases/phase_06_policy_matrix.md
- Updated blueprint authoritative docs list + required tests
- Updated enforcement_gates.md to require policy matrix test suite
- Updated TOON prompts to include policy matrix doc + test suite tasks

## v6 changes (rename + hardening)
- Renamed blueprint everywhere: namespace Store, OTP app :store, paths lib/store and lib/store_web.
- Added governance docs: error_codes.md and outbound_http.md.
- Updated enforcement_gates.md with No raw Req usage gate and Error code registry gate.
- Added Phase 07 doc for error codes + HTTP hardening.
- Updated TOON prompts with tasks for error code pinning and raw Req enforcement.

## v7 additions (side effects quarantine)
- Added governance doc: docs/governance/side_effects_quarantine.md
- Updated enforcement_gates.md with side-effect quarantine CI gate requirements
- Updated STORE_BLUEPRINT.md authoritative docs + required tests
- Updated TOON prompts with side-effects quarantine tasks + CI gates + tests
- Added Phase 08 doc for quarantine enforcement

## v8 additions (immutable snapshots)
- Added governance doc: docs/governance/immutable_snapshots.md
- Updated enforcement_gates.md with immutable snapshot gates
- Updated STORE_BLUEPRINT.md authoritative docs + required tests
- Updated TOON prompts with immutable snapshots doc + test gates + snapshot stability test
- Added Phase 09 doc

## v9 additions (pricing determinism)
- Added governance doc: docs/governance/pricing_determinism.md
- Updated enforcement_gates.md with pricing determinism gates
- Updated STORE_BLUEPRINT.md authoritative docs + required tests
- Updated TOON prompts with pricing determinism doc + test suite tasks
- Added Phase 10 doc

## v10 additions (inventory reservations)
- Added governance doc: docs/governance/inventory_reservations.md
- Updated enforcement_gates.md with inventory reservation gates
- Updated STORE_BLUEPRINT.md authoritative docs + required tests
- Updated TOON prompts with inventory doc + test suite
- Added Phase 11 doc

## v11 additions (refund + tax/shipping)
- Added governance doc: docs/governance/refund_semantics.md
- Added governance doc: docs/governance/tax_shipping.md
- Updated enforcement_gates.md with refund and tax/shipping determinism gates
- Updated STORE_BLUEPRINT.md authoritative docs + required tests
- Updated TOON prompts with refund and tax/shipping tasks + test suites
- Added Phase 12 and Phase 13 docs

## v12 additions (checkout interlocks)
- Added governance doc: docs/governance/checkout_interlocks.md
- Updated enforcement_gates.md with checkout interlock gates
- Updated STORE_BLUEPRINT.md authoritative docs + required tests
- Updated TOON prompts with checkout interlocks doc + test suite
- Added Phase 14 doc

## v13 patch (dev readiness)
- Expanded `docs/governance/error_codes.md` to include all codes referenced across governance docs (refund, inventory, tax/shipping, checkout).
- Clarified error code registry test gate expectations in TOON prompts.
