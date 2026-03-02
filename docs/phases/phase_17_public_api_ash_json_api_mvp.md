# Phase 17 — Public API surface via `ash_json_api` (MVP, read-first)

## Goal
Add **exactly one** public API layer using **AshJsonApi** and expose a **thin, auditable** MVP surface.

This phase is about:
- leveraging Ash’s resource/action model as the **single source of truth**
- producing a stable external surface for clients (mobile, backoffice tools, integrations)
- avoiding “controller DSL drift” by **not** building bespoke controllers for reads

This phase is **read-first**: we expose only vetted read actions for Orders/Payments.

## Why `ash_json_api` (and not GraphQL first)
For this blueprint, the priority is **constrained surfaces** and **auditability**.

- JSON:API tends to keep the surface area explicit (routes are configured per action).
- It aligns well with caching/proxying and contract workflows.
- It avoids the “just query it” temptation that can sprawl a GraphQL surface.

GraphQL may be added later, but not before the core store is operational.

## Non‑negotiables (enterprise rules)
1. **One API extension only** (for now): `ash_json_api`.
2. **No duplication of business logic**: API must call **resource actions** and **policies**.
3. **No write endpoints** in MVP (except auth/token if you explicitly add it later).
4. **No raw parameter → Ash.Query mapping** in web.
   - API input must map to **typed query contracts** or AshJsonApi’s vetted filter support.
5. **Policies remain the security boundary**.
   - Never use `authorize?: false` to “make the API work”.

## Deliverables
1. Add dependency: `:ash_json_api`.
2. Add AshJsonApi extension to the relevant domains/resources.
3. Define a dedicated JSON:API router module.
4. Forward a versioned API scope from the Phoenix router.
5. Expose a minimal set of read routes:
   - Orders: `read_for_user`, `read_for_admin`, and `get_for_user` (by id)
   - Payments: `read_for_admin` and `get_for_admin` (by id)
6. Add OpenAPI + JSON schema endpoints (optional but recommended for enterprise tooling).
7. Add enforcement gates:
   - “No GraphQL deps” while JSON:API is the chosen surface
   - “No custom controllers for read endpoints” (prefer forward router)

## Recommended route layout
- Phoenix router scope:
  - `/api/v1/json` (or `/api/v1` if you only run JSON:API)
- AshJsonApi router:
  - forwards resources for the selected domains
- Optional docs endpoints:
  - `/api/v1/open_api`
  - `/api/v1/json_schema`

## Implementation outline (high-level, no over-engineering)
### 1) Dependency
Add `{:ash_json_api, "~> 1.5"}` to `mix.exs`.

### 2) Router module
Create `lib/store_web/json_api_router.ex`:
- `use AshJsonApi.Router, domains: [...]`
- enable `json_schema` and `open_api` routes if desired

### 3) Forward from Phoenix router
In `lib/store_web/router.ex`, under an `:api` pipeline:
- `forward "/v1", StoreWeb.JsonApiRouter`

Keep it versioned from day one.

### 4) Resource exposure (MVP)
Expose only vetted read actions.

**Rule:** do not expose the “default read”.
Always expose named actions that encode:
- scope (admin vs user)
- load shape
- default sort
- allowed filters/arguments

This keeps your external surface stable and prevents accidental data leakage.

## Security & actor loading
MVP can support either:
- session-cookie auth (if same-origin client)
- bearer token auth (recommended for external consumers)

**Blueprint direction:** bearer token.

Key requirements:
- the API pipeline must load actor (e.g., via AshAuthentication token strategy)
- the actor must be attached to the request context
- all resource actions must remain policy-protected

If actor loading is not present yet, keep the API private/internal until it is.

## Filtering, sorting, pagination (don’t recreate a query DSL)
### Default stance
- Keep filtering minimal in MVP.
- Prefer a small set of explicit action arguments over “free-form filters”.

### Allowed (MVP)
- cursor/limit pagination
- simple whitelisted filters (status, inserted_at window)

### Forbidden (MVP)
- arbitrary relationship filters
- arbitrary includes/loads
- client-defined sorts across relationship fields

If you need richer search later:
- add *new named actions* and keep them scoped.

## OpenAPI: production-ready approach
If you expose `/open_api`, do **not** generate it dynamically in production.

Recommended:
- generate dynamically in dev
- serve a pre-generated file in prod (stored in `priv/static/open_api.json`)

This avoids runtime overhead and keeps the spec stable for clients.

## Enforcement gates (add in `mix check`)
Add a gate that fails if:
- `ash_graphql` is added as a dep while JSON:API is the chosen surface
- custom read controllers are created under `StoreWeb` for resources that are exposed via the JSON:API router

## Acceptance criteria
1. Requests to `/api/v1/...` are served by `StoreWeb.JsonApiRouter`.
2. Only named read actions are exposed (no default read).
3. Policies apply consistently (no `authorize?: false`).
4. No controller contains query-building logic for these reads.
5. OpenAPI and/or JSON schema endpoints are reachable (if enabled).
6. `mix check` includes enforcement gates for “one API surface only”.

## Edge cases & risk review
- **Surface sprawl:**
  Do not expose write actions “just because it’s easy.” Keep MVP read-only.

- **Auth confusion:**
  If you mix session and bearer, you will get inconsistent actor behavior. Pick one.

- **Over-flexible filtering:**
  Free-form filtering becomes an accidental query language. Keep it explicit.

- **Schema drift:**
  OpenAPI must be generated from the resource/action truth, not handwritten.

## Notes
- This phase intentionally prioritizes stability over breadth.
- After the storefront is operational, expand the API surface in small increments.
