# Store Blueprint Hardening — Subscription Hardening Loop Specification

**Version:** v0.1.4
**Status:** APPROVED DESIGN / EXECUTION SPECIFICATION  
**Repository:** `JCSchoeman96/Store_Blueprint_Hardening`  
**Workstream:** `SUBS` — Subscription Backbone Hardening  
**Persistent worktree:** `/home/jcschoeman96/projects/current/Store_Blueprint_Hardening-subscriptions`  
**Persistent workstream branch:** `hardening/subscriptions`  
**Primary programme authority:** `SUBSCRIPTION_HARDENING_MASTER_REGISTER.md`

> This specification defines how bounded Subscription hardening work is selected, executed, reviewed, recorded, and stopped. v0.1.4 separates activation feasibility, canonical lane activation, governance/contract freeze, and implementation admission. It does **not** activate SUBS or authorize implementation by itself.

---

# 1. Ultimate Goal

Create a controlled, repeatable hardening loop that can execute already-approved Subscription improvements without repeated human re-prompting while preserving strict authority, lifecycle, scope, review, and merge boundaries.

The review/governance lane decides what “better” means. The loop executes only work that has already been proven, bounded, authorized, and marked `READY`.

---

# 2. Responsibility Boundaries

## Programme authority
Owns scope, lifecycle law, priority, exclusions, accepted risk, and closure criteria. The loop cannot modify programme authority.

## Hardening Register
Owns findings, evidence, dependencies, priority, `loop_eligible`, and READY state. The loop may read it and report new candidates, but may not promote, reprioritize, or rewrite findings.

## Task Contract
Defines exactly one branch-sized implementation unit.

## Deterministic Controller
Owns preflight, fixed-point verification, counters, READY selection, branch naming, retry ceilings, no-progress detection, STOP logic, and run-state persistence.

## Implementation Worker
Owns bounded investigation, TDD, minimal implementation, focused verification, and corrections within task scope.

## Fresh Reviewer
Owns exact-diff, invariant, lifecycle, scope, test, security, and performance review. The reviewer must not modify code.

## Human / Independent Merge Gate
Owns merge authorization, accepted risk, ambiguous product decisions, shared-boundary authority, and architectural reopen decisions. The loop never merges.

---

# 3. Programme → Batch → Beat

## Programme
Long-lived Subscription Hardening programme. Ends only when the final hardening matrix satisfies the Master Register exhaustion criteria.

## Batch
One autonomous invocation may complete `0..3` successful **independent** READY tasks, then must STOP for independent review. Three is a ceiling, not a target.

## Beat
One exact task:

```text
Task Contract
→ task branch
→ deterministic RED
→ minimal implementation
→ GREEN
→ fresh review
→ required full verification
→ draft PR
→ record result
```

---

# 4. Loop Modes

## `PRE_ACTIVATION_VALIDATION`

Purpose: prove the current SUBS development base, canonical governance, local authority package, and task-admission prerequisites without performing implementation.

Before canonical activation, this mode also proves activation feasibility. It does not require an implementation task that already satisfies `state == READY` and `loop_eligible == true`.

Allowed: read Git state, fetch refs, read canonical governance from `origin/main`, read the local Subscription register/spec/template/prompt, fingerprint approved bootstrap authority, verify the accepted development base, verify the ownership and dependency model, confirm an authorized next governance/review task, classify task-specific blockers, and record the feasibility result.

Forbidden: task branch creation, Subscription source changes, migrations, push, implementation PR, merge, deployment.

Valid pre-activation outcomes include:

```text
ACTIVATION_FEASIBILITY_PASS
BASELINE_NOT_PINNED
LOCAL_AUTHORITY_UPGRADE_REQUIRED
BLOCKED_SHARED_AUTHORITY
BLOCKED_EXTERNAL_DEPENDENCY
AUTHORITY_MOVED
PRE_ACTIVATION_STOP
```

