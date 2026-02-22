# Phase 02 Docs Notes

## Links Consulted (Hexdocs / web search)
- https://hexdocs.pm/ash_authentication/
- https://hexdocs.pm/ash_authentication_phoenix/liveview.html
- https://hexdocs.pm/ash_authentication_phoenix/get-started.html
- https://hexdocs.pm/phoenix_live_view/Phoenix.LiveView.html
- https://hexdocs.pm/ash/policies.html
- https://hexdocs.pm/plug/Plug.Conn.html
- https://hexdocs.pm/phoenix/routing.html

## What the Docs Recommend Now
- Use AshAuthentication + AshAuthenticationPhoenix for identity flows integrated with Ash resources.
- Keep auth routing in Phoenix router and leverage generated LiveView auth flows.
- Keep authorization in Ash policies; avoid web-layer authorization logic drift.
- Model customer data access with explicit policy checks scoped to actor identity.

## What We Will Implement (Decisions)
- Implement accounts/auth baseline on Ash resources and policies.
- Ensure customer read access is own-data only (`user_id == actor.id` patterns).
- Keep web endpoints as thin adapters that call Ash actions.
- Preserve single-tenant semantics; no tenant scoping fields or tenant router branches.
- Lock UI baseline to AshAuthenticationPhoenix LiveViews with Chelekom-styled overrides (no PETAL-specific UI work in Phase 02).
- Lock router integration to `use AshAuthentication.Phoenix.Router` plus auth route macros (`auth_routes`/`auth_routes_for` contract, `sign_in_route`, `sign_out_route`) and LiveView session `on_mount` hooks.
- Lock Google OAuth contract:
  - callback URI shape under `/auth/user/google/callback`
  - explicit register action naming `:register_with_google`
  - redirect URI base from environment.
- Lock delivery determinism:
  - tests use deterministic test delivery (Swoosh test adapter/capture)
  - SMTP configured for dev via environment variables only.

## Version Pins / Breaking Changes
- Use Phase 00 pinned families:
  - `ash_authentication ~> 4.0`
  - `ash_authentication_phoenix ~> 2.0`
- Breaking change watch:
  - Auth strategy/router macro options can change across minor releases; re-check docs on upgrade.
  - Session claim formats should be treated as contracts for step-up and policy enforcement.
  - `auth_routes_for` is deprecated in newer `ash_authentication_phoenix`; prefer current macro variants while preserving equivalent route behavior.

## Performance & Scaling Review
- Hot paths:
  - Login/session validation and policy checks on user-facing pages.
  - Keep per-request auth plumbing small and deterministic.
- Warm paths:
  - Registration/password reset and account maintenance flows.
- Cold paths:
  - Admin user lifecycle tasks and occasional support lookups.
- Indexes:
  - Global unique index for `accounts_users.email` is mandatory.
  - Add indexes for auth token lookup tables once introduced.
- TTL:
  - Token/session expiry windows should be explicit and test-covered.
- Invalidation:
  - Invalidate session/token material on credential rotation or logout.
- PubSub:
  - Optional PubSub broadcasts for session revocation notifications if multi-session support is needed.
- Indexes:
  - Global unique index on `users.email` is mandatory.
  - Token tables require strategy-generated indexes for subject and expiry pruning.
