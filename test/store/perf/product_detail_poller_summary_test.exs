defmodule Store.Perf.ProductDetailPollerSummaryTest do
  use ExUnit.Case, async: true

  alias Store.Perf.ProductDetailPollerSummary

  test "summarizes static vs live join payload and query deltas" do
    input_path = Path.join(System.tmp_dir!(), "product_detail_poller_summary_test.ndjson")
    output_path = Path.join(System.tmp_dir!(), "product_detail_poller_summary_test.json")

    on_exit(fn ->
      File.rm(input_path)
      File.rm(output_path)
    end)

    rows = [
      %{
        "captured_at" => "2026-03-08T10:00:00Z",
        "scheduler" => %{"run_queue" => 2, "memory_total" => 4096},
        "postgres_activity" => %{"active_backends" => 3, "lock_waiters" => 1},
        "shop_live" => [
          %{
            "key" => ["static_render", false, "ok"],
            "count" => 2,
            "averages" => %{
              "duration" => 2_000_000,
              "reductions_delta" => 1000,
              "memory_delta" => 2048
            },
            "maxes" => %{},
            "metadata" => %{},
            "metadata_values" => %{"payload_hash" => ["hash-static"]}
          },
          %{
            "key" => ["live_join", true, "ok"],
            "count" => 2,
            "averages" => %{
              "duration" => 3_000_000,
              "reductions_delta" => 2000,
              "memory_delta" => 4096
            },
            "maxes" => %{},
            "metadata" => %{},
            "metadata_values" => %{"payload_hash" => ["hash-live"]}
          }
        ],
        "catalog" => [
          %{
            "key" => ["ok"],
            "count" => 2,
            "averages" => %{
              "query_count" => 1,
              "query_time" => 1_500_000,
              "encoded_payload_bytes" => 512
            },
            "maxes" => %{},
            "metadata" => %{},
            "metadata_values" => %{"payload_hash" => ["hash-static", "hash-live"]}
          }
        ]
      }
    ]

    File.write!(input_path, Enum.map_join(rows, "\n", &Jason.encode!/1))

    summary = ProductDetailPollerSummary.run(input_path: input_path, output_path: output_path)

    assert summary.static_render.count == 2
    assert summary.live_join.count == 2
    assert summary.catalog.count == 2
    assert summary.scheduler.averages["run_queue"] == 2.0
    assert summary.postgres_activity.averages["lock_waiters"] == 1.0
    assert summary.shop_show_under_contention.count == 4
    assert summary.static_vs_live.query_count_delta == 0.0
    assert summary.static_vs_live.payload_hash_match? == false
    assert summary.static_vs_live.static_payload_hashes == ["hash-static"]
    assert summary.static_vs_live.live_payload_hashes == ["hash-live"]
    assert File.exists?(output_path)
  end
end
