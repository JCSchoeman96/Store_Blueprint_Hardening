defmodule Store.PerformanceSmoke.ObserverContractTest do
  use ExUnit.Case, async: true

  alias Store.PerformanceSmoke.ObserverContract

  test "bounded reservation-row waits pass without hiding contention" do
    summary =
      ObserverContract.summarize(
        "domain_thundering_herd_observer",
        config(),
        [sample(10, [expected_waiter(), expected_waiter()])],
        expected_scope: reservation_scope(),
        drain: drained(),
        enforced: true
      )

    assert summary.pass
    assert summary.expected_contention_observed?
    assert summary.peak_total_lock_waiters == 2
    assert summary.peak_expected_reservation_waiters == 2
    assert summary.peak_unexpected_lock_waiters == 0
    assert summary.samples_over_lock_threshold == 1
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
        [sample(10, [expected_waiter()])],
        expected_scope: reservation_scope(),
        drain: %{
          enabled?: true,
          drained?: false,
          post_workload_sample: sample(10, [expected_waiter()])
        },
        enforced: true
      )

    refute summary.pass
    refute summary.drained?
    assert summary.post_workload_expected_reservation_waiters == 1
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
  end

  test "a waiter on the target relation with no blocker is not expected" do
    summary =
      ObserverContract.summarize(
        "domain_thundering_herd_observer",
        config(),
        [
          sample(10, [
            %{expected_waiter() | has_blocker?: false},
            %{expected_waiter() | has_blocker?: false}
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

  defp config do
    %{
      lock_wait_max_ratio: 0.10,
      lock_wait_min_active_backends: 10,
      pool_utilization_max_ratio: 0.95,
      repo_pool_size: 40
    }
  end

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

  defp sample(active_backends, backend_rows) do
    %{
      active_backends: active_backends,
      active_backend_utilization: active_backends / 40,
      backend_rows: backend_rows
    }
  end

  defp drained do
    %{enabled?: true, drained?: true, post_workload_sample: sample(2, [])}
  end
end
