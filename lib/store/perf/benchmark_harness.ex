defmodule Store.Perf.BenchmarkHarness do
  @moduledoc false

  alias Store.Perf.ChaosProfile
  alias Store.Perf.ProductDetailPollerSummary

  @default_host "127.0.0.1"
  @default_port 4000
  @connect_timeout 500
  @ready_timeout_ms 30_000
  @ready_poll_interval_ms 250

  def benchmark_host do
    System.get_env("STORE_BENCHMARK_HOST", @default_host)
  end

  def benchmark_port do
    System.get_env("PORT", Integer.to_string(@default_port))
    |> String.to_integer()
  end

  def benchmark_base_url do
    "http://#{benchmark_host()}:#{benchmark_port()}"
  end

  def benchmark_data_path do
    System.get_env("STORE_BENCHMARK_DATA_PATH", "tmp/perf/benchmark_data.json")
    |> Path.expand(File.cwd!())
  end

  def product_detail_poller_log_path do
    System.get_env(
      "STORE_PRODUCT_DETAIL_POLLER_LOG_PATH",
      "tmp/perf/product_detail_poller.ndjson"
    )
  end

  def product_detail_poller_summary_path do
    System.get_env(
      "STORE_PRODUCT_DETAIL_POLLER_SUMMARY_PATH",
      "tmp/perf/product_detail_poller_summary.json"
    )
  end

  def playwright_result_path do
    System.get_env(
      "STORE_PLAYWRIGHT_RESULT_PATH",
      "tmp/perf/playwright_product_detail_live_join.json"
    )
  end

  def chaos_playwright_result_path do
    profile = chaos_profile()

    System.get_env(
      "STORE_PLAYWRIGHT_CHAOS_RESULT_PATH",
      "tmp/perf/playwright_product_detail_live_join_#{profile}.json"
    )
  end

  def storefront_summary_path(kind \\ "contention") do
    System.get_env(
      "STORE_K6_SUMMARY_PATH",
      "tmp/perf/k6_http_storefront_phase307_#{kind}.json"
    )
  end

  def chaos_storefront_summary_path(kind \\ "contention") do
    profile = chaos_profile()

    System.get_env(
      "STORE_K6_CHAOS_SUMMARY_PATH",
      "tmp/perf/k6_http_storefront_#{profile}_#{kind}.json"
    )
  end

  def chaos_profile do
    ChaosProfile.current_profile()
  end

  def chaos_seed do
    ChaosProfile.current_seed()
  end

  def phase308_storefront_summary_path(rung) when is_integer(rung) do
    "tmp/perf/k6_http_storefront_phase308_#{rung}.json"
  end

  def phase308_writer_result_path(rung) when is_integer(rung) do
    "tmp/perf/checkout_write_contention_phase308_#{rung}.json"
  end

  def phase308_poller_log_path(rung) when is_integer(rung) do
    "tmp/perf/product_detail_poller_phase308_#{rung}.ndjson"
  end

  def phase308_poller_summary_path(rung) when is_integer(rung) do
    "tmp/perf/product_detail_poller_summary_phase308_#{rung}.json"
  end

  def phase308_report_path do
    "tmp/perf/phase308_stress_to_failure_report.json"
  end

  def phase309_storefront_summary_path do
    "tmp/perf/k6_http_storefront_phase309.json"
  end

  def phase309_writer_result_path do
    "tmp/perf/checkout_write_contention_phase309.json"
  end

  def phase309_poller_log_path do
    "tmp/perf/product_detail_poller_phase309.ndjson"
  end

  def phase309_poller_summary_path do
    "tmp/perf/product_detail_poller_summary_phase309.json"
  end

  def phase309_report_path do
    "tmp/perf/phase309_durability_report.json"
  end

  def checkout_write_contention_path do
    System.get_env(
      "STORE_CHECKOUT_WRITE_CONTENTION_PATH",
      "tmp/perf/checkout_write_contention.json"
    )
  end

  def poller_log_path(kind \\ "contention") do
    "tmp/perf/product_detail_poller_#{kind}.ndjson"
  end

  def poller_summary_path(kind \\ "contention") do
    "tmp/perf/product_detail_poller_summary_#{kind}.json"
  end

  def require_test_env! do
    if Mix.env() != :test do
      raise "benchmark harness scripts must run with MIX_ENV=test"
    end
  end

  def require_isolated_test_db! do
    case System.get_env("STORE_TEST_DB_SUFFIX") do
      nil ->
        raise """
        benchmark harness requires an isolated test database.
        Run with STORE_TEST_DB_SUFFIX=bench or another suffix.
        """

      "" ->
        raise """
        benchmark harness requires an isolated test database.
        Run with STORE_TEST_DB_SUFFIX=bench or another suffix.
        """

      suffix ->
        suffix
    end
  end

  def ensure_port_available! do
    case :gen_tcp.connect(
           String.to_charlist(benchmark_host()),
           benchmark_port(),
           [:binary],
           @connect_timeout
         ) do
      {:ok, socket} ->
        :gen_tcp.close(socket)

        raise """
        benchmark server port #{benchmark_port()} is already in use on #{benchmark_host()}.
        Stop the existing process or choose a different PORT before starting the benchmark harness.
        """

      {:error, :econnrefused} ->
        :ok

      {:error, :timeout} ->
        raise """
        timed out while checking benchmark port #{benchmark_port()} on #{benchmark_host()}.
        Resolve the local networking issue before running the benchmark harness.
        """

      {:error, :nxdomain} ->
        raise "benchmark host #{benchmark_host()} could not be resolved"

      {:error, reason} ->
        raise "unable to validate benchmark port availability: #{inspect(reason)}"
    end
  end

  def configure_endpoint! do
    endpoint_config = Application.get_env(:store, StoreWeb.Endpoint, [])

    ip =
      benchmark_host() |> String.split(".") |> Enum.map(&String.to_integer/1) |> List.to_tuple()

    Application.put_env(
      :store,
      StoreWeb.Endpoint,
      Keyword.merge(endpoint_config,
        server: true,
        http: [ip: ip, port: benchmark_port()],
        url: [host: benchmark_host(), port: benchmark_port(), scheme: "http"]
      )
    )
  end

  def configure_repos! do
    repo_config = Application.get_env(:store, Store.Repo, [])
    direct_repo_config = Application.get_env(:store, Store.DirectRepo, [])

    Application.put_env(
      :store,
      Store.Repo,
      Keyword.merge(repo_config,
        pool: DBConnection.ConnectionPool,
        pool_size: Keyword.get(repo_config, :pool_size, 20),
        prepare: :unnamed,
        queue_target: 10_000,
        queue_interval: 10_000,
        timeout: 60_000
      )
    )

    Application.put_env(
      :store,
      Store.DirectRepo,
      Keyword.merge(direct_repo_config,
        pool: DBConnection.ConnectionPool,
        pool_size: Keyword.get(direct_repo_config, :pool_size, 10),
        queue_target: 10_000,
        queue_interval: 10_000,
        timeout: 60_000
      )
    )
  end

  def wait_for_endpoint! do
    deadline = System.monotonic_time(:millisecond) + @ready_timeout_ms
    url = benchmark_base_url() <> "/shop"
    :inets.start()

    wait_until(deadline, fn ->
      case :httpc.request(:get, {String.to_charlist(url), []}, [timeout: 1_000], []) do
        {:ok, {{_version, status, _reason}, _headers, _body}} when status in 200..399 -> :ok
        {:ok, {{_version, status, _reason}, _headers, _body}} -> {:retry, "HTTP #{status}"}
        {:error, reason} -> {:retry, inspect(reason)}
      end
    end)
  end

  def run_poller_summary! do
    ProductDetailPollerSummary.run(
      input_path: product_detail_poller_log_path(),
      output_path: product_detail_poller_summary_path()
    )
  end

  def run_poller_summary!(input_path, output_path) do
    ProductDetailPollerSummary.run(
      input_path: input_path,
      output_path: output_path
    )
  end

  def run_poller_summary!(kind) do
    ProductDetailPollerSummary.run(
      input_path: poller_log_path(kind),
      output_path: poller_summary_path(kind)
    )
  end

  def print_runbook(log_path) do
    IO.puts("Benchmark server ready at #{benchmark_base_url()}")
    IO.puts("Benchmark data: #{benchmark_data_path()}")
    IO.puts("Poller log: #{log_path}")
    IO.puts("Poller summary: #{product_detail_poller_summary_path()}")
    IO.puts("Playwright result: #{playwright_result_path()}")
    IO.puts("Chaos Playwright result: #{chaos_playwright_result_path()}")
    IO.puts("")
    IO.puts("Run order:")

    IO.puts(
      "  1. STORE_LIVE_JOIN_MODE=quick npx playwright test -c perf/playwright/playwright.config.mjs perf/playwright/product_detail_live_join.mjs"
    )

    IO.puts("  2. MIX_ENV=test mix run --no-start priv/perf/product_detail_poller_summary.exs")

    IO.puts(
      "  3. STORE_LIVE_JOIN_MODE=full npx playwright test -c perf/playwright/playwright.config.mjs perf/playwright/product_detail_live_join.mjs"
    )

    IO.puts("  4. MIX_ENV=test mix run --no-start priv/perf/product_detail_poller_summary.exs")
    IO.puts("  5. STORE_K6_QUICK=1 k6 run perf/k6/http_storefront.js")

    IO.puts(
      "  6. STORE_PERF_CHAOS_PROFILE=mobile_realistic STORE_PERF_CHAOS_SEED=#{chaos_seed()} STORE_K6_QUICK=1 k6 run --summary-export #{chaos_storefront_summary_path("quick")} perf/k6/http_storefront.js"
    )

    IO.puts(
      "  7. STORE_PERF_CHAOS_PROFILE=mobile_realistic STORE_PERF_CHAOS_SEED=#{chaos_seed()} STORE_PLAYWRIGHT_RESULT_PATH=#{chaos_playwright_result_path()} STORE_LIVE_JOIN_MODE=quick npx playwright test -c perf/playwright/playwright.config.mjs perf/playwright/product_detail_live_join.mjs"
    )
  end

  def benchmark_mode do
    System.get_env("STORE_PHASE307_MODE", "quick")
  end

  def phase308_writer_steps do
    System.get_env("STORE_PHASE308_WRITER_STEPS", "20,40,60,80,100,120,140,160,180,200")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.to_integer/1)
  end

  def phase308_warmup_ms do
    System.get_env("STORE_PHASE308_WARMUP_MS", "30000")
    |> String.to_integer()
  end

  def phase308_measure_ms do
    System.get_env("STORE_PHASE308_MEASURE_MS", "120000")
    |> String.to_integer()
  end

  def phase308_cooldown_ms do
    System.get_env("STORE_PHASE308_COOLDOWN_MS", "30000")
    |> String.to_integer()
  end

  def phase308_total_ms do
    phase308_warmup_ms() + phase308_measure_ms() + phase308_cooldown_ms()
  end

  def phase308_writer_duration_ms do
    phase308_warmup_ms() + phase308_measure_ms()
  end

  def phase309_writer_users do
    System.get_env("STORE_PHASE309_WRITER_USERS", "100")
    |> String.to_integer()
  end

  def phase309_warmup_ms do
    System.get_env("STORE_PHASE309_WARMUP_MS", "60000")
    |> String.to_integer()
  end

  def phase309_measure_ms do
    System.get_env("STORE_PHASE309_MEASURE_MS", "600000")
    |> String.to_integer()
  end

  def phase309_cooldown_ms do
    System.get_env("STORE_PHASE309_COOLDOWN_MS", "60000")
    |> String.to_integer()
  end

  def phase309_total_ms do
    phase309_warmup_ms() + phase309_measure_ms() + phase309_cooldown_ms()
  end

  def phase309_writer_duration_ms do
    phase309_warmup_ms() + phase309_measure_ms()
  end

  def writer_users do
    case System.get_env("STORE_CONTENTION_WRITER_USERS") do
      nil -> if(benchmark_mode() == "quick", do: 20, else: 60)
      value -> String.to_integer(value)
    end
  end

  def writer_ramp_per_second do
    System.get_env("STORE_CONTENTION_WRITER_RAMP_PER_SECOND", "5")
    |> String.to_integer()
  end

  def cooldown_ms do
    System.get_env("STORE_PHASE307_COOLDOWN_MS", "30000")
    |> String.to_integer()
  end

  def storefront_total_ms do
    case benchmark_mode() do
      "quick" -> 120_000
      _ -> 600_000
    end
  end

  def writer_duration_ms do
    max(storefront_total_ms() - cooldown_ms(), 1_000)
  end

  def writer_env do
    writer_env(writer_users(), writer_duration_ms(), checkout_write_contention_path())
  end

  def writer_env(users, duration_ms, output_path) do
    [
      {"STORE_BENCH_ROLE", "writer"},
      {"STORE_BENCH_WRITER_POOL_SIZE", System.get_env("STORE_BENCH_WRITER_POOL_SIZE", "20")},
      {"STORE_BENCH_WRITER_DIRECT_POOL_SIZE",
       System.get_env("STORE_BENCH_WRITER_DIRECT_POOL_SIZE", "5")},
      {"STORE_CONTENTION_WRITER_USERS", Integer.to_string(users)},
      {"STORE_CONTENTION_WRITER_RAMP_PER_SECOND", Integer.to_string(writer_ramp_per_second())},
      {"STORE_CONTENTION_DURATION_MS", Integer.to_string(duration_ms)},
      {"STORE_CHECKOUT_WRITE_CONTENTION_PATH", output_path},
      {"STORE_BENCHMARK_DATA_PATH", benchmark_data_path()},
      {"PORT", Integer.to_string(benchmark_port())},
      {"STORE_BENCHMARK_BASE_URL", benchmark_base_url()},
      {"STORE_TEST_DB_SUFFIX", require_isolated_test_db!()},
      {"MIX_ENV", "test"}
    ]
  end

  defp wait_until(deadline, fun) do
    case fun.() do
      :ok ->
        :ok

      {:retry, _reason} ->
        if System.monotonic_time(:millisecond) >= deadline do
          raise "benchmark endpoint #{benchmark_base_url()} did not become ready before timeout"
        end

        Process.sleep(@ready_poll_interval_ms)
        wait_until(deadline, fun)
    end
  end
end
