defmodule Store.Perf.ProductDetailPollerSummary do
  @moduledoc false

  @default_input "tmp/perf/product_detail_poller.ndjson"
  @default_output "tmp/perf/product_detail_poller_summary.json"

  def run(opts \\ []) do
    input_path = Keyword.get(opts, :input_path, @default_input)
    output_path = Keyword.get(opts, :output_path, @default_output)

    summary =
      input_path
      |> File.stream!([], :line)
      |> Enum.map(&Jason.decode!/1)
      |> build_summary()

    File.mkdir_p!(Path.dirname(output_path))
    File.write!(output_path, Jason.encode_to_iodata!(summary, pretty: true))
    summary
  end

  defp build_summary(snapshots) do
    static_rows = collect_shop_live_rows(snapshots, ["static_render", false, "ok"])
    live_rows = collect_shop_live_rows(snapshots, ["live_join", true, "ok"])
    catalog_rows = collect_catalog_rows(snapshots, ["ok"])
    scheduler = aggregate_snapshot_maps(snapshots, "scheduler")
    postgres_activity = aggregate_snapshot_maps(snapshots, "postgres_activity")

    static = aggregate_rows(static_rows)
    live = aggregate_rows(live_rows)
    catalog = aggregate_rows(catalog_rows)

    %{
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      source_snapshots: length(snapshots),
      static_render: static,
      live_join: live,
      catalog: catalog,
      scheduler: scheduler,
      postgres_activity: postgres_activity,
      shop_show_under_contention: aggregate_rows(static_rows ++ live_rows),
      static_vs_live: compare_phase(static, live)
    }
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

  defp average([]), do: 0.0
  defp average(values), do: Enum.sum(values) / length(values)

  defp delta(nil, nil), do: 0.0
  defp delta(left, nil) when is_number(left), do: left * 1.0
  defp delta(nil, right) when is_number(right), do: -right * 1.0
  defp delta(left, right), do: left - right
end
