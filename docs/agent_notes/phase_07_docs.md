# Phase 07 — Error codes + outbound HTTP hardening

## GOAL

Implement enforcement infrastructure for stable, registry-backed error codes and safe outbound HTTP, without broad refactors. Phase 07 must end with a single canonical error envelope at the web boundary, a governed Req wrapper policy, and CI gates preventing drift.

## LINKS CONSULTED

- Project docs:
  - `docs/phases/phase_07_error_codes_http.md`
  - `docs/governance/error_codes.md`
  - `docs/governance/outbound_http.md`
- External docs (HexDocs / primary):
  - https://hexdocs.pm/req/Req.html
  - https://hexdocs.pm/req/Req.Steps.html
  - https://hexdocs.pm/req/changelog.html
  - https://hexdocs.pm/ash/error-handling.html
  - https://hexdocs.pm/ash/authorize-access-to-resources.html

## PLAN

- Keep Phase 07 scope minimal: governance enforcement only.
- Pin Req retries for safe methods to bounded retries + jitter; keep mutating methods non-retrying by default.
- Add one representative real HTTP path (`GET /api/orders/:id`) proving:
  - no actor -> `UNAUTHORIZED` / 401
  - actor + missing order -> `NOT_FOUND` / 404
- Ensure all error responses go through `StoreWeb.ErrorJSON` so Normalize remains the choke point.
- Finish gate evidence and bead/documentation closure.

## DONE

- Req governance hardening:
  - `Store.Support.HTTP.ReqClient` now sets:
    - GET/HEAD defaults: `retry: :safe_transient`, `max_retries: 2`, `retry_delay: &retry_delay_with_jitter/1`.
    - POST/PUT/PATCH/DELETE defaults: `retry: false`.
  - Removed deprecated `:redact_auth` option handling.
  - Added deterministic range tests for jittered delay bounds.
- Representative web round-trip:
  - Added `/api/orders/:id` route.
  - Added `StoreWeb.OrderApiController`.
  - Added `StoreWeb.API.ErrorResponder` so API errors render through `StoreWeb.ErrorJSON` (`error.json`) instead of direct `json/2`.
  - Added controller tests proving canonical envelope/status for:
    - `UNAUTHORIZED` (401)
    - `NOT_FOUND` (404)
- Beads fanout for remaining Phase 07 work:
  - `store_blueprint-7yf.1.8` (Req retry alignment)
  - `store_blueprint-7yf.1.9` (minimal API round-trip)
  - `store_blueprint-7yf.1.10` (bd panic blocker tracking)

## NEXT

- Update bead notes (`GOAL/PLAN/DONE/NEXT/BLOCKERS/COMMANDS RUN/GATES`) for `1.5`, `1.6`, `1.7`, `1.8`, `1.9`, `1.10`.
- Close in order: `1.8` -> `1.5`, `1.9` -> `1.6`, then `1.7`, then parent `1`.
- Run `bd sync`, `git pull --rebase`, `git push`, and verify clean/up-to-date `git status`.

## BLOCKERS

- Intermittent beads CLI panic observed while using list/show in some invocations:
  - tracked as `store_blueprint-7yf.1.10`.
  - current impact: non-blocking for implementation and gate runs.
  - workaround command set: `bd ready`, `bd show`, `bd dep cycles`, `bd sync`, `bd close`.

## GATES

- Error code registry parity + uniqueness:
  - `test/store/support/errors/error_codes_test.exs`
- Error normalization choke point:
  - `lib/store/support/errors/normalize.ex`
  - `lib/store_web/controllers/error_json.ex`
  - `test/store/support/errors/normalize_test.exs`
  - `test/store_web/controllers/error_json_test.exs`
- Req wrapper policy:
  - `lib/store/support/http/req_client.ex`
  - `test/store/support/http/req_client_test.exs`
- Req denylist gate:
  - `lib/mix/tasks/check/req_usage.ex`
  - wired in `mix.exs` alias `check`
  - manual proof completed:
    - inserted temporary forbidden `Req` reference in web controller -> `mix check.req_usage` failed
    - removed temporary reference -> `mix check.req_usage` passed
- Representative HTTP boundary proof:
  - `test/store_web/controllers/order_api_controller_test.exs`

## COMMANDS RUN

- `bd prime --json`
- `bd ready --json`
- `bd create ...` (for `1.8`, `1.9`, `1.10`)
- `bd dep add ...`
- `bd dep cycles`
- `mix format`
- `mix test test/store/support/http/req_client_test.exs test/store_web/controllers/order_api_controller_test.exs test/store_web/controllers/error_json_test.exs`
- `mix check.req_usage` (intentional fail + pass verification)
- `mix check`
