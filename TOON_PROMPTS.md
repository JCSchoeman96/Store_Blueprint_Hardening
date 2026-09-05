# TOON Prompts — Store Blueprint (Single-Tenant Hardening)
One task per prompt. No mixed responsibilities.

---

## Performance/runtime Note contract

For any TOON prompt that changes runtime behavior, designs a hot path, or
requires performance or load evidence, the `Note` field must include the
following fields when they apply:

- `DATA LAYER`
- `INDEXES`
- `CACHE`
- `REDIS STRUCTURE`
- `TTL`
- `INVALIDATION/CLEANUP`
- `PUBSUB`
- `STORE.REPO EFFECT`
- `100K STATUS`
- `MEMORY`: bounded process, ETS, cache, and transient resource state
- `GC`: allocation, heap, and major or full-sweep considerations
- `MAILBOX`: bounded long-lived process queues
- `RESOURCE CLEANUP`: owner plus expiry or termination behavior
- `POST-LOAD`: expected convergence after workload cooldown

The memory/runtime fields are conditional. Do not force them onto a prompt that
is purely documentation-only and has no runtime or performance relevance.

The 100k review must reject designs that move contention away from PostgreSQL
by creating one BEAM process per waiter, one timer or monitor per unbounded
request, unbounded Redis state, unbounded ETS or cache state, unbounded Oban
jobs, or unbounded mailboxes. The Note must answer where waiting state lives,
whether it is bounded, who cleans it up, and what remains after cooldown.

---

## Scaffolding Prompt (Whole project)

| Field     | Content |
|-----------|---------|
| Task      | Scaffold the Store single-tenant blueprint kernel + packs skeleton with constitutional laws and CI enforcement gates. |
| Objective | Create a reusable baseline repo where identity/governance is P0 and feature packs are added without drift. |
| Output    | Project compiles; `mix check` passes; docs under `docs/governance`, `docs/agent_notes`, `docs/phases`; directory structure matches blueprint. |
| Note      | MUST be single-tenant: NO tenant_id columns, NO tenant routing, NO marketplace semantics. MUST document: UUIDv7 PKs, deterministic binary UUID sort law (BAN UUID string sorting), lock ordering law, polyglot ID surface policy, order_ref policy, global uniqueness constraints (slugs/SKUs/coupons/order_ref). MUST add `mix check` gates: (1) no Repo in web, (2) moduledoc required, (3) docs-first notes required. For runtime-relevant work, apply the Performance/runtime Note contract above. |

---

## P0 — Governance Docs (Authoritative Specs)

| Field     | Content |
|-----------|---------|
| Task      | Create governance docs under `docs/governance/` exactly as specified by the blueprint. |
| Objective | Make lifecycle/idempotency/audit/retention/step-up/enforcement rules authoritative and stable across projects. |
| Output    | Files created: state_machines.md, idempotency.md, audit_and_pii.md, retention.md, step_up.md, enforcement_gates.md, performance_scaling.md. |
| Note      | MUST ensure docs contain no multi-tenant assumptions. MUST include global uniqueness constraints and single-tenant actor model (scope by user_id only). For runtime-relevant governance, include the Performance/runtime Note contract fields and the `PERF-MEM-001`, `PERF-GC-001`, `PERF-MBOX-001`, and `PERF-RESOURCE-001` invariants. |

---

## P0 — CI Enforcement Gates

### TOON E01 — Add “No Repo in web” gate
| Field     | Content |
|-----------|---------|
| Task      | Add a CI gate that fails if `Store.Repo` or `Ecto.Repo` is referenced under `lib/store_web/**`. |
| Objective | Mechanically enforce “web calls Ash actions only”. |
| Output    | Credo custom check OR grep-based mix task; wired into `mix check`. |
| Note      | MUST print offending file/line. MUST not block non-web usage. |

