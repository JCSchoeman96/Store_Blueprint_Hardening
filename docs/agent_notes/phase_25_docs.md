# Phase 25 — Variable Products, Options, and Deterministic Variant Resolution

## GOAL

Implement Phase 25 end-to-end with:

- per-product option axes and values in `Store.Catalog`
- deterministic ID-based variant resolution from storefront selections
- required-option sellable completeness for active variants
- cache-aware availability summaries and invalidation triggers
- stock enforcement at cart add/update with checkout finalize as final authority
- dedicated admin CRUD surfaces for options/values/variants/selections
- storefront selector UX for valid/invalid/ambiguous states

without introducing Phase 26 subscription fields or contaminating Orders/Payments semantics.

## LINKS CONSULTED

### Project docs

- `AGENTS.md`
- `docs/phases/phase_24_digital_products_download_grants.md`
- `docs/phases/phase_25_variable_products_variants.md`
- `docs/phases/phase_26_simple_subscriptions.md`
- `docs/phases/phase_27_variable_subscriptions.md`
- `docs/phases/phase_29_performance_architecture_optimizations.md`
- `docs/governance/enforcement_gates.md`
- `docs/governance/pricing_determinism.md`
- `docs/governance/inventory_reservations.md`
- `docs/governance/immutable_snapshots.md`
- `docs/governance/checkout_interlocks.md`
- `docs/governance/tax_shipping.md`
- `docs/governance/performance_scaling.md`
- `docs/governance/observability_slos.md`
- `docs/governance/policy_matrix.md`
- `docs/governance/route_inventory.md`
- `docs/governance/error_codes.md`
- `docs/agent_notes/phase_24_docs.md`

### Key implementation files reviewed

- `lib/store/catalog/product.ex`
- `lib/store/catalog/variant.ex`
- `lib/store/catalog/facade.ex`
- `lib/store/catalog/inputs/cart_line_input.ex`
- `lib/store/carts/facade.ex`
- `lib/store/carts/cart_item.ex`
- `lib/store/checkout/domain.ex`
- `lib/store/orders/inventory_reservations.ex`
- `lib/store/orders/order_line_item.ex`
- `lib/store/support/governance/surface_registry.ex`
- `lib/store/support/governance/uniqueness_registry.ex`
- `lib/store/support/errors/error_codes.ex`
- `lib/store_web/live/shop_live/show.ex`
- `lib/store_web/live/admin/products/index_live.ex`
- `lib/store_web/live/admin/products/form_component.ex`

### External references

- https://hexdocs.pm/ash/relationships.html
- https://hexdocs.pm/ash/manage-relationships.html
- https://hexdocs.pm/ash_phoenix/AshPhoenix.Form.html
- https://hexdocs.pm/ash_postgres/dsl-ashpostgres-datalayer.html
- https://www.postgresql.org/docs/current/indexes-unique.html
- https://www.postgresql.org/docs/current/indexes-partial.html

## DECISIONS / PINS

1. Variant-first sellable identity remains authoritative for catalog/cart/checkout/orders.
2. Signature canonicalization uses IDs, not slugs.
3. Canonical signature order is `product_option.position ASC`, tie-break `product_option.id raw16 ASC`.
4. Signature payload is deterministic `option_id_raw16 <> value_id_raw16` pairs.
5. Signature is computed over required axes and any optional axes present in canonical axis order.
6. Missing required axes is invalid and yields no signature.
7. Missing optional axes is valid.
8. Resolver accepts slugs only for UX input and resolves to IDs before signature matching.
9. Resolver behavior for optional omissions:
   - required axes must be fully selected
   - optional axes may be omitted
   - if exactly one sellable variant matches: resolve it
   - if multiple sellable variants match: return `:selection_ambiguous` (no auto-pick)
10. Sellable completeness validation is required-only:
    - active variant must have exactly one value per required option
    - optional options are not required for sellable status
11. A variant is sellable iff:
    - product is published
    - variant is active
    - required-option completeness is satisfied
12. Active uniqueness is enforced by `(product_id, selection_signature)` partial unique index.
13. Phase 25 uses per-product options only; global reusable option axes are out of scope.
14. Web never resolves variants locally; web parses params -> typed structs -> domain facade.
15. Availability cache invalidation is domain-driven only via explicit API:
    - `Store.Catalog.AvailabilityCache.invalidate_product(product_id)`
16. Invalidation triggers are explicit:
    - successful reservation apply
    - reservation expiry release
    - inventory admin adjustment
    - variant option assignment changes
    - product publish/unpublish
