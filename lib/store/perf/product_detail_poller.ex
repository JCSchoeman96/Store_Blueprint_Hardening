defmodule Store.Perf.ProductDetailPoller do
  @moduledoc false

  use GenServer
  require Logger

  alias Store.DirectRepo

  @tick_ms 1_000

  def record(kind, measurements, metadata) when kind in [:shop_live, :catalog] do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:record, kind, measurements, metadata})
    end
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    File.mkdir_p!(Path.dirname(log_path(opts)))
    File.write!(log_path(opts), "")

    state = %{
      log_path: log_path(opts),
      shop_live: %{},
      catalog: %{}
    }

    schedule_tick()
    {:ok, state}
  end

  @impl true
  def handle_cast({:record, :shop_live, measurements, metadata}, state) do
    key = {metadata.phase, metadata.connected?, metadata.result}

    {:noreply,
     put_in(state, [:shop_live, key], merge_window(state.shop_live[key], measurements, metadata))}
  end

  def handle_cast({:record, :catalog, measurements, metadata}, state) do
    key = {metadata.result}

    {:noreply,
     put_in(state, [:catalog, key], merge_window(state.catalog[key], measurements, metadata))}
  end

  @impl true
  def handle_info(:tick, state) do
    scheduler = scheduler_sample()
    postgres_activity = postgres_activity_sample()

    pending_provider_setup_backlog =
      Store.Orders.pending_provider_setup_backlog_snapshot(
        DateTime.utc_now(),
        source: :perf_poller
      )

    snapshot = %{
      captured_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      shop_live: serialize_windows(state.shop_live),
      catalog: serialize_windows(state.catalog),
      scheduler: scheduler,
      postgres_activity: postgres_activity,
      pending_provider_setup_backlog: pending_provider_setup_backlog
    }

    print_snapshot(snapshot)
    File.write!(state.log_path, Jason.encode_to_iodata!(snapshot) ++ "\n", [:append])

    schedule_tick()
    {:noreply, %{state | shop_live: %{}, catalog: %{}}}
  end

  @impl true
  def terminate(_reason, _state), do: :ok

  defp log_path(opts) do
    Keyword.get(opts, :log_path, "tmp/perf/product_detail_poller.ndjson")
  end

  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_ms)

  defp merge_window(nil, measurements, metadata) do
    %{
      count: 1,
      metadata: metadata,
      metadata_values: metadata_values(metadata),
      sums: normalize_numbers(measurements),
      maxes: normalize_numbers(measurements)
    }
  end

  defp merge_window(window, measurements, metadata) do
    values = normalize_numbers(measurements)

    %{
      count: window.count + 1,
      metadata: window.metadata,
      metadata_values: merge_metadata_values(window.metadata_values, metadata),
      sums: Map.merge(window.sums, values, fn _key, left, right -> left + right end),
      maxes: Map.merge(window.maxes, values, fn _key, left, right -> max(left, right) end)
    }
  end

  defp normalize_numbers(measurements) do
    Enum.reduce(measurements, %{}, fn {key, value}, acc ->
      if is_integer(value) or is_float(value) do
        Map.put(acc, key, value)
      else
        acc
      end
    end)
  end

  defp serialize_windows(windows) do
    Enum.map(windows, fn {key, window} ->
      %{
        key: Tuple.to_list(key),
        count: window.count,
        averages: average_map(window.sums, window.count),
        maxes: window.maxes,
        metadata: window.metadata,
        metadata_values: serialize_metadata_values(window.metadata_values)
      }
    end)
  end

  defp serialize_metadata_values(values) do
    Enum.into(values, %{}, fn {key, value_set} ->
      {key, value_set |> MapSet.to_list() |> Enum.sort()}
    end)
  end

  defp average_map(values, count) do
    Enum.into(values, %{}, fn {key, value} -> {key, value / max(count, 1)} end)
  end

  defp metadata_values(metadata) do
    metadata
    |> Enum.reduce(%{}, fn
      {key, value}, acc
      when is_binary(value) or is_atom(value) or is_boolean(value) or is_nil(value) ->
        Map.put(acc, key, MapSet.new([normalize_metadata_value(value)]))

      _entry, acc ->
        acc
    end)
  end

  defp merge_metadata_values(left, right) do
    Enum.reduce(right, left, fn
      {key, value}, acc
      when is_binary(value) or is_atom(value) or is_boolean(value) or is_nil(value) ->
        Map.update(
          acc,
          key,
          MapSet.new([normalize_metadata_value(value)]),
          &MapSet.put(&1, normalize_metadata_value(value))
        )

      _entry, acc ->
        acc
    end)
  end

  defp normalize_metadata_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_metadata_value(value) when is_boolean(value), do: to_string(value)
  defp normalize_metadata_value(nil), do: "nil"
  defp normalize_metadata_value(value), do: value

  defp print_snapshot(snapshot) do
    Enum.each(snapshot.shop_live, fn row ->
      [phase, connected?, result] = row.key

      Logger.info(
        "[poller][shop_live] phase=#{phase} connected?=#{connected?} result=#{result} count=#{row.count} " <>
          "avg_ms=#{fmt_ms(row.averages.duration)} max_ms=#{fmt_ms(row.maxes.duration)} " <>
          "avg_reductions=#{fmt_number(row.averages.reductions_delta)} avg_mem=#{fmt_bytes(row.averages.memory_delta)}"
      )
    end)

    Enum.each(snapshot.catalog, fn row ->
      [result] = row.key

      Logger.info(
        "[poller][catalog] result=#{result} count=#{row.count} avg_ms=#{fmt_ms(row.averages.duration)} " <>
          "avg_queries=#{fmt_number(row.averages.query_count)} avg_queue_ms=#{fmt_ms(row.averages.queue_time)} " <>
          "avg_query_ms=#{fmt_ms(row.averages.query_time)} avg_decode_ms=#{fmt_ms(row.averages.decode_time)} " <>
          "avg_payload=#{fmt_bytes(row.averages.encoded_payload_bytes)} avg_options=#{fmt_number(row.averages.option_count)} " <>
          "avg_values=#{fmt_number(row.averages.option_value_count)} avg_variants=#{fmt_number(row.averages.variant_row_count)} " <>
          "avg_cells=#{fmt_number(row.averages.availability_cell_count)} avg_cell_values=#{fmt_number(row.averages.availability_value_count)}"
      )
    end)

    Logger.info(
      "[poller][scheduler] run_queue=#{fmt_number(snapshot.scheduler.run_queue)} total_mem=#{fmt_bytes(snapshot.scheduler.memory_total)}"
    )

    Logger.info(
      "[poller][postgres] active_backends=#{fmt_number(snapshot.postgres_activity.active_backends)} " <>
        "lock_waiters=#{fmt_number(snapshot.postgres_activity.lock_waiters)}"
    )

    Logger.info(
      "[poller][pending_provider_setup] count=#{fmt_number(snapshot.pending_provider_setup_backlog.count)} " <>
        "oldest_age_s=#{fmt_number(snapshot.pending_provider_setup_backlog.oldest_age_seconds)} " <>
        "reserved_variants=#{fmt_number(snapshot.pending_provider_setup_backlog.reserved_variant_count)}"
    )
  end

  defp scheduler_sample do
    %{
      run_queue: :erlang.statistics(:run_queue),
      memory_total: :erlang.memory(:total)
    }
  end

  defp postgres_activity_sample do
    sql = """
    SELECT
      COUNT(*) FILTER (WHERE state = 'active')::bigint AS active_backends,
      COUNT(*) FILTER (WHERE state = 'active' AND wait_event_type = 'Lock')::bigint AS lock_waiters
    FROM pg_stat_activity
    WHERE datname = current_database()
      AND backend_type = 'client backend'
      AND pid <> pg_backend_pid()
    """

    case DirectRepo.query(sql, []) do
      {:ok, %{rows: [[active_backends, lock_waiters]]}} ->
        %{
          active_backends: active_backends,
          lock_waiters: lock_waiters
        }

      {:error, reason} ->
        Logger.warning("[poller][postgres] failed to sample pg_stat_activity: #{inspect(reason)}")
        %{active_backends: 0, lock_waiters: 0}
    end
  rescue
    error ->
      Logger.warning("[poller][postgres] sampling raised: #{inspect(error)}")
      %{active_backends: 0, lock_waiters: 0}
  end

  defp fmt_ms(nil), do: "0.00"

  defp fmt_ms(value) do
    native_per_ms = System.convert_time_unit(1, :millisecond, :native)

    :io_lib.format("~.2f", [value / native_per_ms])
    |> IO.iodata_to_binary()
  end

  defp fmt_bytes(nil), do: "0"
  defp fmt_bytes(value), do: value |> round() |> Integer.to_string()

  defp fmt_number(nil), do: "0"
  defp fmt_number(value) when is_integer(value), do: fmt_number(value * 1.0)

  defp fmt_number(value) when is_float(value) do
    :io_lib.format("~.2f", [value]) |> IO.iodata_to_binary()
  end
end