### TOON E02 — Add moduledoc gate
| Field     | Content |
|-----------|---------|
| Task      | Fail CI if modules under `lib/**` lack `@moduledoc` (allow explicit `@moduledoc false`). |
| Objective | Prevent documentation drift in a reusable blueprint. |
| Output    | Credo configuration updated and proven active. |
| Note      | MUST fail `mix check` and list offending modules. |

### TOON E03 — Add docs-first notes gate
| Field     | Content |
|-----------|---------|
| Task      | Fail CI if required phase notes are missing under `docs/agent_notes/`. |
| Objective | Turn “docs-first” into an enforceable habit for agents. |
| Output    | Gate wired into `mix check`. |
| Note      | MUST require Phase 00–03 at minimum for release-1. List required files explicitly. |

### TOON E04 — Add single-tenant uniqueness gate (schema/migration)
| Field     | Content |
|-----------|---------|
| Task      | Add a test gate that asserts the presence of key unique indexes required in a single-tenant app. |
| Objective | Prevent accidental drift into tenant-scoped uniqueness assumptions. |
| Output    | Tests under `test/store/governance/uniqueness_gates_test.exs` that validate expected unique constraints (via Repo indexes or migration introspection). |
| Note      | MUST assert unique constraints for: users.email, products.slug, posts.slug, variants.sku, coupons.code, orders.order_ref, webhook_receipts.idempotency_key, provider_events(provider, provider_event_id). Keep it minimal and deterministic. |

---

## P0 — State Machines + Idempotency (Implementation Tasks)

### TOON S01 — Implement Orders.Order state machine + transition tests
| Field     | Content |
|-----------|---------|
| Task      | Implement Orders.Order with explicit state machine transitions and tests enforcing allowed/forbidden transitions and replay NOOP rules. |
| Objective | Prevent lifecycle drift and double-processing under webhook duplication. |
| Output    | `lib/store/orders/order.ex` transitions + tests. |
| Note      | MUST include states: pending_payment, paid, cancelled, refunded. MUST use optimistic locking. Forbidden transitions MUST return `INVALID_STATE_TRANSITION`. Replay of paid/refunded MUST be NOOP. |

### TOON S02 — Implement Payments.PaymentIntent state machine + idempotency tests
| Field     | Content |
|-----------|---------|
| Task      | Implement Payments.PaymentIntent transitions and provider event idempotency enforcement. |
| Objective | Ensure provider events cannot double-apply payment state and side effects. |
| Output    | PaymentIntent resource, ProviderEvent resource, unique constraints, tests. |
| Note      | MUST store receipt/provider event before transitions. DB uniqueness mandatory. Use Oban worker for processing. Duplicate provider event MUST NOOP. |

---

## P0 — Audit + Step-up (Implementation Tasks)

### TOON A01 — Make AuditLog create-only + PII rules
| Field     | Content |
|-----------|---------|
| Task      | Implement Admin.AuditLog as append-only (create-only actions) and enforce PII redaction rules. |
| Objective | Ensure audit cannot be edited and PII doesn’t leak into governance logs. |
| Output    | `admin/audit_log.ex` create-only actions + policy denies + tests. |
| Note      | MUST forbid raw webhook payloads. Store hashes/ids only. Optional DB trigger is a separate pack. |

### TOON A02 — Implement Step-up module + Plug + tests
| Field     | Content |
|-----------|---------|
| Task      | Implement step-up protection with a 15-minute window and stable error semantics. |
| Objective | Make sensitive operations consistent across projects. |
| Output    | `support/security/step_up.ex`, `store_web/plugs/require_step_up.ex`, tests. |
| Note      | MUST use session claim `step_up_at`. Error: `STEP_UP_REQUIRED` with meta: required_window_minutes and step_up_last_at. |

### TOON G08 — Add policy matrix spec doc
| Field     | Content |
|-----------|---------|
| Task      | Create `docs/governance/policy_matrix.md` pinning role permissions per resource and action. |
| Objective | Prevent authorization drift across client projects by making “who can do what” explicit and testable. |
| Output    | A complete matrix for roles: super_admin, admin, editor, support, customer across Accounts/Admin/Content/Catalog/Pricing/Orders/Payments. |
| Note      | MUST be deny-by-default for non-read actions. MUST include own-data rule for customers (scope by user_id). MUST define stable error codes UNAUTHORIZED/FORBIDDEN/STEP_UP_REQUIRED. MUST list step-up-required actions and forbid support from “shadow admin” capabilities. |