Do **not** use `WAITING_FOR_BASELINE_SYNC` or S0 movement as a blanket blocker. Canonical governance merged in PR #8 establishes independent hardening lanes; external changes block only tasks that actually depend on them.

## `ACTIVE_IMPLEMENTATION_BATCH`

May run only when all are true:

```text
canonical governance permits parallel SUBS hardening
SUBS lifecycle == READY or ACTIVE_PARALLEL
accepted development_base_sha is proven
batch_base_sha is frozen
local authority package is tracked/promoted or supplied externally read-only
at least one complete READY Task Contract is executable against the development base
```

If activation cannot be proven: STOP.

`NO_EXECUTABLE_READY_WORK` is not an activation-feasibility result. It remains a valid implementation-selection result after canonical activation, governance/contract freeze, and Batch 001 admission begins.

### Activation control-plane sequence

The following are control-plane phases, not additional persistent workstream lifecycle enum values:

```text
SUB-ACT-01  accepted development base
    ↓
SUB-ACT-02  activation feasibility
    ↓ ACTIVATION_FEASIBILITY_PASS
SUB-ACT-03  canonical ordered BASELINE_PINNED then READY recording
    ↓
SBH-00-01 / SBH-00-02  governance and review work becomes available
    ↓
SBH-00-05  first executable dependency graph and hardening matrix
    ↓
SUB-ACT-04  Batch 001 freeze and implementation-ready admission
```

`SUB-ACT-02` is not executable merely because `SUB-ACT-01` passed. Before it runs, the tracked authority must be v0.1.4 and the external controller state must be compatible with that authority: schema `1.4`, `activation_phase`, and `activation_feasibility` must be present, and any schema migration or runtime reclassification must have been separately authorized and verified. If v0.1.4 authority is tracked while the external runtime remains schema `1.3`, the deterministic result is `LOCAL_AUTHORITY_UPGRADE_REQUIRED → STOP`; `SUB-ACT-02` must not mutate runtime state.

After that compatibility gate, `SUB-ACT-02` proves that a viable authority-compliant path exists. Its proof requires an accepted development base, a valid authority package, valid SUBS ownership, at least one authorized next governance/review task, a usable task-specific external-dependency model, a usable shared-authority model, and no programme-wide blocker. It does not select an implementation-loop READY task.

`SBH-00-01` and `SBH-00-02` remain governance/review tasks with `loop_eligible = No`. They become available only after `SUB-ACT-03`; their availability is not implementation-loop READY admission.

`SUB-ACT-04` owns the Batch 001 base freeze and the v1.3/v1.4 admission recertification. Only after that gate does the implementation loop apply the READY rule below.

The canonical lifecycle responsibility is:

```text
BOOTSTRAPPED
    ↓ SUB-ACT-01 accepted development base, recorded by SUB-ACT-03
BASELINE_PINNED
    ↓ SUB-ACT-02 == ACTIVATION_FEASIBILITY_PASS, recorded by SUB-ACT-03
READY
    ↓ SBH-00 governance and contract freeze evidence
READY with batch admission prepared
    ↓ SUB-ACT-04
ACTIVE_PARALLEL
```

"Governance and contract freeze evidence" and "batch admission prepared" are control-plane evidence phases, not new persistent workstream lifecycle enum values.

`SUB-ACT-03` records two ordered, validated transitions in canonical governance: `BOOTSTRAPPED → BASELINE_PINNED` is guarded by the accepted `SUB-ACT-01` development base, and `BASELINE_PINNED → READY` is guarded by `ACTIVATION_FEASIBILITY_PASS` from `SUB-ACT-02`. A single bounded governance record may record both transitions, but it must not skip `BASELINE_PINNED`. The resulting canonical lane state is `READY`; `SBH-00-01` and `SBH-00-02` then become available as governance/review work. `SUB-ACT-03` does not set `ACTIVE_PARALLEL`, freeze `batch_base_sha`, start Batch 001, or authorize production Subscription implementation. `ACTIVE_PARALLEL` remains a successful `SUB-ACT-04` implementation-admission outcome.

