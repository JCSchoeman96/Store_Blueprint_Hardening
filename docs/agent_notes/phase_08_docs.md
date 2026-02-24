# Phase 08 — Side effects quarantine

## GOAL

Implement Phase 08 side-effects quarantine so the web layer stays pure: no outbound HTTP in web, no web enqueue outside webhook allowlist, webhook controller stores receipt evidence and enqueues only, and worker performs transitions.

## LINKS CONSULTED

- Project docs:
  - `docs/phases/phase_08_side_effects_quarantine.md`
  - `docs/governance/side_effects_quarantine.md`
  - `docs/governance/enforcement_gates.md`
- Official docs:
  - https://hexdocs.pm/oban/Oban.html
  - https://hexdocs.pm/oban/Oban.Worker.html
  - https://hexdocs.pm/oban/Oban.Testing.html
  - https://hexdocs.pm/oban/Oban.Migrations.html
  - https://hexdocs.pm/req/Req.html

## PLAN

- Add Oban baseline wiring (config, supervision, migration, test mode).
- Add CI gates:
  - deny `Req` / `Store.Support.HTTP.ReqClient` under `lib/store_web/**`.
  - deny `Oban.insert` / `Oban.insert_all` under `lib/store_web/**` except webhook controller allowlist.
- Implement receipt-first webhook flow:
  - controller reads raw request body and captures headers.
  - deterministic idempotency key: `sha256("#{provider}\n" <> raw_body)`.
  - controller ingests receipt and enqueues worker only.
- Implement worker-owned payment transition proof:
  - worker reads receipt and marks `PaymentIntent` from `submitted` to `succeeded`.
- Add tests proving enqueue-only controller and worker transition ownership.

## DONE

- Created Phase 08 bead tree and dependencies:
  - `store_blueprint-7yf.2` (parent)
  - `store_blueprint-7yf.2.1` docs + notes
  - `store_blueprint-7yf.2.2` Oban baseline
  - `store_blueprint-7yf.2.3` CI gates
  - `store_blueprint-7yf.2.4` webhook + worker
  - `store_blueprint-7yf.2.5` verification + closure
- Oban baseline implemented:
  - Added Oban config in `config/config.exs`.
  - Added test manual mode in `config/test.exs`.
  - Added Oban child in `lib/store/application.ex`.
  - Added migration `priv/repo/migrations/20260224120000_phase_08_side_effects_quarantine.exs` using `Oban.Migrations.up/down`.
- Web side-effects gates implemented and wired into `mix check`:
  - `lib/mix/tasks/check/web_no_http.ex`
  - `lib/mix/tasks/check/web_no_oban_enqueue.ex`
  - `mix.exs` alias now runs both tasks.
- Webhook enqueue-only flow implemented:
  - Added raw-body capture plug helper `lib/store_web/raw_body_reader.ex`.
  - Endpoint parser uses body reader in `lib/store_web/endpoint.ex`.
  - Added `lib/store_web/controllers/webhook_controller.ex`.
  - Added route `POST /api/webhooks/:provider` in `lib/store_web/router.ex`.
  - Controller stores receipt evidence (`raw_body`, `headers`) and enqueues only.
- Deterministic idempotency implemented:
  - `WebhookReceipt.ingest` computes `idempotency_key = sha256("#{provider}\n" <> raw_body)` when not explicitly provided.
  - Duplicate ingest remains NOOP-safe due upsert identity.
- Worker transition ownership implemented:
  - Added `lib/store/workers/process_webhook_receipt_worker.ex`.
  - Worker loads receipt, extracts `payment_intent_id`, and performs `PaymentIntent submitted -> succeeded`.
- Tests added:
  - `test/store_web/controllers/webhook_controller_test.exs` (enqueue-only + duplicate ingest NOOP).
  - `test/store/workers/process_webhook_receipt_worker_test.exs` (worker transition ownership).

## NEXT

- Update bead notes and close Phase 08 child beads in dependency order.
- Close Phase 08 parent bead and run final sync/push checklist.

## BLOCKERS

- None currently.

## GATES

- Pending implementation for Phase 08:
- `check.web_no_http` gate active.
- `check.web_no_oban_enqueue` gate active with webhook controller allowlist.
- webhook enqueue-only test active.
- worker transition ownership test active.
- Manual fail/pass proof completed:
  - temporary `Req` reference in web -> `check.web_no_http` failed.
  - temporary `Oban.insert` reference in non-allowlisted web file -> `check.web_no_oban_enqueue` failed.
  - removal of temporary lines restored pass state.

## PERFORMANCE/SCALING REVIEW

- Hot path:
  - webhook controller request path performs receipt upsert + single enqueue only.
  - no provider HTTP on request path.
- Warm path:
  - worker queue `webhooks` handles transition asynchronously.
  - duplicate events remain NOOP-safe via receipt idempotency key.
- Cold path:
  - Oban pruning plugin removes stale jobs (24h max age baseline).
- Indexes:
  - Existing `webhook_receipts` unique index on `idempotency_key` remains core dedupe gate.
  - Existing provider/received_at indexes remain effective for ops queries.
- TTL/invalidation/PubSub:
  - no cache invalidation introduced in this phase.
  - no PubSub fanout introduced in this phase.

## COMMANDS RUN

- `bd prime --json`
- `bd ready --json`
- `bd create ...` for `store_blueprint-7yf.2` and child beads
- `bd dep add ...`
- `bd dep cycles`
- `mix format`
- `mix test test/store_web/controllers/webhook_controller_test.exs test/store/workers/process_webhook_receipt_worker_test.exs test/store/governance/uniqueness_gates_test.exs test/store/governance/policy_matrix_test.exs`
- `mix check.web_no_http` (pass)
- `mix check.web_no_oban_enqueue` (pass)
- `mix check.web_no_http` (intentional fail + pass after revert)
- `mix check.web_no_oban_enqueue` (intentional fail + pass after revert)
- `mix check`