### TOON E05 — Add policy matrix test suite gate
| Field     | Content |
|-----------|---------|
| Task      | Add `test/store/governance/policy_matrix_test.exs` that asserts the pinned matrix behaviors. |
| Objective | Make authorization drift fail CI immediately. |
| Output    | Tests covering at least: customer own-data rule, editor boundaries, support boundaries, admin vs refund step-up requirement, provider config step-up requirement. |
| Note      | Keep tests deterministic and minimal. Use stable error codes in assertions. Do not test LiveView routes only; test Ash action authorization. |

### TOON G10 — Add error codes governance doc
| Field     | Content |
|-----------|---------|
| Task      | Create `docs/governance/error_codes.md` and pin stable error code semantics + registry requirements. |
| Objective | Prevent error-code drift and keep integrations stable across projects. |
| Output    | Governance doc + registry updated to include pinned codes + tests proving uniqueness and presence. |
| Note      | Codes MUST be SCREAMING_SNAKE_CASE. Any code used by policies/actions MUST exist in the registry. |

### TOON E06 — Add “No raw Req usage” CI gate
| Field     | Content |
|-----------|---------|
| Task      | Add a CI gate that fails if `Req.` is referenced outside `lib/store/support/http/req_client.ex`. |
| Objective | Enforce a single outbound HTTP policy and prevent unsafe retry patterns. |
| Output    | Credo/custom check OR mix task integrated into `mix check`. |
| Note      | Gate MUST report file/line. Allowlist only the wrapper file. |

### TOON E07 — Add error code registry test gate
| Field     | Content |
|-----------|---------|
| Task      | Add `test/store/governance/error_code_registry_test.exs` to assert pinned codes exist and registry uniqueness holds. |
| Objective | Make error code drift fail CI immediately. |
| Output    | Tests that assert presence of core codes from `docs/governance/error_codes.md` and no duplicates. |
| Note      | Keep tests deterministic. Assert all codes listed in `docs/governance/error_codes.md` exist in the registry and registry uniqueness holds. Update governance doc + registry + tests together.
| Field     | Content |
|-----------|---------|
| Task      | Create `docs/governance/side_effects_quarantine.md` defining where side effects may occur and web-layer prohibitions. |
| Objective | Stop irreversible work from leaking into LiveViews/controllers, preventing drift across client projects. |
| Output    | Governance doc + references added to blueprint and enforcement gates. |
| Note      | MUST quarantine side effects to workers/domain actions/integrations. MUST forbid outbound HTTP and Oban enqueue in `lib/store_web/**` except allowlist for webhook enqueue-only. |

### TOON E08 — Add “No outbound HTTP in web” CI gate
| Field     | Content |
|-----------|---------|
| Task      | Add a CI gate that fails if `Store.Support.HTTP.ReqClient` or `Req.` is referenced under `lib/store_web/**`. |
| Objective | Guarantee web layer never calls third-party APIs directly. |
| Output    | Credo custom check (preferred) or mix task; wired into `mix check`. |
| Note      | MUST report file/line. No allowlist except if later added explicitly to governance doc. |

### TOON E09 — Add “No Oban enqueue in web” CI gate (with allowlist)
| Field     | Content |
|-----------|---------|
| Task      | Add a CI gate that fails if `Oban.insert`/`Oban.insert_all` is referenced under `lib/store_web/**`, except the webhook controller allowlist. |
| Objective | Ensure job enqueueing is controlled and webhooks only enqueue, never process. |
| Output    | Credo custom check with allowlist for `lib/store_web/controllers/webhook_controller.ex`; wired into `mix check`. |
| Note      | Webhook controller may enqueue only; all verification/state transitions MUST be in an Oban worker. Gate MUST report file/line. |

