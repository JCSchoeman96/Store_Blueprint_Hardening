# Phase 16 — AshPhoenix.Forms: admin CRUD surfaces (P1)

## Goal
Adopt **AshPhoenix.Form** (and **AshPhoenix.FilterForm** where appropriate) for admin CRUD flows so the UI becomes a thin reflection of Ash actions/validations and we avoid parameter drift.

This phase comes **after Phase 15 (web query discipline)** so the web layer is already “thin”. Phase 16 makes the web layer **consistently resource-backed** for writes *and* reads.

## Why this matters (enterprise + blueprint)
- **One source of truth:** Ash actions/validations/policies drive the UX, not ad-hoc controller/LiveView code.
- **Less drift:** when an action changes, the form validation feedback changes automatically.
- **Auditability:** LiveViews submit to resource actions with actor context; no “secret” params.
- **Reusability:** the same patterns are cloned into every client project.

## Scope (start here, don’t overcommit)
Adopt AshPhoenix.Form for **admin-only, rule-heavy, mostly-CRUD** resources first:
- Shipping zones / shipping methods / shipping rates (Phase 13 artifacts)
- Tax rates / tax rules (Phase 13 artifacts)

**Do not start with Orders/Payments admin** yet. Those screens tend to grow “grid + bulk + export” behaviors quickly and will push you into custom flows prematurely.

## Hard rules
### 1) All admin writes must use AshPhoenix.Form
In `lib/store_web/live/admin/**`:
- Do not call `Ash.create/2`, `Ash.update/2`, `Ash.destroy/2` directly from LiveView event handlers.
- Do not build `Ash.Changeset` in LiveView handlers.
- Do not accept raw params and forward them to actions.

Instead:
- build an `AshPhoenix.Form` using `for_create/for_update/for_action`
- validate with `AshPhoenix.Form.validate/3` on `phx-change`
- submit with `AshPhoenix.Form.submit/2` on `phx-submit`

### 2) Actions must be explicit (no “accept :*”)
For resources managed by admin forms:
- create/update actions must explicitly define accepted attributes/arguments
- validations live in the resource DSL, not the LiveView

### 3) Forms must always be actor-aware
All forms must be created with:
- `actor: socket.assigns.current_user` (or equivalent)
- and **never** rely on implicit global actor

(Policies and field visibility must be enforced at the resource/action layer.)

## Canonical folder structure
Keep admin surfaces consistent and predictable:

- `lib/store_web/live/admin/shipping_zones/index_live.ex`
- `lib/store_web/live/admin/shipping_zones/form_component.ex`
- `lib/store_web/live/admin/tax_rates/index_live.ex`
- `lib/store_web/live/admin/tax_rates/form_component.ex`

Design pattern:
- `IndexLive` owns listing + selection state
- `FormComponent` owns the AshPhoenix.Form lifecycle
- Both call **domain interfaces** for reads (Phase 15 rule)

## Canonical LiveView/Form pattern (no code, just the flow)
### Mount
- Load the initial list via a domain read surface, e.g. `Store.Shipping.list_zones_for_admin(query, actor)`
- Initialize `@form` to a create-form or nil (depending on UX)

### New/Edit
- For create: `AshPhoenix.Form.for_create(Resource, :create, ...)`
- For edit: `AshPhoenix.Form.for_update(record, :update, ...)`
- Assign the form into socket assigns and keep it stable through the lifecycle.

### Validate (`phx-change`)
- Call `AshPhoenix.Form.validate(form, params, ...)`
- Reassign the returned form
- Render errors directly from the form

### Submit (`phx-submit`)
- Call `AshPhoenix.Form.submit(form, params: params)`
- On success:
  - refresh the list via domain read surface
  - close modal / clear form state
- On error:
  - reassign returned form (contains error state)

## Filtering/search in admin lists
For simple lists:
- use a typed query struct (Phase 15) and map UI controls into it.

For richer filtering:
- use `AshPhoenix.FilterForm` to build an Ash filter expression, then pass that filter into the domain read surface.

**Do not** embed `Ash.Query.filter` or `Ash.Query.sort` directly in the LiveView.

## Nested editing (avoid until needed)
Shipping and tax often tempt nested forms (zone has many rates). For the blueprint MVP:
- Prefer **separate CRUD pages** per resource:
  - Zones list + zone edit
  - Rates list filtered by zone + rate edit
- Introduce nested forms later only when the UX demands it, using AshPhoenix nested-form helpers.

## Enforcement gates to add (recommended)
Add a new repo-local check (same style as existing checks) that fails if:
- `lib/store_web/live/admin/**` contains `Ash.Query` or direct `Ash.create/update/destroy`
- `lib/store_web/live/admin/**` contains `Ash.Changeset`

Rationale: force the blueprint pattern to stay consistent as surfaces expand.

## Acceptance criteria
This phase is complete when:
1) At least one admin vertical (Shipping or Tax) uses AshPhoenix.Forms end-to-end for create/update.
2) List pages use domain read surfaces (no web query logic).
3) Policies are enforced by actor context, and forbidden actions cannot be submitted.
4) No direct Ash writes exist in `store_web/live/admin/**` for those resources.

## Risks & edge cases
- **Form reuse requirement:** AshPhoenix forms are designed to be reused across the LiveView lifecycle; don’t rebuild them on each event.
- **Tampering:** protect server-side fields via action arguments/private arguments or `before_submit` hooks; do not trust browser params.
- **Pagination:** if lists grow, prefer resource read actions that define pagination + stable sorting rules, and keep pagination params as a typed query struct.
- **Validation drift:** if you see validations duplicated in LiveView, you are doing it wrong.

## References
- AshPhoenix.Form docs: https://hexdocs.pm/ash_phoenix/AshPhoenix.Form.html
- AshPhoenix.FilterForm docs: https://hexdocs.pm/ash_phoenix/AshPhoenix.FilterForm.html
