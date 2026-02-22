# Governance: Time Policy (Authoritative)

## Internal units (MUST)
- Internal duration/window logic uses monotonic microseconds (`*_usec`).
- Use `System.monotonic_time(:microsecond)` for recency/timeout checks.

## Persistence and display (MUST)
- Persisted business/audit timestamps use UTC datetime columns (`*_at`, `inserted_at`, `updated_at`).
- UTC timestamps are for display/reporting, not recency authorization math.

## Step-up contract (MUST)
- Policy checks consume `context[:step_up_at_mono_usec]`.
- This value is server-issued only after trusted step-up completion (reauth/MFA boundary).
- Client-provided timestamps must never be trusted for step-up authorization.

## Naming conventions (MUST)
- Duration values: `*_usec`
- Monotonic points: `*_mono_usec`
- UTC points: `*_utc` (or existing `*_at` schema timestamps)

## Boundary conversions (MUST)
- Convert units only at edges (Redis/API/JS).
- Keep core authorization/state logic in monotonic microseconds.
