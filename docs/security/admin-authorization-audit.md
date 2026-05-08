# Admin Authorization Audit (Phase 2D)

Last updated: 2026-05-07 (Phase 3D follow-up)
Owner: Phase 2D (Admin Auth Audit)
Status: Completed with minimal fix

## Scope

Audit `/admin/**` authorization depth and determine whether protections are admin-role enforced or login-only.

## Evidence consulted

- `AGENTS.md`
- `docs/stabilization/source-of-truth.md`
- `lib/store_web/router.ex`
- `lib/store_web/live_user_auth.ex`
- `lib/store_web/live/admin_live.ex`
- `lib/store_web/live/admin/subscriptions/index_live.ex`
- `lib/store_web/live/admin/subscriptions/show_live.ex`
- `lib/store/admin/authorization.ex`
- `lib/store/subscriptions/facade.ex`
- `lib/store/subscriptions/subscription.ex`
- `test/store_web/live/admin_live_test.exs`
- `test/store_web/live/subscriptions_live_test.exs`

## Findings (severity ordered)

### High: `/admin` router gate was authentication-only, not role-complete by itself

- Router uses `on_mount: [{StoreWeb.LiveUserAuth, :live_user_required}]` for `/admin` session.
- `StoreWeb.LiveUserAuth.live_user_required` checks only `current_user` presence and redirects unauthenticated users to `/sign-in`.
- Therefore router/on_mount proves login requirement only; it does not prove admin-role authorization.

### Medium: subscriptions admin LiveViews lacked explicit mount role gate

- Most `/admin` LiveViews enforce role checks in `mount` via `Store.Admin.Authorization.has_any_role?/2`.
- `StoreWeb.Admin.Subscriptions.IndexLive` and `StoreWeb.Admin.Subscriptions.ShowLive` previously mounted without a role check and delegated denial to downstream facade/resource policy.
- This allowed authenticated non-admin users to reach admin subscription route handling before denial, creating inconsistent authorization depth versus other admin surfaces.

### Low: domain policy backstop existed, but web-layer behavior was inconsistent

- `Store.Subscriptions.Facade.*_for_admin` routes through `Subscription` `:read_for_admin`/`:get_for_admin`.
- `Subscription` policies authorize admin/support/system roles, preventing data disclosure to non-admin actors.
- Backstop was present, but route-level UX and defense-in-depth consistency were weaker than other `/admin/**` routes.

## Minimal fix applied

### Gap fixed

- Added explicit role gate in `mount/3` for:
  - `StoreWeb.Admin.Subscriptions.IndexLive`
  - `StoreWeb.Admin.Subscriptions.ShowLive`
- Allowed roles match existing subscription admin policy intent: `[:super_admin, :admin, :support]`.
- Non-authorized authenticated users are redirected to `/` at mount, matching existing admin live patterns.

### Tests added

- Added `authenticated non-admin is redirected away from admin subscriptions routes` in `test/store_web/live/subscriptions_live_test.exs`.
- Asserts redirect for:
  - `/admin/subscriptions`
  - `/admin/subscriptions/:id`

## Resulting protection chain for `/admin/**`

1. Router + `live_admin_required`: blocks anonymous users (redirect `/sign-in`) and authenticated non-admin users (redirect `/`) at session entry.
2. LiveView `mount` role gate: preserves route-specific role constraints (for example, subscriptions allows support role in addition to admin roles).
3. Facade/resource policies: enforce domain authorization as backstop.

## Phase 3D follow-up evidence

- `StoreWeb.Router` `/admin` live session now uses `on_mount: [{StoreWeb.LiveUserAuth, :live_admin_required}]`.
- `StoreWeb.LiveUserAuth.live_admin_required` enforces:
  - unauthenticated users redirect to `/sign-in`
  - authenticated users without `:super_admin`/`:admin`/`:support` role redirect to `/`
  - admin-capable users continue to `/admin/**`, with route-level mount checks still enforcing tighter per-page role rules
- `test/store_web/live/admin_live_test.exs` now verifies all three outcomes on:
  - `/admin`
  - `/admin/subscriptions` (nested route proving session-wide guard effectiveness)

## Risk and assumptions

- Support-role allowance on subscriptions admin routes is preserved intentionally to match current domain policy and existing support-grade operational behavior.
- This audit does not redefine global admin RBAC semantics for every admin surface; it closes the concrete proven gap in subscriptions admin LiveViews only.
