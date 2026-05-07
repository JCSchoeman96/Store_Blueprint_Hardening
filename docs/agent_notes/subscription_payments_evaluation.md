# Subscription Payments Capability Evaluation (Current State)

This note answers subscription-flow capability questions for the current codebase implementation.
It is not a provider production-readiness approval. Provider enablement truth is tracked in `docs/payments/provider-readiness.md`.

## Capability matrix (short answer)

1) **Pay monthly till cancelled (auto renew): `YES`**
- Supported via `interval_unit` + `interval_count` on `SubscriptionPlan`, renewal scheduling, and due-renewal workers.

2) **Pay yearly (auto renew): `YES`**
- Supported via `interval_unit: :year` and period advancement logic in `Scheduler`.

3) **Subscription for only 5 months then stop automatically: `PARTIAL / LIKELY NOT ENFORCED END-TO-END`**
- Plan model supports `term_mode` (`:fixed_cycles`) and `term_cycles`, but term-cutoff enforcement is not clearly applied in the renewal execution path.

4) **Retry mechanism for failed payments: `YES`**
- Supported with dunning fields (`max_retry_attempts`, `retry_schedule_hours`) and retry/suppression transitions.

5) **Deposit and then subscription payments onward: `PARTIAL`**
- Initial paid order -> subscription activation is supported.
- Explicit “deposit/down-payment + separate recurring amount contract” behavior is not modeled as a first-class dedicated flow.

6) **Pro rata payment + site-wide payment synchronization (admin set date): `PARTIAL`**
- Site-wide-like synchronization is possible per plan using `anchor_mode: :fixed_day_of_month` + `anchor_day_of_month`.
- Explicit pro-rata proration charging/credit logic is not currently evident as a dedicated capability.

---

## Gateway integration readiness (APIs, webhook/ITN verification, tokens)

Short answer: **the integration framework is in place, but only Stripe appears fully implemented end-to-end right now.**

- The provider boundary is standardized (`create_intent`, `charge_off_session`, `verify_webhook`, `normalize_webhook`) and routed via a fail-closed resolver with enabled-provider gating.
- Runtime config already supports provider enablement and secure env-var loading for Stripe keys/secrets.
- **Stripe**: implemented adapter with API calls, webhook signature verification, and canonical normalization.
- **PayFast / Paystack / Yoco / Peach Payments**: capability declarations exist, but current adapter functions return explicit `not implemented yet` errors for intent creation and webhook verification/normalization.

Operational readiness constraint:
- Treat non-Stripe providers as scaffold-only and keep them disabled in production until direct adapter and webhook contract proof exists.

Implication for **ITN tokens / easy gateway integration**:
- For **PayFast ITN** specifically, the scaffolding exists (provider module + capability model), but ITN verification/normalization is **not yet implemented in code**.
- So: **easy to add from a structure perspective, not yet turnkey operational for non-Stripe providers**.

---

## Evidence highlights

### Cadence and auto-renew (monthly/yearly)
- `SubscriptionPlan` exposes `interval_unit` (`:day | :month | :year`) and `interval_count`.
- `Scheduler.advance_period_end/2` explicitly handles `:month` and `:year`.
- Renewals are scheduled and fanned out through `RunDueSubscriptionRenewalsWorker` -> `ProcessSubscriptionRenewalWorker`.

### Term model exists (fixed cycles / end date)
- `SubscriptionPlan` contains `term_mode`, `term_cycles`, `term_end_at`.
- Validation requires cycles/end date depending on term mode.
- Implementation caution: term fields are present in the model, but automatic stop-after-N-cycles is not clearly visible in the main renewal execution flow.

### Retry/dunning exists
- `SubscriptionPlan` has `max_retry_attempts` and `retry_schedule_hours`.
- `Scheduler.next_retry_at/3` computes deterministic retry moments.
- Renewal failure handling increments dunning attempts, sets `next_retry_at`, and suppresses retries for hard blocker reasons.

### Initial paid order -> subscription creation
- `create_subscriptions_from_paid_order_for_system/1` requires a paid order and succeeded payment intent, then creates subscriptions (replay-safe).
- This is sufficient for “first payment happened, recurring continues,” but there is no explicit deposit-contract abstraction.

### Admin-date synchronization and pro-rata
- Anchor model supports normalization to a fixed billing day-of-month and timezone-driven UTC conversion.
- No dedicated pro-rata engine was found in subscription renewal/payment orchestration.

### Provider implementation depth
- Resolver + behavior contracts are present and cleanly separated.
- Stripe implements API + verify + normalize.
- Non-Stripe adapters currently expose explicit unimplemented boundaries (safe/fail-closed, but not production-ready integrations).

---

## Recommendation (minimal)

If your business requires strict support for items (3), (5), and (6), plus multi-gateway readiness:

1. Add an explicit **capability guard** in tests and docs (fixed-cycle enforcement, deposit flow, pro-rata, per-provider readiness).
2. Implement **term enforcement in renewal path** (hard stop at cycles/end date) before exposing fixed-term plans broadly.
3. Implement provider adapters one-by-one (start with PayFast ITN verification + normalization + create_intent), keeping `verify_webhook` + `normalize_webhook` contract-complete before enabling provider in production.
