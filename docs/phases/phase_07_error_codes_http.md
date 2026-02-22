# Phase 07 — Error codes + outbound HTTP hardening (P0)

## Goal
Prevent integration drift and unsafe outbound call behavior across client projects.

## Must deliver
- `docs/governance/error_codes.md`
- `docs/governance/outbound_http.md`
- CI gate: no raw `Req.` usage outside wrapper
- Test gate: error code registry pinned + unique

## Acceptance gates
- `mix check` fails if any `Req.` call is found outside the wrapper
- Registry contains core codes and has no duplicates
- Policies/actions return stable codes (UNAUTHORIZED/FORBIDDEN/STEP_UP_REQUIRED etc.)
