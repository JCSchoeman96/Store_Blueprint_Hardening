# SUB-ACT-04 findings

**Status:** `BLOCKED / STOP`

**Run:** `sub-act-04-20260917T181117Z`

**Date:** 2026-09-17

**Workstream:** `SUBS`

This document records the Batch 001 admission attempt. It does not freeze a
batch base, change the lifecycle, assign task priority, or authorize production
implementation.

## Fixed-point record

| Field | Verified value |
| --- | --- |
| Persistent worktree | `/home/jcschoeman96/projects/current/Store_Blueprint_Hardening-subscriptions` |
| Persistent branch | `hardening/subscriptions` |
| Local HEAD | `8f93e0c9b6edc083093c74cc8e6243259683d50b` |
| `origin/hardening/subscriptions` | `8f93e0c9b6edc083093c74cc8e6243259683d50b` |
| `origin/main` | `baeac140f68db80643b76626e99387089821f790` |
| Accepted development base | `575ffa1848ac69abe855bd018c7ae8eaf05d61e4` |
| Candidate Batch 001 base | `8f93e0c9b6edc083093c74cc8e6243259683d50b` |
| `batch_base_sha` before this run | `null` |
| `integration_base_sha` before this run | `null` |
| Canonical lifecycle | `READY` |

The persistent worktree was clean before and after the admission attempt. The
candidate base was not frozen.

## Why admission stopped

Two independent control-plane conditions prevent activation.

1. The SUBS master register at the candidate tip still describes its current
   fixed point with obsolete hashes: `origin/main =
   95f0a51e6e14e494b30ff589da64ad0d8d15fca8` and
   `origin/hardening/subscriptions =
   4af7f3889d03eea1a9719600202449b5a8e488b8`. Current `origin/main` records
   `baeac140...` and current SUBS authority records `8f93e0c...`.
2. The task-contract template requires `priority = P1 | P2`, but the current
   rows for `SBH-30-02`, `SBH-70-02`, and `SBH-80-01` record no governed
   priority. No priority was inferred from numbering, ordering, severity,
   dependency position, or `READY` state.

The external runtime file is schema `1.4`, but it is an old `run-0a` snapshot.
It has no governance authority hash and still says
`BOOTSTRAPPED / WAITING_FOR_BASELINE_SYNC`. It was not rewritten during this
run because the authority mismatch requires a separately authorized
reconciliation.

The first condition is `AUTHORITY_MOVED`. The second makes every candidate
`BLOCKED_TASK_CONTRACT`. No activation state was persisted.

## Base comparison

`575ffa1848ac69abe855bd018c7ae8eaf05d61e4` is an ancestor of
`8f93e0c9b6edc083093c74cc8e6243259683d50b`.

The interval contains only governance or metadata changes:

```text
.agent-loop/subscriptions/state.example.json
.beads/events.jsonl
.beads/issues.jsonl
.dockerignore
.gitignore
AGENTS.md
docs/governance/subscription_scheduling_terms.md
docs/hardening/01_domain_map.md
docs/hardening/subscriptions/SUBSCRIPTION_HARDENING_CODEX_LOOP_PROMPT.md
docs/hardening/subscriptions/SUBSCRIPTION_HARDENING_LOOP_SPEC.md
docs/hardening/subscriptions/SUBSCRIPTION_HARDENING_MASTER_REGISTER.md
```

The comparison contains no changes under `lib`, `test`, migrations, resource
snapshots, `mix.exs`, or `mix.lock`. The accepted development baseline remains
usable, and the candidate base has no runtime or dependency drift.

## v1.3/v1.4 recertification

The three synthetic proofs were run in an in-memory admission evaluator:

| Proof | Result |
| --- | --- |
| 0A-P, independent READY work while another lane is ahead | `PASS`, `TASK_ADMISSION: EXECUTABLE` |
| 0A-B, one blocked task plus independent READY work | `PASS`, Task A `BLOCKED_EXTERNAL_DEPENDENCY`; Task B selectable |
| 0A-N, every READY task individually blocked | `PASS`, `NO_EXECUTABLE_READY_WORK` |

The evaluator did not manufacture work, waive a dependency, or modify runtime
state.

The tracked controller example contains schema `1.4` and the required
provenance, lifecycle, batch, task, counter, and terminal-outcome fields. The
persisted runtime snapshot still needs fixed-point reconciliation before a
future admission run.

## Candidate findings

The current register has exactly these `READY` and `loop_eligible = true`
candidates. All three declare shared-authority status `NONE` and remain
lane-local at the level of the current register.

