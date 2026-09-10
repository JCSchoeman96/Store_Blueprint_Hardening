# S0-CLOSE-06 provider-fault pool gates implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Separate the existing whole-request Store.Repo capacity gate from the existing provider-wait isolation gate without changing either threshold or production payment behavior.

**Architecture:** `Store.PerformanceSmoke.ObserverContract` remains the single owner of phase classification, whole-window summary values, and provider-wait peak calculation. The standalone smoke script will require both `observer_summary.pass` for the generic whole-window contract and a provider-wait-only predicate for the provider-fault threshold. Focused tests will use synthetic phase samples and keep the existing attribution, UUID, contention, and enforcement coverage.

**Tech Stack:** Elixir, ExUnit, Ecto/PostgreSQL observer telemetry, standalone `mix run` performance harness.

---

### Task 1: Add failing phase-gate contract tests

**Files:**
- Modify: `test/store/perf/observer_contract_test.exs`

- [ ] **Step 1: Add tests for the provider-wait-only predicate and explicit phase peaks.** Use the existing `phase_sample/2`, `config/0`, and `ObserverContract.summarize/4` helpers. The tests will call the new `ObserverContract.provider_wait_pool_gate_pass?/2` function and assert that whole-window and provider-wait decisions are independent:

```elixir
test "provider-wait gate ignores pre-provider pressure below the generic limit" do
  summary =
    ObserverContract.summarize(
      "provider_fault_slow_observer",
      config(),
      [phase_sample(:pre_provider, 0.6), phase_sample(:provider_wait, 0.0)],
      enforced: true
    )

  assert summary.pass
  assert ObserverContract.provider_wait_pool_gate_pass?(summary, 0.35)
  assert summary.peak_repo_active_backend_utilization == 0.6
  assert summary.provider_wait_repo_utilization_peak == 0.0
end

test "provider-wait gate fails only when provider-wait utilization exceeds 0.35" do
  summary =
    ObserverContract.summarize(
      "provider_fault_slow_observer",
      config(),
      [phase_sample(:pre_provider, 0.2), phase_sample(:provider_wait, 0.4)],
      enforced: true
    )

  refute ObserverContract.provider_wait_pool_gate_pass?(summary, 0.35)
end

test "missing provider-wait samples fail the provider-wait gate" do
  summary =
    ObserverContract.summarize(
      "provider_fault_slow_observer",
      config(),
      [phase_sample(:pre_provider, 0.6), phase_sample(:post_provider, 0.6)],
      enforced: true
    )

  refute ObserverContract.provider_wait_pool_gate_pass?(summary, 0.35)
  assert summary.provider_wait_sample_count == 0
end

test "summary retains independent pre, provider-wait, post, and whole-window peaks" do
  summary =
    ObserverContract.summarize(
      "provider_fault_slow_observer",
      config(),
      [
        phase_sample(:pre_provider, 0.6),
        phase_sample(:provider_wait, 0.2),
        phase_sample(:post_provider, 0.8)
      ],
      enforced: true
    )

  assert summary.peak_repo_active_backend_utilization == 0.8
  assert summary.pre_provider_repo_utilization_peak == 0.6
  assert summary.provider_wait_repo_utilization_peak == 0.2
  assert summary.post_provider_repo_utilization_peak == 0.8
end
```

- [ ] **Step 2: Add focused cases for the generic `0.95` observer gate, `ci_gate` enforcement, the existing UUID/expected-contention/attribution/DirectRepo regressions, provider expectation, DB-share, and lock gate behavior.** Keep the existing passing tests and add only assertions for behavior not already covered. A whole-window value of `1.0` must continue to make `summary.pass` false; a whole-window value of `0.6` must leave it true when no lock or drain gate fails.

- [ ] **Step 3: Run the focused test file before implementation.**

Run:

```bash
mix test test/store/perf/observer_contract_test.exs
```

Expected result: the new tests fail because the provider-wait predicate and pre/post peak fields do not yet exist. Existing tests must not fail for unrelated reasons.

### Task 2: Implement the observer contract split

**Files:**
- Modify: `test/support/performance_smoke_observer_contract.ex`

- [ ] **Step 1: Add explicit pre-provider and post-provider peak fields beside the existing provider-wait fields.** Compute every phase peak by filtering `classified_samples` on the phase atom. Keep the existing whole-window `peak_repo_active_backend_utilization` and provider-wait fields so previous observer evidence remains readable.

