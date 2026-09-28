unless Code.ensure_loaded?(Store.TestSupport.ProviderWaitOwnershipProbe) do
  Code.require_file(
    Path.expand("../../../test/support/provider_wait_ownership_probe.ex", __DIR__)
  )
end

defmodule Store.PerformanceSmoke.ProviderWaitOwnershipProbeTest do
  use ExUnit.Case, async: false

  alias Store.TestSupport.ProviderWaitOwnershipProbe, as: Probe

  setup do
    Probe.reset!()
    on_exit(&Probe.reset!/0)
    :ok
  end

  test "await_and_sample waits for released waiters before passing the proof" do
    parent = self()
    sampler = start_sampler(parent)
    configure_probe(sampler, after_release: release_gate(parent))

    _baseline = Probe.capture_baseline!()
    send(sampler, :start)
    waiter = Task.async(&Probe.maybe_enter_barrier/0)

    assert_receive {:release_received, waiter_pid}, 1_000
    assert waiter_pid == waiter.pid
    refute_receive {:proof, _proof}, 30

    send(waiter_pid, :continue_release)

    assert_receive {:proof, proof}, 1_000
    assert proof.status == :proof_passed
    assert proof.released_waiter_count == 1
    assert Task.await(waiter, 1_000) == :ok
  end

  test "release acknowledgement timeout makes the actual sampled proof incomplete" do
    parent = self()
    sampler = start_sampler(parent)
    configure_probe(sampler, release_wait_ms: 30, after_release: release_gate(parent))

    _baseline = Probe.capture_baseline!()
    send(sampler, :start)
    waiter = Task.async(&Probe.maybe_enter_barrier/0)

    assert_receive {:release_received, waiter_pid}, 1_000
    assert waiter_pid == waiter.pid

    assert_receive {:proof, proof}, 1_000
    assert proof.status == :proof_incomplete
    assert proof.diagnostic =~ "PROVIDER_WAIT_BARRIER_RELEASE_TIMEOUT"
    assert proof.released_waiter_count == 0

    send(waiter_pid, :continue_release)
    assert Task.await(waiter, 1_000) == :ok
  end

  test "ownership proof fails when pool occupancy and local checkout remain held" do
    parent = self()
    sampler = start_sampler(parent)
    calls = :atomics.new(1, [])

    configure_probe(
      sampler,
      metrics_sampler: fn ->
        ready_conn_count = if :atomics.add_get(calls, 1, 1) == 1, do: 4, else: 3
        {:ok, pool_sample(ready_conn_count)}
      end,
      checkout_detector: fn -> true end
    )

    _baseline = Probe.capture_baseline!()
    send(sampler, :start)
    waiter = Task.async(&Probe.maybe_enter_barrier/0)

    assert_receive {:proof, proof}, 1_000
    assert proof.status == :proof_failed
    assert proof.occupancy_delta == 1
    assert proof.process_local_checked_out_count == 1
    assert Task.await(waiter, 1_000) == :ok
  end

  test "barrier readiness waits for the full expected cohort" do
    parent = self()
    sampler = start_sampler(parent)

    configure_probe(
      sampler,
      expected_cohort: 2,
      after_admit: fn
        1 ->
          send(parent, {:first_admitted, self()})

          receive do
            :continue_first -> :ok
          after
            2_000 -> flunk("first admission gate was not opened")
          end

        2 ->
          send(parent, {:second_admitted, self()})
      end,
      after_barrier_reached: fn reached -> send(parent, {:barrier_reached, reached}) end
    )

    _baseline = Probe.capture_baseline!()
    send(sampler, :start)

    first = Task.async(&Probe.maybe_enter_barrier/0)
    assert_receive {:first_admitted, first_pid}, 1_000
    second = Task.async(&Probe.maybe_enter_barrier/0)
    assert_receive {:second_admitted, _second_pid}, 1_000
    assert_receive {:barrier_reached, 1}, 1_000
    assert Probe.barrier_snapshot().admitted_count == 2
    assert Probe.barrier_snapshot().barrier_reached_count == 1
    refute_receive {:proof, _proof}, 30

    send(first_pid, :continue_first)
    assert_receive {:barrier_reached, 2}, 1_000
    assert_receive {:proof, proof}, 1_000
    assert proof.status == :proof_passed
    assert proof.barrier_reached_count == 2
    assert Task.await(first, 1_000) == :ok
    assert Task.await(second, 1_000) == :ok
  end

  test "durable release covers a waiter that has not entered its receive yet" do
    parent = self()
    sampler = start_sampler(parent)

    configure_probe(
      sampler,
      release_wait_ms: 1_000,
      before_wait_for_release: fn ->
        send(parent, {:before_wait_for_release, self()})

        receive do
          :continue_to_release -> :ok
        after
          2_000 -> flunk("release receive gate was not opened")
        end
      end
    )

    _baseline = Probe.capture_baseline!()
    send(sampler, :start)
    waiter = Task.async(&Probe.maybe_enter_barrier/0)
    assert_receive {:before_wait_for_release, waiter_pid}, 1_000
    assert waiter_pid == waiter.pid

    assert_eventually(fn -> Probe.barrier_snapshot().released? end)
    send(waiter_pid, :continue_to_release)

    assert_receive {:proof, proof}, 1_000
    assert proof.status == :proof_passed
    assert proof.released_waiter_count == 1
    assert Task.await(waiter, 1_000) == :ok
  end

  defp start_sampler(parent) do
    spawn(fn ->
      receive do
        :start -> send(parent, {:proof, Probe.await_and_sample!()})
      end
    end)
  end

  defp configure_probe(sampler, opts) do
    :ok =
      Probe.configure!(
        Keyword.merge(
          [
            expected_cohort: 1,
            hold_checkout?: false,
            sampler: sampler,
            metrics_sampler: fn -> {:ok, pool_sample()} end,
            checkout_detector: fn -> false end
          ],
          opts
        )
      )
  end

  defp assert_eventually(fun, attempts \\ 100)
  defp assert_eventually(_fun, 0), do: flunk("condition did not become true")

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(5)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp release_gate(parent) do
    fn ->
      send(parent, {:release_received, self()})

      receive do
        :continue_release -> :ok
      after
        2_000 -> flunk("release acknowledgement gate was not opened")
      end
    end
  end

  defp pool_sample do
    pool_sample(4)
  end

  defp pool_sample(ready_conn_count) do
    %{
      sources: [%{type: "test_pool"}],
      ready_conn_count: ready_conn_count,
      checkout_queue_length: 0,
      metrics: []
    }
  end
end