### SBH-30-02, retry schedule offset semantics

The scheduler currently clamps an offset of `0` to `24` hours and saturates its
schedule index, which repeats the final configured entry indefinitely. The
facade caller also calculates the next retry from `now` instead of the durable
`past_due_since_at` episode anchor.

Any future contract must cover `0`, `24`, and `72` hours, first-failure
anchoring, normalization, the final entry exactly once, and the exhausted
schedule result. It must remain separate from `SBH-30-03`: no lifecycle
terminalization, suspension, access effect, or new state belongs here.

### SBH-70-02, RenewalAttempt terminal success

The current status actions write directly and do not visibly guard a successful
attempt from later `processing` or `failed` writes. A future contract must
preserve the deterministic renewal key, unique renewal identity, initial claim
CAS, Oban uniqueness, and replay behavior while proving terminal success and
late-failure handling. A migration or Subscription aggregate redesign is out
of scope.

### SBH-80-01, StoredPaymentMethod revocation

The current explicit status actions are unconditional, and `create_or_reuse`
upserts both `status` and `fingerprint`. A future contract must cover that
upsert path as well as `mark_active`, `mark_inactive`, and `mark_revoked`, while
preserving `ACTIVE <-> INACTIVE` and making `REVOKED` terminal. It must not add
AshStateMachine, change provider contracts, or absorb replacement races from
`SBH-80-03`.

## Same-batch scope check

Under the intended bounded scopes, the three lanes have no semantic dependency
on one another and no write conflict:

| Candidate | Intended write scope |
| --- | --- |
| `SBH-30-02` | `scheduler.ex`, one narrow durable-anchor hunk in `facade.ex`, and focused scheduler/retry tests |
| `SBH-70-02` | `renewal_attempt.ex` and a focused RenewalAttempt test file |
| `SBH-80-01` | `stored_payment_method.ex` and its focused test file |

This is a scope check, not an admission. If a future contract expands into a
shared facade function or broad shared test file, the pairwise check must run
again and the affected tasks must be serialized or blocked.

## Contract result

No executable Task Contract was materialized. The template's required priority
field cannot be completed without inventing governance metadata.

```text
SBH-30-02 = INCOMPLETE, priority UNPROVEN
SBH-70-02 = INCOMPLETE, priority UNPROVEN
SBH-80-01 = INCOMPLETE, priority UNPROVEN
```

The smallest required governance correction is:

1. refresh the SUBS register's fixed-point claims against current authority;
2. reconcile the external v1.4 runtime state to the current `READY` fixed
   point; and
3. assign explicit governed `P1` or `P2` metadata to each affected current
   READY row.

This report does not make those corrections.

## Performance and scaling review

- Hot paths: the affected future work concerns retry scheduling, renewal
  attempt writes, and stored-payment-method writes. This findings PR changes no
  hot-path code.
- Warm state: the report and external run evidence are review artifacts. They
  are not application cache or business truth.
- Cold state: no migration, index, snapshot, or dependency change is included.
- Query count and N+1 risk: no application query path changed.
- Indexes: existing renewal and stored-payment-method identities remain the
  authority; future implementation must retain them and use database-side
  guards for terminal transitions.
- Caching: no ETS, Redis, TTL, invalidation, or stampede behavior changed.
- Oban and idempotency: future renewal work must retain existing Oban
  uniqueness and deterministic renewal identity.
- Telemetry and logging: this run is identified by its external evidence run
  ID. No production telemetry changed.

## Security and tenancy review

This PR changes no authorization, provider, payment, order, entitlement, or
web boundary. The project remains single-tenant. No `tenant_id`, tenant
routing, or marketplace behavior is introduced.

## Validation and review

The isolated branch passed the repository gate after dependency setup:

```text
mix check
586 tests, 3 properties, 0 failures
5405 mods/funs, found no issues
```

The command emitted existing Postgrex disconnect, migration-order, and hidden
documentation warnings, but exited with code `0`. `git diff --check` passed.

The fresh independent SUB-ACT-04 reviewer returned `PASS` for the proposed
`BLOCKED / STOP` outcome. The persistent SUBS worktree and branch were not
modified. No production source, test, migration, task branch, or
implementation PR was created by the admission run.

## Next action

Do not start Batch 001 implementation. Complete the separately authorized
governance/runtime reconciliation and explicit priority assignment, then rerun
SUB-ACT-04 against the unchanged candidate tip.
