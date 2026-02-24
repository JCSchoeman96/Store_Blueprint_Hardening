# Phase 09 — Immutable snapshots (P0)

## Goal
Make order evidence immutable so historical orders remain correct under audits and support.

## Must deliver
- `docs/governance/immutable_snapshots.md`
- CI/test gates:
  - snapshot resources have no update/destroy actions
  - snapshot read paths return stored evidence values (no read-time recomputation)
  - deterministic ordering invariants exist for snapshot rows (`line_no`, `sequence_no`)

## Acceptance gates
- CI fails if update/destroy actions appear on OrderLineItem or OrderAdjustment
- Snapshot read-immutability test passes
- Real "price change does not mutate historical totals" gate is deferred until pricing/catalog resources and pricing evaluation actions exist (Phase 10+).
