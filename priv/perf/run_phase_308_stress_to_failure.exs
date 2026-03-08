if Mix.env() != :test do
  raise "run_phase_308_stress_to_failure.exs must be run with MIX_ENV=test"
end

Code.ensure_loaded!(Store.Perf.BenchmarkHarness)
alias Store.Perf.BenchmarkHarness

BenchmarkHarness.require_test_env!()
BenchmarkHarness.require_isolated_test_db!()

if Enum.any?(Application.started_applications(), fn {app, _desc, _vsn} -> app == :store end) do
  raise "run_phase_308_stress_to_failure.exs expects standalone startup"
end

defmodule Store.Perf.Phase308StressToFailure do
  @moduledoc false

  alias Store.Perf.BenchmarkHarness

  @writer_ready_timeout_ms 30_000
  @process_shutdown_timeout_ms 5_000
  @process_exit_grace_ms 90_000
  @shop_show_red_line_ms 200.0

  def run do
    steps = BenchmarkHarness.phase308_writer_steps()

    result =
      %{
        generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        mode: BenchmarkHarness.benchmark_mode(),
        base_url: BenchmarkHarness.benchmark_base_url(),
        red_line: %{
          shop_show_p95_ms: @shop_show_red_line_ms,
          storefront_http_failures: true,
          writer_failures: true,
          allowed_failed_cycles: allowed_failed_cycles(),
          allowed_step_errors: allowed_step_errors()
        },
        timings: %{
          warmup_ms: BenchmarkHarness.phase308_warmup_ms(),
          measure_ms: BenchmarkHarness.phase308_measure_ms(),
          cooldown_ms: BenchmarkHarness.phase308_cooldown_ms()
        },
        pools: %{
          server: %{
            repo: System.get_env("STORE_BENCH_POOL_SIZE", "80") |> String.to_integer(),
            direct_repo:
              System.get_env("STORE_BENCH_DIRECT_POOL_SIZE", "40") |> String.to_integer()
          },
          writer: %{
            repo: System.get_env("STORE_BENCH_WRITER_POOL_SIZE", "20") |> String.to_integer(),
            direct_repo:
              System.get_env("STORE_BENCH_WRITER_DIRECT_POOL_SIZE", "5") |> String.to_integer()
          }
        },
        writer_steps: steps,
        rungs: run_ladder(steps)
      }
      |> finalize_report()

    path = BenchmarkHarness.phase308_report_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode_to_iodata!(result, pretty: true))
    IO.puts("Wrote Phase 30.8 stress-to-failure report to #{path}")
    result
  end

  defp run_ladder(steps) do
    Enum.reduce_while(steps, [], fn writer_count, acc ->
      rung_result = run_rung(writer_count)
      acc = acc ++ [rung_result]

      if get_in(rung_result, [:red_line, :crossed]) do
        {:halt, acc}
      else
        {:cont, acc}
      end
    end)
  end

  defp run_rung(writer_count) do
    context = %{
      writer_concurrency: writer_count,
      log_path: BenchmarkHarness.phase308_poller_log_path(writer_count),
      summary_path: BenchmarkHarness.phase308_poller_summary_path(writer_count),
      storefront_summary_path: BenchmarkHarness.phase308_storefront_summary_path(writer_count),
      writer_result_path: BenchmarkHarness.phase308_writer_result_path(writer_count),
      ready_path: "tmp/perf/phase308_writer_#{writer_count}.ready",
      server_log_path: "tmp/perf/phase308_server_#{writer_count}.log",
      writer_log_path: "tmp/perf/phase308_writer_#{writer_count}.log"
    }

    try do
      do_run_rung(context)
    rescue
      error ->
        %{
          writer_concurrency: writer_count,
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
          cooldown_summary: %{},
          classification: %{
            type: "orchestration_timeout",
            reason: Exception.message(error)
          },
          red_line: %{
            crossed: true,
            shop_show_p95_ms: nil,
            http_req_failed_rate: 1.0,
            failed_cycles: 0,
            step_error_counts: %{}
          }
        }
    end
  end

  defp do_run_rung(context) do
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
          context.writer_concurrency,
          context.ready_path,
          context.writer_log_path,
          context.writer_result_path
        )

      try do
        wait_for_ready_file!(context.ready_path)

        writer_started_at = DateTime.utc_now()
        storefront = run_storefront_k6(context.storefront_summary_path)

        writer =
          wait_for_process(
            writer_port,
            BenchmarkHarness.phase308_writer_duration_ms() + @process_exit_grace_ms
          )

        writer_finished_at = DateTime.utc_now()

        stop_process(server_port)

        poller_summary =
          BenchmarkHarness.run_poller_summary!(
            context.log_path,
            context.summary_path
          )

        writer_result = read_json_if_exists(context.writer_result_path)

        cooldown_summary =
          summarize_cooldown_window(
            context.log_path,
            writer_finished_at,
            DateTime.add(
              writer_finished_at,
              BenchmarkHarness.phase308_cooldown_ms(),
              :millisecond
            )
          )

        classify_rung(%{
          writer_concurrency: context.writer_concurrency,
          storefront: storefront,
          writer:
            Map.merge(writer, %{result_path: context.writer_result_path, data: writer_result}),
          poller_log_path: context.log_path,
          poller_summary_path: context.summary_path,
          poller_summary: poller_summary,
          writer_started_at: DateTime.to_iso8601(writer_started_at),
          writer_finished_at: DateTime.to_iso8601(writer_finished_at),
          cooldown_summary: cooldown_summary
        })
      after
        stop_process(writer_port)
      end
    after
      stop_process(server_port)
      File.rm_rf(context.ready_path)
    end
  end

  defp finalize_report(report) do
    {last_healthy, first_failing} =
      Enum.reduce(report.rungs, {nil, nil}, fn rung, {healthy, failing} ->
        if get_in(rung, [:red_line, :crossed]) do
          {healthy, failing || rung}
        else
          {rung, failing}
        end
      end)

    Map.merge(report, %{
      last_healthy_rung: summarize_rung(last_healthy),
      first_failing_rung: summarize_rung(first_failing),
      recommended_waiting_room_threshold: waiting_room_threshold(last_healthy),
      stayed_within_target_through_tested_ceiling: is_nil(first_failing)
    })
  end

  defp summarize_rung(nil), do: nil

  defp summarize_rung(rung) do
    %{
      writer_concurrency: rung.writer_concurrency,
      shop_show_p95_ms: get_in(rung, [:storefront, :metrics, :shop_show_p95_ms]),
      http_req_failed_rate: get_in(rung, [:storefront, :metrics, :http_req_failed_rate]),
      classification: get_in(rung, [:classification, :type]),
      reason: get_in(rung, [:classification, :reason])
    }
  end

  defp waiting_room_threshold(nil) do
    %{
      writer_concurrency: 0,
      suggested_trigger: 0,
      note: "No healthy rung was observed during the tested ladder."
    }
  end

  defp waiting_room_threshold(rung) do
    safe = rung.writer_concurrency
    conservative = max(safe - 20, 0)

    %{
      writer_concurrency: safe,
      suggested_trigger: conservative,
      note:
        "Use the last healthy rung as the tested ceiling and apply a 20-writer buffer for a conservative waiting-room trigger on this workstation."
    }
  end

  defp classify_rung(rung) do
    storefront_metrics = rung.storefront.metrics
    writer_totals = get_in(rung, [:writer, :data, "totals"]) || %{}
    poller = rung.poller_summary || %{}
    contention = Map.get(poller, :shop_show_under_contention, %{})
    scheduler = Map.get(poller, :scheduler, %{})
    postgres = Map.get(poller, :postgres_activity, %{})
    cooldown = rung.cooldown_summary || %{}

    queue_time_ms = native_to_ms(get_in(contention, [:averages, "queue_time"]) || 0)
    query_time_ms = native_to_ms(get_in(contention, [:averages, "query_time"]) || 0)
    run_queue = get_in(scheduler, [:averages, "run_queue"]) || 0.0
    active_backends = get_in(postgres, [:averages, "active_backends"]) || 0.0
    lock_waiters = get_in(postgres, [:averages, "lock_waiters"]) || 0.0
    failed_cycles = Map.get(writer_totals, "failed_cycles", 0)
    step_error_counts = step_error_counts(get_in(rung, [:writer, :data, "steps"]) || %{})
    cooldown_memory_total = get_in(cooldown, [:scheduler, :averages, "memory_total"]) || 0.0
    overall_memory_total = get_in(scheduler, [:averages, "memory_total"]) || 0.0

    cooldown_query_time_ms =
      native_to_ms(get_in(cooldown, [:shop_show_under_contention, :averages, "query_time"]) || 0)

    cooldown_snapshots = Map.get(cooldown, :snapshots, 0)

    red_line_crossed =
      red_line_crossed?(
        storefront_metrics,
        failed_cycles,
        step_error_counts,
        rung.writer.exit_status
      )

    classification =
      cond do
        queue_time_ms > 20.0 and query_time_ms <= queue_time_ms ->
          %{
            type: "server_pool_pressure",
            reason:
              "Shop reads kept a flat query count while repo queue time rose ahead of service time."
          }

        query_time_ms > 20.0 and active_backends > 0 and lock_waiters < 1 ->
          %{
            type: "db_service_saturation",
            reason: "Repo service time increased under write load without lock wait growth."
          }

        lock_waiters >= 1 ->
          %{
            type: "lock_interference",
            reason: "Postgres lock waiters rose materially during checkout writes."
          }

        rung.writer.exit_status not in [0, :ok] ->
          %{
            type: "writer_process_failure",
            reason:
              "The isolated checkout writer process exited before completing the rung and writing a clean result."
          }

        failed_cycles > allowed_failed_cycles() or
            map_nonzero?(step_error_counts, allowed_step_errors()) ->
          %{
            type: "writer_error_growth",
            reason:
              "Checkout write errors exceeded the allowed floor while storefront latency remained inside the read-side target."
          }

        run_queue >= 3.0 and queue_time_ms < 10.0 and query_time_ms < 10.0 ->
          %{
            type: "scheduler_starvation",
            reason: "BEAM run queue rose while DB timings stayed low."
          }

        red_line_crossed and cooldown_snapshots > 0 and overall_memory_total > 0 and
          cooldown_memory_total > overall_memory_total * 0.9 and
            cooldown_query_time_ms > query_time_ms * 0.8 ->
          %{
            type: "recovery_pressure",
            reason:
              "Memory pressure stayed elevated into the cooldown window after writers stopped."
          }

        red_line_crossed ->
          %{
            type: "http_boundary_exhaustion",
            reason: "The acceptance load crossed the red line without a stronger internal signal."
          }

        true ->
          %{
            type: "mild_db_pressure",
            reason:
              "Reads remained healthy with only mild queue/service-time growth under concurrent writes."
          }
      end

    Map.merge(rung, %{
      classification: classification,
      red_line: %{
        crossed: red_line_crossed,
        shop_show_p95_ms: storefront_metrics.shop_show_p95_ms,
        http_req_failed_rate: storefront_metrics.http_req_failed_rate,
        failed_cycles: failed_cycles,
        step_error_counts: step_error_counts
      }
    })
  end

  defp red_line_crossed?(storefront_metrics, failed_cycles, step_error_counts, writer_exit_status) do
    (storefront_metrics.shop_show_p95_ms || 0.0) > @shop_show_red_line_ms or
      (storefront_metrics.http_req_failed_rate || 0.0) > 0.0 or
      failed_cycles > allowed_failed_cycles() or
      map_nonzero?(step_error_counts, allowed_step_errors()) or
      writer_exit_status not in [0, :ok]
  end

  defp step_error_counts(steps) do
    Enum.into(steps, %{}, fn {step, summary} ->
      {step, Map.get(summary, "error_codes", %{})}
    end)
  end

  defp map_nonzero?(map, _floor) when map == %{}, do: false

  defp map_nonzero?(map, floor) do
    Enum.any?(map, fn
      {_key, nested} when is_map(nested) -> map_nonzero?(nested, floor)
      {_key, value} when is_integer(value) or is_float(value) -> value > floor
      {_key, _value} -> false
    end)
  end

  defp allowed_failed_cycles do
    System.get_env("STORE_PHASE308_ALLOWED_FAILED_CYCLES", "0")
    |> String.to_integer()
  end

  defp allowed_step_errors do
    System.get_env("STORE_PHASE308_ALLOWED_STEP_ERRORS", "0")
    |> String.to_integer()
  end

  defp summarize_cooldown_window(log_path, writer_finished_at, cooldown_until) do
    rows =
      if File.exists?(log_path) do
        log_path
        |> File.stream!([], :line)
        |> Enum.map(&Jason.decode!/1)
        |> Enum.filter(fn snapshot ->
          with {:ok, captured_at, _} <- DateTime.from_iso8601(snapshot["captured_at"]) do
            DateTime.compare(captured_at, writer_finished_at) != :lt and
              DateTime.compare(captured_at, cooldown_until) != :gt
          else
            _ -> false
          end
        end)
      else
        []
      end

    %{
      snapshots: length(rows),
      shop_show_under_contention: aggregate_shop_live(rows),
      scheduler: aggregate_snapshot_maps(rows, "scheduler"),
      postgres_activity: aggregate_snapshot_maps(rows, "postgres_activity")
    }
  end

  defp aggregate_shop_live(rows) do
    windows =
      rows
      |> Enum.flat_map(&Map.get(&1, "shop_live", []))
      |> Enum.filter(fn row ->
        case Map.get(row, "key") do
          ["static_render", false, "ok"] -> true
          ["live_join", true, "ok"] -> true
          _ -> false
        end
      end)

    aggregate_rows(windows)
  end

  defp aggregate_rows([]) do
    %{
      count: 0,
      averages: %{},
      maxes: %{}
    }
  end

  defp aggregate_rows(rows) do
    count = Enum.sum(Enum.map(rows, &Map.get(&1, "count", 0)))

    averages =
      rows
      |> Enum.flat_map(&Map.to_list(Map.get(&1, "averages", %{})))
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.into(%{}, fn {key, values} -> {key, Enum.sum(values) / length(values)} end)

    maxes =
      rows
      |> Enum.flat_map(&Map.to_list(Map.get(&1, "maxes", %{})))
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.into(%{}, fn {key, values} -> {key, Enum.max(values)} end)

    %{
      count: count,
      averages: averages,
      maxes: maxes
    }
  end

  defp aggregate_snapshot_maps(rows, key) do
    maps =
      rows
      |> Enum.map(&Map.get(&1, key, %{}))
      |> Enum.filter(&is_map/1)

    if maps == [] do
      %{count: 0, averages: %{}, maxes: %{}}
    else
      averages =
        maps
        |> Enum.flat_map(&Map.to_list/1)
        |> Enum.filter(fn {_metric, value} -> is_number(value) end)
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
        |> Enum.into(%{}, fn {metric, values} -> {metric, Enum.sum(values) / length(values)} end)

      maxes =
        maps
        |> Enum.flat_map(&Map.to_list/1)
        |> Enum.filter(fn {_metric, value} -> is_number(value) end)
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
        |> Enum.into(%{}, fn {metric, values} -> {metric, Enum.max(values)} end)

      %{count: length(maps), averages: averages, maxes: maxes}
    end
  end

  defp start_server_process(log_path, server_log_path) do
    env = [
      {"STORE_BENCH_ROLE", "server"},
      {"STORE_BENCH_POOL_SIZE", System.get_env("STORE_BENCH_POOL_SIZE", "80")},
      {"STORE_BENCH_DIRECT_POOL_SIZE", System.get_env("STORE_BENCH_DIRECT_POOL_SIZE", "40")},
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
        BenchmarkHarness.phase308_writer_duration_ms(),
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
    quick_env =
      if BenchmarkHarness.benchmark_mode() == "quick", do: [{"STORE_K6_QUICK", "1"}], else: []

    env =
      [
        {"STORE_BENCHMARK_DATA_PATH", BenchmarkHarness.benchmark_data_path()},
        {"STORE_BENCHMARK_BASE_URL", BenchmarkHarness.benchmark_base_url()},
        {"STORE_K6_WARMUP_MS", Integer.to_string(BenchmarkHarness.phase308_warmup_ms())},
        {"STORE_K6_MEASURE_MS", Integer.to_string(BenchmarkHarness.phase308_measure_ms())},
        {"STORE_K6_COOLDOWN_MS", Integer.to_string(BenchmarkHarness.phase308_cooldown_ms())}
      ] ++ quick_env

    {output, exit_code} =
      System.cmd(
        "k6",
        ["run", "--summary-export", summary_path, "perf/k6/http_storefront.js"],
        stderr_to_stdout: true,
        env: env,
        cd: File.cwd!()
      )

    unless File.exists?(summary_path) do
      raise "k6 storefront run did not produce a summary file:\n#{output}"
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
          raise "timed out waiting for Phase 30.8 process readiness"
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
end

Store.Perf.Phase308StressToFailure.run()
