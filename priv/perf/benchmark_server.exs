alias Store.Perf.{BenchmarkHarness, ProductDetailPoller}

BenchmarkHarness.require_test_env!()
BenchmarkHarness.require_isolated_test_db!()

if Enum.any?(Application.started_applications(), fn {app, _desc, _vsn} -> app == :store end) do
  raise """
  benchmark_server.exs expects standalone startup.
  Run with: STORE_TEST_DB_SUFFIX=bench PORT=4000 MIX_ENV=test mix run --no-start --no-halt priv/perf/benchmark_server.exs
  """
end

BenchmarkHarness.ensure_port_available!()
BenchmarkHarness.configure_repos!()
BenchmarkHarness.configure_endpoint!()

{:ok, _} = Application.ensure_all_started(:store)
{:ok, poller} = ProductDetailPoller.start_link()
Process.unlink(poller)
:ok = BenchmarkHarness.wait_for_endpoint!()

BenchmarkHarness.print_runbook("tmp/perf/product_detail_poller.ndjson")
