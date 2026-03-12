defmodule Store.Workers.FlushRedisAggregateBucketsWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :ops,
    max_attempts: 10,
    unique: [period: 55, fields: [:worker, :queue]]

  alias Store.Operations.AggregateBucket
  alias Store.Support.Redis
  alias Store.Support.Telemetry.RedisAggregates

  @metric_prefixes [
    "metrics:counter_buckets:",
    "metrics:duration_buckets:",
    "metrics:unique_buckets:"
  ]

  @spec flush(DateTime.t()) ::
          {:ok, %{bucket_count: non_neg_integer(), row_count: non_neg_integer()}}
          | {:error, term()}
  def flush(now \\ DateTime.utc_now()) when is_struct(now, DateTime) do
    started_at = System.monotonic_time()

    result =
      with {:ok, bucket_ids} <- closed_bucket_ids(now),
           {:ok, row_count} <- flush_bucket_rows(bucket_ids) do
        {:ok, %{bucket_count: length(bucket_ids), row_count: row_count}}
      end

    emit_telemetry(result, started_at)
    result
  end

  @impl Oban.Worker
  def perform(_job) do
    case flush(DateTime.utc_now()) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp closed_bucket_ids(now) do
    {current_bucket_int, ""} = now |> RedisAggregates.current_bucket_id() |> Integer.parse()

    with {:ok, keys} <- scan_metric_keys() do
      bucket_ids =
        keys
        |> Enum.reduce(MapSet.new(), &collect_closed_bucket_id(&1, &2, current_bucket_int))
        |> MapSet.to_list()
        |> Enum.sort()

      {:ok, bucket_ids}
    end
  end

  defp collect_closed_bucket_id(relative_key, acc, current_bucket_int) do
    case RedisAggregates.parse_bucket_key(relative_key) do
      {:ok, %{bucket_id: bucket_id}} ->
        maybe_put_closed_bucket(acc, bucket_id, current_bucket_int)

      _ ->
        acc
    end
  end

  defp maybe_put_closed_bucket(acc, bucket_id, current_bucket_int) do
    case Integer.parse(bucket_id) do
      {bucket_int, ""} when bucket_int < current_bucket_int -> MapSet.put(acc, bucket_id)
      _ -> acc
    end
  end

  defp scan_metric_keys do
    @metric_prefixes
    |> Enum.reduce_while({:ok, []}, fn prefix, {:ok, acc} ->
      case Redis.scan_prefix(prefix) do
        {:ok, keys} -> {:cont, {:ok, keys ++ acc}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp flush_bucket_rows([]), do: {:ok, 0}

  defp flush_bucket_rows(bucket_ids) do
    with {:ok, rows, keys_to_delete} <- collect_rows(bucket_ids),
         {:ok, row_count} <- upsert_rows(rows),
         :ok <- Redis.delete_many(keys_to_delete) do
      {:ok, row_count}
    end
  end

  defp collect_rows(bucket_ids) do
    allowed = MapSet.new(bucket_ids)

    @metric_prefixes
    |> Enum.reduce_while({:ok, [], []}, &scan_prefix_rows(&1, &2, allowed))
  end

  defp scan_prefix_rows(prefix, {:ok, rows_acc, delete_acc}, allowed) do
    with {:ok, keys} <- Redis.scan_prefix(prefix),
         {:ok, rows, deletions} <- collect_rows_for_keys(keys, allowed) do
      {:cont, {:ok, rows ++ rows_acc, deletions ++ delete_acc}}
    else
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp collect_rows_for_keys(keys, allowed_bucket_ids) do
    Enum.reduce_while(keys, {:ok, [], []}, &collect_key_rows(&1, &2, allowed_bucket_ids))
  end

  defp collect_key_rows(relative_key, {:ok, rows_acc, delete_acc}, allowed_bucket_ids) do
    case RedisAggregates.parse_bucket_key(relative_key) do
      {:ok, %{bucket_id: bucket_id}} = parsed ->
        collect_allowed_key_rows(
          relative_key,
          parsed,
          bucket_id,
          allowed_bucket_ids,
          rows_acc,
          delete_acc
        )

      _ ->
        {:cont, {:ok, rows_acc, delete_acc}}
    end
  end

  defp collect_allowed_key_rows(
         relative_key,
         parsed,
         bucket_id,
         allowed_bucket_ids,
         rows_acc,
         delete_acc
       ) do
    if MapSet.member?(allowed_bucket_ids, bucket_id) do
      case rows_for_key(relative_key, parsed) do
        {:ok, rows} -> {:cont, {:ok, rows ++ rows_acc, [relative_key | delete_acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    else
      {:cont, {:ok, rows_acc, delete_acc}}
    end
  end

  defp rows_for_key(
         relative_key,
         {:ok, %{kind: :count, bucket_id: bucket_id, event_name: event_name}}
       ) do
    hash_rows_for_key(relative_key, bucket_id, event_name, "count")
  end

  defp rows_for_key(
         relative_key,
         {:ok, %{kind: :duration_sum, bucket_id: bucket_id, event_name: event_name}}
       ) do
    hash_rows_for_key(relative_key, bucket_id, event_name, "duration_sum")
  end

  defp rows_for_key(
         relative_key,
         {:ok, %{kind: :unique_count, bucket_id: bucket_id, event_name: event_name}}
       ) do
    with {:ok, bucket_start} <- RedisAggregates.bucket_start(bucket_id),
         {:ok, unique_count} <- Redis.pfcount(relative_key) do
      {:ok,
       [
         %{
           id: Ecto.UUID.generate(),
           bucket_start: bucket_start,
           bucket_width_seconds: RedisAggregates.bucket_seconds(),
           event_name: event_name,
           metric_kind: "unique_count",
           dimension: "total",
           value: unique_count,
           inserted_at: DateTime.utc_now(),
           updated_at: DateTime.utc_now()
         }
       ]}
    end
  end

  defp hash_rows_for_key(relative_key, bucket_id, event_name, metric_kind) do
    with {:ok, bucket_start} <- RedisAggregates.bucket_start(bucket_id),
         {:ok, values} <- Redis.hash_get_all(relative_key) do
      now = DateTime.utc_now()

      rows = Enum.map(values, &build_hash_row(&1, bucket_start, event_name, metric_kind, now))

      {:ok, rows}
    end
  end

  defp build_hash_row({dimension, value}, bucket_start, event_name, metric_kind, now) do
    %{
      id: Ecto.UUID.generate(),
      bucket_start: bucket_start,
      bucket_width_seconds: RedisAggregates.bucket_seconds(),
      event_name: event_name,
      metric_kind: metric_kind,
      dimension: dimension,
      value: parse_integer_value(value),
      inserted_at: now,
      updated_at: now
    }
  end

  defp parse_integer_value(value) do
    case Integer.parse(value) do
      {integer_value, ""} -> integer_value
      _ -> 0
    end
  end

  defp upsert_rows([]), do: {:ok, 0}

  defp upsert_rows(rows) do
    case Store.DirectRepo.insert_all(
           AggregateBucket,
           rows,
           conflict_target: [
             :bucket_start,
             :bucket_width_seconds,
             :event_name,
             :metric_kind,
             :dimension
           ],
           on_conflict: {:replace, [:value, :updated_at]}
         ) do
      {count, _rows} -> {:ok, count}
    end
  rescue
    error -> {:error, error}
  end

  defp emit_telemetry({:ok, result}, started_at) do
    :telemetry.execute(
      [:store, :ops, :redis_aggregate_flush],
      %{
        duration: System.monotonic_time() - started_at,
        bucket_count: result.bucket_count,
        row_count: result.row_count
      },
      %{result: :ok}
    )
  end

  defp emit_telemetry({:error, _reason}, started_at) do
    :telemetry.execute(
      [:store, :ops, :redis_aggregate_flush],
      %{duration: System.monotonic_time() - started_at, bucket_count: 0, row_count: 0},
      %{result: :error}
    )
  end
end
