# Phase 09 — Immutable snapshots (P0)

## Goal
Make order evidence immutable so historical orders remain correct under audits and support.

## Must deliver
- `docs/governance/immutable_snapshots.md`
- CI/test gates:
  - snapshot resources have no update/destroy actions
  - order totals do not change after price updates

## Acceptance gates
- CI fails if update/destroy actions appear on OrderLineItem or OrderAdjustment
- Snapshot stability test passes
