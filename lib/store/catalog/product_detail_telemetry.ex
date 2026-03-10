defmodule Store.Catalog.ProductDetailTelemetry do
  @moduledoc false

  alias Store.Catalog.Types.ProductDetail
  alias Store.Perf.ProductDetailPoller
  alias Store.Support.Errors.Normalize
  alias Store.Support.Governance.Idempotency

  @shop_live_event [:store, :shop_live, :product_detail]
  @catalog_event [:store, :catalog, :product_detail, :public]
  @catalog_compat_event [:store, :catalog, :product_detail]

  @type process_snapshot :: %{reductions: non_neg_integer(), memory: non_neg_integer()}

  @spec process_snapshot() :: process_snapshot()
  def process_snapshot do
    %{
      reductions: process_info_value(:reductions),
      memory: process_info_value(:memory)
    }
  end

  @spec emit_shop_live(integer(), map(), term(), map(), process_snapshot(), process_snapshot()) ::
          :ok
  def emit_shop_live(started_at, attrs, result, repo_stats, before_snapshot, after_snapshot)
      when is_integer(started_at) and is_map(attrs) and is_map(before_snapshot) and
             is_map(after_snapshot) do
    measurements = %{
      duration: System.monotonic_time() - started_at,
      query_count: Map.get(repo_stats, :query_count, 0),
      queue_time: Map.get(repo_stats, :queue_time, 0),
      query_time: Map.get(repo_stats, :query_time, 0),
      decode_time: Map.get(repo_stats, :decode_time, 0),
      reductions_delta:
        max(Map.get(after_snapshot, :reductions, 0) - Map.get(before_snapshot, :reductions, 0), 0),
      memory_delta: Map.get(after_snapshot, :memory, 0) - Map.get(before_snapshot, :memory, 0)
    }

    metadata = %{
      slug: Map.get(attrs, :slug),
      selection_count: Map.get(attrs, :selection_count, 0),
      phase: Map.get(attrs, :phase),
      connected?: Map.get(attrs, :connected?, false),
      connected: if(Map.get(attrs, :connected?, false), do: "connected", else: "disconnected"),
      result: telemetry_result(result),
      error_code: telemetry_error_code(result) || "NONE",
      payload_hash: telemetry_payload_hash(result)
    }

    :telemetry.execute(
      @shop_live_event,
      measurements,
      metadata
    )

    ProductDetailPoller.record(:shop_live, measurements, metadata)
  end

  @spec emit_catalog_public_detail(
          integer(),
          String.t() | nil,
          non_neg_integer(),
          term(),
          map(),
          map() | nil
        ) :: :ok
  def emit_catalog_public_detail(
        started_at,
        slug,
        selection_count,
        result,
        repo_stats,
        payload_metrics
      )
      when is_integer(started_at) and is_integer(selection_count) and is_map(repo_stats) do
    measurements =
      Map.merge(
        %{
          duration: System.monotonic_time() - started_at,
          query_count: Map.get(repo_stats, :query_count, 0),
          queue_time: Map.get(repo_stats, :queue_time, 0),
          query_time: Map.get(repo_stats, :query_time, 0),
          decode_time: Map.get(repo_stats, :decode_time, 0)
        },
        payload_metrics || empty_payload_metrics()
      )

    metadata = %{
      slug: slug,
      selection_count: selection_count,
      result: telemetry_result(result),
      error_code: telemetry_error_code(result) || "NONE",
      payload_hash: telemetry_payload_hash(result)
    }

    :telemetry.execute(
      @catalog_event,
      measurements,
      metadata
    )

    :telemetry.execute(
      @catalog_compat_event,
      %{duration: measurements.duration},
      %{
        slug: slug,
        cache: "miss",
        result: metadata.result,
        payload_hash: metadata.payload_hash
      }
    )

    ProductDetailPoller.record(:catalog, measurements, metadata)
  end

  @spec payload_metrics(ProductDetail.t(), map()) :: map()
  def payload_metrics(%ProductDetail{} = detail, payload) when is_map(payload) do
    %{
      encoded_payload_bytes: encoded_payload_bytes(detail),
      option_count: length(detail.options),
      option_value_count: Enum.sum(Enum.map(detail.options, &length(&1.values))),
      variant_row_count: length(Map.get(payload, :variant_rows, [])),
      availability_cell_count: length(detail.availability_matrix),
      availability_value_count:
        Enum.sum(Enum.map(detail.availability_matrix, &length(Map.get(&1, :values, []))))
    }
  end

  def payload_metrics(_detail, _payload), do: empty_payload_metrics()

  @spec telemetry_result(term()) :: atom()
  def telemetry_result({:ok, _value}), do: :ok
  def telemetry_result({:error, _error}), do: :error
  def telemetry_result(_), do: :error

  @spec telemetry_error_code(term()) :: String.t() | nil
  def telemetry_error_code({:error, error}) do
    error
    |> Normalize.normalize()
    |> Map.get(:code, "INTERNAL_ERROR")
  end

  def telemetry_error_code(_result), do: nil

  @spec telemetry_payload_hash(term()) :: String.t() | nil
  def telemetry_payload_hash({:ok, %ProductDetail{} = detail}) do
    detail
    |> payload_export()
    |> Idempotency.payload_hash()
  end

  def telemetry_payload_hash(_result), do: nil

  defp empty_payload_metrics do
    %{
      encoded_payload_bytes: 0,
      option_count: 0,
      option_value_count: 0,
      variant_row_count: 0,
      availability_cell_count: 0,
      availability_value_count: 0
    }
  end

  defp encoded_payload_bytes(%ProductDetail{} = detail) do
    detail
    |> payload_export()
    |> Jason.encode!()
    |> byte_size()
  end

  defp payload_export(%ProductDetail{} = detail) do
    %{
      product: %{
        id: detail.product.id,
        slug: detail.product.slug,
        title: detail.product.title,
        subtitle: detail.product.subtitle,
        description: detail.product.description,
        default_variant_id: detail.product.default_variant_id,
        image_count: length(detail.product.images || [])
      },
      options:
        Enum.map(detail.options, fn option ->
          %{
            id: option.id,
            slug: option.slug,
            name: option.name,
            position: option.position,
            selection_required: option.selection_required,
            values:
              Enum.map(option.values, fn value ->
                %{id: value.id, slug: value.slug, name: value.name, position: value.position}
              end)
          }
        end),
      selected: detail.selected,
      resolution: %{
        status: detail.resolution.status,
        variant_id: detail.resolution.variant_id,
        reason: detail.resolution.reason,
        variant:
          case detail.resolution.variant do
            nil ->
              nil

            variant ->
              %{
                id: variant.id,
                sku: variant.sku,
                price_minor: variant.price_minor,
                currency_code: variant.currency_code,
                image_id: variant.image_id
              }
          end
      },
      availability_matrix:
        Enum.map(detail.availability_matrix, fn cell ->
          %{
            option_id: cell.option_id,
            option_slug: cell.option_slug,
            selected_value_id: cell.selected_value_id,
            values:
              Enum.map(cell.values, fn value ->
                %{
                  value_id: value.value_id,
                  value_slug: value.value_slug,
                  selectable: value.selectable,
                  in_stock: value.in_stock
                }
              end)
          }
        end)
    }
  end

  defp process_info_value(key) do
    case :erlang.process_info(self(), key) do
      {^key, value} when is_integer(value) -> value
      _ -> 0
    end
  end
end
