defmodule Store.Support.Telemetry.RedisAggregates do
  @moduledoc """
  Async telemetry sink for high-velocity counters, event windows, queue helpers, and
  minute-bucketed durable aggregates in Redis.
  """

  use GenServer

  alias Store.Support.Redis

  @bucket_seconds 60
  @counter_ttl_seconds 172_800
  @window_ttl_seconds 3_600
  @unique_ttl_seconds 172_800
  @handler_id "#{__MODULE__}"
  @events [
    [:store, :catalog, :product_list],
    [:store, :catalog, :product_detail],
    [:store, :shipping, :quote],
    [:store, :payments, :webhook_received],
    [:store, :payments, :webhook_enqueued],
    [:store, :payments, :webhook_processed],
    [:store, :payments, :refund_webhook_processed],
    [:store, :payments, :interlock_apply_payment_success_once],
    [:store, :comms, :outbox_insert],
    [:store, :comms, :delivery_attempt],
    [:store, :digital, :grant_issued],
    [:store, :digital, :signed_url],
    [:store, :subscriptions, :tick],
    [:store, :subscriptions, :renewal_attempt],
    [:store, :subscriptions, :dunning]
  ]
  @unique_metrics %{
    "catalog_product_list" => "store.catalog.product_list",
    "shipping_quote" => "store.shipping.quote",
    "webhook_events" => "store.payments.webhook_received"
  }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec bucket_seconds() :: pos_integer()
  def bucket_seconds, do: @bucket_seconds

  @spec current_bucket_id(DateTime.t()) :: String.t()
  def current_bucket_id(now \\ DateTime.utc_now()) when is_struct(now, DateTime) do
    now
    |> DateTime.to_unix(:second)
    |> div(@bucket_seconds)
    |> Integer.to_string()
  end

  @spec bucket_start(String.t()) :: {:ok, DateTime.t()} | {:error, term()}
  def bucket_start(bucket_id) when is_binary(bucket_id) do
    with {bucket_int, ""} <- Integer.parse(bucket_id),
         seconds when seconds >= 0 <- bucket_int * @bucket_seconds,
         {:ok, datetime} <- DateTime.from_unix(seconds, :second) do
      {:ok, %{datetime | microsecond: {0, 6}}}
    else
      _ -> {:error, :invalid_bucket_id}
    end
  end

  @spec parse_bucket_key(String.t()) ::
          {:ok,
           %{
             kind: :count | :duration_sum | :unique_count,
             bucket_id: String.t(),
             event_name: String.t()
           }}
          | :ignore
  def parse_bucket_key(relative_key) when is_binary(relative_key) do
    cond do
      match =
          Regex.named_captures(
            ~r/^metrics:counter_buckets:(?<bucket>\d+):(?<event>.+)$/,
            relative_key
          ) ->
        {:ok, %{kind: :count, bucket_id: match["bucket"], event_name: match["event"]}}

      match =
          Regex.named_captures(
            ~r/^metrics:duration_buckets:(?<bucket>\d+):(?<event>.+)$/,
            relative_key
          ) ->
        {:ok, %{kind: :duration_sum, bucket_id: match["bucket"], event_name: match["event"]}}

      match =
          Regex.named_captures(
            ~r/^metrics:unique_buckets:(?<bucket>\d+):(?<metric>.+)$/,
            relative_key
          ) ->
        case Map.fetch(@unique_metrics, match["metric"]) do
          {:ok, event_name} ->
            {:ok, %{kind: :unique_count, bucket_id: match["bucket"], event_name: event_name}}

          :error ->
            :ignore
        end

      true ->
        :ignore
    end
  end

  @impl true
  def init(_opts) do
    :ok = attach_handlers()
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:telemetry, event, measurements, metadata}, state) do
    _ = write_aggregate(event, measurements, metadata)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :telemetry.detach(@handler_id)
    :ok
  end

  def handle_event(event, measurements, metadata, _config) do
    if Process.whereis(__MODULE__) do
      GenServer.cast(__MODULE__, {:telemetry, event, measurements, metadata})
    end
  end

  defp attach_handlers do
    case :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, nil) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  defp write_aggregate(event, measurements, metadata) do
    event_name = Enum.map_join(event, ".", &Atom.to_string/1)
    bucket_id = current_bucket_id()
    counter_key = "metrics:counter_buckets:#{bucket_id}:#{event_name}"
    duration_key = "metrics:duration_buckets:#{bucket_id}:#{event_name}"
    window_key = "metrics:window:#{event_name}"

    member_prefix =
      Map.get(metadata, :provider_event_id) || Map.get(metadata, :receipt_id) ||
        Map.get(metadata, :outbox_id) || Map.get(metadata, :order_id) || event_name

    _ =
      Redis.hash_incr_by(
        counter_key,
        dimension_field(event_name, metadata),
        1,
        @counter_ttl_seconds
      )

    score = System.system_time(:millisecond)
    member = Redis.window_member(member_prefix, System.unique_integer([:positive]))
    _ = Redis.zadd_with_ttl(window_key, score, member, @window_ttl_seconds)

    write_unique(bucket_id, event_name, metadata)
    write_queue_helpers(event, score, metadata)
    write_duration_counter(duration_key, event_name, measurements, metadata)
    :ok
  rescue
    _error -> :ok
  end

  defp write_unique(bucket_id, "store.catalog.product_list", metadata) do
    maybe_track_unique(
      "metrics:unique_buckets:#{bucket_id}:catalog_product_list",
      Map.get(metadata, :cache_key)
    )
  end

  defp write_unique(bucket_id, "store.shipping.quote", metadata) do
    maybe_track_unique(
      "metrics:unique_buckets:#{bucket_id}:shipping_quote",
      Map.get(metadata, :request_key)
    )
  end

  defp write_unique(bucket_id, "store.payments.webhook_received", metadata) do
    maybe_track_unique(
      "metrics:unique_buckets:#{bucket_id}:webhook_events",
      Map.get(metadata, :provider_event_id)
    )
  end

  defp write_unique(_bucket_id, _event_name, _metadata), do: :ok

  defp maybe_track_unique(_relative_key, nil), do: :ok

  defp maybe_track_unique(relative_key, value) do
    Redis.pfadd(relative_key, [to_string(value)], @unique_ttl_seconds)
  end

  defp write_queue_helpers([:store, :payments, :webhook_received], score, metadata) do
    with receipt_id when is_binary(receipt_id) <- Map.get(metadata, :receipt_id) do
      Redis.zadd_with_ttl("queues:webhook:pending", score, receipt_id, @counter_ttl_seconds)
    end
  end

  defp write_queue_helpers([:store, :payments, :webhook_processed], _score, metadata) do
    with receipt_id when is_binary(receipt_id) <- Map.get(metadata, :receipt_id) do
      Redis.zrem("queues:webhook:pending", receipt_id)
    end
  end

  defp write_queue_helpers([:store, :payments, :refund_webhook_processed], _score, metadata) do
    with receipt_id when is_binary(receipt_id) <- Map.get(metadata, :receipt_id) do
      Redis.zrem("queues:webhook:pending", receipt_id)
    end
  end

  defp write_queue_helpers([:store, :comms, :outbox_insert], score, metadata) do
    with outbox_id when is_binary(outbox_id) <- Map.get(metadata, :outbox_id) do
      Redis.zadd_with_ttl("queues:outbox:pending", score, outbox_id, @counter_ttl_seconds)
    end
  end

  defp write_queue_helpers([:store, :comms, :delivery_attempt], _score, metadata) do
    with outbox_id when is_binary(outbox_id) <- Map.get(metadata, :outbox_id),
         outcome when outcome in [:sent, :permanent_error] <- Map.get(metadata, :outcome) do
      Redis.zrem("queues:outbox:pending", outbox_id)
    else
      _ -> :ok
    end
  end

  defp write_queue_helpers(_event, _score, _metadata), do: :ok

  defp write_duration_counter(duration_key, event_name, measurements, metadata) do
    duration = Map.get(measurements, :duration)

    if is_integer(duration) and duration >= 0 do
      micros = System.convert_time_unit(duration, :native, :microsecond)

      Redis.hash_incr_by(
        duration_key,
        dimension_field(event_name, metadata),
        micros,
        @counter_ttl_seconds
      )
    else
      :ok
    end
  end

  defp dimension_field(event_name, metadata) do
    dimensions = dimensions_for_event(event_name, metadata)

    if map_size(dimensions) == 0 do
      "total"
    else
      dimensions
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map_join("|", fn {key, value} -> "#{key}=#{value}" end)
    end
  end

  defp dimensions_for_event("store.catalog.product_list", metadata),
    do: Map.take(metadata, [:cache, :layer, :result])

  defp dimensions_for_event("store.catalog.product_detail", metadata),
    do: Map.take(metadata, [:cache, :result])

  defp dimensions_for_event("store.shipping.quote", metadata),
    do: Map.take(metadata, [:cache, :layer, :result])

  defp dimensions_for_event("store.payments.webhook_received", metadata),
    do: Map.take(metadata, [:provider, :event_type, :verified])

  defp dimensions_for_event("store.payments.webhook_enqueued", metadata),
    do: Map.take(metadata, [:provider, :event_type, :result])

  defp dimensions_for_event("store.payments.webhook_processed", metadata),
    do: Map.take(metadata, [:provider, :outcome])

  defp dimensions_for_event("store.payments.refund_webhook_processed", metadata),
    do: Map.take(metadata, [:provider, :outcome])

  defp dimensions_for_event("store.payments.interlock_apply_payment_success_once", metadata),
    do: Map.take(metadata, [:replay])

  defp dimensions_for_event("store.comms.outbox_insert", metadata),
    do: Map.take(metadata, [:kind, :provider])

  defp dimensions_for_event("store.comms.delivery_attempt", metadata),
    do: Map.take(metadata, [:provider, :template, :outcome])

  defp dimensions_for_event("store.digital.grant_issued", metadata),
    do: Map.take(metadata, [:asset_id, :order_id])

  defp dimensions_for_event("store.digital.signed_url", metadata),
    do: Map.take(metadata, [:outcome])

  defp dimensions_for_event("store.subscriptions.tick", metadata),
    do: Map.take(metadata, [:due_count])

  defp dimensions_for_event("store.subscriptions.renewal_attempt", metadata),
    do: Map.take(metadata, [:outcome])

  defp dimensions_for_event("store.subscriptions.dunning", metadata),
    do: Map.take(metadata, [:status, :attempt_no])

  defp dimensions_for_event(_event_name, _metadata), do: %{}
end
