# Phase 3C Facade Split Notes

## Goal

Create concrete, future-facing documentation for facade/surface decomposition without implementing code changes in this phase.

## Scope Boundaries

- Allowed: planning docs and stabilization tracker updates.
- Forbidden in this phase:
  - runtime code movement
  - behavior changes
  - policy rewrites
  - release/runtime contract changes

## Planning Assumptions

1. `docs/stabilization/source-of-truth.md` is canonical baseline.
2. `AGENTS.md` rules are mandatory and supersede local preferences.
3. Existing top-level facade APIs are externally consumed and must remain stable.
4. Future splits should be internal decomposition first, wrapper-preserving by default.
5. Hot-path performance/query budgets from prior phases are regression-sensitive and must be preserved.

## Key Decisions

1. Keep split targets constrained to:
   - `Store.Checkout.*`
   - `Store.Orders.*`
   - `Store.Payments.*`
2. Define extraction as future ticket slices, one concern per PR.
3. Require explicit stop-the-line triggers for:
   - gate failures
   - API drift
   - transaction/lock drift
   - idempotency/interlock drift
   - query-count regressions
4. Keep cross-lane requirement as:
   - `NEEDS_CROSS_LANE_CHANGE: no` for planning-only phase.

## Risks Logged

- Baseline drift risk between initial 2A assumptions and current post-optimization state.
- Public API drift risk during internal extraction.
- Boundary gate regression risk in mixed web/domain refactors.
- Checkout/payment interlock risk if extraction crosses transaction seams incorrectly.
- Rollback complexity risk if multiple concerns are bundled in one PR.

## Mitigation Strategy

- One concern per future PR.
- Wrapper-preserving extraction sequence.
- Mandatory gate + parity checklist on every extraction.
- Immediate single-slice rollback on stop-the-line trigger.

## Artifacts Produced in Phase 3C

- `docs/phases/phase_3c_facade_split_plan.md`
- `docs/governance/facade_split_migration_strategy.md`

## Evidence Consulted

- `AGENTS.md`
- `docs/stabilization/source-of-truth.md`
- `docs/stabilization-pass.md`
- `docs/governance/enforcement_gates.md`
- `docs/governance/side_effects_quarantine.md`
- `docs/governance/policy_matrix.md`
- `docs/phases/phase_28_production_readiness_release_checklist.md`
- `docs/phases/phase_29_performance_architecture_optimizations.md`
- `docs/agent_notes/phase_14_docs.md`
- `docs/agent_notes/phase_15_docs.md`
- `docs/agent_notes/phase_29_docs.md`
- `docs/agent_notes/phase_30_docs.md`

## NEXT

Update Phase 3C status subsection in `docs/stabilization-pass.md` to reference artifacts and mark planning completion.