- [ ] **Step 2: Add the minimal provider-wait gate predicate.** It must require `provider_wait_sample_count > 0` and compare `provider_wait_repo_utilization_peak` to the supplied existing threshold. It must return `false` for missing wait samples rather than treating the empty phase as `0.0`.

```elixir
@spec provider_wait_pool_gate_pass?(map(), number()) :: boolean()
def provider_wait_pool_gate_pass?(summary, max_ratio)
    when is_map(summary) and is_number(max_ratio) do
  Map.fetch!(summary, :provider_wait_sample_count) > 0 and
    Map.fetch!(summary, :provider_wait_repo_utilization_peak) <= max_ratio
end
```

- [ ] **Step 3: Keep `summary.pass` as the generic whole-window source of truth.** It must continue using `pool_utilization_max_ratio` and the existing generic lock/drain rules. Do not place the provider-fault `0.35` threshold inside `summary.pass`.

### Task 3: Make provider-fault evaluation require both contracts

**Files:**
- Modify: `priv/repo/performance_smoke_test.exs`

- [ ] **Step 1: Replace the provider-fault whole-window pool comparison with the two independent checks.** The pressure expression must use `observer_summary.pass` for the generic whole-window contract, the unchanged DB-share comparison, the new provider-wait predicate with the existing mode-specific provider threshold, and the existing whole-request provider lock comparison.

```elixir
provider_wait_pool_pass =
  ObserverContract.provider_wait_pool_gate_pass?(
    observer_summary,
    pool_utilization_max_ratio
  )

pressure_pass =
  observer_summary.pass and
    mean_db_share_ratio <= config.provider_fault_db_share_max_ratio and
    provider_wait_pool_pass and
    observer_summary.peak_lock_wait_ratio <= config.provider_fault_lock_wait_max_ratio
```

- [ ] **Step 2: Preserve diagnostics in the provider-fault summary.** Emit whole-window, pre-provider, provider-wait, and post-provider Store.Repo utilization values, plus provider-wait sample count and whether the provider-wait gate passed. Keep the existing whole-window peak visible in the report table. Do not add a second generic `0.95` comparison.

- [ ] **Step 3: Include missing provider-wait evidence in the failure message.** A slow-provider scenario with no `PROVIDER_WAIT` sample must report the missing evidence and fail when the profile is enforced.

### Task 4: Verify focused behavior and repository gates

**Files:**
- No additional files.

- [ ] **Step 1: Run the focused observer/provider contract tests and confirm zero failures.**

```bash
mix test test/store/perf/observer_contract_test.exs
```

- [ ] **Step 2: Run the repository quality gate.**

```bash
mix check
```

Expected result: format, compile, dependency audit, static gates, tests, Credo, and docs all pass. Do not run the performance smoke script as part of this step.

- [ ] **Step 3: Check the patch and scope.**

```bash
git diff --check
git status -sb
git diff --name-only
```

The implementation scope must contain only the existing performance harness/support/test files plus this execution plan. No production commerce file, migration, dependency, CI, or pool configuration may appear.

### Task 5: Run one canonical normal profile and stop on the first truthful failure

**Files:**
- No additional files.

- [ ] **Step 1: Run exactly one canonical normal-profile performance execution from the verified state.** Use the repository's existing canonical normal command and unchanged profile, pool, concurrency, provider, and threshold settings. Capture whole-window, pre-provider, provider-wait, post-provider, generic observer, provider-wait, DB-share, lock, provider outcome, queue, and overall results.

- [ ] **Step 2: If the run passes, record the result and restart the bounded 3 normal plus 3 chaos certification cycle from this exact state.** Do not retry an individual failed run. If any corrected gate fails, stop and report that gate without changing code, thresholds, pool size, concurrency, or production behavior.

- [ ] **Step 3: Do not commit, push, merge, update final S0 closure documentation, or start S1 in this task.** Those actions require the full S0-CLOSE-02 through S0-CLOSE-06 chain and independent review.

## Plan self-review

- The plan covers generic whole-request enforcement, provider-wait-only enforcement, missing evidence, four phase diagnostics, existing DB-share and lock gates, attribution and UUID/contention regressions, quality gates, and the one-run certification stop rule.
- No production payment file, migration, dependency, pool, threshold, workload, or CI change is planned.
- The only new function name is `provider_wait_pool_gate_pass?/2`; all phase fields use the existing `*_repo_utilization_peak` naming pattern.
- The plan does not alter historical failed-run evidence or final closure documentation.
