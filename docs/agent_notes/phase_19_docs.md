# Phase 19 - Catalog simple products (variant-first identity)

## GOAL

Implement Phase 19 catalog surfaces with variant-first sellable identity, strict publish semantics, slug/SKU invariants, and web-boundary-safe storefront/admin flows.

## LINKS CONSULTED

- `AGENTS.md`
- `docs/phases/phase_19_catalog_simple_products.md`
- `docs/phases/phase_20_storefront_cart_ux.md`
- `docs/phases/phase_25_variable_products_variants.md`
- `docs/governance/policy_matrix.md`
- `docs/governance/route_inventory.md`
- `docs/governance/enforcement_gates.md`
- `docs/governance/inventory_reservations.md`
- `docs/governance/performance_scaling.md`
- `docs/phases/phase_29_performance_architecture_optimizations.md`
- `lib/store/catalog/domain.ex`
- `lib/store/catalog/inventory_item.ex`
- `lib/store/orders/domain.ex`
- `lib/store/orders/inventory_reservations.ex`
- `lib/store/support/governance/surface_registry.ex`
- `lib/mix/tasks/check/surface_naming.ex`
- `test/store/governance/policy_matrix_test.exs`
- `test/store/governance/surface_naming_test.exs`

External references:
- https://hexdocs.pm/ash/code-interfaces.html
- https://hexdocs.pm/ash/policies.html
- https://hexdocs.pm/ash_state_machine/get-started-with-ash-state-machine.html
- https://www.postgresql.org/docs/current/indexes-unique.html

## DECISIONS/PINS

1. Identity law: inventory and reservations stay `variant_id` based.
2. Simple product law: each Product must have exactly one default/base Variant in Phase 19.
3. Product create action must atomically create Product + base Variant + InventoryItem and set `products.default_variant_id`.
4. Publish semantics:
   - storefront visibility: `status == :published` and `published_at != nil`.
   - publish sets `published_at`; unpublish clears it.
   - archive is terminal.
5. Slug law: product slug is required, lowercase URL-safe, unique, storefront detail resolves by slug.
6. SKU law: variant SKU is required and unique in Phase 19 (no nullable SKU path).
7. Cart normalization boundary:
   - accepts `product_id` or `variant_id`.
   - normalizes to `variant_id` only.
   - mismatched dual inputs fail with `VALIDATION_ERROR`.
8. Scope boundary:
   - no hold/reservation/availability enforcement in Phase 19 cart handoff.
   - no stock messaging in storefront UI.
9. Surface naming gate update is additive:
   - `_for_public` allowed only for `Store.Catalog.Facade`.
   - existing facade suffix constraints remain unchanged.
10. `products.default_variant_id` DB FK is deferred so Product + base Variant + assignment can be committed atomically in one transaction while keeping `NOT NULL` + referential integrity guarantees.

## PLAN

1. Docs-first updates for phase/governance notes and route canonicalization.
2. Add migration and resources:
   - Product, Variant, Category, ProductImage.
   - base-variant and default-variant invariants.
3. Extend catalog domain/facade/contracts/params for storefront/admin reads.
4. Add cart-line normalization input and downstream compatibility updates.
5. Add `/shop` and `/shop/:slug` public LiveViews and minimal admin catalog surfaces.
6. Add additive gate logic/tests for catalog-only `*_for_public`.
7. Update governance tests (including policy-matrix deferred resource check).
8. Run `mix check`.

## DONE

- Created phase docs note.
- Updated:
  - `docs/phases/phase_19_catalog_simple_products.md`
  - `docs/governance/policy_matrix.md`
  - `docs/governance/route_inventory.md`
- Pinned variant-first identity and publish/slug/SKU semantics before code changes.

## NEXT

1. Implement schema/resources and atomic create flow.
2. Implement facade/contracts and normalization boundary.
3. Implement storefront/admin minimal web surfaces.
4. Implement gate refinements and regression tests.
5. Run full `mix check` and closure protocol.

## BLOCKERS

- None currently.

## COMMANDS RUN

- `bd dolt test`
- `bd status`
- `bd ready`
- `bd --sandbox create ...`
- `bd --sandbox dep add ...`
- `bd --sandbox update store_blueprint-7yf.11.1 --claim`
- `rg ...`
- `sed ...`

## GATES

- Docs-first requirement satisfied before implementation edits.
- Bead claimed before repo code mutations.

## PERFORMANCE & SCALING REVIEW

- Hot paths touched:
  - `/shop` list and `/shop/:slug` detail reads.
  - admin product/catalog list/detail reads.
- Query/load rules:
  - paginated storefront list.
  - product detail loads product + base variant + images only.
  - avoid deep recursive relationship loads.
- Indexes pinned:
  - `products.slug`, `products.status`, `variants.sku`, `variants.product_id`, default-variant partial unique, `product_images(product_id, position)`.
- Caching:
  - no new cache implementation in this phase; keep cache-ready read surfaces.
- Idempotency/concurrency:
  - no new hold/reservation semantics introduced in this phase.
- Telemetry:
  - no new telemetry contract introduced in phase implementation scope.
