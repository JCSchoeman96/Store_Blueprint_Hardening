defmodule Store.Catalog.ProductDetailProjection do
  @moduledoc false

  import Ecto.Query

  alias Store.Catalog.{
    AvailabilityCache,
    InventoryItem,
    Product,
    ProductImage,
    ProductOption,
    ProductOptionValue,
    Variant,
    VariantOptionSelection
  }

  alias Store.Repo
  alias Store.Support.Errors.Error
  alias Store.Support.ID.BinaryUuidSort

  @type payload :: %{
          options: [ProductOption.t()],
          values_by_option_id: %{optional(String.t()) => [ProductOptionValue.t()]},
          required_option_ids: [String.t()],
          option_lookup: %{optional(String.t()) => ProductOption.t()},
          value_lookup: %{optional({String.t(), String.t()}) => String.t()},
          variant_rows: [map()],
          default_variant_id: String.t() | nil,
          published?: boolean()
        }

  @spec fetch(Product.t()) :: {:ok, payload()} | {:error, Error.t()}
  def fetch(%Product{id: product_id} = product) when is_binary(product_id) do
    AvailabilityCache.fetch(product_id, fn -> {:ok, build_payload(product_id)} end)
    |> normalize_cache_result()
    |> case do
      {:ok, payload} ->
        {:ok,
         Map.merge(payload, %{
           default_variant_id: product.default_variant_id,
           published?: product.status == :published and not is_nil(product.published_at)
         })}

      {:error, _} = error ->
        error
    end
  end

  def fetch(_product), do: {:error, Error.new("VALIDATION_ERROR", "product is required")}

  @spec load_public_product(String.t()) :: {:ok, Product.t() | nil} | {:error, Error.t()}
  def load_public_product(slug) when is_binary(slug) do
    rows =
      from(product in Product,
        where:
          product.slug == ^slug and product.status == :published and
            not is_nil(product.published_at),
        left_join: default_variant in Variant,
        on:
          default_variant.id == product.default_variant_id and default_variant.status == :active,
        left_join: image in ProductImage,
        on: image.product_id == product.id,
        order_by: [asc: image.position, asc: image.id],
        select: {product, default_variant, image}
      )
      |> Repo.all()

    {:ok, hydrate_product(rows)}
  rescue
    _error -> {:error, Error.new("INTERNAL_ERROR", "unable to load public product detail")}
  end

  def load_public_product(_slug),
    do: {:error, Error.new("VALIDATION_ERROR", "slug must be a string")}

  defp hydrate_product([]), do: nil

  defp hydrate_product([{product, default_variant, _image} | _] = rows) do
    images =
      rows
      |> Enum.map(fn {_product, _default_variant, image} -> image end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(& &1.id)

    product
    |> Map.put(:default_variant, default_variant)
    |> Map.put(:images, images)
  end

  defp build_payload(product_id) do
    options = load_options(product_id)
    values_by_option_id = load_values_by_option_id(Enum.map(options, & &1.id))
    variant_rows = load_variant_rows(product_id, options)

    option_lookup = Map.new(options, &{&1.slug, &1})
    required_option_ids = options |> Enum.filter(& &1.selection_required) |> Enum.map(& &1.id)
    option_slug_by_id = Map.new(options, &{&1.id, &1.slug})

    %{
      options: options,
      values_by_option_id: values_by_option_id,
      required_option_ids: required_option_ids,
      option_lookup: option_lookup,
      value_lookup: build_value_lookup(values_by_option_id, option_slug_by_id),
      variant_rows: variant_rows
    }
  end

  defp build_value_lookup(values_by_option_id, option_slug_by_id) do
    Enum.reduce(values_by_option_id, %{}, fn {option_id, values}, acc ->
      append_option_values(acc, Map.get(option_slug_by_id, option_id), values)
    end)
  end

  defp append_option_values(acc, option_slug, values) when is_binary(option_slug) do
    Enum.reduce(values, acc, fn value, value_acc ->
      Map.put(value_acc, {option_slug, value.slug}, value.id)
    end)
  end

  defp append_option_values(acc, _option_slug, _values), do: acc

  defp load_options(product_id) do
    ProductOption
    |> where([option], option.product_id == ^product_id)
    |> order_by([option], asc: option.position, asc: option.id)
    |> Repo.all()
  end

  defp load_values_by_option_id([]), do: %{}

  defp load_values_by_option_id(option_ids) do
    ProductOptionValue
    |> where([value], value.product_option_id in ^option_ids)
    |> order_by([value], asc: value.position, asc: value.id)
    |> Repo.all()
    |> Enum.group_by(& &1.product_option_id)
    |> Map.new()
  end

  defp load_variant_rows(product_id, options) do
    required_option_ids =
      options
      |> Enum.filter(& &1.selection_required)
      |> Enum.map(& &1.id)

    from(variant in Variant,
      where: variant.product_id == ^product_id and variant.status == :active,
      left_join: inventory in InventoryItem,
      on: inventory.variant_id == variant.id,
      left_join: selection in VariantOptionSelection,
      on: selection.variant_id == variant.id,
      order_by: [asc: variant.inserted_at, asc: variant.id],
      select: %{
        variant: variant,
        inventory: inventory,
        selection_option_id: selection.product_option_id,
        selection_value_id: selection.product_option_value_id
      }
    )
    |> Repo.all()
    |> Enum.group_by(& &1.variant.id)
    |> Enum.map(&build_variant_row(&1, required_option_ids))
    |> Enum.sort_by(fn %{variant: variant} ->
      {variant.inserted_at, BinaryUuidSort.normalize_raw16!(variant.id)}
    end)
  end

  defp build_variant_row({_variant_id, rows}, required_option_ids) do
    %{variant: variant, inventory: inventory} = hd(rows)
    selection_map = selection_map(rows)
    required_complete? = Enum.all?(required_option_ids, &Map.has_key?(selection_map, &1))

    %{
      variant: variant,
      selection_by_option_id: selection_map,
      required_complete?: required_complete?,
      sellable?: required_complete?,
      in_stock?: variant_in_stock?(inventory)
    }
  end

  defp selection_map(rows) do
    Enum.reduce(rows, %{}, fn row, acc ->
      if is_binary(row.selection_option_id) and is_binary(row.selection_value_id) do
        Map.put(acc, row.selection_option_id, row.selection_value_id)
      else
        acc
      end
    end)
  end

  defp variant_in_stock?(%InventoryItem{allow_oversell: true}), do: true

  defp variant_in_stock?(%InventoryItem{} = inventory) do
    inventory.stock_on_hand - inventory.reserved_count > 0
  end

  defp variant_in_stock?(_inventory), do: false

  defp normalize_cache_result({:ok, payload}), do: {:ok, payload}
  defp normalize_cache_result({:error, %Error{} = error}), do: {:error, error}

  defp normalize_cache_result({:error, _reason}),
    do: {:error, Error.new("INTERNAL_ERROR", "availability cache failed")}
end
