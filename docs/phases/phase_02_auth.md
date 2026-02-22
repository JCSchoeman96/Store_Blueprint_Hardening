# Phase 02 — Accounts/Auth (P0)

## Goal
Actor identity exists for policies, audit, and step-up.

## Locked decisions
- UI: use AshAuthenticationPhoenix LiveViews with `StoreWeb.AuthOverrides` styling aligned to Chelekom baseline.
  - No PETAL-specific auth UI implementation in this phase.
- Router contract:
  - `use AshAuthentication.Phoenix.Router`
  - `auth_routes` for provider and password endpoints under `/auth`
  - `sign_in_route`, `sign_out_route`, `reset_route`, `confirm_route`
  - `ash_authentication_live_session` plus LiveView `on_mount` hooks for required/optional auth.
- Google OAuth contract:
  - request route: `/auth/user/google`
  - callback route: `/auth/user/google/callback`
  - user action name: `:register_with_google`
  - redirect URI base from environment (`STORE_GOOGLE_REDIRECT_URI_BASE`) with strategy suffix appended by AshAuthentication.
- Email delivery:
  - tests use deterministic test adapter assertions (`Swoosh.Adapters.Test`)
  - SMTP available in development only through environment variables.

## Acceptance gates
- Register/login tests
- Password reset request email test
- Google request + callback route contract tests
- Protected LiveView requires auth
- Policies scope customer reads to actor-owned records only
