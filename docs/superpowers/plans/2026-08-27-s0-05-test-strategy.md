# S0-05 Test Strategy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `verification-before-completion` before claiming this documentation task is complete.

**Goal:** Create an evidence-based test strategy for the existing subscription-commerce implementation without changing application or test behaviour.

**Architecture:** Documentation-only. The strategy will inventory tests and CI/configuration, distinguish executable coverage from future requirements, and classify extraction gates from observed evidence.

**Tech Stack:** Elixir 1.19.5 / OTP 28, Phoenix, Ash 3.x, Ecto/PostgreSQL, Oban, Redis, ExUnit, Benchee, Credo, Dialyzer.

---

### Task 1: Record repository evidence

**Files:** `mix.exs`, `config/test.exs`, `test/test_helper.exs`, `test/support/`, `test/`, `.github/workflows/`, `docs/governance/`

- [x] Inventory test directories and lifecycle, invariant, integration, policy, worker, concurrency, replay, and performance tests.
- [x] Inspect test database, sandbox, Redis, Oban, provider-stub, async, and factory configuration.
- [x] Inspect pull-request and nightly workflow commands, services, and checks.
- [x] Compare observed coverage against the applicable governance requirements.

### Task 2: Write the strategy document

**Files:** `docs/hardening/05_test_strategy.md`, `docs/agent_notes/phase_00_docs.md`

- [x] Create the required current test inventory and confidence/gap table.
- [x] Map lifecycle and invariant evidence for the scoped commerce resources.
- [x] Document payment, subscription, concurrency, security, performance, soak/stress, CI, and extraction testing requirements.
- [x] Keep current facts separate from future extraction gates and record unknowns without proposing implementation changes.

### Task 3: Verify documentation-only completion

**Files:** `docs/hardening/05_test_strategy.md`, `docs/agent_notes/phase_00_docs.md`

- [x] Check links, headings, required sections, wording, and absence of placeholders.
- [x] Confirm no application or test files changed.
- [x] Run `mix check`, `git diff --check`, and repository status checks.
- [ ] Push the documentation commit and close the claimed bead with verification evidence.
