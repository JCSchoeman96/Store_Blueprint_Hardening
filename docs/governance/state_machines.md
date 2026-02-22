# Governance: State Machines (Authoritative)
This document defines the **enforceable** lifecycle models for Orders and Payments.

## Non-negotiable rules
- State transitions MUST be explicit and limited to the tables below.
- Forbidden transitions MUST return `INVALID_STATE_TRANSITION`.
- Transition actions MUST be idempotent for replays.
- Lifecycle writes MUST use optimistic locking (stale writes -> `STALE_RECORD`).
- Multi-record operations MUST acquire locks using the Lock Ordering Law (binary raw16 UUID order).

## Orders.Order lifecycle

### States
- pending_payment
- paid
- cancelled
- refunded

### Transition table (MUST)
| From            | To             | Allowed | Trigger | Replay behavior |
|----------------|----------------|---------|---------|-----------------|
| pending_payment| paid           | YES     | verified payment success | if already paid: NOOP |
| pending_payment| cancelled      | YES     | customer/admin cancel | if already cancelled: NOOP |
| paid           | refunded       | YES     | refund confirmed | if already refunded: NOOP |
| paid           | cancelled      | NO      | — | INVALID_STATE_TRANSITION |
| cancelled      | *any*          | NO      | — | INVALID_STATE_TRANSITION |
| refunded       | *any*          | NO      | — | INVALID_STATE_TRANSITION |

## Payments.PaymentIntent lifecycle

### States
- created
- submitted
- succeeded
- failed
- cancelled

### Transition table (MUST)
| From      | To         | Allowed | Trigger | Replay behavior |
|----------|------------|---------|---------|-----------------|
| created  | submitted  | YES     | provider intent created/confirmed | if already submitted: NOOP |
| submitted| succeeded  | YES     | verified provider event | if already succeeded: NOOP |
| submitted| failed     | YES     | verified provider event | if already failed: NOOP |
| created  | cancelled  | YES     | user/admin cancel | if already cancelled: NOOP |
| succeeded| *any*      | NO      | — | INVALID_STATE_TRANSITION |
| failed   | *any*      | NO      | — | INVALID_STATE_TRANSITION |
| cancelled| *any*      | NO      | — | INVALID_STATE_TRANSITION |

## Test gates (MUST)
- Allowed transitions succeed.
- Forbidden transitions fail with `INVALID_STATE_TRANSITION`.
- Replay tests: applying success/failure twice produces NO duplicate side effects.
- Stale write test produces `STALE_RECORD`.