---

# 5. Loop State Machine

This state machine describes implementation-loop execution after `SUB-ACT-04`. The pre-activation control-plane sequence above is evaluated first.

```text
IDLE
  ↓
PREFLIGHT
  ↓
AUTHORITY_VERIFIED
  ↓
DEVELOPMENT_BASE_VERIFIED
  ↓
LOAD_REGISTER
  ↓
SELECT_READY
  ↓
TASK_ADMISSION
  ├── MISSING_EXTERNAL_DEPENDENCY → BLOCK_TASK
  ├── MISSING_SHARED_AUTHORITY → BLOCK_TASK
  ├── NO_EXECUTABLE_READY_WORK → STOP
  └── EXECUTABLE → TASK_CLAIMED
  ↓
BRANCH_CREATED
  ↓
IMPLEMENTING
  ↓
FOCUSED_VERIFY
  ↓
REVIEWING
  ↓ CHANGES_REQUIRED
CORRECTING
  ↓
FOCUSED_VERIFY
  ↓
REVIEWING
  ↓ PASS
FULL_VERIFY
  ↓
COMMIT_PUSH
  ↓
PR_OPEN
  ↓
PR_CI_VERIFY
  ├── TASK_CAUSED_FAILURE → CORRECTING
  ├── UNRELATED_BLOCKING_FAILURE → BLOCKED
  ├── CI_PENDING_LIMIT → CI_PENDING_STOP
  └── PASS → TASK_COMPLETE
  ↓
SELECT_READY
```

Terminal outcomes:

```text
BATCH_REVIEW_REQUIRED
NO_EXECUTABLE_READY_WORK
BLOCKED
BLOCKED_EXTERNAL_DEPENDENCY
BLOCKED_SHARED_AUTHORITY
BASELINE_INVALIDATED
AUTHORITY_MOVED
RETRY_EXHAUSTED
CI_PENDING_STOP
PRE_ACTIVATION_STOP
```

There is intentionally no `MERGED` state.

---

# 6. Mandatory Preflight

Start in:

```text
/home/jcschoeman96/projects/current/Store_Blueprint_Hardening-subscriptions
```

Minimum commands:

```bash
pwd
git status --short --branch
git branch --show-current
git fetch origin
git rev-parse HEAD
git rev-parse origin/hardening/subscriptions
git rev-parse origin/main
git show origin/main:AGENTS.md
git show origin/main:docs/agent_rules/active_workstreams.md
```

Canonical governance is read from current `origin/main`; the SUBS branch does not need to merge main merely to consume governance.

Read local Subscription programme authority after canonical governance:

```text
docs/hardening/subscriptions/SUBSCRIPTION_HARDENING_MASTER_REGISTER.md
docs/hardening/subscriptions/SUBSCRIPTION_HARDENING_LOOP_SPEC.md
docs/hardening/subscriptions/SUBSCRIPTION_TASK_CONTRACT_TEMPLATE.md
docs/hardening/subscriptions/SUBSCRIPTION_HARDENING_CODEX_LOOP_PROMPT.md
```

If an approved document has not yet been committed but is explicitly supplied in-session, treat that copy as read-only authority and record provenance.

Before modification record:

```text
WORKSTREAM:
PATH:
BRANCH:
HEAD:
UPSTREAM:
GOVERNANCE_AUTHORITY_SHA:
DEVELOPMENT_BASE_SHA:
BATCH_BASE_SHA:
INTEGRATION_BASE_SHA:
LIFECYCLE_STATE:
OWNED_AREA:
EXCLUDED_AREA:
```

`integration_base_sha` may be null during ordinary hardening. It is populated only when integration preparation begins.

---

# 7. Preflight STOP Guards

## 7.1 Tracked-worktree rule

Staged or unstaged **tracked** repository changes are never allowed at loop start.

```text
tracked dirt → UNOWNED_DIRT → STOP
```

