if Mix.env() != :test do
  raise "run_phase_309_durability.exs must be run with MIX_ENV=test"
end

Code.ensure_loaded!(Store.Perf.BenchmarkHarness)
Code.ensure_loaded!(Store.Perf.ProductDetailPollerSummary)

alias Store.Perf.{BenchmarkHarness, ProductDetailPollerSummary}

BenchmarkHarness.require_test_env!()
BenchmarkHarness.require_isolated_test_db!()

if Enum.any?(Application.started_applications(), fn {app, _desc, _vsn} -> app == :store end) do
  raise "run_phase_309_durability.exs expects standalone startup"
end

defmodule Store.Perf.Phase309Durability do
  @moduledoc false

  alias Store.Perf.{BenchmarkHarness, ProductDetailPollerSummary}

  @writer_ready_timeout_ms 30_000
  @process_shutdown_timeout_ms 5_000
  @process_exit_grace_ms 120_000
  @shop_show_red_line_ms 50.0

  def run do
    context = %{
      writer_users: BenchmarkHarness.phase309_writer_users(),
      log_path: BenchmarkHarness.phase309_poller_log_path(),
      summary_path: BenchmarkHarness.phase309_poller_summary_path(),
      storefront_summary_path: BenchmarkHarness.phase309_storefront_summary_path(),
      writer_result_path: BenchmarkHarness.phase309_writer_result_path(),
      ready_path: "tmp/perf/phase309_writer.ready",
      server_log_path: "tmp/perf/phase309_server.log",
      writer_log_path: "tmp/perf/phase309_writer.log"
    }

    report =
      try do
        do_run(context)
      rescue
        error ->
          failure_report(context, Exception.message(error))
      end

    path = BenchmarkHarness.phase309_report_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode_to_iodata!(report, pretty: true))
    IO.puts("Wrote Phase 30.9 durability report to #{path}")
    report
  end

  defp do_run(context) do
    Enum.each(
      [
        context.log_path,
        context.summary_path,
        context.storefront_summary_path,
        context.writer_result_path,
        context.ready_path
      ],
      &File.rm_rf/1
    )

    server_port = start_server_process(context.log_path, context.server_log_path)

    try do
      BenchmarkHarness.wait_for_endpoint!()

      writer_port =
        start_writer_process(
          context.writer_users,
          context.ready_path,
          context.writer_log_path,
          context.writer_result_path
        )

      try do
        wait_for_ready_file!(context.ready_path)

        writer_started_at = DateTime.utc_now()

        measure_start_at =
          DateTime.add(writer_started_at, BenchmarkHarness.phase309_warmup_ms(), :millisecond)

        measure_end_at =
          DateTime.add(measure_start_at, BenchmarkHarness.phase309_measure_ms(), :millisecond)

        nominal_cooldown_end_at =
          DateTime.add(measure_end_at, BenchmarkHarness.phase309_cooldown_ms(), :millisecond)

        storefront = run_storefront_k6(context.storefront_summary_path)

        writer =
          wait_for_process(
            writer_port,
            BenchmarkHarness.phase309_writer_duration_ms() + @process_exit_grace_ms
          )

        writer_finished_at = DateTime.utc_now()
        cooldown_end_at = max_datetime(nominal_cooldown_end_at, writer_finished_at)

        stop_process(server_port)

        poller_summary =
          ProductDetailPollerSummary.run(
            input_path: context.log_path,
            output_path: context.summary_path,
            mode: :durability,
            measure_start_at: measure_start_at,
            measure_end_at: measure_end_at,
            cooldown_end_at: cooldown_end_at,
            nominal_cooldown_end_at: nominal_cooldown_end_at,
            writer_finished_at: writer_finished_at,
            measure_ms: BenchmarkHarness.phase309_measure_ms(),
            cooldown_ms: BenchmarkHarness.phase309_cooldown_ms()
          )

        writer_result = read_json_if_exists(context.writer_result_path)

        build_report(%{
          generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          base_url: BenchmarkHarness.benchmark_base_url(),
          writer_users: context.writer_users,
          timings: %{
            warmup_ms: BenchmarkHarness.phase309_warmup_ms(),
            measure_ms: BenchmarkHarness.phase309_measure_ms(),
            cooldown_ms: BenchmarkHarness.phase309_cooldown_ms()
          },
          pools: %{
            server: %{
              repo: System.get_env("STORE_BENCH_POOL_SIZE", "100") |> String.to_integer(),
              direct_repo:
                System.get_env("STORE_BENCH_DIRECT_POOL_SIZE", "60") |> String.to_integer()
            },
            writer: %{
              repo: System.get_env("STORE_BENCH_WRITER_POOL_SIZE", "20") |> String.to_integer(),
              direct_repo:
                System.get_env("STORE_BENCH_WRITER_DIRECT_POOL_SIZE", "5") |> String.to_integer()
            }
          },
          thresholds: %{
            shop_show_p95_ms: @shop_show_red_line_ms,
            storefront_http_failures: true,
            writer_failures: true,
            writer_step_errors: true
          },
          storefront: storefront,
          writer:
            Map.merge(writer, %{
              result_path: context.writer_result_path,
              data: writer_result,
              started_at: DateTime.to_iso8601(writer_started_at),
              finished_at: DateTime.to_iso8601(writer_finished_at)
            }),
          poller_log_path: context.log_path,
          poller_summary_path: context.summary_path,
          poller_summary: poller_summary
        })
      after
        stop_process(writer_port)
      end
    after
      stop_process(server_port)
      File.rm_rf(context.ready_path)
    end
  end

  defp build_report(report) do
    storefront_metrics = report.storefront.metrics
    writer_data = get_in(report, [:writer, :data]) || %{}
    writer_totals = Map.get(writer_data, "totals", %{})
    writer_steps = Map.get(writer_data, "steps", %{})
    poller = report.poller_summary || %{}
    durability = Map.get(poller, :durability, %{})
    memory_status = get_in(durability, [:memory_status, :status]) || "healthy"
    shop_show = Map.get(poller, :shop_show_under_contention, %{})
    scheduler = Map.get(poller, :scheduler, %{})
    postgres = Map.get(poller, :postgres_activity, %{})

    queue_time_ms = native_to_ms(get_in(shop_show, [:averages, "queue_time"]) || 0)
    query_time_ms = native_to_ms(get_in(shop_show, [:averages, "query_time"]) || 0)
    active_backends = get_in(postgres, [:averages, "active_backends"]) || 0.0
    lock_waiters = get_in(durability, [:lock_waiters_max]) || 0.0
    run_queue = get_in(scheduler, [:averages, "run_queue"]) || 0.0
    failed_cycles = Map.get(writer_totals, "failed_cycles", 0)
    step_error_counts = step_error_counts(writer_steps)

    durability_status =
      if storefront_metrics.shop_show_p95_ms > @shop_show_red_line_ms or
           storefront_metrics.http_req_failed_rate > 0.0 or
           failed_cycles > 0 or
           map_nonzero?(step_error_counts) or
           report.writer.exit_status not in [0, :ok] or
           memory_status == "memory_leak" do
        "fail"
      else
        "pass"
      end

    failure_mode =
      cond do
        memory_status == "memory_leak" ->
          "memory_leak"

        report.writer.exit_status not in [0, :ok] or failed_cycles > 0 or
            map_nonzero?(step_error_counts) ->
          "mixed"

        storefront_metrics.http_req_failed_rate > 0.0 and queue_time_ms > query_time_ms ->
          "pool_pressure"

        query_time_ms > 20.0 and active_backends > 0 and lock_waiters < 1 ->
          "db_service_saturation"

        run_queue >= 3.0 and queue_time_ms < 10.0 and query_time_ms < 10.0 ->
          "scheduler_pressure"

        memory_status == "temporary_heap_pressure" ->
          "recovery_lag"

        storefront_metrics.shop_show_p95_ms > @shop_show_red_line_ms and
            queue_time_ms >= query_time_ms ->
          "pool_pressure"

        storefront_metrics.shop_show_p95_ms > @shop_show_red_line_ms ->
          "mixed"

        true ->
          "none"
      end

    deployment_readiness_note =
      case durability_status do
        "pass" ->
          "The #{report.writer_users}-writer soak stayed inside the storefront latency and durability envelope; keep the 380-writer waiting-room trigger on this workstation profile."

        _ ->
          "The #{report.writer_users}-writer durability soak crossed the speed or stamina envelope; keep the 380-writer waiting-room trigger in place until the provider and memory gates pass."
      end

    Map.merge(report, %{
      writer_summary: %{
        successful_cycles: Map.get(writer_totals, "successful_cycles", 0),
        failed_cycles: failed_cycles,
        total_cycles: Map.get(writer_totals, "completed_cycles", 0),
        step_p95s_ms: step_p95s_ms(writer_steps),
        step_error_counts: step_error_counts
      },
      trend_summary: %{
        storefront: storefront_metrics,
        memory_profile: get_in(durability, [:memory_profile]) || %{},
        run_queue_profile: get_in(durability, [:run_queue_profile]) || %{},
        active_backends_profile: get_in(durability, [:active_backends_profile]) || %{},
        lock_waiters_max: lock_waiters,
        pending_provider_setup_trends:
          get_in(durability, [:pending_provider_setup_trends]) || %{},
        shop_show_trends: get_in(durability, [:shop_show_trends]) || %{}
      },
      durability_status: durability_status,
      failure_mode: failure_mode,
      deployment_readiness_note: deployment_readiness_note
    })
  end

  defp failure_report(context, reason) do
    %{
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      base_url: BenchmarkHarness.benchmark_base_url(),
      writer_users: context.writer_users,
      storefront: %{
        summary_path: context.storefront_summary_path,
        exit_code: :error,
        metrics: %{
          http_req_failed_rate: 1.0,
          shop_show_p95_ms: nil,
          shop_index_p95_ms: nil,
          cart_p95_ms: nil,
          checkout_p95_ms: nil
        }
      },
      writer: %{
        exit_status: :error,
        result_path: context.writer_result_path,
        data: read_json_if_exists(context.writer_result_path)
      },
      poller_log_path: context.log_path,
      poller_summary_path: context.summary_path,
      poller_summary: read_json_if_exists(context.summary_path),
      writer_summary: %{
        successful_cycles: 0,
        failed_cycles: 0,
        total_cycles: 0,
        step_p95s_ms: %{},
        step_error_counts: %{}
      },
      trend_summary: %{},
      durability_status: "fail",
      failure_mode: "mixed",
      deployment_readiness_note:
        "The soak orchestration failed before producing a complete durability signal.",
      orchestration_error: reason
    }
  end

  defp step_p95s_ms(steps) do
    Enum.into(steps, %{}, fn {step, summary} ->
      {step, Map.get(summary, "p95_duration_ms", 0.0)}
    end)
  end

  defp step_error_counts(steps) do
    Enum.into(steps, %{}, fn {step, summary} ->
      {step, Map.get(summary, "error_codes", %{})}
    end)
  end

  defp map_nonzero?(map) when map == %{}, do: false

  defp map_nonzero?(map) do
    Enum.any?(map, fn
      {_key, nested} when is_map(nested) -> map_nonzero?(nested)
      {_key, value} when is_integer(value) or is_float(value) -> value > 0
      {_key, _value} -> false
    end)
  end

  defp start_server_process(log_path, server_log_path) do
    env = [
      {"STORE_BENCH_ROLE", "server"},
      {"STORE_BENCH_POOL_SIZE", System.get_env("STORE_BENCH_POOL_SIZE", "100")},
      {"STORE_BENCH_DIRECT_POOL_SIZE", System.get_env("STORE_BENCH_DIRECT_POOL_SIZE", "60")},
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

  defp start_writer_process(writer_count, ready_path, writer_log_path, writer_result_path) do
    env =
      BenchmarkHarness.writer_env(
        writer_count,
        BenchmarkHarness.phase309_writer_duration_ms(),
        writer_result_path
      ) ++ [{"STORE_CONTENTION_READY_PATH", ready_path}]

    start_port_process(
      "mix run --no-start priv/perf/checkout_write_contention.exs",
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
      {"STORE_K6_WARMUP_MS", Integer.to_string(BenchmarkHarness.phase309_warmup_ms())},
      {"STORE_K6_MEASURE_MS", Integer.to_string(BenchmarkHarness.phase309_measure_ms())},
      {"STORE_K6_COOLDOWN_MS", Integer.to_string(BenchmarkHarness.phase309_cooldown_ms())}
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
      raise "k6 storefront durability run did not produce a summary file:\n#{output}"
    end

    summary = Jason.decode!(File.read!(summary_path))

    %{
      summary_path: summary_path,
      stdout: output,
      exit_code: exit_code,
      metrics: %{
        http_req_failed_rate: get_in(summary, ["metrics", "http_req_failed", "value"]) || 0.0,
        shop_show_p95_ms:
          get_in(summary, ["metrics", "http_req_duration{route:shop_show}", "p(95)"]) || 0.0,
        shop_index_p95_ms:
          get_in(summary, ["metrics", "http_req_duration{route:shop_index}", "p(95)"]) || 0.0,
        cart_p95_ms:
          get_in(summary, ["metrics", "http_req_duration{route:cart}", "p(95)"]) || 0.0,
        checkout_p95_ms:
          get_in(summary, ["metrics", "http_req_duration{route:checkout}", "p(95)"]) || 0.0
      }
    }
  end

  defp wait_for_ready_file!(path) do
    deadline = System.monotonic_time(:millisecond) + @writer_ready_timeout_ms
    wait_until(deadline, fn -> if File.exists?(path), do: :ok, else: :retry end)
  end

  defp wait_until(deadline, fun) do
    case fun.() do
      :ok ->
        :ok

      :retry ->
        if System.monotonic_time(:millisecond) >= deadline do
          raise "timed out waiting for Phase 30.9 process readiness"
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

  defp native_to_ms(value) when is_number(value) do
    native_per_ms = System.convert_time_unit(1, :millisecond, :native)
    value / native_per_ms
  end

  defp max_datetime(left, right) do
    case DateTime.compare(left, right) do
      :lt -> right
      _ -> left
    end
  end
end

Store.Perf.Phase309Durability.run()
