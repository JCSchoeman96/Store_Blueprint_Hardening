# Governance: Step-up (Authoritative)

## Definition (MUST)
Step-up is a “recent re-authentication” requirement for sensitive operations.

- step_up_window_minutes: 15 (default)
- See `docs/governance/time.md` for internal time-unit rules.

## Proof mechanism (MUST)
- Session claim: `step_up_at_mono_usec` (server-issued monotonic microseconds)
- Set only by an explicit re-auth step (password re-entry; MFA later).
- Claim MUST be issued by trusted server code only (never trusted from client input).

## Enforcement (MUST)
Sensitive operations must refuse unless within window:
- refunds
- payment provider configuration changes
- shipping/tax pricing configuration changes
- payout/bank detail changes (if enabled)

## Error semantics (MUST)
- error code: STEP_UP_REQUIRED
- meta:
  - required_window_minutes
  - step_up_last_at_utc (nullable, display only)
