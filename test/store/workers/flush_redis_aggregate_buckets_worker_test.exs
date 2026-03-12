defmodule Store.Workers.FlushRedisAggregateBucketsWorkerTest do
  use Store.DataCase, async: false

  import Ecto.Query

  alias Store.Operations.AggregateBucket
  alias Store.Support.Redis
  alias Store.Support.Telemetry.RedisAggregates
  alias Store.Workers.FlushRedisAggregateBucketsWorker

  setup do
    assert :ok = Redis.flush_db()
    Store.DirectRepo.delete_all(AggregateBucket)
    :ok
  end

  test "flush persists closed buckets and deletes flushed redis keys" do
    now = DateTime.utc_now()

    stale_bucket_id =
      now
      |> DateTime.add(-RedisAggregates.bucket_seconds(), :second)
      |> RedisAggregates.current_bucket_id()

    assert :ok =
             Redis.hash_incr_by(
               "metrics:counter_buckets:#{stale_bucket_id}:store.catalog.product_list",
               "cache=hit|layer=hot|result=ok",
               3,
               3600
             )

    assert :ok =
             Redis.hash_incr_by(
               "metrics:duration_buckets:#{stale_bucket_id}:store.catalog.product_list",
               "cache=hit|layer=hot|result=ok",
               1250,
               3600
             )

    assert :ok =
             Redis.pfadd(
               "metrics:unique_buckets:#{stale_bucket_id}:catalog_product_list",
               ["catalog-a", "catalog-b"],
               3600
             )

    assert {:ok, %{bucket_count: 1, row_count: 3}} = FlushRedisAggregateBucketsWorker.flush(now)

    rows =
      AggregateBucket
      |> order_by([row], asc: row.metric_kind)
      |> Store.DirectRepo.all()

    assert Enum.map(rows, & &1.metric_kind) == ["count", "duration_sum", "unique_count"]
    assert Enum.map(rows, & &1.value) == [3, 1250, 2]

    assert {:ok, remaining_counter_keys} = Redis.scan_prefix("metrics:counter_buckets:")
    refute Enum.any?(remaining_counter_keys, &String.contains?(&1, stale_bucket_id))

    assert {:ok, remaining_duration_keys} = Redis.scan_prefix("metrics:duration_buckets:")
    refute Enum.any?(remaining_duration_keys, &String.contains?(&1, stale_bucket_id))

    assert {:ok, remaining_unique_keys} = Redis.scan_prefix("metrics:unique_buckets:")
    refute Enum.any?(remaining_unique_keys, &String.contains?(&1, stale_bucket_id))
  end
end
