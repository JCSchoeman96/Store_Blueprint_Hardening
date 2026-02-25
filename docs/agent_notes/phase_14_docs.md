# Phase 14 - Checkout interlocks and replay safety

## GOAL

Implement deterministic checkout/payment idempotency and exactly-once paid side effects so retries and replays cannot create duplicate orders, duplicate charge attempts, or duplicate paid transitions.

## LINKS CONSULTED

- Project docs:
  - `docs/phases/phase_14_checkout_interlocks.md`
  - `docs/governance/checkout_interlocks.md`
  - `docs/governance/enforcement_gates.md`
  - `docs/governance/error_codes.md`
  - `docs/governance/side_effects_quarantine.md`
  - `docs/governance/idempotency.md`
  - `docs/agent_notes/phase_13_docs.md`
- External references:
  - https://ash-project.github.io/ash/create-actions.html
  - https://hexdocs.pm/ash/Ash.Changeset.html
  - https://hexdocs.pm/oban/unique_jobs.html
  - https://docs.stripe.com/api/idempotent_requests
  - https://docs.stripe.com/webhooks
  - https://www.postgresql.org/docs/current/sql-insert.html
  - https://www.postgresql.org/docs/current/ddl-constraints.html
  - https://www.postgresql.org/docs/14/indexes-partial.html

## WHAT DOCS RECOMMEND NOW

- Checkout creation must be idempotent per checkout attempt and return existing pending order on replay.
- Payment intent creation/attach must be idempotent and interlocked against concurrent in-flight attempts.
- Paid transitions and paid side effects must be guarded by durable exactly-once evidence.
- Callback/redirect paths in web must be enqueue-only; worker paths own side effects.
- Idempotency keys should be deterministic and stable across retries.

## DECISIONS TAKEN (PINS)

- `checkout_key` and `payment_intent_key` are bounded hashed keys:
  - `checkout_key = "ck:" <> base32(sha256(canonical_checkout_payload))`
  - `payment_intent_key = "pi:" <> base32(sha256(canonical_pi_payload))`
- Canonical checkout payload includes deterministic line ordering by raw16 UUID sort and includes quantities, currency, as_of, and pricing/tax/shipping determinism inputs.
- DB interlocks are required (not code-only):
  - unique `orders.checkout_key` (non-null rows)
  - unique `payment_intents.payment_intent_key` (non-null rows)
  - partial unique in-flight intent index by order id and in-flight states.
- Exactly-once paid side effects are guarded by create-only `payment_applications` evidence with unique `application_key`.
- Callback route is provider scoped and enqueue-only:
  - `/api/payments/:provider/callback`
- Callback and webhook paths converge on one shared apply-once core function in payments logic.
- `PaymentAttempt` resource is included in Phase 14 for durable provider-attempt evidence.

## PLAN

1. Add migration/resources for keys, in-flight index, `PaymentAttempt`, and `PaymentApplication`.
2. Add deterministic idempotency helpers for canonical payload hashing and key derivation.
3. Implement `Store.Orders.begin_checkout/2` create-or-reuse behavior.
4. Implement payment intent create-or-reuse and in-flight interlock logic.
5. Add apply-once payment success core path and wire webhook + callback into it.
6. Add callback controller/route and minimal gate allowlist update.
7. Add governance tests for replay and concurrency semantics.
8. Run `mix check` and closure protocol.

## DONE

- Created Phase 14 docs-first note and pinned implementation decisions for keys/interlocks/evidence.
- Created Phase 14 bead tree and claimed docs-first bead before any implementation mutations.

## NEXT

- Implement schema/resource changes under Phase 14.2.
- Implement begin checkout and payment interlock orchestration under Phase 14.3 and 14.4.
- Implement apply-once paid effects and callback convergence under Phase 14.5.
- Finalize governance tests and closure under Phase 14.6.

## BLOCKERS

- `bd dolt test` succeeds in the user environment but is not reachable from this sandbox context; proceed with user-verified Beads service availability.

## COMMANDS RUN

- `bd dolt test`
- `bd status`
- `bd ready`
- `systemctl --user start dolt-beads.service`
- `systemctl --user status dolt-beads.service --no-pager`
- `bd search "Phase 14"`
- `bd create ...` (phase 14 parent and child beads)
- `bd dep add ...`
- `bd dep cycles`
- `bd update store_blueprint-7yf.4.1 --claim`

## GATES

- Docs-first Phase 14 note created before implementation edits.
- Bead claimed before code/docs mutation.

## PERFORMANCE REVIEW

- Hot path:
  - begin_checkout idempotent order creation and payment intent interlocks under retries.
- Warm path:
  - webhook/callback replay processing and apply-once paid side-effect guards.
- Cold path:
  - support/audit evidence reads for payment attempts and payment applications.
- Indexes:
  - unique checkout key, unique payment intent key, partial unique in-flight order index, unique payment application key.
- TTL:
  - no new TTL in Phase 14 baseline.
- Invalidation:
  - no cache invalidation introduced in Phase 14 baseline.
- PubSub:
  - no new PubSub fanout introduced in Phase 14 baseline.
