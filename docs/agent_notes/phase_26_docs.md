# Phase 26 — Subscriptions (26A/26B/26H)

## GOAL

Implement the Phase 26 subscription constitution with SA-first provider posture and enterprise verification:
- variant-first sellable identity
- strict provider enum-at-rest on durable payment/subscription records
- fail-closed provider normalization and selection (no backend default provider)
- evidence-first webhook receipt handling for disabled providers
- merchant-managed recurring core with stored payment method precondition
- required CI + Dialyzer gates and governance anti-drift enforcement

## LINKS CONSULTED

- `AGENTS.md`
- `docs/phases/phase_25_subscription_plans.md`
- `docs/phases/phase_26_simple_subscriptions.md`
- `docs/phases/phase_27_variable_subscriptions.md`
- `docs/governance/payment_provider_contract.md`
- `docs/governance/payment_provider_capabilities.md`
- `docs/governance/subscriptions_rollout_rollback.md`
- `docs/governance/error_codes.md`
- `docs/governance/performance_scaling.md`

## DECISIONS / PINS

1. Provider at rest is strict enum for durable records.
2. Boundary parsing may accept strings, but `:unknown` is always hard error.
3. No backend default provider; selection is required.
4. Disabled provider webhooks persist verified evidence and fail processing in worker.
5. Merchant-managed recurring is primary; provider-managed remains capability/flag gated.
6. Required CI gates are `mix check` and `mix check.types`; nightly hardening remains active.

## PLAN

1. Build bead tree for PV0-PV9 and execute each hardening slice.
2. Enforce provider resolver/web boundary fail-closed behavior and stable error codes.
3. Add stored payment method model and renewal precondition enforcement.
4. Align runtime config + capabilities + billing mode interlocks to SA-first fail-closed behavior.
5. Harden tests, docs, and CI/nightly workflows; run full gates; close beads and epic.

## DONE

- Created and executed Phase 26 bead tree `store_blueprint-7yf.20.2.*` and closed all beads.
- Hardened provider resolver:
  - `PAYMENT_PROVIDER_SELECTION_REQUIRED` for missing selection
  - `PAYMENT_PROVIDER_UNSUPPORTED` for unknown provider
  - `PAYMENT_PROVIDER_DISABLED` for disabled provider
- Removed implicit/default provider behavior from payment/subscription orchestration paths.
- Enforced provider enum-at-rest + DB constraints across payment/subscription durable records.
- Kept canonical webhook provider as boundary string while ensuring persisted provider remains normalized enum.
- Hardened webhook and callback controllers to reject unknown provider before signature verification/persistence.
- Implemented evidence-first disabled-provider flow in workers/facades:
  - verified receipt persists
  - processing marks failed with `PAYMENT_PROVIDER_DISABLED`
- Added `StoredPaymentMethod` model, migration, uniqueness constraints, subscription linkage, and tests.
- Enforced renewal precondition: no merchant-managed renewal charge without active stored payment method (`PAYMENT_METHOD_REQUIRED`).
- Added SA-first runtime config parsing for enabled providers and UI-only default hint.
- Updated capability/governance docs and registries (error codes, uniqueness, rollout contract).
- Hardened CI and nightly workflows:
  - required `check_static` (`mix check`)
  - required `test_pr_strict`
  - required `dialyzer_required` (`mix check.types`)
  - nightly heavy multi-seed + artifacts

## NEXT

1. Phase 27 planning can now assume merchant-managed recurring as baseline.
2. Optional follow-up: reduce ignored Dialyzer baseline warnings outside Phase 26 scope.

## BLOCKERS

- None at phase close.

## COMMANDS RUN

- `bd dolt test`
- `bd status`
- `bd ready`
- `bd create ...`
- `bd update ... --claim`
- `bd close ...`
- `mix check`
- `mix check.types`
- `systemctl --user stop dolt-beads.service`
- `dolt push origin main`
- `systemctl --user start dolt-beads.service`

## GATES

- `mix check`: PASS
- `mix check.types`: PASS
- Web boundary and governance anti-drift checks: PASS
- Phase 26 beads/epic closure: PASS

## PERFORMANCE & SCALING REVIEW

- Hot paths:
  - webhook ingest path (`verify -> persist -> enqueue`)
  - subscription renewal tick
  - entitlement and subscription status reads
- Query shape:
  - renewal path remains keyed by subscription + renewal key (idempotent)
  - stored payment method lookup is indexed and scoped by subscription user/provider
- Indexes/constraints:
  - provider value checks on durable payment/subscription tables
  - stored payment method uniqueness on `(provider, provider_customer_ref, provider_payment_method_ref)`
  - subscription FK/index on `stored_payment_method_id`
- Idempotency:
  - webhook receipts unique key
  - renewal attempt unique key and claim guards
  - worker retry-safe transitions
- Observability:
  - disabled-provider failures are recorded as receipt failures (no silent drops)
  - queue-driven processing remains observable through worker outcomes