### TOON T01 — Add side effects quarantine tests
| Field     | Content |
|-----------|---------|
| Task      | Add `test/store/governance/side_effects_quarantine_test.exs` to assert webhook controller enqueues only and transitions happen in worker. |
| Objective | Prove the quarantine is real and prevent future regressions. |
| Output    | Tests asserting: (1) receipt stored first, (2) job enqueued, (3) no state transition occurs inline. |
| Note      | Tests should be minimal and deterministic. Use stable error codes and verify order/payment state changes only after worker execution. |


### TOON G12 — Add immutable snapshots governance doc
| Field     | Content |
|-----------|---------|
| Task      | Create `docs/governance/immutable_snapshots.md` defining immutability rules for order evidence. |
| Objective | Prevent “edit history” bugs and ensure orders remain correct evidence under audits/support. |
| Output    | Governance doc + references added to blueprint and enforcement gates. |
| Note      | MUST enforce create/read only for OrderLineItem and OrderAdjustment. Corrections must be additive evidence, not edits. |

### TOON E10 — Add immutable snapshot action-absence test gate
| Field     | Content |
|-----------|---------|
| Task      | Add `test/store/governance/immutable_snapshots_test.exs` that asserts OrderLineItem and OrderAdjustment have no update/destroy actions. |
| Objective | Make snapshot immutability fail CI immediately on drift. |
| Output    | Deterministic tests that introspect resource actions and fail if update/destroy actions exist. |
| Note      | Tests should check Ash resource action list. Fail with clear message naming offending action/resource. |

### TOON T02 — Add snapshot stability test (price change does not mutate historical order)
| Field     | Content |
|-----------|---------|
| Task      | Add a test proving that changing a product price after order creation does not change stored order totals. |
| Objective | Enforce “no historical recomputation” invariant in ecommerce pack. |
| Output    | Test under `test/store/orders/order_snapshot_stability_test.exs`. |
| Note      | The order must store unit_price_minor and totals in snapshot fields; the test must assert these remain unchanged after price updates. |


### TOON G13 — Add pricing determinism governance doc
| Field     | Content |
|-----------|---------|
| Task      | Create `docs/governance/pricing_determinism.md` pinning money model, rounding, allocation, and stacking rules. |
| Objective | Prevent pricing drift and penny leaks across client projects. |
| Output    | Governance doc + references added to blueprint and enforcement gates. |
| Note      | MUST use integer minor units only. MUST define round-half-up and deterministic remainder distribution by UUID binary sort. MUST pin stacking rules (exclusive/combinable/coupon). |

### TOON T03 — Add pricing determinism test suite
| Field     | Content |
|-----------|---------|
| Task      | Add `test/store/pricing/pricing_determinism_test.exs` to enforce deterministic results and no penny leaks. |
| Objective | Make pricing drift fail CI immediately. |
| Output    | Tests for: repeated evaluation equality, allocation sum correctness, tie-break determinism, stacking enforcement, deterministic ordering of applied discounts. |
| Note      | Tests MUST not depend on wall clock; pass an explicit `as_of` timestamp into pricing actions. Ensure stable ordering using binary UUID sort for remainder allocation. |


### TOON G14 — Add inventory reservations governance doc
| Field     | Content |
|-----------|---------|
| Task      | Create `docs/governance/inventory_reservations.md` pinning the no-oversell reservation model and lifecycle. |
| Objective | Prevent overselling and inconsistent stock behavior under concurrency. |
| Output    | Governance doc + references added to blueprint and enforcement gates. |
| Note      | Default MUST be strict no-oversell for inventory-tracked SKUs. Must define reservation TTL, idempotency key, and consume/expire rules. Lock ordering MUST follow binary UUID sort when reserving multiple SKUs. |

