# Phase 15 — Ash interface refactor: web query discipline (P0)

## Goal
Move all *authorization-meaningful* querying logic out of `StoreWeb` and into explicit Ash resource actions + domain interfaces.

This phase is a **prerequisite** for Phase 16+ (catalog + storefront + checkout UX). If we expand product surfaces while `StoreWeb` still builds queries directly, the blueprint will drift and become non-auditable.

## What “off ad-hoc Ash.Query in web” means
### Hard rule
`lib/store_web/**` must not contain:
- `require Ash.Query`
- `Ash.Query.*` (filter/sort/load/limit/offset)
- direct `Ash.read(query, ...)` where the query is built inline in web

### Allowed in web
- parameter parsing + normalization
- calling a **domain surface function** (interface) or a **resource code interface**
- rendering

### Why this matters (enterprise reality)
When web builds queries directly, it silently decides:
- scoping
- preload/load shape
- limits/sorts
- policy-sensitive filters

That creates “policy drift” across controllers/liveviews and is extremely hard to audit.

## Deliverables
1. **Domain read surfaces** for each consumer type:
   - `*_for_public` (anonymous)
   - `*_for_user` (customer)
   - `*_for_admin` (backoffice)

2. **Typed query contracts** (structs) for any non-trivial read surface.

3. **Web param modules** that convert params → query contract struct.

4. **Enforcement gate**: fail `mix check` if `StoreWeb` contains `Ash.Query` usage.

## Canonical design
### 1) Resource read actions (Ash is the truth)
For each “read surface”, define a named read action on the resource (or a resource-backed query module) that:
- accepts arguments (not raw params)
- applies filters using `expr(^arg(:...))`
- sets sort/limit defaults
- constrains loads/preloads

This keeps the query semantics close to the resource and policy.

### 2) Domain interface functions (the only entrypoint)
Expose functions in the domain module (or a dedicated `Queries/` module) that:
- accept `(actor, query_struct)` or `(query_struct, actor)` consistently
- call the resource action via Ash code interface / domain API
- return a *stable result shape* (e.g. `{:ok, result}` / `{:error, error}`)

### 3) Web param parsing (thin adapters)
For each surface, define a web module that:
- validates + normalizes params
- produces the domain query struct
- never calls `Ash.Query`

## Concrete refactors required now (current violations)
### A) `lib/store_web/controllers/order_api_controller.ex`
**Today:** builds a query inline using `Ash.Query.filter(expr(id == ^id))`.

**Refactor target:**
- Create a resource read action on `Store.Orders.Order` for “read-by-id for api/user”.
- Expose a domain interface like `Store.Orders.fetch_order_for_api/2` (or similar) that accepts `(id, actor)` and returns `{:ok, order | nil}`.
- Controller becomes:
  - auth/actor check
  - call domain interface
  - render

### B) `lib/store_web/live/admin_live.ex`
**Today:** builds a query inline using `Ash.Query.sort/limit`.

**Refactor target:**
- Create a resource read action on `Store.Admin.AuditLog` for “recent audit entries for admin”.
- Expose a domain interface like `Store.Admin.recent_audit_logs/2` that accepts `(actor, limit)`.
- LiveView becomes:
  - role check
  - call domain interface
  - render

## Enforcement gates
Add a gate (new or extended) that fails if `Ash.Query` appears in `lib/store_web/**`.

Recommended implementation approach:
- implement as a `mix check.*` task (consistent with existing gates)
- scan only `lib/store_web/**`
- deny patterns:
  - `require Ash.Query`
  - `Ash.Query.`

Allowlist should be **empty** in this blueprint.

## Acceptance gates (must pass)
1. `mix check` fails if any `Ash.Query` usage exists in `lib/store_web/**`.
2. All read paths that were previously built in web are now performed through:
   - resource read action + domain interface
3. Controller/LiveView logic contains no query semantics beyond param normalization.
4. Policies still apply (actor passed through, no `authorize?: false`).

## Edge cases & risk review
- **Over-abstracting query flexibility:**
  Avoid building a custom “mini query DSL”. Use typed query structs with a *small* set of vetted fields.

- **Pagination drift:**
  Standardize page inputs (limit, cursor/offset) in query structs early, even if Phase 15 only uses fixed limits.

- **Load/preload explosions:**
  Resource read actions must define load shape explicitly; web must not decide.

- **Auth drift:**
  Never re-encode authorization rules in web. Web may redirect/deny, but the resource policy remains source of truth.

## Notes
- This phase is intentionally small: it proves the pattern on two existing offenders.
- Phase 16+ will use the same pattern for Catalog + Storefront read surfaces.
