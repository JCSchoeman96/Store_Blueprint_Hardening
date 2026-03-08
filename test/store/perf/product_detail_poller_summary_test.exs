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

  test "summarizes durability trends and memory classification" do
    input_path = Path.join(System.tmp_dir!(), "product_detail_poller_durability_test.ndjson")
    output_path = Path.join(System.tmp_dir!(), "product_detail_poller_durability_test.json")

    on_exit(fn ->
      File.rm(input_path)
      File.rm(output_path)
    end)

    rows =
      [
        {"2026-03-08T10:00:00Z", 1_000, 1, 3, 0, 1_000_000, 2_000_000},
        {"2026-03-08T10:05:00Z", 2_000, 1, 4, 0, 2_000_000, 3_000_000},
        {"2026-03-08T10:10:00Z", 1_100, 1, 2, 0, 1_500_000, 2_500_000}
      ]
      |> Enum.map(fn {captured_at, memory_total, run_queue, active_backends, lock_waiters,
                      queue_time, query_time} ->
        %{
          "captured_at" => captured_at,
          "scheduler" => %{"run_queue" => run_queue, "memory_total" => memory_total},
          "postgres_activity" => %{
            "active_backends" => active_backends,
            "lock_waiters" => lock_waiters
          },
          "shop_live" => [
            %{
              "key" => ["static_render", false, "ok"],
              "count" => 1,
              "averages" => %{
                "query_count" => 1,
                "queue_time" => queue_time,
                "query_time" => query_time,
                "duration" => 4_000_000
              },
              "maxes" => %{},
              "metadata" => %{},
              "metadata_values" => %{"payload_hash" => ["same-hash"]}
            }
          ],
          "catalog" => []
        }
      end)

    File.write!(input_path, Enum.map_join(rows, "\n", &Jason.encode!/1))

    summary =
      ProductDetailPollerSummary.run(
        input_path: input_path,
        output_path: output_path,
        mode: :durability,
        measure_start_at: "2026-03-08T10:00:00Z",
        measure_end_at: "2026-03-08T10:05:00Z",
        cooldown_end_at: "2026-03-08T10:10:00Z"
      )

    assert summary.durability.memory_status.status == "temporary_heap_pressure"
    assert summary.durability.lock_waiters_max == 0
    assert summary.durability.shop_show_trends.query_count.start == 1.0
    assert summary.durability.shop_show_trends.queue_time.end == 2_000_000.0
    assert summary.durability.windows.cooldown.snapshots == 2
    assert File.exists?(output_path)
  end
end