### TOON T04 — Add inventory reservation test suite
| Field     | Content |
|-----------|---------|
| Task      | Add `test/store/catalog/inventory_reservations_test.exs` covering concurrency safety, idempotency, expiry release, and consume-on-payment. |
| Objective | Make inventory drift fail CI immediately. |
| Output    | Tests: concurrent reserve last unit, retry no double reserve, expiry releases, payment consumes reservations. |
| Note      | Tests must be deterministic. Avoid flakey timing; model time with explicit timestamps where possible and invoke expiry worker directly. Ensure stable error codes: OUT_OF_STOCK, RESERVATION_CONFLICT. |


### TOON G15 — Add refund semantics governance doc
| Field     | Content |
|-----------|---------|
| Task      | Create `docs/governance/refund_semantics.md` pinning refund evidence, idempotency, authorization, and interlocks. |
| Objective | Prevent double refunds, inconsistent order states, and unsafe refund behavior across projects. |
| Output    | Governance doc + enforcement gates updated accordingly. |
| Note      | Refunds MUST be idempotent via unique idempotency_key. Refund requires admin/super_admin + step-up. Order transitions to refunded only when refunds reach refundable amount. Webhook processing MUST be receipt-first and worker-driven. |

### TOON T05 — Add refund semantics test suite
| Field     | Content |
|-----------|---------|
| Task      | Add `test/store/payments/refund_semantics_test.exs` enforcing idempotency, step-up, state interlocks, and limits. |
| Objective | Make refund drift fail CI immediately. |
| Output    | Tests: step-up required, duplicate refund NOOP, cannot exceed refundable, webhook replay NOOP, order transitions only when refundable reached. |
| Note      | Keep tests deterministic. Use explicit timestamps and stable error codes: REFUND_NOT_ALLOWED, REFUND_EXCEEDS_REFUNDABLE, REFUND_DUPLICATE. |

### TOON G16 — Add tax & shipping determinism governance doc
| Field     | Content |
|-----------|---------|
| Task      | Create `docs/governance/tax_shipping.md` pinning deterministic shipping selection and tax calculation rules. |
| Objective | Prevent rounding drift and inconsistent totals across projects. |
| Output    | Governance doc + enforcement gates updated. |
| Note      | Must use integer minor units only. Must accept explicit `as_of`. Must store shipping/tax evidence snapshots on orders. Tie-break shipping rates deterministically using lowest cost then UUID binary sort. |

### TOON T06 — Add tax & shipping determinism test suite
| Field     | Content |
|-----------|---------|
| Task      | Add `test/store/orders/tax_shipping_determinism_test.exs` enforcing deterministic outputs and rounding correctness. |
| Objective | Make tax/shipping drift fail CI immediately. |
| Output    | Tests: same inputs => same outputs, tie-break determinism, no penny leak, evidence stored and stable. |
| Note      | Tests must not use wall clock. Pass explicit `as_of` and fixed shipping/tax tables. Validate totals equal sum of parts. |


### TOON G17 — Add checkout interlocks governance doc
| Field     | Content |
|-----------|---------|
| Task      | Create `docs/governance/checkout_interlocks.md` defining idempotency keys and replay-safe interlocks for checkout and payment intents. |
| Objective | Prevent double orders, double charges, and duplicate side effects under refreshes/webhook replays. |
| Output    | Governance doc + enforcement gates updated. |
| Note      | MUST define checkout_key and payment_intent_key, both unique. Duplicate begin_checkout must return existing order. Duplicate payment intent creation must return existing intent. Paid side effects must be exactly-once, worker-driven. |

### TOON T07 — Add checkout replay safety test suite
| Field     | Content |
|-----------|---------|
| Task      | Add `test/store/orders/checkout_replay_safety_test.exs` enforcing checkout_key and payment_intent_key idempotency and exactly-once paid side effects. |
| Objective | Make checkout replay drift fail CI immediately. |
| Output    | Tests: begin_checkout idempotency, payment_intent idempotency, duplicate success event NOOP side effects, callback enqueue-only. |
| Note      | Tests must be deterministic and must not depend on wall clock. Use explicit as_of and stable idempotency keys. Ensure side effects are guarded by durable unique event keys. |
