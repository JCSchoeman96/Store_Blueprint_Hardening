# Phase 32 — Railway Go-Live Hardening

## Links Consulted
- https://docs.railway.com/networking/private-networking
- https://docs.railway.com/networking/private-networking/how-it-works
- https://docs.railway.com/reference/config-as-code
- https://docs.railway.com/guides/pre-deploy-command
- https://hexdocs.pm/phoenix/Mix.Tasks.Phx.Gen.Release.html
- https://hexdocs.pm/remote_ip/RemoteIp.html
- https://www.cloudflare.com/ips-v4
- https://www.cloudflare.com/ips-v6

## Decisions / Pins
- No PDF or Chromium work is part of Phase 32.
- Railway deploys use explicit release commands via `bin/store eval ...`; no production `mix` dependency.
- Railway migrations run in the platform pre-deploy hook through `Store.Release.migrate_all/0`.
- `dns_cluster` remains the clustering mechanism.
- Release distribution is explicitly named and Railway-compatible through `rel/env.sh.eex`.
- Client IP recovery behind Cloudflare is trusted-proxy based and must run before waiting-room or request-rate-limit logic.
- CDN/origin hardening is limited to immutable static asset caching and explicit non-caching of waiting-room/dynamic routes.

## Implementation Plan
1. Extend `Store.Release` with explicit migration entrypoints and JSON reports.
2. Add Railway deployment files: `Dockerfile`, `.dockerignore`, `railway.toml`, `rel/env.sh.eex`.
3. Add trusted proxy recovery before endpoint waiting-room/rate-limit plugs using `remote_ip`.
4. Add immutable cache headers for static assets at the Phoenix origin.
5. Expand runtime/runbook checks for clustering, release cookie, trusted proxies, and Railway pre-deploy migration flow.

## Performance & Scaling Review
- Hot path impact:
  - Waiting room and admin/webhook rate limits now key off the actual client IP behind Cloudflare instead of edge proxy IPs.
  - Static asset cache headers reduce origin bandwidth and free the BEAM for HTML/websocket traffic.
- Warm/cold:
  - `dns_cluster` remains optional-safe in single-node mode and active when `DNS_CLUSTER_QUERY` is set.
  - Release migrations stay outside request paths and run only during Railway pre-deploy lifecycle.
- DB / Oban:
  - No new request-path DB work is introduced.
  - Release migration execution is explicit and isolated from normal web boot.
- Telemetry / ops:
  - Existing waiting-room telemetry stays authoritative.
  - Preflight/runtime checks now include trusted proxy and cluster readiness context.