## 7.2 `LOCAL_AUTHORITY_BOOTSTRAP` exception

Only `PRE_ACTIVATION_VALIDATION` may tolerate untracked files, and only this exact set:

```text
docs/hardening/subscriptions/SUBSCRIPTION_HARDENING_MASTER_REGISTER.md
docs/hardening/subscriptions/SUBSCRIPTION_HARDENING_LOOP_SPEC.md
docs/hardening/subscriptions/SUBSCRIPTION_TASK_CONTRACT_TEMPLATE.md
docs/hardening/subscriptions/SUBSCRIPTION_HARDENING_CODEX_LOOP_PROMPT.md
.agent-loop/subscriptions/state.example.json
```

All five must be present. No sixth untracked path is allowed.

Run 0A computes SHA-256 fingerprints for all five and persists them in external controller state. Every later pre-activation run compares current fingerprints with the stored fingerprints.

```text
fingerprint mismatch → LOCAL_AUTHORITY_DRIFT → STOP
```

The loop may read these files but may not edit them.

## 7.3 Active-mode cleanliness

`ACTIVE_IMPLEMENTATION_BATCH` requires a genuinely clean worktree. The local bootstrap exception is not valid in active mode.

Before active implementation, the authority files must either:

1. be committed/tracked through an explicitly authorized SUBS/governance documentation task; or
2. be removed from the worktree and supplied as external read-only authority.

If untracked bootstrap authority remains when active mode is requested:

```text
BOOTSTRAP_NOT_PROMOTED
STOP
```

## 7.4 General guards

STOP immediately if:

1. `pwd` is not the registered SUBS worktree.
2. current branch is not the expected persistent SUBS branch before task checkout.
3. tracked worktree state is dirty.
4. untracked state violates the mode-specific rule above.
5. upstream cannot be proven when required.
6. registry conflicts with actual Git state.
7. SUBS lifecycle is not `READY` or `ACTIVE_PARALLEL` in implementation mode.
8. canonical governance moved materially or the accepted development base was invalidated.
9. accepted `development_base_sha` or frozen `batch_base_sha` cannot be proven.
10. Master Register is missing, ambiguous, or materially inconsistent with canonical governance.
11. shared-boundary ownership changed.
12. the selected task has an unresolved external dependency or required shared authority.
13. a force push or history rewrite would be required.
14. implementation would have to occur in the permanent `main` worktree.

On STOP: make no speculative correction, create no task branch, persist evidence externally, and exit.

---

# 8. Authorized Batch Base

An activated SUBS lane has an accepted development base and each active batch freezes one exact batch base SHA:

```text
development_base_sha
batch_base_sha
```

Every independent task branch in the batch originates from that SHA unless an explicit Task Contract says otherwise.

Before each new task:

```bash
git switch hardening/subscriptions
git fetch origin
git rev-parse hardening/subscriptions
git rev-parse origin/hardening/subscriptions
```

If persistent branch or remote authority moved relative to the frozen `batch_base_sha`:

```text
AUTHORITY_MOVED
STOP ENTIRE BATCH
```

Never silently rebase, merge, or refresh mid-batch.

---

# 9. READY Selection

This section applies only after canonical lane activation, SBH-00 contract freezing, and `SUB-ACT-04` Batch 001 admission. `SUB-ACT-02` must not call this selector.

A candidate enters task admission only if:

```text
state == READY
loop_eligible == true
product_and_architecture_law == FROZEN
acceptance_criteria == DETERMINISTIC
task development_base_sha == accepted SUBS development_base_sha
task batch_base_sha == current batch_base_sha
```

Then evaluate task-specific dependencies:

```text
external dependency required and absent from development base
→ BLOCKED_EXTERNAL_DEPENDENCY for this task
→ consider next READY task

shared boundary required and authority not assigned
→ BLOCKED_SHARED_AUTHORITY for this task
→ consider next READY task
```

A sibling lane moving is not itself a blocker.

