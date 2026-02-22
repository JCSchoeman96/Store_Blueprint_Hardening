# Phase 00 — Skeleton + deps + CI gates (P0)

## Goal
Bootable Phoenix LiveView app with Bandit, Ash 3.x deps, Petal UI baseline, and enforceable `mix check` gates.

## Single-tenant requirement
- No tenant routing
- No tenant_id columns

## Acceptance gates
- mix format --check-formatted
- mix compile --warnings-as-errors
- mix test
- mix credo --strict
- mix docs
- no Repo in lib/store_web/**
- required docs/agent_notes files exist
