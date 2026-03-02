# Phase 16 - AshPhoenix.Forms admin CRUD surfaces

## GOAL

Implement admin CRUD for `ShippingZone`, `ShippingRate`, and `TaxRate` using `AshPhoenix.Form` so admin writes are action-backed, actor-aware, and policy-enforced, while list reads stay on typed domain surfaces.

## LINKS CONSULTED

- Project docs:
  - `docs/phases/phase_16_ash_phoenix_forms_admin_crud.md`
  - `docs/phases/phase_15_ash_interfaces_web_query_discipline.md`
  - `docs/governance/enforcement_gates.md`
  - `docs/governance/policy_matrix.md`
  - `docs/governance/step_up.md`
  - `docs/governance/route_inventory.md`
  - `docs/agent_rules/phoenix_guidelines.md`
  - `docs/agent_notes/phase_15_docs.md`
- External references:
  - https://hexdocs.pm/ash_phoenix/AshPhoenix.Form.html
  - https://hexdocs.pm/ash_phoenix/AshPhoenix.FilterForm.html
  - https://hexdocs.pm/ash/actions.html
  - https://hexdocs.pm/ash/policies.html

## WHAT DOCS RECOMMEND NOW

- Use `AshPhoenix.Form.for_create/for_update` + `validate` + `submit` lifecycle in LiveView and keep form state stable across events.
- Keep web thin: parse params and call domain interfaces; do not build ad-hoc query semantics in LiveView/controller code.
- Keep writes policy-first at Ash resource actions with actor context; avoid implicit auth behavior.
- Add mix gates that enforce non-negotiable architecture rules in CI (`mix check`).

## DECISIONS TAKEN (PINS)

- Phase 16 resource scope is pinned to existing pricing artifacts:
  - `Store.Pricing.ShippingZone`
  - `Store.Pricing.ShippingRate`
  - `Store.Pricing.TaxRate`
- Admin pricing writes are money-sensitive and now require:
  - `RoleWithStepUp` roles `[:super_admin, :admin]`
  - step-up window `15` minutes
- Read discipline pin:
  - action-defined sort only (`inserted_at DESC`, `id ASC`)
  - query contracts expose clamped `limit` only; no user sort controls
- Admin CRUD skeleton pin:
  - `IndexLive` owns listing/selection/route mode and streams
  - `FormComponent` owns `AshPhoenix.Form` lifecycle
- Gate pin:
  - new scoped gate for `lib/store_web/live/admin/**` using AST call-site detection
  - deny direct `Ash.create/read/update/destroy`, `Ash.Changeset`, `Ash.Query`
  - avoid false positives on comments/docstrings
- Step-up UX is not fully built in Phase 16:
  - forms pass step-up context when present
  - missing/stale context correctly returns `STEP_UP_REQUIRED`

## PLAN

1. Add governance doc updates for step-up-sensitive pricing writes and new admin gate.
2. Add pricing query contracts and domain read surfaces for admin lists/show.
3. Tighten pricing resource policies for step-up-required writes.
4. Implement admin routes + LiveViews/components for shipping zones/rates/tax rates with `AshPhoenix.Form`.
5. Add AST-based admin gate and wire into `mix check`.
6. Add governance, contract, policy, and LiveView tests.
7. Run `mix check` and complete closure protocol.

## DONE

- Created Phase 16 docs-first note with pinned decisions and implementation plan.

## NEXT

- Implement pricing query contracts, read surfaces, policies, admin LiveViews, gate, and tests.

## BLOCKERS

- `bd dep add` and `bd dep cycles` commands are rejected by the current runtime policy in this session, so dependency linking must be retried when policy permits.

## COMMANDS RUN

- `bd dolt test`
- `bd status`
- `bd ready`
- `bd create ...` for `store_blueprint-7yf.8` and child beads
- `bd update store_blueprint-7yf.8.1 --claim`
- `git status -sb`

## GATES

- Docs-first note created before implementation edits.
- Claimed bead exists before repository mutations.

## PERFORMANCE REVIEW

- Hot path:
  - admin create/update of shipping/tax records through Ash actions + policy checks.
- Warm path:
  - admin list reads for zones/rates/tax rates with bounded limit and pinned sort.
- Cold path:
  - architecture gate scans (`mix check`) and governance test assertions.
- Indexes:
  - reuse existing pricing indexes:
    - `shipping_zones_active_index`
    - `shipping_zones_country_region_index`
    - `shipping_rates_currency_active_index`
    - `shipping_rates_window_index`
    - `shipping_rates_shipping_zone_id_index`
    - `tax_rates_country_region_index`
    - `tax_rates_active_index`
    - `tax_rates_window_index`
- TTL:
  - no TTL introduced in Phase 16.
- Invalidation:
  - no cache invalidation behavior introduced in Phase 16.
- PubSub:
  - no PubSub behavior introduced in Phase 16.