Batch independence must also be true:

```text
semantic_dependency_on_current_batch == false
write_scope_conflict_with_current_batch == false
requires_prior_current_batch_PR_merge == false
```

If no executable READY task remains:

```text
NO_EXECUTABLE_READY_WORK
STOP
```

The controller cannot change item state to manufacture work.

Selection order is deterministic:

1. register priority;
2. dependency order;
3. canonical task ID ascending as tie-breaker.

---

# 10. Task Claim

Before branch creation, load one complete Task Contract containing:

```text
identity
authority
objective
canonical invariant
lifecycle impact
allowed read scope
allowed write scope
forbidden scope
dependencies
shared authority
acceptance criteria
required tests
required quality gates
performance/scaling review
security/multi-tenant review
branch name
STOP conditions
```

If anything materially required is missing or ambiguous:

```text
BLOCKED_TASK_CONTRACT
STOP CURRENT ITEM
```

Do not infer missing product or architecture law.

---

# 11. Branch Creation

Proposed namespace after activation:

```text
subs-task/<canonical-id>-<short-description>
```

Create from exact batch base:

```bash
git switch -c <TASK_BRANCH> <AUTHORIZED_BATCH_BASE_SHA>
```

Guards:

- branch must not already exist locally/remotely unless resumption is explicitly authorized;
- no unrelated commits;
- only one implementation branch checked out in the persistent SUBS worktree at a time.

---

# 12. Implementation Worker

Normal implementation:

```text
Primary skill: $tdd
Supporting instruction: @unslop where available
```

Minimum tools:

```text
filesystem/search
shell
git
mix
existing repository quality commands
test PostgreSQL where genuinely required
gh only for push / draft PR / check inspection
```

Forbidden by default:

```text
production DB
production provider dashboards
deployment tools
browser automation
generic internet research
Redis console
unrelated repository/service mutation
```

Do not add tools unless the Task Contract proves they are necessary.

---

# 13. TDD Beat

```text
READ TASK CONTRACT
↓
READ RELEVANT SOURCE + EXISTING TESTS
↓
WRITE MINIMAL DETERMINISTIC FAILING TEST
↓
RUN FOCUSED TEST
↓
PROVE RED FOR EXPECTED REASON
↓
IMPLEMENT MINIMAL CORRECTION
↓
RUN SAME FOCUSED TEST
↓
PROVE GREEN
```

If RED fails for an unexplained reason, stop normal implementation and use `$diagnosing-bugs` for bounded diagnosis. Do not alter production code until the failure mechanism is understood.

---

# 14. Minimal-Change Rule

Implementation must:

- solve only the approved invariant;
- prefer existing Ash/Elixir patterns;
- preserve proven renewal idempotency/CAS mechanisms;
- avoid opportunistic facade decomposition;
- avoid unrelated cleanup;
- avoid speculative abstractions;
- avoid Redis/distributed locking unless separately authorized;
- keep PostgreSQL as durable Subscription truth.

If smallest correct fix exceeds scope:

```text
BLOCKED_SCOPE
STOP
```

---

# 15. Performance & Scaling Review

Every task must explicitly answer:

```text
What layer does changed data belong to: hot / warm / cold?
Does this add avoidable DB calls?
Is every critical query indexed?
Is any cache derived rather than authoritative?
What invalidates it?
Is a Redis representation actually justified?
Can large data be streamed/batched?
Is this safe under high concurrency?
Does this alter provider or async latency?
Does this introduce cache-stampede/thundering-herd risk?
```

Subscription defaults:

```text
authoritative Subscription lifecycle → PostgreSQL
authoritative RenewalAttempt/contract evidence → PostgreSQL
async work → Oban
realtime notification → Phoenix PubSub after commit
Redis authoritative Subscription truth → forbidden
global Subscription GenServer serialization → forbidden
```

---

# 16. Focused Verification

Use exact Task Contract commands.

At minimum:

