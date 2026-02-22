# Phase 08 — Side effects quarantine (P0)

## Goal
Keep the web layer pure and prevent irreversible work from leaking into controllers/liveviews.

## Must deliver
- `docs/governance/side_effects_quarantine.md`
- CI gates:
  - no outbound HTTP in `lib/store_web/**`
  - no Oban enqueue in `lib/store_web/**` (allowlist webhook controller enqueue-only)
- Test gate proving webhook controller enqueues only and worker does transitions

## Acceptance gates
- `mix check` fails if `Store.Support.HTTP.ReqClient` is referenced in web
- `mix check` fails if `Oban.insert` is referenced in web (except allowlist)
- Tests prove state transitions happen in worker, not controller
