# Subscription Hardening Loop Specification — Historical Notice

**Historical specification version:** `v0.1.8`
**Historical loop protocol:** `v1.4`
**Last canonical full version:** Git commit
`80d44613dc45a26ecb34a8eb6cbad8cce1e4f0c1`

## Supersession

The autonomous Subscription hardening loop was superseded by canonical `main`
governance at commit `59dd41100593b207907c3a7ab4d77755cd80f929`.

This file is historical provenance only. **Do not use it to select, admit,
resume, or execute current SUBS work.** It is not an executable controller
specification and must not be treated as implementation authority.

Current execution authority is:

```text
docs/agent_rules/active_workstreams.md
```

Current SUBS work is `READY` with a separate `SERIAL / EXPLICIT HARDENING`
policy: a human selects one canonical READY issue, materializes one bounded task
from the exact current accepted SUBS tip, completes TDD/minimal implementation,
focused verification, independent review, repository gates and exact-head CI,
then makes the merge decision before another issue is selected.

The retirement of the controller does not supersede frozen Subscription
business/domain law. JC-219 through JC-223 and the existing Subscription
lifecycle and scheduling law remain canonical in their governing records.

The full historical specification remains available in Git at the commit above;
it is intentionally not reproduced here as active-looking instructions.