- targeted regression test;
- named neighbouring lifecycle tests;
- relevant Ash/action/policy tests;
- `git diff --check`.

Do not run expensive unrelated suites before focused behaviour is green.

---

# 17. Fresh Reviewer Gate

After focused verification, dispatch a **fresh reviewer context**.

Reviewer receives only:

```text
Task Contract
authorized batch base SHA
task branch HEAD SHA
exact base...HEAD diff
focused test commands/results
relevant quality results
```

Reviewer must not edit code.

Required output:

```text
VERDICT: PASS | CHANGES_REQUIRED | BLOCKED

FINDINGS:
- severity
- invariant
- file/surface
- evidence
- required correction
```

Reviewer checks:

1. exact objective;
2. invariant actually proven;
3. lifecycle states/transitions/guards/side effects;
4. scope;
5. shared authority;
6. stale-snapshot/concurrency safety;
7. TDD quality;
8. performance/scaling;
9. security/multi-tenant isolation;
10. no unrelated refactor.

Worker self-review cannot substitute.

If no fresh reviewer can be obtained:

```text
REVIEWER_UNAVAILABLE
STOP CURRENT ITEM
```

---

# 18. Correction Loop

On `CHANGES_REQUIRED`:

```text
review finding
→ correct only finding
→ focused verify
→ fresh review
```

Limits:

```text
maximum correction cycles: 2
maximum no-progress iterations: 2
```

On exhaustion:

```text
RETRY_EXHAUSTED
STOP
```

---

# 19. Full Verification

Only after reviewer PASS, run exact full/relevant quality gates from Task Contract and governance.

Do not invent new required gates.

If full verification reveals unrelated baseline failure:

- establish whether task caused it;
- do not fix unrelated infrastructure;
- STOP where governance requires green and no authority exists.

Maximum task-caused full-quality reruns: `2`.

---

# 20. Commit, Push, Draft PR

Only after focused verification PASS, fresh reviewer PASS, and required full verification PASS:

```bash
git status --short
git diff --check
git add <AUTHORIZED_TASK_FILES_ONLY>
git commit -m "<BOUNDED_TASK_COMMIT_MESSAGE>"
git push -u origin <TASK_BRANCH>
```

Open exactly one **draft PR**, normally targeting the authorized workstream branch:

```text
hardening/subscriptions
```

unless current governance explicitly authorizes a different base.

PR must record:

```text
Task ID
authorized batch base SHA
task HEAD SHA
objective
canonical invariant
scope
tests
quality gates
shared-authority notes
new candidate findings
```

Never merge.

---

# 21. Exact-Head PR CI Verification

A draft PR is not a successful completed task merely because it opened.

Verify all required checks against the exact current task head SHA.

Required result:

```text
required exact-head checks = PASS
```

Use `gh` only for bounded PR/check inspection.

Allow at most one bounded CI wait/check cycle for the current head. If required checks remain pending after that bounded cycle:

```text
CI_PENDING_STOP
STOP ENTIRE BATCH
```

Do not begin another task while the current task's required CI state is unknown.

If required CI fails:

1. determine whether the failure is caused by the task;
2. if task-caused, consume the same correction budget, correct only the bounded task, rerun local focused verification + fresh review + local quality gates, push a new head, and verify exact-head CI again;
3. if unrelated but governance requires green, record evidence and STOP;
4. never repair unrelated CI/platform/performance infrastructure from a Subscription task.

A task increments `successful_pr_count` only after:

```text
draft PR open
AND required exact-head CI PASS
```

---

# 22. Post-PR Record

Persist:

```text
task_id
task_branch
base_sha
head_sha
pr_number
pr_url
review_verdict
focused_verification
full_verification
pr_ci_verification
new_candidate_findings
completed_at
```

Increment `successful_pr_count` only after required exact-head PR CI passes, then return to the persistent branch.

Before next task, re-run authority-moved guard.

---

# 23. Batch Stop

STOP the batch when:

