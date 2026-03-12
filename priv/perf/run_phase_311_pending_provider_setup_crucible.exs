if Mix.env() != :test do
  raise "run_phase_311_pending_provider_setup_crucible.exs must be run with MIX_ENV=test"
end

Code.ensure_loaded!(Store.Perf.BenchmarkHarness)
alias Store.Perf.BenchmarkHarness

BenchmarkHarness.require_test_env!()
BenchmarkHarness.require_isolated_test_db!()

if Enum.any?(Application.started_applications(), fn {app, _desc, _vsn} -> app == :store end) do
  raise "run_phase_311_pending_provider_setup_crucible.exs expects standalone startup"
end

defmodule Store.Perf.Phase311PendingProviderSetupCrucible do
  @moduledoc false

  alias Store.Perf.BenchmarkHarness

  @writer_ready_timeout_ms 30_000
  @process_shutdown_timeout_ms 5_000
  @process_exit_grace_ms 120_000
  @shop_show_red_line_ms 200.0

  def run do
    context = %{
      log_path: BenchmarkHarness.phase311_poller_log_path(),
      summary_path: BenchmarkHarness.phase311_poller_summary_path(),
      storefront_summary_path: BenchmarkHarness.phase311_storefront_summary_path(),
      report_path: BenchmarkHarness.phase311_report_path(),
      writer_result_path: "tmp/perf/pending_provider_setup_crucible_writer.json",
      ready_path: "tmp/perf/phase311_pending_provider_setup_crucible.ready",
      server_log_path: "tmp/perf/phase311_server.log",
      writer_log_path: "tmp/perf/phase311_writer.log"
    }

    File.rm_rf(context.report_path)
    File.rm_rf(context.writer_result_path)
    File.rm_rf(context.ready_path)
    File.rm_rf(context.log_path)
    File.rm_rf(context.summary_path)

    server_port = start_server_process(context.log_path, context.server_log_path)

    try do
      BenchmarkHarness.wait_for_endpoint!()

      writer_port =
        start_writer_process(
          context.ready_path,
          context.writer_log_path,
          context.writer_result_path
        )

      try do
        wait_for_ready_file!(context.ready_path)

        storefront = run_storefront_k6(context.storefront_summary_path)

        writer =
          wait_for_process(
            writer_port,
            storefront_total_ms() + @process_exit_grace_ms
          )

        stop_process(server_port)

        poller_summary =
          BenchmarkHarness.run_poller_summary!(
            context.log_path,
            context.summary_path
          )

        writer_result = read_json_if_exists(context.writer_result_path)

        report =
          build_report(
            writer,
            writer_result,
            storefront,
            poller_summary,
            context
          )

        File.mkdir_p!(Path.dirname(context.report_path))
        File.write!(context.report_path, Jason.encode_to_iodata!(report, pretty: true))
        IO.puts("Wrote Phase 31 pending provider setup crucible report to #{context.report_path}")
        report
      after
        stop_process(writer_port)
      end
    after
      stop_process(server_port)
      File.rm_rf(context.ready_path)
    end
  end

  defp build_report(writer, writer_result, storefront, poller_summary, context) do
    writer_result = writer_result || %{}

    assertion_failures =
      writer_result
      |> Map.get("assertions", %{})
      |> Enum.filter(fn
        {"expected_batch_iterations", _value} -> false
        {"actual_batch_iterations", _value} -> false
        {"max_sweep_duration_ms", _value} -> false
        {_key, value} when is_boolean(value) -> value == false
        _other -> false
      end)
      |> Enum.map(&elem(&1, 0))

    classification =
      cond do
        writer.exit_status not in [0, :ok] ->
          %{
            type: "writer_process_failure",
            reason: "The crucible writer process exited before producing a clean completion."
          }

        (storefront.metrics.shop_show_p95_ms || 0.0) > @shop_show_red_line_ms ->
          %{
            type: "storefront_red_line",
            reason: "Storefront p95 crossed the red-line threshold during the crucible."
          }

        (storefront.metrics.http_req_failed_rate || 0.0) > 0.0 ->
          %{
            type: "storefront_http_failures",
            reason: "Storefront requests failed while the cleanup crucible was running."
          }

        assertion_failures != [] ->
          %{
            type: "cleanup_pressure_failure",
            reason:
              "One or more cleanup assertions failed: #{Enum.join(assertion_failures, ", ")}"
          }

        true ->
          %{
            type: "pass",
            reason:
              "Ghost reservations drained predictably and the second wave reclaimed inventory."
          }
      end

    %{
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      base_url: BenchmarkHarness.benchmark_base_url(),
      config: %{
        storefront: %{
          warmup_ms: storefront_warmup_ms(),
          measure_ms: storefront_measure_ms(),
          cooldown_ms: storefront_cooldown_ms()
        }
      },
      writer: %{
        exit_status: writer.exit_status,
        result_path: context.writer_result_path,
        data: writer_result
      },
      storefront: storefront,
      poller_log_path: context.log_path,
      poller_summary_path: context.summary_path,
      poller_summary: poller_summary,
      summary: %{
        pending_provider_setup_peak_count:
          get_in(poller_summary, [:pending_provider_setup_backlog, :maxes, "count"]) || 0,
        pending_provider_setup_oldest_age_seconds:
          get_in(poller_summary, [:pending_provider_setup_backlog, :maxes, "oldest_age_seconds"]) ||
            0,
        scheduler_run_queue_max: get_in(poller_summary, [:scheduler, :maxes, "run_queue"]) || 0,
        active_backends_max:
          get_in(poller_summary, [:postgres_activity, :maxes, "active_backends"]) || 0,
        lock_waiters_max:
          get_in(poller_summary, [:postgres_activity, :maxes, "lock_waiters"]) || 0
      },
      classification: classification,
      passed?: classification.type == "pass"
    }
  end

  defp start_server_process(log_path, server_log_path) do
    env = [
      {"STORE_BENCH_ROLE", "server"},
      {"STORE_BENCH_POOL_SIZE", System.get_env("STORE_BENCH_POOL_SIZE", "40")},
      {"STORE_BENCH_DIRECT_POOL_SIZE", System.get_env("STORE_BENCH_DIRECT_POOL_SIZE", "20")},
      {"STORE_PRODUCT_DETAIL_POLLER_LOG_PATH", log_path},
      {"STORE_TEST_DB_SUFFIX", BenchmarkHarness.require_isolated_test_db!()},
      {"STORE_BENCHMARK_DATA_PATH", BenchmarkHarness.benchmark_data_path()},
      {"STORE_BENCHMARK_BASE_URL", BenchmarkHarness.benchmark_base_url()},
      {"PORT", Integer.to_string(BenchmarkHarness.benchmark_port())},
      {"MIX_ENV", "test"}
    ]

    start_port_process(
      "mix run --no-start --no-halt priv/perf/benchmark_server.exs",
      env,
      server_log_path
    )
  end

  defp start_writer_process(ready_path, writer_log_path, writer_result_path) do
    env = [
      {"STORE_BENCH_ROLE", "writer"},
      {"STORE_BENCH_WRITER_POOL_SIZE", System.get_env("STORE_BENCH_WRITER_POOL_SIZE", "10")},
      {"STORE_BENCH_WRITER_DIRECT_POOL_SIZE",
       System.get_env("STORE_BENCH_WRITER_DIRECT_POOL_SIZE", "5")},
      {"STORE_PENDING_PROVIDER_SETUP_CRUCIBLE_READY_PATH", ready_path},
      {"STORE_PENDING_PROVIDER_SETUP_CRUCIBLE_PATH", writer_result_path},
      {"STORE_BENCHMARK_DATA_PATH", BenchmarkHarness.benchmark_data_path()},
      {"STORE_TEST_DB_SUFFIX", BenchmarkHarness.require_isolated_test_db!()},
      {"MIX_ENV", "test"},
      {"STORE_PROVIDER_SETUP_TTL_SECONDS",
       System.get_env("STORE_PROVIDER_SETUP_TTL_SECONDS", "30")},
      {"STORE_PROVIDER_SETUP_SWEEP_BATCH_SIZE",
       System.get_env("STORE_PROVIDER_SETUP_SWEEP_BATCH_SIZE", "50")},
      {"STORE_PERF_PENDING_PROVIDER_SWEEP_INTERVAL_MS",
       System.get_env("STORE_PERF_PENDING_PROVIDER_SWEEP_INTERVAL_MS", "5000")},
      {"STORE_PERF_PENDING_PROVIDER_ABANDON",
       System.get_env("STORE_PERF_PENDING_PROVIDER_ABANDON", "true")},
      {"STORE_PERF_PENDING_PROVIDER_ABANDON_AFTER_STEP",
       System.get_env("STORE_PERF_PENDING_PROVIDER_ABANDON_AFTER_STEP", "create_payment_intent")},
      {"STORE_PERF_PENDING_PROVIDER_PROVIDER_DELAY_MS",
       System.get_env("STORE_PERF_PENDING_PROVIDER_PROVIDER_DELAY_MS", "45000")},
      {"STORE_PERF_PENDING_PROVIDER_CLIENTS",
       System.get_env("STORE_PERF_PENDING_PROVIDER_CLIENTS", "200")},
      {"STORE_PERF_PENDING_PROVIDER_PROBE_CLIENTS",
       System.get_env("STORE_PERF_PENDING_PROVIDER_PROBE_CLIENTS", "5")},
      {"STORE_PERF_PENDING_PROVIDER_SECOND_WAVE_CLIENTS",
       System.get_env("STORE_PERF_PENDING_PROVIDER_SECOND_WAVE_CLIENTS", "200")}
    ]

    start_port_process(
      "mix run --no-start priv/perf/pending_provider_setup_crucible.exs",
      env,
      writer_log_path
    )
  end

  defp start_port_process(command, extra_env, log_path) do
    File.mkdir_p!(Path.dirname(log_path))
    File.rm_rf(log_path)

    env_prefix =
      extra_env
      |> Enum.map(fn {key, value} -> ~s(#{key}=#{shell_escape(value)}) end)
      |> Enum.join(" ")

    full_command =
      "export PATH=\"$HOME/.asdf/shims:$HOME/.asdf/bin:$PATH\" && exec env #{env_prefix} #{command} > #{shell_escape(log_path)} 2>&1"

    Port.open({:spawn_executable, System.find_executable("bash")}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      {:args, ["-lc", full_command]}
    ])
  end

  defp run_storefront_k6(summary_path) do
    env = [
      {"STORE_BENCHMARK_DATA_PATH", BenchmarkHarness.benchmark_data_path()},
      {"STORE_BENCHMARK_BASE_URL", BenchmarkHarness.benchmark_base_url()},
      {"STORE_K6_WARMUP_MS", Integer.to_string(storefront_warmup_ms())},
      {"STORE_K6_MEASURE_MS", Integer.to_string(storefront_measure_ms())},
      {"STORE_K6_COOLDOWN_MS", Integer.to_string(storefront_cooldown_ms())},
      {"STORE_K6_QUICK", "1"}
    ]

    {output, exit_code} =
      System.cmd(
        "k6",
        ["run", "--summary-export", summary_path, "perf/k6/http_storefront.js"],
        stderr_to_stdout: true,
        env: env,
        cd: File.cwd!()
      )

    unless File.exists?(summary_path) do
      raise "k6 storefront crucible run did not produce a summary file:\n#{output}"
    end

    summary = Jason.decode!(File.read!(summary_path))

    %{
      summary_path: summary_path,
      stdout: output,
      exit_code: exit_code,
      metrics: summarize_k6(summary)
    }
  end

  defp summarize_k6(summary) do
    metrics = Map.get(summary, "metrics", %{})

    %{
      http_req_failed_rate: get_in(metrics, ["http_req_failed", "value"]) || 0.0,
      shop_show_p95_ms: get_in(metrics, ["http_req_duration{route:shop_show}", "p(95)"]) || 0.0,
      shop_index_p95_ms: get_in(metrics, ["http_req_duration{route:shop_index}", "p(95)"]) || 0.0,
      cart_p95_ms: get_in(metrics, ["http_req_duration{route:cart}", "p(95)"]) || 0.0,
      checkout_p95_ms: get_in(metrics, ["http_req_duration{route:checkout}", "p(95)"]) || 0.0
    }
  end

  defp wait_for_ready_file!(path) do
    deadline = System.monotonic_time(:millisecond) + @writer_ready_timeout_ms

    wait_until(deadline, fn ->
      if File.exists?(path), do: :ok, else: :retry
    end)
  end

  defp wait_until(deadline, fun) do
    case fun.() do
      :ok ->
        :ok

      :retry ->
        if System.monotonic_time(:millisecond) >= deadline do
          raise "timed out waiting for Phase 31 crucible process readiness"
        end

        Process.sleep(250)
        wait_until(deadline, fun)
    end
  end

  defp wait_for_process(port, timeout_ms) do
    receive do
      {^port, {:exit_status, status}} -> %{exit_status: status}
    after
      timeout_ms ->
        stop_process(port)
        %{exit_status: :timeout}
    end
  end

  defp stop_process(nil), do: :ok

  defp stop_process(port) when is_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} when is_integer(os_pid) ->
        System.cmd("kill", ["-TERM", Integer.to_string(os_pid)])

        receive do
          {^port, {:exit_status, _status}} -> :ok
        after
          @process_shutdown_timeout_ms -> System.cmd("kill", ["-KILL", Integer.to_string(os_pid)])
        end

      _ ->
        Port.close(port)
        :ok
    end
  rescue
    _ -> :ok
  end

  defp shell_escape(value) do
    escaped = String.replace(value, "'", "'\\''")
    "'#{escaped}'"
  end

  defp read_json_if_exists(path) do
    if File.exists?(path), do: Jason.decode!(File.read!(path)), else: nil
  end

  defp storefront_warmup_ms do
    env_integer("STORE_PHASE311_STOREFRONT_WARMUP_MS", 5_000)
  end

  defp storefront_measure_ms do
    env_integer("STORE_PHASE311_STOREFRONT_MEASURE_MS", 90_000)
  end

  defp storefront_cooldown_ms do
    env_integer("STORE_PHASE311_STOREFRONT_COOLDOWN_MS", 5_000)
  end

  defp storefront_total_ms do
    storefront_warmup_ms() + storefront_measure_ms() + storefront_cooldown_ms()
  end

  defp env_integer(name, default) do
    case System.get_env(name) do
      nil ->
        default

      value ->
        case Integer.parse(value) do
          {parsed, ""} when parsed > 0 -> parsed
          _ -> default
        end
    end
  end
end

Store.Perf.Phase311PendingProviderSetupCrucible.run()
