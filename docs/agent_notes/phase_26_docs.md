# Phase 26 — Subscriptions (26A/26B/26H)

## GOAL

Implement enterprise-grade subscriptions with:
- variant-first sellable identity
- plan-aware cart/order evidence
- worker-only activation/renewal/dunning flows
- minimal durable entitlement grants
- provider capability hardening (fail-closed + explicit gating)
- strict CI/Dialyzer/governance anti-drift gates

## LINKS CONSULTED

- `AGENTS.md`
- `docs/phases/phase_26_simple_subscriptions.md`
- `docs/phases/phase_27_variable_subscriptions.md`
- `docs/phases/phase_27a_membership_subscriptions_entitlements.md`
- `docs/governance/subscription_scheduling_terms.md`
- `docs/governance/payment_provider_contract.md`
- `docs/governance/payment_provider_capabilities.md`
- `docs/governance/subscriptions_rollout_rollback.md`
- `docs/governance/idempotency.md`
- `docs/governance/performance_scaling.md`
- `docs/governance/observability_slos.md`
- `docs/governance/enforcement_gates.md`

## DECISIONS / PINS

1. Dialyzer is required in CI (no advisory mode).
2. CI splits into static checks, strict PR tests, and required Dialyzer.
3. Nightly hardening runs multi-seed stress-style verification and diagnostics capture.
4. Subscriptions docs/governance anchors are enforced by `check.subscriptions_docs_sync`.

## PLAN

1. Harden CI, Dialyzer, and anti-drift checks first.
2. Implement provider fail-closed resolver and capability contract expansion.
3. Implement subscriptions/entitlements resources and worker orchestration.
4. Add strict governance + replay + concurrency + provider contract tests.
5. Run `mix check` and `mix check.types`, then close beads using closure protocol.

## DONE

- Phase 26 parent bead created and hardening bead claimed.
- CI required jobs + nightly hardening workflow added.
- Provider resolver fail-closed routing and capability declaration expanded.
- Subscriptions + entitlements domains, facades, uniqueness, and migration scaffold added.
- Worker activation + due-renewal workers implemented with replay/race-safe renewal attempt claiming.
- Subscription/account/admin web read surfaces and params adapters added.
- Governance drift tests for docs/policy/uniqueness/error codes added.
- Rollout/rollback runbook and phased feature flags added.

## NEXT

1. Complete remaining Dialyzer warning debt elimination to satisfy required type gate.
2. Run full `mix check` + strict subscription/entitlement suites and capture evidence.
3. Close bead with closure protocol once all gates are green.

## BLOCKERS

- None.

## COMMANDS RUN

- `bd dolt test`
- `bd status`
- `bd ready`
- `bd create ...`
- `bd update ... --claim`

## GATES

- Web boundary discipline remains mandatory.
- Subscriptions/docs anti-drift gate is added to `mix check`.
- Dialyzer required CI job is part of phase acceptance.

## PERFORMANCE & SCALING REVIEW

- Hot paths: renewals, webhook ingestion, entitlement checks.
- Query risk: renewal tick and entitlement lookups must avoid N+1.
- Indexes: `(status, next_renewal_at)`, renewal uniqueness, entitlement lookup indexes.
- Caching: entitlement set cache with deterministic invalidation hooks.
- Idempotency: renewal keys + unique jobs + apply-once transitions.
- Telemetry: renewal outcomes, queue/backlog age, dunning transitions.
