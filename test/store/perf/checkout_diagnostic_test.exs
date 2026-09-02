defmodule Store.PerformanceSmoke.CheckoutDiagnosticTest do
  use ExUnit.Case, async: false

  alias Store.PerformanceSmoke.CheckoutDiagnostic, as: Diagnostic

  @base_input %{
    run_id: "diagnostic-test",
    profile: :ci_gate,
    worker_count: 4,
    variant_count: 4,
    store_repo_pool_size: 40,
    direct_repo_pool_size: 10,
    observer_interval_ms: 500,
    seed: 0,
    timeout: 5_000,
    provider_mode: :stub,
    max_buffered_events: 64,
    flush_interval_ms: 60_000
  }

  setup do
    artifact_directory =
      Path.join(
        System.tmp_dir!(),
        "store-checkout-diagnostic-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(artifact_directory) end)
    {:ok, artifact_directory: artifact_directory}
  end

  test "query telemetry cannot alter the named outer result arity", %{artifact_directory: dir} do
    {:ok, result} =
      run(dir, fn session ->
        assert {:ok, _sequence} =
                 Diagnostic.record_repo_query(
                   session,
                   %{query_time: 1_000, queue_time: 2_000},
                   %{source: "checkout", query: "SELECT 1", params: ["secret"]}
                 )

        %{workload: %{durations_ms: [4.0]}, correctness: correctness()}
      end)

    assert result.status == :ok
    assert result.telemetry.repo_query_count == 1
    assert is_map(result.correctness)
    assert is_map(result.observer)
  end

  test "the 08B nested-tuple failure class cannot change the outer result shape", %{
    artifact_directory: dir
  } do
    {:ok, result} =
      run(dir, fn session ->
        Diagnostic.record_repo_query(session, %{}, %{source: "checkout", query: "SELECT 1"})

        {:ok,
         %{
           workload: %{durations_ms: [5.0], errors: []},
           correctness: correctness()
         }}
      end)

    assert result.status == :ok
    assert result.workload.durations_ms == [5.0]
    assert result.telemetry.repo_query_count == 1
  end

  test "valid lifecycle transitions reach the complete terminal state" do
    states = [
      {:configured, :raw_open},
      {:raw_open, :running},
      {:running, :workload_complete},
      {:workload_complete, :raw_sealed},
      {:raw_sealed, :aggregating},
      {:aggregating, :aggregated},
      {:aggregated, :reporting},
      {:reporting, :complete}
    ]

    assert {:ok, :complete} = Diagnostic.walk_lifecycle(:configured, states)
  end

  test "invalid lifecycle transitions fail deterministically" do
    assert {:error, %{reason: :invalid_transition, from: :configured, to: :aggregating}} =
             Diagnostic.transition_state(:configured, :aggregating)
  end

  test "the raw artifact exists before the mock workload starts", %{artifact_directory: dir} do
    {:ok, result} =
      run(dir, fn session ->
        assert File.exists?(session.raw_path)
        %{correctness: correctness()}
      end)

    assert File.exists?(result.artifacts.raw)
    assert File.exists?(result.artifacts.aggregate)
    assert File.exists?(result.artifacts.final_report)

    [header | _events] = Diagnostic.read_raw_events!(result.artifacts.raw)
    assert header["event_type"] == "run_metadata"
    assert get_in(header, ["payload", "observer", "source"]) == "pg_stat_activity"
    refute get_in(header, ["payload", "observer", "ecto_pool_ownership_high_water_available?"])
    assert result.observer.metric.source == "pg_stat_activity"
  end

  test "correctness evidence is written before aggregation", %{artifact_directory: dir} do
    aggregator = fn raw_path ->
      events = Diagnostic.read_raw_events!(raw_path)

      assert Enum.any?(events, &(&1["event_type"] == "correctness"))
      {:ok, %{checked_before_aggregation: true}}
    end

    {:ok, result} =
      run(dir, fn _session -> %{correctness: correctness()} end, aggregator: aggregator)

    assert result.aggregate.checked_before_aggregation
  end

  test "raw evidence survives aggregation failure", %{artifact_directory: dir} do
    {:error, result} =
      run(dir, fn _session -> %{correctness: correctness()} end,
        aggregator: fn _raw_path -> {:error, :forced_aggregation_failure} end
      )

    assert result.status == :aggregation_error
    assert File.exists?(result.artifacts.raw)

    assert Enum.any?(
             Diagnostic.read_raw_events!(result.artifacts.raw),
             &(&1["event_type"] == "correctness")
           )
  end

  test "raw and aggregate evidence survive final-report failure", %{artifact_directory: dir} do
    {:error, result} =
      run(dir, fn _session -> %{correctness: correctness()} end,
        reporter: fn _report -> {:error, :forced_report_failure} end
      )

    assert result.status == :artifact_error
    assert File.exists?(result.artifacts.raw)
    assert File.exists?(result.artifacts.aggregate)
    assert result.artifacts.final_report == nil
  end

  test "workload and instrumentation errors remain distinguishable", %{artifact_directory: dir} do
    {:error, workload_result} =
      run(dir, fn _session -> raise "fake workload failure" end)

    assert workload_result.status == :workload_error
    assert Enum.any?(workload_result.errors, &(&1.kind == :workload))

    {:error, instrumentation_result} =
      run(dir, fn session ->
        assert :ok = Diagnostic.record_instrumentation_error(session, :fake_telemetry_failure)
        %{correctness: correctness()}
      end)

    assert instrumentation_result.status == :instrumentation_error
    assert Enum.any?(instrumentation_result.errors, &(&1.kind == :instrumentation))
    refute Enum.any?(instrumentation_result.errors, &(&1.kind == :workload))
  end

  test "artifact creation failure returns a typed artifact status", %{artifact_directory: dir} do
    occupied_path = Path.join(dir, "occupied")
    File.mkdir_p!(dir)
    File.write!(occupied_path, "not a directory")

    bad_directory = Path.join(occupied_path, "child")

    {:error, result} = run(bad_directory, fn _session -> %{correctness: correctness()} end)

    assert result.status == :artifact_error
    assert Enum.any?(result.errors, &(&1.kind == :artifact))
  end

  test "artifact write failure returns a typed artifact status", %{artifact_directory: dir} do
    File.mkdir_p!(dir)
    run_id = "artifact-write"
    aggregate_path = Path.join(dir, "#{run_id}.aggregate.json")
    File.write!(aggregate_path, "occupied")

    {:ok, input} =
      Diagnostic.Input.new(Map.merge(@base_input, %{run_id: run_id, artifact_directory: dir}))

    {:error, result} =
      Diagnostic.run(input, fn _session -> %{correctness: correctness()} end)

    assert result.status == :artifact_error
    assert File.exists?(result.artifacts.raw)
    assert Enum.any?(result.errors, &(&1.kind == :artifact))
  end

  test "observer sample identities are retained in raw evidence", %{artifact_directory: dir} do
    {:ok, result} =
      run(dir, fn session ->
        assert {:ok, 1} = Diagnostic.record_observer_sample(session, observer_sample(4, 0.1))
        assert {:ok, 2} = Diagnostic.record_observer_sample(session, observer_sample(7, 0.2))
        %{correctness: correctness()}
      end)

    samples =
      result.artifacts.raw
      |> Diagnostic.read_raw_events!()
      |> Enum.filter(&(&1["event_type"] == "observer_sample"))

    assert Enum.map(samples, &get_in(&1, ["payload", "sample_sequence"])) == [1, 2]
    assert Enum.all?(samples, &is_integer(get_in(&1, ["sequence"])))
  end

  test "peak selection is deterministic", %{artifact_directory: dir} do
    {:ok, result} =
      run(dir, fn session ->
        Diagnostic.record_observer_sample(session, observer_sample(2, 0.05))
        Diagnostic.record_observer_sample(session, observer_sample(8, 0.20))
        Diagnostic.record_observer_sample(session, observer_sample(3, 0.075))
        %{correctness: correctness()}
      end)

    assert result.observer.peak_store_repo_active_backends == 8
    assert result.observer.peak_sample_sequences == [2]
  end

  test "peak ties retain every tied sample identity", %{artifact_directory: dir} do
    {:ok, result} =
      run(dir, fn session ->
        Diagnostic.record_observer_sample(session, observer_sample(8, 0.20))
        Diagnostic.record_observer_sample(session, observer_sample(8, 0.20))
        %{correctness: correctness()}
      end)

    assert result.observer.peak_sample_sequences == [1, 2]
  end

  test "evidence overflow produces an evidence-incomplete result", %{artifact_directory: dir} do
    {:error, result} =
      run(
        dir,
        fn session ->
          Diagnostic.record(session, :phase, %{phase: "checkout"})
          Diagnostic.record(session, :phase, %{phase: "inventory"})
          Diagnostic.record(session, :phase, %{phase: "payment"})
          %{correctness: correctness()}
        end,
        input_overrides: [max_buffered_events: 1]
      )

    assert result.status == :evidence_incomplete

    assert Enum.any?(Diagnostic.read_raw_events!(result.artifacts.raw), fn event ->
             event["event_type"] == "evidence_drop" and
               get_in(event, ["payload", "dropped_count"]) > 0
           end)
  end

  test "event buffering exposes an explicit bounded capacity", %{artifact_directory: dir} do
    {:error, result} =
      run(
        dir,
        fn session ->
          Enum.each(1..10, &Diagnostic.record(session, :phase, %{phase: "phase-#{&1}"}))
          stats = Diagnostic.buffer_stats(session)
          assert stats.max_buffered_events == 2
          assert stats.max_observed_buffered_events <= stats.max_buffered_events
          %{correctness: correctness()}
        end,
        input_overrides: [max_buffered_events: 2]
      )

    assert result.evidence.max_buffered_events == 2
  end

  test "sensitive query and bind values are not persisted", %{artifact_directory: dir} do
    sensitive_query = "SELECT * FROM payments WHERE token = 'query-secret-token'"
    sensitive_bind = "bind-secret-value"

    {:ok, result} =
      run(dir, fn session ->
        Diagnostic.record_repo_query(
          session,
          %{query_time: 1_000, queue_time: 0},
          %{
            source: "checkout",
            query: sensitive_query,
            params: [sensitive_bind],
            authorization: "Bearer header-secret"
          }
        )

        %{correctness: correctness()}
      end)

    raw = File.read!(result.artifacts.raw)
    refute String.contains?(raw, sensitive_query)
    refute String.contains?(raw, sensitive_bind)
    refute String.contains?(raw, "header-secret")

    [query_event] =
      Diagnostic.read_raw_events!(result.artifacts.raw)
      |> Enum.filter(&(&1["event_type"] == "repo_query"))

    assert get_in(query_event, ["payload", "query_identity", "fingerprint"])
    refute Map.has_key?(query_event["payload"], "params")
  end

  test "named telemetry sections retain phase, worker, inventory, and queue evidence", %{
    artifact_directory: dir
  } do
    {:ok, result} =
      run(dir, fn session ->
        Diagnostic.record_phase(session, :checkout, %{state: "started"})
        Diagnostic.record_worker_sync(session, %{state: "workers_started", expected: 4})
        Diagnostic.record_inventory_subphase(session, %{subphase: "reservation"})

        Diagnostic.record_checkout_step(
          session,
          %{duration: 1_000, query_count: 2, queue_time: 500, query_time: 700, decode_time: 100},
          %{step: "finalize_totals", result: :ok}
        )

        %{correctness: correctness()}
      end)

    assert result.aggregate.phase_counts["checkout"] == 1
    assert result.telemetry.worker_sync_count == 1
    assert result.telemetry.inventory_subphases["reservation"] == 1
    assert result.telemetry.checkout_step_count == 1
  end

  test "observer gate semantics remain the existing 0.95 threshold", %{artifact_directory: dir} do
    {:ok, result} =
      run(dir, fn _session -> %{correctness: correctness()} end)

    assert result.input.observer_interval_ms == 500

    summary =
      Store.PerformanceSmoke.ObserverContract.summarize(
        "generic_observer",
        %{
          lock_wait_max_ratio: 0.10,
          lock_wait_min_active_backends: 10,
          pool_utilization_max_ratio: 0.95
        },
        [
          %{
            active_backends: 40,
            active_backend_utilization: 1.0,
            backend_rows: [],
            phase: :untracked
          }
        ],
        enforced: true
      )

    refute summary.pass
    assert summary.samples_over_pool_threshold == 1
  end

  defp run(dir, workload, opts \\ []) do
    attrs =
      @base_input
      |> Map.put(:run_id, "diagnostic-test-#{System.unique_integer([:positive])}")
      |> Map.put(:artifact_directory, dir)
      |> Map.merge(Map.new(Keyword.get(opts, :input_overrides, [])))

    {:ok, input} = Diagnostic.Input.new(attrs)
    opts = Keyword.drop(opts, [:input_overrides])
    Diagnostic.run(input, workload, opts)
  end

  defp correctness(overrides \\ %{}) do
    Map.merge(
      %{
        expected_workers: 1,
        completed_workers: 1,
        successful_workers: 1,
        governed_failures: 0,
        unexpected_failures: 0,
        db_errors: 0,
        deadlocks: 0,
        gate: :pass
      },
      overrides
    )
  end

  defp observer_sample(repo_active_backends, utilization) do
    %{
      sample_start_timestamp_ms: 1_000,
      sample_end_timestamp_ms: 1_001,
      timestamp_ms: 1_001,
      phase: :untracked,
      backend_rows: [],
      repo_active_backends: repo_active_backends,
      direct_repo_active_backends: 0,
      other_active_backends: 0,
      total_active_backends: repo_active_backends,
      repo_active_backend_utilization: utilization,
      direct_repo_active_backend_utilization: 0.0,
      active_backends: repo_active_backends,
      active_backend_utilization: utilization
    }
  end
end
