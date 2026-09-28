defmodule Store.PerformanceSmoke.ObserverContractTest do
  use ExUnit.Case, async: true

  alias Store.PerformanceSmoke.ConnectionIdentity
  alias Store.PerformanceSmoke.ObserverContract

  test "bounded reservation-row waits pass without hiding contention" do
    summary =
      ObserverContract.summarize(
        "domain_thundering_herd_observer",
        config(),
        [sample(10, [expected_waiter(20), expected_waiter(50)])],
        expected_scope: reservation_scope(),
        drain: drained(),
        enforced: true
      )

    assert summary.pass
    assert summary.expected_contention_observed?
    assert summary.peak_total_lock_waiters == 2
    assert summary.peak_expected_reservation_waiters == 2
    assert summary.peak_expected_wait_duration_ms == 50
    assert summary.peak_unexpected_lock_waiters == 0
    assert summary.samples_over_lock_threshold == 1
    assert summary.samples_over_expected_wait_duration_threshold == 0
    assert summary.samples_over_unexpected_lock_threshold == 0
  end

  test "unclassified lock contention still fails the required gate" do
    summary =
      ObserverContract.summarize(
        "generic_observer",
        config(),
        [sample(10, [unexpected_waiter(), unexpected_waiter()])],
        enforced: true
      )

    refute summary.pass
    assert summary.peak_unexpected_lock_waiters == 2
    assert summary.peak_unexpected_lock_wait_ratio == 0.2
    assert summary.samples_over_unexpected_lock_threshold == 1
  end

  test "aggregate observer samples keep lock waiters classified as unexpected" do
    summary =
      ObserverContract.summarize(
        "generic_observer",
        config(),
        [%{active_backends: 10, lock_waiters: 2, active_backend_utilization: 0.25}],
        enforced: true
      )

    refute summary.pass
    assert summary.peak_total_lock_waiters == 2
    assert summary.peak_unexpected_lock_waiters == 2
    assert summary.samples_over_unexpected_lock_threshold == 1
  end

  test "expected reservation contention that does not drain fails" do
    summary =
      ObserverContract.summarize(
        "domain_thundering_herd_observer",
        config(),
        [sample(10, [expected_waiter(20)])],
        expected_scope: reservation_scope(),
        drain: %{
          enabled?: true,
          drained?: false,
          post_workload_sample: sample(10, [expected_waiter(400)])
        },
        enforced: true
      )

    refute summary.pass
    refute summary.drained?
    assert summary.post_workload_expected_reservation_waiters == 1
  end

  test "pathological expected-shaped waits fail the boundedness gate" do
    summary =
      ObserverContract.summarize(
        "domain_thundering_herd_observer",
        config(),
        [sample(10, [expected_waiter(400), expected_waiter(500)])],
        expected_scope: reservation_scope(),
        drain: drained(),
        enforced: true
      )

    refute summary.pass
    assert summary.peak_expected_reservation_waiters == 2
    assert summary.peak_unexpected_lock_waiters == 0
    assert summary.peak_expected_wait_duration_ms == 500
    assert summary.samples_over_expected_wait_duration_threshold == 1
  end

  test "bounded expected serialization can use the pool without hiding the signal" do
    summary =
      ObserverContract.summarize(
        "domain_thundering_herd_observer",
        config(),
        [sample(40, [expected_waiter(20)])],
        expected_scope: reservation_scope(),
        drain: drained(),
        enforced: true
      )

    assert summary.pass
    assert summary.samples_over_pool_threshold == 1
    assert summary.samples_over_unmitigated_pool_threshold == 0
  end

  test "pool saturation fails independently of lock classification" do
    summary =
      ObserverContract.summarize(
        "pool_observer",
        config(),
        [%{sample(40, []) | active_backend_utilization: 1.0}],
        enforced: true
      )

    refute summary.pass
    assert summary.peak_unexpected_lock_waiters == 0
    assert summary.samples_over_pool_threshold == 1
    assert summary.samples_over_unmitigated_pool_threshold == 1
  end

  test "a waiter on the target relation with no blocker is not expected" do
    summary =
      ObserverContract.summarize(
        "domain_thundering_herd_observer",
        config(),
        [
          sample(10, [
            %{expected_waiter(20) | has_blocker?: false},
            %{expected_waiter(20) | has_blocker?: false}
          ])
        ],
        expected_scope: reservation_scope(),
        drain: drained(),
        enforced: true
      )

    refute summary.pass
    assert summary.peak_expected_reservation_waiters == 0
    assert summary.peak_unexpected_lock_waiters == 2
  end

  test "connection populations keep Store.Repo utilization separate" do
    populations =
      ObserverContract.connection_populations(
        [
          backend_row(101, ConnectionIdentity.store_repo_application_name()),
          backend_row(202, ConnectionIdentity.direct_repo_application_name()),
          backend_row(303, "unrelated_client")
        ],
        40,
        10
      )

    assert populations.total_active_backends == 3
    assert populations.repo_active_backends == 1
    assert populations.direct_repo_active_backends == 1
    assert populations.other_active_backends == 1
    assert populations.repo_utilization == 1 / 40
    assert populations.direct_repo_utilization == 1 / 10
  end

  test "generic pool evidence uses Store.Repo population rather than all sessions" do
    summary =
      ObserverContract.summarize(
        "generic_observer",
        config(),
        [
          %{
            active_backends: 41,
            active_backend_utilization: 0.1,
            repo_active_backend_utilization: 0.4,
            backend_rows: []
          }
        ],
        enforced: true
      )

    assert summary.pass
    assert summary.peak_active_backend_utilization == 0.4
    assert summary.samples_over_pool_threshold == 0
  end

  defp config do
    %{
      lock_wait_max_ratio: 0.10,
      lock_wait_min_active_backends: 10,
      pool_utilization_max_ratio: 0.95,
      expected_reservation_wait_max_ms: 250.0,
      repo_pool_size: 40
    }
  end

  defp reservation_scope do
    %{kind: :inventory_reservation, relation: "inventory_items", ctid: "(0,1)"}
  end

  defp expected_waiter(wait_duration_ms) do
    %{
      pid: 101,
      state: "active",
      wait_event_type: "Lock",
      has_blocker?: true,
      waits_on_target_row?: true,
      has_ungranted_lock?: true,
      wait_duration_ms: wait_duration_ms,
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

  defp sample(active_backends, backend_rows) do
    %{
      active_backends: active_backends,
      active_backend_utilization: active_backends / 40,
      backend_rows: backend_rows
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
      has_ungranted_lock?: false,
      waits_on_target_row?: false
    }
  end

  defp drained do
    %{enabled?: true, drained?: true, post_workload_sample: sample(2, [])}
  end
end
