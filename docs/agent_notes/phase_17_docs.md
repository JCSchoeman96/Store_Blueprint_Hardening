# Phase 17 - Public API surface via ash_json_api (MVP)

## GOAL

Implement a read-first, versioned `/api/v1` public API using `ash_json_api` only, with constrained route semantics, policy-bound authorization, JSON:API media-type support, and governance gates that prevent API surface drift.

## LINKS CONSULTED

- Project docs:
  - `docs/phases/phase_17_public_api_ash_json_api_mvp.md`
  - `docs/governance/enforcement_gates.md`
  - `docs/governance/route_inventory.md`
  - `docs/governance/policy_matrix.md`
  - `docs/governance/error_codes.md`
  - `docs/governance/performance_scaling.md`
  - `docs/phases/phase_29_performance_architecture_optimizations.md`
- External references:
  - `deps/ash_json_api/documentation/tutorials/getting-started-with-ash-json-api.md`
  - `deps/ash_json_api/documentation/dsls/DSL-AshJsonApi.Resource.md`
  - `deps/ash_json_api/documentation/dsls/DSL-AshJsonApi.Domain.md`
  - `deps/ash_json_api/documentation/topics/open-api.md`
  - `deps/ash_json_api/documentation/topics/authenticate-with-json-api.md`
  - `deps/ash_json_api/lib/ash_json_api/router.ex`

## DECISIONS / PINS

- API routing:
  - keep webhook/callback controllers under `/api/**`
  - expose JSON:API at `/api/v1/**` only via `forward "/v1", StoreWeb.JsonApiRouter`
- Auth actor proof:
  - existing `pipeline :api` (`load_from_bearer` + `set_actor, :user`) is reused for `/api/v1`
  - `StoreWeb.JsonApiRouter.before_dispatch/2` enforces 401 when actor is missing
- Media type pin:
  - support `application/vnd.api+json` via MIME mapping and router accepts list (`["json", "jsonapi"]`)
- Surface constraints:
  - route-level `derive_filter?: false` and `derive_sort?: false` on every exposed route
  - resource-level `derive_filter? false`, `derive_sort? false`, `includes []`
  - no relationship routes in Phase 17
- Action pins:
  - Orders: `read_for_user`, `get_for_user`, `read_for_admin`, `get_for_admin`
  - Payments: `read_for_admin`, `get_for_admin`
  - remove legacy `Order :for_api` when legacy controller route is removed
- Sort/pagination pins:
  - deterministic default sort: `inserted_at DESC, id DESC`
  - bounded pagination: default limit 20, max page size 50
- OpenAPI/schema visibility:
  - admin-only for `/api/v1/open_api` and `/api/v1/json_schema` via `before_dispatch`
- OpenAPI production pin:
  - use `open_api_file: "priv/static/open_api.json"` in prod only

## PLAN

1. Add `ash_json_api` + `open_api_spex` deps and JSON:API media type config.
2. Add `StoreWeb.JsonApiRouter` and route forward under existing `/api` scope.
3. Add AshJsonApi domain/resource extensions and constrained routes/actions for Orders/Payments.
4. Remove legacy order API controller/params/query contract path.
5. Add governance gates:
   - `check.no_ash_graphql_dep`
   - `check.api_v1_forward_only`
6. Add integration and governance tests for media type, auth/policy, constraints, and gates.
7. Update governance/route docs and run `mix check`.

## DONE

- Docs-first note created with pinned implementation decisions and governance alignment.

## NEXT

- Complete implementation, run full `mix check`, then execute closure protocol and bead closures.

## BLOCKERS

- None.

## COMMANDS RUN

- `bd dolt test`
- `bd status`
- `bd ready`
- `bd update store_blueprint-7yf.9 --claim`
- `git status -sb`
- `mix deps.get`
- targeted `rg`/`sed` inspections across `lib/`, `test/`, `config/`, `docs/`, and `deps/ash_json_api/`

## GATES

- Session bootstrap gate satisfied.
- No web-layer query semantics introduced; `/api/v1` is forward-only by design.
- New governance gates are part of `mix check`.

## PERFORMANCE & SCALING REVIEW

- Hot paths:
  - `GET /api/v1/orders`
  - `GET /api/v1/admin/orders`
  - `GET /api/v1/admin/payment-intents`
- Warm paths:
  - `GET /api/v1/open_api`
  - `GET /api/v1/json_schema`
- Cold paths:
  - static gate scans (`mix check.*`)
- Query + N+1:
  - list/read actions are constrained and paginated
  - includes disabled in MVP, reducing relationship-driven N+1 risk
- Indexes:
  - existing `orders_user_id_index`, `orders_state_index`, `payment_intents_state_index`, `payment_intents_order_id_index` support primary read shapes
- Caching:
  - no new cache introduced for MVP reads
  - OpenAPI static file in prod avoids repeated runtime spec generation
- Oban/idempotency:
  - no new queue writes introduced in this phase
- Telemetry/logging:
  - JSON:API dispatch is centralized in router with deterministic auth/error handling for docs + auth boundary
