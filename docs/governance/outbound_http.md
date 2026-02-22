# Governance: Outbound HTTP (Authoritative)
This document prevents drift and unsafe retries in external calls.

## Rules (MUST)
1) All outbound HTTP calls MUST go through `Store.Support.HTTP.ReqClient`.
2) Direct usage of `Req.*` is forbidden outside the wrapper.
3) Money flows MUST NOT use inline retry loops (retries happen via Oban with idempotency).
4) Wrapper MUST set explicit timeouts.
5) Logs MUST NOT include secrets.

## Retry policy (baseline)
- Safe idempotent GET/HEAD: small bounded retry (1–2) with jitter
- Webhooks/payments/refunds: no inline retries; use Oban retries

## Enforcement gate (MUST)
`mix check` MUST fail if `Req.` appears outside:
- `lib/store/support/http/req_client.ex` (wrapper)

Preferred: Credo/custom check; fallback: mix task + ripgrep denylist.

## Test gates (P0)
- Wrapper unit tests for defaults
- No raw Req usage gate proven active