- `successful_pr_count == 3`;
- no READY independent work remains;
- base moves;
- governance moves;
- SUBS lifecycle changes;
- shared authority becomes unresolved;
- a blocking required CI condition appears.

Never start task four.

---

# 24. New Finding Rule

Allowed:

```text
record candidate finding
record bounded evidence
identify impacted domain/workstream
continue current task only if still safe
```

Forbidden:

```text
fix new finding
expand current scope
mark it READY
reprioritize register
modify another domain
```

---

# 25. Machine State

Runtime state is persisted outside Git under:

```text
${XDG_STATE_HOME:-$HOME/.local/state}/store-blueprint-hardening/subscription-hardening/
```

`.agent-loop/subscriptions/state.example.json` is schema/documentation only and must never be runtime-written.

The v1.4 example records the corrected control-plane fields. The external runtime remains on its existing schema until a separate runtime migration/reclassification gate authorizes that change.

Minimum conceptual state:

```json
{
  "schema_version": "1.4",
  "programme": "subscription-hardening",
  "mode": "PRE_ACTIVATION_VALIDATION",
  "activation_phase": "PRE_ACTIVATION_FEASIBILITY",
  "activation_feasibility": null,
  "governance_authority_sha": null,
  "development_base_sha": null,
  "batch_base_sha": null,
  "integration_base_sha": null,
  "batch_id": null,
  "workstream_branch": "hardening/subscriptions",
  "lifecycle_state": null,
  "successful_pr_count": 0,
  "current_task_id": null,
  "current_task_branch": null,
  "current_task_state": null,
  "blocked_tasks": [],
  "terminal_outcome": null
}
```

Semantics:

- `activation_phase` identifies the control-plane phase; it is separate from `lifecycle_state` and does not add a workstream lifecycle enum.
- `activation_feasibility` is null before `SUB-ACT-02`, or `ACTIVATION_FEASIBILITY_PASS` after that bounded proof. It is not implementation task admission.
- `governance_authority_sha` = canonical main governance observed for the run.
- `development_base_sha` = accepted SUBS code base for independent hardening.
- `batch_base_sha` = exact SUBS branch SHA frozen for the current batch.
- `integration_base_sha` = null during normal hardening; populated when entering integration preparation.

Runtime state must never silently reinterpret one SHA role as another.

---

# 26. Run Evidence

Runtime evidence directory:

```text
${XDG_STATE_HOME:-$HOME/.local/state}/store-blueprint-hardening/subscription-hardening/runs/<RUN_ID>/
├── preflight.json
├── selection.json
├── task-<id>-contract.md
├── task-<id>-implementation-summary.md
├── task-<id>-review.json
├── task-<id>-verification.json
└── result.json
```

Keep model context bounded; summarize logs rather than repeatedly pasting raw output.

---

# 27. Loop v1.4 Hard Limits

| Guard | Limit |
|---|---:|
| Successful draft PRs per batch | 3 |
| Active implementation workers | 1 |
| Correction cycles per task | 2 |
| No-progress iterations | 2 |
| Full-quality reruns caused by correction | 2 |
| Bounded PR CI wait/check cycles per head | 1 |
| Automatic merges | 0 |
| Production operations | 0 |
| Self-authorized findings | 0 |
| Self-authorized shared-boundary changes | 0 |

---

# 28. Universal STOP Conditions

STOP when:

1. authority SHA moves;
2. workstream lifecycle is not authorized;
3. registry and Git reality disagree;
4. worktree is unexpectedly dirty;
5. path/branch/upstream is wrong;
6. task contract is incomplete;
7. product semantics are ambiguous;
8. architecture decision is unresolved;
9. shared authority is absent;
10. migration authority is absent where required;
11. correct fix crosses excluded ownership;
12. new lifecycle state/resource is required without approval;
13. reviewer is unavailable;
14. two correction cycles fail;
15. two iterations make no meaningful progress;
16. required quality gates cannot pass without expanding scope;
17. production access/credentials/deployment/destructive action is required;
18. exact batch base moves;
19. three successful PRs exist;
20. no READY independent work exists;
21. terminal task/batch outcome has been recorded.