17. Cart stock pre-check is best-effort and fast-path:
    - fastest available layer first (hot cache/ETS first, DB fallback)
    - avoid per-item expensive joins/N+1
    - checkout finalize remains authoritative under concurrency
18. Optional selectors render in stable canonical ordering in storefront UI.
19. Invalid deep-link behavior stays explicit:
    - show validation error state
    - disable add-to-cart until corrected
20. No Phase 26 fields or resources in Phase 25 (`product_kind`, `subscription_plan_id`, subscription domain).

## PREVIOUS/NEXT PHASE BOUNDARY CHECK

### Previous phase (24) protections

- Keep digital link/grant semantics unchanged (`product_id` and `variant_id` links remain valid).
- Do not alter grant issuance/revocation contracts while adding variant option modeling.

### Next phases (26/27) protections

- Do not introduce subscription resources/fields in catalog or checkout in Phase 25.
- Do not introduce variant-plan coupling or renewal logic in Phase 25.

### Anti-creep pins

- No global option axis catalog in this phase.
- No bundle/configurator logic.
- No web-layer `Ash.Query` or direct `Ash.*` in scoped web paths.

## PLAN

1. Add catalog schema/resources for options/values/selections and variant signature/image fields.
2. Implement deterministic resolver + typed query contracts + availability cache seam.
3. Integrate fast best-effort stock pre-check in cart mutations and preserve checkout authority.
4. Add dedicated admin CRUD surfaces for options/values/variants/selections.
5. Update storefront `/shop/:slug` for selector UX and deep-link ambiguity handling.
6. Add governance/docs/registry updates and tests; run `mix check`; close phase beads.

## DONE

- Session-start protocol complete (`bd dolt test`, `bd status`, `bd ready`).
- Repaired accidental bead metadata reuse for Phase 24 and re-closed `store_blueprint-7yf.16`.
- Completed required beads DB push cycle after repair.
- Created Phase 25 parent and child bead set under `store_blueprint-7yf.17`.
- Added dependency graph and claimed `store_blueprint-7yf.17.1`.
- Created this docs-first note before any Phase 25 schema/code edits.

## NEXT

1. Implement Phase 25.2 catalog schema/resources + invariants.
2. Implement resolver/contracts/cache (Phase 25.3).
3. Implement cart/checkout integration, admin/storefront surfaces, and governance/tests.
4. Run full checks and closure protocol.

## BLOCKERS

- `bd dep add` is runtime-permitted only with `--sandbox` in this environment; normal flow commands are used where available.

## COMMANDS RUN

- `bd dolt test`
- `bd status`
- `bd ready`
- `bd create ...` for parent/children under `store_blueprint-7yf.17`
- `bd --sandbox dep add ...` for dependency wiring
- `bd update store_blueprint-7yf.17.1 --claim`
- repair sequence for `store_blueprint-7yf.16`
- beads DB push cycle (`systemctl --user stop/start`, native `dolt push origin main`)

## GATES

- Docs-first note created and pinned before Phase 25 schema/code edits.
- Phase boundaries explicitly documented (24 protected, 26/27 excluded).
- Performance constraints and cache invalidation triggers explicitly pinned.

## PERFORMANCE & SCALING REVIEW

### Hot / warm / cold

- Hot:
  - product detail resolver (`/shop/:slug`)
  - cart add/update stock pre-check
  - checkout finalize reservation authority
- Warm:
  - admin option/variant management reads
  - availability summary cache regeneration
- Cold:
  - historical variant/selection states not on active storefront path

### Query count + N+1 risk

- Resolver and cart pre-check must avoid per-axis/per-item query fan-out.
- Use bounded loads and map lookups in domain surfaces.
- Avoid web-level query composition to prevent drift/N+1.

### Indexes

- Option/slug uniqueness and position indexes for stable selector rendering.
- Selection uniqueness and lookup indexes for resolver performance.
- Active signature uniqueness index for deterministic resolution safety.

### Caching / TTL / invalidation

- ETS hot cache for availability summary (short TTL).
- Explicit invalidation API in domain, called from mutation points.
- Avoid stale cache correctness risk by invalidating on stock/selection/publish changes.

### Idempotency / concurrency

- Cart pre-check is advisory; checkout reservation remains authoritative and replay-safe.
- Reservation consume/expire semantics remain unchanged and deterministic.

### Telemetry / logging

- Add telemetry around resolver outcome (`ok`, `invalid`, `ambiguous`, `oos`) and cache hit/miss.
- Do not log raw selection payloads beyond safe diagnostic metadata.

