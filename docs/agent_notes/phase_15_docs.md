# Phase 15 - Ash interfaces and web query discipline

## GOAL

Move authorization-meaningful query semantics out of `lib/store_web/**` and into explicit Ash read actions + typed interfaces so read behavior is auditable, policy-safe, and reusable for Phase 16+ surfaces.

## LINKS CONSULTED

- Project docs:
  - `docs/phases/phase_15_ash_interfaces_web_query_discipline.md`
  - `docs/governance/enforcement_gates.md`
  - `docs/governance/side_effects_quarantine.md`
  - `docs/governance/policy_matrix.md`
  - `docs/governance/route_inventory.md`
  - `docs/agent_notes/phase_14_docs.md`
- External references:
  - https://hexdocs.pm/ash/read-actions.html
  - https://hexdocs.pm/ash/code-interfaces.html
  - https://hexdocs.pm/ash/Ash.Query.html
  - https://hexdocs.pm/ash_phoenix/AshPhoenix.FilterForm.html

## WHAT DOCS RECOMMEND NOW

- Put query semantics (filters, sort, limits, load shape) in resource actions, not web endpoints.
- Expose narrow domain interfaces over raw query composition.
- Keep web surfaces as adapters: parse params, call interface, render.
- Enforce architecture invariants in `mix check` to prevent drift.

## DECISIONS TAKEN (PINS)

- Add explicit read actions:
  - `Store.Orders.Order` read action for API id fetch.
  - `Store.Admin.AuditLog` read action for recent admin entries.
- Add hybrid interface surface:
  - Ash `code_interface` definitions on resources.
  - Domain wrapper functions as stable entrypoints for web.
- Add typed query contracts with constructor validation:
  - `OrderForApiQuery.new/1`
  - `RecentAuditLogsQuery.new/1`
- API contract for `GET /api/orders/:id`:
  - missing actor -> `401 UNAUTHORIZED`
  - malformed id -> `400 VALIDATION_ERROR`
  - not found -> `404 NOT_FOUND`
  - unexpected -> `500 INTERNAL_ERROR`
- Gate scope for web Ash query discipline:
  - apply to `lib/store_web/controllers/**`, `lib/store_web/live/**`, `lib/store_web/components/**`
  - deny `require Ash.Query` and `Ash.Query.`
  - do not expand to broader Ash APIs in this phase.
- Keep `Store.Admin.AuditLog` naming unchanged in Phase 15 to avoid scope creep.

## PLAN

1. Add typed query contract modules and web param adapter modules.
2. Add read actions + `code_interface` definitions on `Order` and `AuditLog`.
3. Add domain wrapper functions for those read paths.
4. Refactor `OrderApiController` and `AdminLive` to call typed interfaces only.
5. Add `mix check.web_no_ash_query` task and wire into `mix check`.
6. Add mandatory governance test for gate behavior and alias wiring.
7. Run `mix check` and complete closure protocol.

## DONE

- Reviewed phase/governance docs and pinned implementation contracts and gate scope.
- Added `Order` and `AuditLog` read actions plus `code_interface` definitions.
- Added strict typed query contracts and web param adapters.
- Refactored `OrderApiController` and `AdminLive` to call typed domain interfaces only.
- Added `check.web_no_ash_query` gate and wired it into `mix check`.
- Added mandatory governance regression test and expanded order API behavior tests.
- Passed `mix check` with the new phase gates and tests.

## NEXT

- Proceed to Phase 16 implementation surfaces using this query-discipline pattern.

## BLOCKERS

- None.

## COMMANDS RUN

- `bd dolt test`
- `bd status`
- `bd ready`
- `bd create ...` (Phase 15 parent and child beads)
- `bd dep add ...`
- `bd dep cycles`
- `bd update store_blueprint-7yf.7.3 --claim`
- `rg ...` and `sed -n ...` exploration for current violations and gates

## GATES

- Docs-first Phase 15 note created before code/test/config edits.
- Bead claimed before mutation.

## PERFORMANCE REVIEW

- Hot path:
  - `GET /api/orders/:id` owner/admin/support reads through action/interface path.
- Warm path:
  - `/admin` recent audit-log retrieval with deterministic sort and bounded limit.
- Cold path:
  - governance gate scans in `mix check`.
- Indexes:
  - Reuse existing `orders` PK lookup and `audit_logs_inserted_at_index`; no new DB index required in this phase.
- TTL:
  - no TTL behavior introduced.
- Invalidation:
  - no cache invalidation introduced.
- PubSub:
  - no PubSub changes introduced.
