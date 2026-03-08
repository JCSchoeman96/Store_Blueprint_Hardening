if Mix.env() != :test do
  raise "product_detail_poller_summary.exs must be run with MIX_ENV=test"
end

Code.ensure_loaded!(Store.Perf.BenchmarkHarness)
summary = Store.Perf.BenchmarkHarness.run_poller_summary!()

IO.puts(
  "Wrote product detail poller summary to #{Store.Perf.BenchmarkHarness.product_detail_poller_summary_path()}"
)

IO.puts(Jason.encode!(summary, pretty: true))
