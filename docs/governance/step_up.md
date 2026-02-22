# Governance: Step-up (Authoritative)

## Definition (MUST)
Step-up is a “recent re-authentication” requirement for sensitive operations.

- step_up_window_minutes: 15 (default)

## Proof mechanism (MUST)
- Session claim: step_up_at (timestamp)
- Set only by an explicit re-auth step (password re-entry; MFA later).

## Enforcement (MUST)
Sensitive operations must refuse unless within window:
- refunds
- payment provider configuration changes
- payout/bank detail changes (if enabled)

## Error semantics (MUST)
- error code: STEP_UP_REQUIRED
- meta:
  - required_window_minutes
  - step_up_last_at (nullable)
