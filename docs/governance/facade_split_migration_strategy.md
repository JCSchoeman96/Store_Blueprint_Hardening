# Facade Split Migration Strategy (Governance)

## Status

Planning artifact only. No runtime code movement is authorized by this document.

## Objective

Provide mandatory guardrails for future facade internal decomposition of:

- `Store.Checkout.*`
- `Store.Orders.*`
- `Store.Payments.*`

while preserving public surface stability and all stabilization invariants.

## Mandatory Invariants

1. Surface stability
   - Existing top-level facade APIs remain callable with unchanged signatures.
2. Web boundary compliance
   - No direct `Ash.Query`, `Ash.*`, `Repo.*`, outbound HTTP, or non-webhook enqueue in web adapters.
3. Domain contract compliance
   - Domain functions continue to use actor-aware typed inputs.
4. Transaction and lock safety
   - Existing lock ordering and transaction boundaries are unchanged.
5. Interlock/idempotency safety
   - Checkout/payment apply-once semantics and uniqueness constraints remain intact.
6. Observability continuity
   - Existing hot-path telemetry events and key metadata remain stable.
7. Performance continuity
   - Query-count budgets and p95 behavior do not regress in known hot paths.

## Future Rollout Model

- Model: one sub-facade extraction concern per PR.
- Wrapper-first strategy:
  - keep all top-level public exports
  - delegate internally to extracted sub-facade modules
- Sequence:
  1. Checkout extraction slices
  2. Orders extraction slices
  3. Payments extraction slices
- Coupling rule:
  - if a slice depends on another domain, record dependency explicitly and avoid mixed broad PRs.

## Required Validation Gates (Per Future PR)

### A. Static/governance gates

- `check.surface_naming`
- `check.web_no_ash_query`
- `check.web_no_direct_ash_calls`
- `check.no_repo_in_web`
- `check.web_no_http`
- `check.web_no_oban_enqueue`

### B. Behavioral parity checks

- top-level facade call signatures unchanged
- no changes to policy enforcement location (remain policy-backed)
- no checkout/payment idempotency drift
- no post-commit notification contract drift where applicable

### C. Performance and observability checks

- query counts at or below baseline budgets on hot paths
- no latency regression requiring emergency rollback
- telemetry events and metadata keyset preserved for dashboards/alerts

## Rollback Strategy

Rollback scope is single-slice and immediate:

1. Revert only the extraction PR that introduced drift.
2. Preserve top-level wrappers and previous delegation path.
3. Re-run affected parity and gate checks.
4. Open follow-up slice with narrowed extraction scope.

## Stop-the-line Triggers

- Signature drift on any existing public facade function.
- Gate failure in web-boundary or surface naming checks.
- Lock-order or transaction boundary behavior change.
- Interlock/idempotency regression in checkout/payment paths.
- Query-count regression beyond accepted budget for hot paths.

## Cross-lane Ownership and Escalation

Current planning assessment:

- `NEEDS_CROSS_LANE_CHANGE: no`

Escalate to cross-lane only if future execution requires:

- web adapter call-site rewiring outside wrapper-preserving strategy
- policy contract migration requiring security lane ownership
- release runbook changes beyond existing phase docs ownership

## Evidence Anchors

- `AGENTS.md`
- `docs/stabilization/source-of-truth.md`
- `docs/stabilization-pass.md`
- `docs/governance/enforcement_gates.md`
- `docs/governance/side_effects_quarantine.md`
- `docs/governance/policy_matrix.md`
- `docs/phases/phase_29_performance_architecture_optimizations.md`
- `docs/agent_notes/phase_14_docs.md`
- `docs/agent_notes/phase_15_docs.md`
- `docs/agent_notes/phase_29_docs.md`
- `docs/agent_notes/phase_30_docs.md`
