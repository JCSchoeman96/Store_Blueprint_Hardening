defmodule Store.Perf.ProductDetailPollerSummary do
  @moduledoc false

  @default_input "tmp/perf/product_detail_poller.ndjson"
  @default_output "tmp/perf/product_detail_poller_summary.json"

  def run(opts \\ []) do
    input_path = Keyword.get(opts, :input_path, @default_input)
    output_path = Keyword.get(opts, :output_path, @default_output)
    mode = Keyword.get(opts, :mode, :default)

    summary =
      input_path
      |> File.stream!([], :line)
      |> Enum.map(&Jason.decode!/1)
      |> build_summary(opts, mode)

    File.mkdir_p!(Path.dirname(output_path))
    File.write!(output_path, Jason.encode_to_iodata!(summary, pretty: true))
    summary
  end

  defp build_summary(snapshots, opts, mode) do
    static_rows = collect_shop_live_rows(snapshots, ["static_render", false, "ok"])
    live_rows = collect_shop_live_rows(snapshots, ["live_join", true, "ok"])
    catalog_rows = collect_catalog_rows(snapshots, ["ok"])
    scheduler = aggregate_snapshot_maps(snapshots, "scheduler")
    postgres_activity = aggregate_snapshot_maps(snapshots, "postgres_activity")

    pending_provider_setup_backlog =
      aggregate_snapshot_maps(snapshots, "pending_provider_setup_backlog")

    static = aggregate_rows(static_rows)
    live = aggregate_rows(live_rows)
    catalog = aggregate_rows(catalog_rows)

    summary = %{
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      source_snapshots: length(snapshots),
      static_render: static,
      live_join: live,
      catalog: catalog,
      scheduler: scheduler,
      postgres_activity: postgres_activity,
      pending_provider_setup_backlog: pending_provider_setup_backlog,
      shop_show_under_contention: aggregate_rows(static_rows ++ live_rows),
      static_vs_live: compare_phase(static, live)
    }

    case mode do
      :durability -> Map.put(summary, :durability, durability_summary(snapshots, opts))
      _ -> summary
    end
  end

  defp collect_shop_live_rows(snapshots, key) do
    snapshots
    |> Enum.flat_map(&Map.get(&1, "shop_live", []))
    |> Enum.filter(&(Map.get(&1, "key") == key))
  end

  defp collect_catalog_rows(snapshots, key) do
    snapshots
    |> Enum.flat_map(&Map.get(&1, "catalog", []))
    |> Enum.filter(&(Map.get(&1, "key") == key))
  end

  defp aggregate_rows([]) do
    %{
      count: 0,
      averages: %{},
      maxes: %{},
      payload_hashes: [],
      unique_payload_hash_count: 0
    }
  end

  defp aggregate_rows(rows) do
    count = Enum.sum(Enum.map(rows, &Map.get(&1, "count", 0)))

    averages =
      rows
      |> Enum.flat_map(&Map.to_list(Map.get(&1, "averages", %{})))
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.into(%{}, fn {key, values} -> {key, average(values)} end)

    maxes =
      rows
      |> Enum.flat_map(&Map.to_list(Map.get(&1, "maxes", %{})))
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.into(%{}, fn {key, values} -> {key, Enum.max(values)} end)

    payload_hashes =
      rows
      |> Enum.flat_map(fn row ->
        row
        |> get_in(["metadata_values", "payload_hash"])
        |> List.wrap()
        |> Enum.reject(&(&1 in [nil, "nil", ""]))
      end)
      |> Enum.uniq()
      |> Enum.sort()

    %{
      count: count,
      averages: averages,
      maxes: maxes,
      payload_hashes: payload_hashes,
      unique_payload_hash_count: length(payload_hashes)
    }
  end

  defp aggregate_snapshot_maps(snapshots, key) do
    maps =
      snapshots
      |> Enum.map(&Map.get(&1, key, %{}))
      |> Enum.filter(&is_map/1)

    count = length(maps)

    averages =
      maps
      |> Enum.flat_map(&Map.to_list/1)
      |> Enum.filter(fn {_key, value} -> is_number(value) end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.into(%{}, fn {metric, values} -> {metric, average(values)} end)

    maxes =
      maps
      |> Enum.flat_map(&Map.to_list/1)
      |> Enum.filter(fn {_key, value} -> is_number(value) end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.into(%{}, fn {metric, values} -> {metric, Enum.max(values)} end)

    %{
      count: count,
      averages: averages,
      maxes: maxes
    }
  end

  defp compare_phase(static, live) do
    static_avg = Map.get(static, :averages, %{})
    live_avg = Map.get(live, :averages, %{})
    static_hashes = Map.get(static, :payload_hashes, [])
    live_hashes = Map.get(live, :payload_hashes, [])

    %{
      query_count_delta: delta(live_avg["query_count"], static_avg["query_count"]),
      payload_bytes_delta:
        delta(live_avg["encoded_payload_bytes"], static_avg["encoded_payload_bytes"]),
      reductions_delta: delta(live_avg["reductions_delta"], static_avg["reductions_delta"]),
      memory_delta: delta(live_avg["memory_delta"], static_avg["memory_delta"]),
      payload_hash_match?: static_hashes == live_hashes and static_hashes != [],
      static_payload_hashes: static_hashes,
      live_payload_hashes: live_hashes
    }
  end

  defp durability_summary(snapshots, opts) do
    measure_start_at = parse_datetime!(Keyword.fetch!(opts, :measure_start_at))
    measure_end_at = parse_datetime!(Keyword.fetch!(opts, :measure_end_at))
    cooldown_end_at = parse_datetime!(Keyword.fetch!(opts, :cooldown_end_at))
    measure_ms = Keyword.get(opts, :measure_ms)
    cooldown_ms = Keyword.get(opts, :cooldown_ms)

    timed_snapshots =
      snapshots
      |> Enum.map(fn snapshot ->
        captured_at = parse_datetime!(Map.fetch!(snapshot, "captured_at"))
        Map.put(snapshot, "__captured_at", captured_at)
      end)
      |> Enum.sort_by(&Map.fetch!(&1, "__captured_at"), DateTime)

    {measure_start_at, measure_end_at, cooldown_end_at} =
      maybe_realign_windows(
        timed_snapshots,
        measure_start_at,
        measure_end_at,
        cooldown_end_at,
        measure_ms,
        cooldown_ms
      )

    measure_snapshots =
      Enum.filter(timed_snapshots, fn snapshot ->
        within_range?(snapshot["__captured_at"], measure_start_at, measure_end_at)
      end)

    cooldown_snapshots =
      Enum.filter(timed_snapshots, fn snapshot ->
        DateTime.compare(snapshot["__captured_at"], measure_end_at) != :lt and
          DateTime.compare(snapshot["__captured_at"], cooldown_end_at) != :gt
      end)

    memory_points = Enum.map(measure_snapshots, &scheduler_metric(&1, "memory_total"))
    run_queue_points = Enum.map(measure_snapshots, &scheduler_metric(&1, "run_queue"))
    active_backend_points = Enum.map(measure_snapshots, &postgres_metric(&1, "active_backends"))

    measure_windows = segmented_windows(measure_snapshots)

    shop_show_trend =
      %{
        start: aggregate_rows(collect_shop_live_window_rows(elem(measure_windows, 0))),
        mid: aggregate_rows(collect_shop_live_window_rows(elem(measure_windows, 1))),
        end: aggregate_rows(collect_shop_live_window_rows(elem(measure_windows, 2)))
      }

    memory_profile = %{
      start: first_number(memory_points),
      mid: middle_number(memory_points),
      end: last_number(memory_points),
      cooldown_end:
        last_number(Enum.map(cooldown_snapshots, &scheduler_metric(&1, "memory_total"))),
      slope_bytes_per_second: slope(memory_points, measure_start_at, measure_end_at),
      cooldown_drop_bytes:
        cooldown_drop(
          last_number(memory_points),
          last_number(Enum.map(cooldown_snapshots, &scheduler_metric(&1, "memory_total")))
        )
    }

    run_queue_profile = %{
      start: first_number(run_queue_points),
      mid: middle_number(run_queue_points),
      end: last_number(run_queue_points),
      cooldown_end: last_number(Enum.map(cooldown_snapshots, &scheduler_metric(&1, "run_queue")))
    }

    active_backend_profile = %{
      start: first_number(active_backend_points),
      mid: middle_number(active_backend_points),
      end: last_number(active_backend_points),
      cooldown_end:
        last_number(Enum.map(cooldown_snapshots, &postgres_metric(&1, "active_backends")))
    }

    lock_waiters_max =
      timed_snapshots
      |> Enum.map(&postgres_metric(&1, "lock_waiters"))
      |> Enum.reject(&is_nil/1)
      |> case do
        [] -> 0.0
        values -> Enum.max(values)
      end

    memory_status = classify_memory(memory_profile)

    %{
      timings: %{
        measure_start_at: DateTime.to_iso8601(measure_start_at),
        measure_end_at: DateTime.to_iso8601(measure_end_at),
        cooldown_end_at: DateTime.to_iso8601(cooldown_end_at)
      },
      memory_profile: memory_profile,
      memory_status: memory_status,
      run_queue_profile: run_queue_profile,
      active_backends_profile: active_backend_profile,
      lock_waiters_max: lock_waiters_max,
      shop_show_trends: %{
        query_count: metric_trend(shop_show_trend, "query_count"),
        queue_time: metric_trend(shop_show_trend, "queue_time"),
        query_time: metric_trend(shop_show_trend, "query_time")
      },
      windows: %{
        start: summarize_window(elem(measure_windows, 0)),
        mid: summarize_window(elem(measure_windows, 1)),
        end: summarize_window(elem(measure_windows, 2)),
        cooldown: summarize_window(cooldown_snapshots)
      }
    }
  end

  defp summarize_window(snapshots) do
    %{
      snapshots: length(snapshots),
      scheduler: aggregate_snapshot_maps(snapshots, "scheduler"),
      postgres_activity: aggregate_snapshot_maps(snapshots, "postgres_activity"),
      shop_show_under_contention:
        snapshots
        |> collect_shop_live_window_rows()
        |> aggregate_rows()
    }
  end

  defp collect_shop_live_window_rows(snapshots) do
    snapshots
    |> Enum.flat_map(&Map.get(&1, "shop_live", []))
    |> Enum.filter(fn row ->
      case Map.get(row, "key") do
        ["static_render", false, "ok"] -> true
        ["live_join", true, "ok"] -> true
        _ -> false
      end
    end)
  end

  defp segmented_windows([]), do: {[], [], []}

  defp segmented_windows(snapshots) do
    size = length(snapshots)
    start_count = max(div(size, 3), 1)
    end_count = start_count
    mid_start = start_count
    mid_count = max(size - start_count - end_count, 0)

    start_window = Enum.take(snapshots, start_count)
    mid_window = snapshots |> Enum.drop(mid_start) |> Enum.take(mid_count)
    end_window = Enum.take(snapshots, -end_count)

    {start_window, mid_window, end_window}
  end

  defp metric_trend(windows, metric) do
    %{
      start: get_in(windows.start, [:averages, metric]) || 0.0,
      mid: get_in(windows.mid, [:averages, metric]) || 0.0,
      end: get_in(windows.end, [:averages, metric]) || 0.0
    }
  end

  defp scheduler_metric(snapshot, metric), do: get_in(snapshot, ["scheduler", metric])
  defp postgres_metric(snapshot, metric), do: get_in(snapshot, ["postgres_activity", metric])

  defp classify_memory(profile) do
    profile
    |> memory_classification_inputs()
    |> memory_classification_result()
  end

  defp memory_classification_inputs(profile) do
    start_memory = Map.get(profile, :start, 0.0)
    end_memory = Map.get(profile, :end, 0.0)
    cooldown_drop = Map.get(profile, :cooldown_drop_bytes, 0.0)

    %{
      slope: Map.get(profile, :slope_bytes_per_second, 0.0),
      cooldown_drop: cooldown_drop,
      growth_ratio: safe_ratio(end_memory - start_memory, start_memory),
      drop_ratio: safe_ratio(cooldown_drop, end_memory)
    }
  end

  defp memory_classification_result(%{
         growth_ratio: growth_ratio,
         slope: slope,
         cooldown_drop: cooldown_drop
       })
       when growth_ratio <= 0.05 and slope <= 1_024 and cooldown_drop >= 0 do
    %{
      status: "healthy",
      reason: "Memory stayed flat or sawtoothed through the measure window."
    }
  end

  defp memory_classification_result(%{growth_ratio: growth_ratio, drop_ratio: drop_ratio})
       when growth_ratio > 0.05 and drop_ratio >= 0.10 do
    %{
      status: "temporary_heap_pressure",
      reason: "Memory rose during the measure window but dropped materially during cooldown."
    }
  end

  defp memory_classification_result(%{growth_ratio: growth_ratio}) when growth_ratio > 0.05 do
    %{
      status: "memory_leak",
      reason: "Memory rose during the measure window and did not drop materially during cooldown."
    }
  end

  defp memory_classification_result(_inputs) do
    %{
      status: "healthy",
      reason: "Memory profile remained within the acceptable durability envelope."
    }
  end

  defp safe_ratio(_numerator, denominator) when denominator <= 0, do: 0.0
  defp safe_ratio(numerator, denominator), do: numerator / denominator

  defp slope([], _start_at, _end_at), do: 0.0
  defp slope([_single], _start_at, _end_at), do: 0.0

  defp slope(points, start_at, end_at) do
    duration_seconds = max(DateTime.diff(end_at, start_at, :second), 1)
    (last_number(points) - first_number(points)) / duration_seconds
  end

  defp cooldown_drop(end_memory, cooldown_end), do: end_memory - cooldown_end

  defp first_number([]), do: 0.0
  defp first_number([value | _]), do: value * 1.0

  defp middle_number([]), do: 0.0

  defp middle_number(values) do
    values
    |> Enum.at(div(length(values), 2), 0.0)
    |> Kernel.*(1.0)
  end

  defp last_number([]), do: 0.0
  defp last_number(values), do: List.last(values) * 1.0

  defp within_range?(captured_at, start_at, end_at) do
    DateTime.compare(captured_at, start_at) != :lt and
      DateTime.compare(captured_at, end_at) != :gt
  end

  defp parse_datetime!(%DateTime{} = datetime), do: datetime

  defp parse_datetime!(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> raise ArgumentError, "invalid ISO8601 datetime: #{inspect(value)}"
    end
  end

  defp maybe_realign_windows(
         timed_snapshots,
         measure_start_at,
         measure_end_at,
         cooldown_end_at,
         measure_ms,
         cooldown_ms
       ) do
    latest_at =
      timed_snapshots
      |> List.last()
      |> case do
        nil -> nil
        snapshot -> snapshot["__captured_at"]
      end

    cond do
      is_nil(latest_at) ->
        {measure_start_at, measure_end_at, cooldown_end_at}

      DateTime.compare(latest_at, measure_end_at) != :lt ->
        {measure_start_at, measure_end_at, cooldown_end_at}

      is_integer(measure_ms) and is_integer(cooldown_ms) ->
        effective_cooldown_end = latest_at
        effective_measure_end = DateTime.add(effective_cooldown_end, -cooldown_ms, :millisecond)
        effective_measure_start = DateTime.add(effective_measure_end, -measure_ms, :millisecond)
        {effective_measure_start, effective_measure_end, effective_cooldown_end}

      true ->
        {measure_start_at, measure_end_at, cooldown_end_at}
    end
  end

  defp average([]), do: 0.0
  defp average(values), do: Enum.sum(values) / length(values)

  defp delta(nil, nil), do: 0.0
  defp delta(left, nil) when is_number(left), do: left * 1.0
  defp delta(nil, right) when is_number(right), do: -right * 1.0
  defp delta(left, right), do: left - right
end
