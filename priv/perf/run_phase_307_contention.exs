if Mix.env() != :test do
  raise "run_phase_307_contention.exs must be run with MIX_ENV=test"
end

Code.ensure_loaded!(Store.Perf.BenchmarkHarness)
alias Store.Perf.BenchmarkHarness

BenchmarkHarness.require_test_env!()
BenchmarkHarness.require_isolated_test_db!()

if Enum.any?(Application.started_applications(), fn {app, _desc, _vsn} -> app == :store end) do
  raise "run_phase_307_contention.exs expects standalone startup"
end

defmodule Store.Perf.Phase307Contention do
  @moduledoc false

  alias Store.Perf.BenchmarkHarness

  def run do
    mode = BenchmarkHarness.benchmark_mode()

    result = %{
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      mode: mode,
      base_url: BenchmarkHarness.benchmark_base_url(),
      baseline: run_baseline(mode),
      contention: run_contention(mode)
    }

    path = "tmp/perf/phase307_contention_report.json"
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode_to_iodata!(result, pretty: true))
    IO.puts("Wrote Phase 30.7 contention report to #{path}")
    result
  end

  defp run_baseline(mode) do
    run_server_scenario("baseline", mode, fn ->
      run_storefront_k6(BenchmarkHarness.storefront_summary_path("baseline"), mode)
    end)
  end

  defp run_contention(mode) do
    run_server_scenario("contention", mode, fn ->
      ready_path = "tmp/perf/checkout_writer.ready"
      writer_log_path = "tmp/perf/phase307_writer.log"
      File.rm_rf(ready_path)
      writer_port = start_writer_process(ready_path, writer_log_path)
      wait_for_ready_file!(ready_path)

      k6_result = run_storefront_k6(BenchmarkHarness.storefront_summary_path("contention"), mode)

      writer_result =
        wait_for_process(writer_port, BenchmarkHarness.writer_duration_ms() + 90_000)

      File.rm_rf(ready_path)

      %{
        storefront: k6_result,
        writer: writer_result,
        writer_result_path: BenchmarkHarness.checkout_write_contention_path()
      }
    end)
  end

  defp run_server_scenario(kind, mode, fun) do
    log_path = BenchmarkHarness.poller_log_path(kind)
    summary_path = BenchmarkHarness.poller_summary_path(kind)
    server_log_path = "tmp/perf/phase307_#{kind}_server.log"
    File.rm_rf(log_path)
    File.rm_rf(summary_path)

    server_port = start_server_process(log_path, server_log_path)

    try do
      wait_for_endpoint!()
      scenario = fun.()
      stop_process(server_port)
      summary = BenchmarkHarness.run_poller_summary!(kind)

      %{
        mode: mode,
        storefront: scenario[:storefront] || scenario,
        writer: Map.get(scenario, :writer),
        poller_log_path: log_path,
        poller_summary_path: summary_path,
        poller_summary: summary
      }
    after
      stop_process(server_port)
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

  defp start_writer_process(ready_path, writer_log_path) do
    env =
      BenchmarkHarness.writer_env() ++
        [{"STORE_CONTENTION_READY_PATH", ready_path}]

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

  defp run_storefront_k6(summary_path, mode) do
    quick_env = if mode == "quick", do: [{"STORE_K6_QUICK", "1"}], else: []

    env =
      [
        {"STORE_BENCHMARK_DATA_PATH", BenchmarkHarness.benchmark_data_path()},
        {"STORE_BENCHMARK_BASE_URL", BenchmarkHarness.benchmark_base_url()}
      ] ++ quick_env

    {output, exit_code} =
      System.cmd(
        "k6",
        ["run", "--summary-export", summary_path, "perf/k6/http_storefront.js"],
        stderr_to_stdout: true,
        env: env,
        cd: File.cwd!()
      )

    if exit_code != 0 do
      raise "k6 storefront run failed:\n#{output}"
    end

    summary = Jason.decode!(File.read!(summary_path))

    %{
      summary_path: summary_path,
      stdout: output,
      metrics: summarize_k6(summary)
    }
  end

  defp wait_for_endpoint! do
    deadline = System.monotonic_time(:millisecond) + 30_000
    url = BenchmarkHarness.benchmark_base_url() <> "/shop"
    :inets.start()

    wait_until(deadline, fn ->
      case :httpc.request(:get, {String.to_charlist(url), []}, [timeout: 1_000], []) do
        {:ok, {{_version, status, _reason}, _headers, _body}} when status in 200..399 -> :ok
        _ -> :retry
      end
    end)
  end

  defp wait_for_ready_file!(path) do
    deadline = System.monotonic_time(:millisecond) + 30_000
    wait_until(deadline, fn -> if File.exists?(path), do: :ok, else: :retry end)
  end

  defp wait_until(deadline, fun) do
    case fun.() do
      :ok ->
        :ok

      :retry ->
        if System.monotonic_time(:millisecond) >= deadline do
          raise "timed out waiting for Phase 30.7 process readiness"
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
          5_000 -> System.cmd("kill", ["-KILL", Integer.to_string(os_pid)])
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

  defp summarize_k6(summary) do
    metrics = Map.get(summary, "metrics", %{})

    %{
      http_req_failed_rate: get_in(metrics, ["http_req_failed", "value"]),
      shop_show_p95_ms: get_in(metrics, ["http_req_duration{route:shop_show}", "p(95)"]),
      shop_index_p95_ms: get_in(metrics, ["http_req_duration{route:shop_index}", "p(95)"]),
      cart_p95_ms: get_in(metrics, ["http_req_duration{route:cart}", "p(95)"]),
      checkout_p95_ms: get_in(metrics, ["http_req_duration{route:checkout}", "p(95)"])
    }
  end
end

Store.Perf.Phase307Contention.run()