On STOP:

```text
record evidence
record terminal outcome
do not speculate
do not merge
do not deploy
do not self-authorize next work
```

---

# 29. Run 0 Validation / v1.4 Admission Recertification

The original v1.2 Run 0A/0B/0C certification remains valid evidence for bounded worker/reviewer mechanics. v1.3 evidence remains historical admission evidence. v1.4 changes activation sequencing, so run these targeted admission proofs after the activation and contract-freeze gates.

## Run 0A-P — Parallel admission positive

Synthetic scenario:

```text
SUBS development base pinned
S0 or another lane is ahead
READY task has no dependency on that external change
```

Expected:

```text
TASK_ADMISSION: EXECUTABLE
```

## Run 0A-B — Task-specific blocker with alternate work

Synthetic scenario:

```text
Task A READY but requires missing external capability
Task B READY and independent
```

Expected:

```text
Task A → BLOCKED_EXTERNAL_DEPENDENCY
Task B → selectable
```

## Run 0A-N — No executable work

Synthetic scenario:

```text
all READY tasks are individually blocked
```

Expected:

```text
NO_EXECUTABLE_READY_WORK
STOP
```

Do not repeat the full worker/reviewer bad-change certification unless implementation/reviewer mechanics change.

---

# 30. Activation Gate for Real Batch 001

Real Subscription implementation begins only when:

```text
canonical PR #8 parallel-governance floor is present on origin/main
SUBS development_base_sha == explicitly accepted
SUBS lifecycle == READY or ACTIVE_PARALLEL
local v1.4 authority package == promoted/tracked or external read-only
v1.3/v1.4 admission recertification == PASS
Master Register == current authority
SBH-00-05 == completed and executable dependency graph frozen
at least one task == READY and loop_eligible
that task is executable against development_base_sha
required shared authority == assigned
batch_base_sha == explicitly frozen
```

Continuous synchronization from S0 is not required.

Otherwise STOP.

---

# 31. Loop v1.4 Success Criteria

Loop v1.4 succeeds when it can:

- refuse unauthorized work;
- deterministically select only READY items;
- isolate one branch-sized task;
- prove RED before implementation;
- produce minimal GREEN changes;
- obtain fresh independent review;
- bound corrections;
- run exact quality gates;
- open one draft PR per successful task;
- require required exact-head CI to pass before a task counts as successful;
- stop after at most three successful independent PRs;
- persist enough state for safe interruption/resume;
- report new candidates without implementing them;
- never merge;
- never deploy;
- never broaden its own authority.

---

# 32. Current Expected Behaviour

Before canonical lane activation is recorded, the v1.4 authority can prove feasibility without implementation-loop READY work:

```text
MODE: PRE_ACTIVATION_VALIDATION
CANONICAL GOVERNANCE: PARALLEL MODEL PRESENT
DEVELOPMENT BASE: CANDIDATE_OR_PINNED_AS_RECORDED
LOCAL AUTHORITY: v1.4
RUNTIME COMPATIBILITY: VERIFIED_V1_4 | LOCAL_AUTHORITY_UPGRADE_REQUIRED
ACTIVATION FEASIBILITY: ACTIVATION_FEASIBILITY_PASS | BLOCKED
OUTCOME: ACTIVATION_FEASIBILITY_PASS | PRE_ACTIVATION_STOP | TASK_SPECIFIC_BLOCKER
SOURCE CHANGES: 0
TASK BRANCHES: 0
PRS: 0
FINAL ACTION: STOP
```

After `SUB-ACT-03`, SBH-00 governance/review work is available. After `SBH-00-05` and `SUB-ACT-04`, the implementation loop may admit only task-specific executable READY work. If no such task exists then `NO_EXECUTABLE_READY_WORK → STOP` remains valid.
