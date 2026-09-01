defmodule Store.PerformanceSmoke.ObserverContractTest do
  use ExUnit.Case, async: true

  alias Store.PerformanceSmoke.ConnectionIdentity
  alias Store.PerformanceSmoke.ObserverContract
  alias Store.PerformanceSmoke.ProviderPhase

  test "expected reservation waits remain visible without failing the unexpected-lock gate" do
    summary =
      ObserverContract.summarize(
        "domain_thundering_herd_observer",
        config(),
        [sample(10, [expected_waiter(), expected_waiter()])],
        expected_scope: reservation_scope(),
        drain: drained(),
        enforced: config().enforced
      )

    assert summary.pass
    assert summary.expected_contention_observed?
    assert summary.peak_total_lock_waiters == 2
    assert summary.peak_expected_reservation_waiters == 2
    assert summary.peak_unexpected_lock_waiters == 0
    assert summary.samples_over_unexpected_lock_threshold == 0
  end

  test "unexpected lock contention above 0.10 fails" do
    summary =
      ObserverContract.summarize(
        "generic_observer",
        config(),
        [sample(10, [unexpected_waiter(), unexpected_waiter()])],
        enforced: config().enforced
      )

    refute summary.pass
    assert summary.peak_unexpected_lock_waiters == 2
    assert summary.peak_unexpected_lock_wait_ratio == 0.2
    assert summary.samples_over_unexpected_lock_threshold == 1
  end

  test "pool utilization above 0.95 fails independently of lock classification" do
    summary =
      ObserverContract.summarize(
        "pool_observer",
        config(),
        [%{sample(40, []) | active_backend_utilization: 1.0}],
        enforced: config().enforced
      )

    refute summary.pass
    assert summary.peak_unexpected_lock_waiters == 0
    assert summary.samples_over_pool_threshold == 1
  end

  test "whole-window utilization at 0.60 passes the generic 0.95 gate" do
    summary =
      ObserverContract.summarize(
        "provider_fault_slow_observer",
        config(),
        [phase_sample(:pre_provider, 0.6)],
        enforced: true
      )

    assert summary.pass
    assert summary.peak_repo_active_backend_utilization == 0.6
    assert summary.samples_over_pool_threshold == 0
  end

  test "expected reservation contention that does not drain fails" do
    summary =
      ObserverContract.summarize(
        "domain_thundering_herd_observer",
        config(),
        [sample(10, [expected_waiter()])],
        expected_scope: reservation_scope(),
        drain: %{
          enabled?: true,
          drained?: false,
          post_workload_sample: sample(10, [expected_waiter()])
        },
        enforced: config().enforced
      )

    refute summary.pass
    refute summary.drained?
    assert summary.post_workload_expected_reservation_waiters == 1
  end

  test "summary retains expected contention visibility and post-workload evidence" do
    summary =
      ObserverContract.summarize(
        "domain_thundering_herd_observer",
        config(),
        [sample(10, [expected_waiter(), unexpected_waiter()])],
        expected_scope: reservation_scope(),
        drain: drained(),
        enforced: config().enforced
      )

    assert summary.expected_contention_observed?
    assert summary.peak_total_lock_waiters == 2
    assert summary.peak_expected_reservation_waiters == 1
    assert summary.peak_unexpected_lock_waiters == 1
    assert summary.post_workload_waiters == 0
    assert summary.post_workload_expected_reservation_waiters == 0
    assert summary.post_workload_unexpected_lock_waiters == 0
    assert summary.drained?
  end

  test "generic observer behavior treats every lock waiter as unexpected without a scope" do
    summary =
      ObserverContract.summarize(
        "generic_observer",
        config(),
        [sample(10, [expected_waiter(), unexpected_waiter()])],
        enforced: config().enforced
      )

    refute summary.pass
    refute summary.expected_contention_observed?
    assert summary.peak_expected_reservation_waiters == 0
    assert summary.peak_unexpected_lock_waiters == 2
    assert summary.peak_lock_waiters == 2
  end

  test "missing enforcement policy fails closed instead of defaulting false" do
    assert_raise KeyError, fn ->
      ObserverContract.summarize("observer_without_policy", config(), [sample(2, [])])
    end
  end

  test "enforced profile handoff remains enabled for ci_gate and full_stress" do
    for profile <- [:ci_gate, :full_stress] do
      summary =
        ObserverContract.summarize(
          "#{profile}_observer",
          config_without_enforcement(),
          [sample(2, [])],
          enforced: true
        )

      assert summary.enforced
      assert summary.pass
    end
  end

  test "non-enforcing profile preserves pass-through behavior" do
    summary =
      ObserverContract.summarize(
        "local_dev_observer",
        config_without_enforcement(),
        [%{sample(40, []) | active_backend_utilization: 1.0}],
        enforced: false
      )

    refute summary.enforced
    assert summary.pass
    assert summary.samples_over_pool_threshold == 1
  end

  test "expected contention cannot bypass an enforced pool threshold" do
    summary =
      ObserverContract.summarize(
        "domain_thundering_herd_observer",
        config_without_enforcement(),
        [%{sample(40, [expected_waiter()]) | active_backend_utilization: 1.0}],
        expected_scope: reservation_scope(),
        drain: drained(),
        enforced: true
      )

    refute summary.pass
    assert summary.enforced
    assert summary.peak_expected_reservation_waiters == 1
    assert summary.samples_over_pool_threshold == 1
  end

  test "converts canonical UUID strings to 16-byte observer query parameters" do
    uuid = "018f0b5b-6d4e-7a21-8c1f-123456789abc"

    assert <<_::binary-size(16)>> = ObserverContract.uuid_param!(uuid)
  end

  test "rejects malformed UUID observer query parameters explicitly" do
    assert_raise ArgumentError, ~r/invalid observer UUID parameter/, fn ->
      ObserverContract.uuid_param!("not-a-uuid")
    end
  end

  test "attributes active Store.Repo sessions to the Store.Repo population" do
    rows = [
      backend_row(101, ConnectionIdentity.store_repo_application_name()),
      backend_row(202, ConnectionIdentity.direct_repo_application_name()),
      backend_row(303, "unrelated_client")
    ]

    populations = ObserverContract.connection_populations(rows, 40, 10)

    assert populations.total_active_backends == 3
    assert populations.repo_active_backends == 1
    assert populations.direct_repo_active_backends == 1
    assert populations.other_active_backends == 1
    assert populations.repo_pool_size == 40
    assert populations.repo_utilization == 1 / 40
  end

  test "excludes the observer session from every active population" do
    rows = [
      backend_row(999, ConnectionIdentity.store_repo_application_name()),
      backend_row(101, ConnectionIdentity.store_repo_application_name()),
      backend_row(202, ConnectionIdentity.direct_repo_application_name())
    ]

    populations =
      ObserverContract.connection_populations(rows, 40, 10, observer_pid: 999)

    assert populations.total_active_backends == 2
    assert populations.repo_active_backends == 1
    assert populations.direct_repo_active_backends == 1
    assert populations.other_active_backends == 0
  end

  test "the Store.Repo utilization metric keeps its numerator and denominator population explicit" do
    populations =
      ObserverContract.connection_populations(
        [
          backend_row(101, ConnectionIdentity.store_repo_application_name()),
          backend_row(102, ConnectionIdentity.store_repo_application_name()),
          backend_row(201, ConnectionIdentity.direct_repo_application_name()),
          backend_row(301, "unrelated_client")
        ],
        40,
        10
      )

    assert %{
             scope: :store_repo,
             numerator: 2,
             denominator: 40,
             utilization: utilization
           } = populations.provider_pool_metric

    assert utilization == 2 / 40
  end

  test "direct and unrelated sessions remain diagnostic without contaminating Store.Repo utilization" do
    populations =
      ObserverContract.connection_populations(
        [
          backend_row(201, ConnectionIdentity.direct_repo_application_name()),
          backend_row(202, ConnectionIdentity.direct_repo_application_name()),
          backend_row(301, "unrelated_client")
        ],
        40,
        10
      )

    assert populations.repo_active_backends == 0
    assert populations.repo_utilization == 0.0
    assert populations.direct_repo_active_backends == 2
    assert populations.other_active_backends == 1
    assert populations.direct_repo_utilization == 0.2
  end

  test "generic observer gate evaluates whole-window Store.Repo utilization" do
    summary =
      ObserverContract.summarize(
        "provider_fault_slow_observer",
        config(),
        [
          sample(40, [])
          |> Map.merge(%{
            active_backend_utilization: 0.1,
            repo_active_backend_utilization: 0.4,
            total_active_backends: 41,
            repo_active_backends: 16,
            direct_repo_active_backends: 20,
            other_active_backends: 5
          })
        ],
        enforced: true
      )

    assert summary.pass
    assert summary.peak_active_backend_utilization == 0.4
    assert summary.peak_repo_active_backend_utilization == 0.4
    assert summary.samples_over_pool_threshold == 0
  end

  test "provider-wait gate passes at 0.00 even when pre-provider utilization is 0.60" do
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

  test "provider-wait gate fails above the existing 0.35 threshold" do
    summary =
      ObserverContract.summarize(
        "provider_fault_slow_observer",
        config(),
        [phase_sample(:pre_provider, 0.2), phase_sample(:provider_wait, 0.4)],
        enforced: true
      )

    assert summary.pass
    refute ObserverContract.provider_wait_pool_gate_pass?(summary, 0.35)
  end

  test "pre-provider utilization above 0.35 does not fail the provider-wait gate" do
    summary =
      ObserverContract.summarize(
        "provider_fault_slow_observer",
        config(),
        [phase_sample(:pre_provider, 0.4), phase_sample(:provider_wait, 0.2)],
        enforced: true
      )

    assert summary.pass
    assert ObserverContract.provider_wait_pool_gate_pass?(summary, 0.35)
  end

  test "post-provider utilization above 0.35 does not fail the provider-wait gate" do
    summary =
      ObserverContract.summarize(
        "provider_fault_slow_observer",
        config(),
        [phase_sample(:provider_wait, 0.2), phase_sample(:post_provider, 0.4)],
        enforced: true
      )

    assert summary.pass
    assert ObserverContract.provider_wait_pool_gate_pass?(summary, 0.35)
  end

  test "pre or post provider utilization above 0.95 fails the generic gate" do
    for phase <- [:pre_provider, :post_provider] do
      summary =
        ObserverContract.summarize(
          "provider_fault_slow_observer",
          config(),
          [phase_sample(phase, 0.96), phase_sample(:provider_wait, 0.0)],
          enforced: true
        )

      refute summary.pass
      assert summary.samples_over_pool_threshold == 1
      assert ObserverContract.provider_wait_pool_gate_pass?(summary, 0.35)
    end
  end

  test "missing provider-wait samples cannot pass the provider-wait gate" do
    summary =
      ObserverContract.summarize(
        "provider_fault_slow_observer",
        config(),
        [phase_sample(:pre_provider, 0.6), phase_sample(:post_provider, 0.6)],
        enforced: true
      )

    assert summary.pass
    assert summary.provider_wait_sample_count == 0
    refute ObserverContract.provider_wait_pool_gate_pass?(summary, 0.35)
  end

  test "provider-wait phase evidence is retained separately from outside-wait pressure" do
    samples = [
      phase_sample(:pre_provider, 0.2),
      phase_sample(:provider_wait, 0.3),
      phase_sample(:post_provider, 0.1)
    ]

    summary =
      ObserverContract.summarize(
        "provider_fault_slow_observer",
        config(),
        samples,
        enforced: true
      )

    assert summary.phase_sample_counts == %{pre_provider: 1, provider_wait: 1, post_provider: 1}
    assert summary.provider_wait_sample_count == 1
    assert summary.provider_wait_repo_active_backend_peak == 12
    assert summary.provider_wait_repo_utilization_peak == 0.3
    assert summary.pre_provider_repo_utilization_peak == 0.2
    assert summary.post_provider_repo_utilization_peak == 0.1
    assert summary.outside_provider_wait_repo_active_backend_peak == 8
    assert summary.outside_provider_wait_repo_utilization_peak == 0.2
  end

  test "provider phase tracker follows ProviderTask started and terminal telemetry" do
    {:ok, handler_id} = ProviderPhase.start_tracking()

    try do
      assert ProviderPhase.current() == :pre_provider

      ProviderPhase.handle_event(:event, %{}, %{result: :started}, nil)
      assert ProviderPhase.current() == :provider_wait

      ProviderPhase.handle_event(:event, %{}, %{result: :ok}, nil)
      assert ProviderPhase.current() == :post_provider
    after
      ProviderPhase.stop_tracking(handler_id)
    end

    assert ProviderPhase.current() == :untracked
  end

  defp config do
    %{
      enforced: true,
      lock_wait_max_ratio: 0.10,
      lock_wait_min_active_backends: 10,
      pool_utilization_max_ratio: 0.95,
      repo_pool_size: 40
    }
  end

  defp config_without_enforcement, do: Map.delete(config(), :enforced)

  defp reservation_scope do
    %{kind: :inventory_reservation, relation: "inventory_items", ctid: "(0,1)"}
  end

  defp expected_waiter do
    %{
      pid: 101,
      state: "active",
      wait_event_type: "Lock",
      has_blocker?: true,
      waits_on_target_row?: true,
      query:
        ~s|SELECT i0."id" FROM "inventory_items" AS i0 WHERE (i0."variant_id" = $1) FOR UPDATE|
    }
  end

  defp unexpected_waiter do
    %{
      pid: 202,
      state: "active",
      wait_event_type: "Lock",
      has_blocker?: true,
      waits_on_target_row?: false,
      query: ~s|UPDATE "orders" SET "state" = $1 WHERE "id" = $2|
    }
  end

  defp backend_row(pid, application_name) do
    %{
      pid: pid,
      application_name: application_name,
      state: "active",
      wait_event_type: nil,
      wait_event: nil,
      query: "SELECT 1",
      has_blocker?: false,
      waits_on_target_row?: false
    }
  end

  defp sample(active_backends, backend_rows) do
    %{
      active_backends: active_backends,
      active_backend_utilization: active_backends / 40,
      backend_rows: backend_rows
    }
  end

  defp phase_sample(phase, repo_utilization) do
    repo_active_backends = round(repo_utilization * 40)

    %{
      phase: phase,
      active_backends: 10,
      active_backend_utilization: repo_utilization,
      repo_active_backend_utilization: repo_utilization,
      total_active_backends: 10,
      repo_active_backends: repo_active_backends,
      direct_repo_active_backends: 0,
      other_active_backends: 10 - repo_active_backends,
      backend_rows: []
    }
  end

  defp drained do
    %{enabled?: true, drained?: true, post_workload_sample: sample(2, [])}
  end
end
