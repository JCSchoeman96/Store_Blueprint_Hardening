# Phase 18 - Ash code interfaces and write surfaces

## GOAL

Implement a strict Ash 3.x interface spine with dedicated facade modules, typed query/input contracts, and enforceable web-boundary gates so `lib/store_web/**` remains an adapter-only layer.

## LINKS CONSULTED

- Project docs:
  - `docs/phases/phase_18_ash_code_interfaces_and_write_surfaces.md`
  - `docs/governance/enforcement_gates.md`
  - `docs/governance/side_effects_quarantine.md`
  - `docs/governance/policy_matrix.md`
  - `docs/governance/performance_scaling.md`
  - `docs/phases/phase_29_performance_architecture_optimizations.md`
  - `AGENTS.md`
- Existing implementation files:
  - `lib/store/orders/domain.ex`
  - `lib/store/payments/domain.ex`
  - `lib/store/pricing/domain.ex`
  - `lib/store_web/controllers/webhook_controller.ex`
  - `lib/store_web/controllers/payment_callback_controller.ex`
  - `lib/mix/tasks/check/web_no_ash_query.ex`
  - `lib/mix/tasks/check/admin_live_no_direct_ash.ex`
- External references (Ash 3.x):
  - https://hexdocs.pm/ash/code-interfaces.html
  - https://hexdocs.pm/ash/read-actions.html
  - https://hexdocs.pm/ash/actions.html
  - https://hexdocs.pm/ash/actors-and-authorization.html
  - https://hexdocs.pm/ash_phoenix/AshPhoenix.Form.html

## DECISION PINS

1. Ash domains remain `Store.Orders`, `Store.Payments`, `Store.Pricing`.
2. Dedicated facade modules are introduced:
   - `Store.Orders.Facade`
   - `Store.Payments.Facade`
   - `Store.Pricing.Facade`
3. `check.web_no_direct_ash_calls` scope is `lib/store_web/**/*.{ex,exs}` and denies only:
   - `Ash.read/read!`
   - `Ash.create/create!`
   - `Ash.update/update!`
   - `Ash.destroy/destroy!`
4. `check.web_no_direct_ash_calls` does not deny `Ash.Changeset` references.
5. Unknown-key rejection is mandatory in both layers:
   - web params adapters (query/filter adapters) -> `VALIDATION_ERROR`
   - domain query/input structs `new/1` -> `{:error, ...}`
6. `check.surface_naming` is registry-driven:
   - source of truth: `Store.Support.Governance.SurfaceRegistry`
   - checks only exported functions on facade modules, no heuristics.
7. Webhook and callback controllers remain verify/normalize + receipt ingest + enqueue-only.
   - No state transitions, outbound HTTP, or business transitions in controllers.
8. Facade naming is consumer-scoped only (`for_user`, `for_admin`, `for_support` as authorized).
   - `for_api` facade naming is prohibited.

## PLAN

1. Add/update typed contracts for orders/payments + webhook receipt ingest input.
2. Add/align resource actions and `code_interface` entries backing facade operations.
3. Implement dedicated facade modules and migrate callers to facade surfaces.
4. Refactor webhook/callback controllers and webhook workers to use payments facade.
5. Add `SurfaceRegistry`, `check.web_no_direct_ash_calls`, and `check.surface_naming`.
6. Add governance tests for new gates and contract/boundary tests.
7. Run `mix check`, then complete closure protocol and bead updates.

## DONE

- Docs-first phase note created before implementation edits.
- Decision pins and sequencing constraints are recorded.
- Phase 18 bead tree created with dependencies and docs-first bead claimed.
- Added dedicated facade modules:
  - `Store.Orders.Facade`
  - `Store.Payments.Facade`
  - `Store.Pricing.Facade`
- Added typed contracts:
  - `Store.Orders.Queries.OrderIndexQuery`
  - `Store.Orders.Queries.OrderShowQuery`
  - `Store.Payments.Queries.PaymentIntentIndexQuery`
  - `Store.Payments.Queries.PaymentIntentShowQuery`
  - `Store.Payments.Inputs.WebhookReceiptIngestInput`
- Added web params adapters for orders/payments contracts and tightened admin pricing adapters to strict unknown-key rejection.
- Added code interfaces on:
  - `Store.Orders.Order`
  - `Store.Payments.PaymentIntent`
  - `Store.Payments.WebhookReceipt`
  - `Store.Pricing.ShippingZone`
  - `Store.Pricing.ShippingRate`
  - `Store.Pricing.TaxRate`
- Refactored webhook/callback controllers to ingest receipts via `Store.Payments.Facade`.
- Refactored webhook workers to fetch/process receipts via facade functions.
- Added governance registry:
  - `Store.Support.Governance.SurfaceRegistry`
- Added and wired new gates:
  - `check.web_no_direct_ash_calls`
  - `check.surface_naming`
- Added governance + contract tests for Phase 18 surfaces and gates.
- `mix check` passes after Phase 18 changes.

## NEXT

1. Close/bead-by-bead bookkeeping updates and final bead closure reasons.
2. Proceed to next phase implementation work.

## BLOCKERS

- None at the code level.
- Operational note: direct `bd dep add` required `--sandbox` in this environment due runtime policy behavior.

## COMMANDS RUN

- `bd dolt test`
- `bd status`
- `bd ready`
- `bd create ...` (phase 18 parent + children)
- `bd --sandbox dep add ...` (dependency wiring)
- `bd update store_blueprint-7yf.10.2 --claim`
- `rg` / `sed` exploration across `lib/`, `test/`, and `docs/`
- `mix compile --warnings-as-errors`
- `mix test test/store/contracts/phase_18_contracts_test.exs test/store/governance/web_no_direct_ash_calls_test.exs test/store/governance/surface_naming_test.exs`
- `mix check`

## GATES

- Docs-first requirement satisfied prior to implementation code mutations.
- Bead claimed before implementation work.
- Phase 18 gates implemented and active:
  - `check.web_no_direct_ash_calls`
  - `check.surface_naming`

## PERFORMANCE & SCALING REVIEW

- Hot paths:
  - webhook ingest + worker processing
  - admin pricing list reads and CRUD follow-up reads
  - customer/admin order/payment list/get surfaces
- Query count / N+1:
  - list/get semantics remain in resource actions to keep load/sort/pagination deterministic.
  - facade modules do not add per-record query loops.
- Indexes:
  - existing indexes on orders/payment_intents/webhook_receipts/pricing tables are reused.
  - no new index required unless a new read action introduces a new lookup pattern.
- Caching:
  - no cache layer changes in this phase.
- Oban/idempotency:
  - callback/webhook controllers stay enqueue-only.
  - worker idempotency behavior remains domain-governed.
- Telemetry/logging:
  - gate failures provide file/line output.
  - no additional telemetry contract introduced in this phase.
