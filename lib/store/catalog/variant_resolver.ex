defmodule Store.Catalog.VariantResolver do
  @moduledoc """
  Deterministic product option -> sellable variant resolver.
  """

  import Ecto.Query

  alias Store.Catalog.{
    AvailabilityCache,
    InventoryItem,
    Product,
    ProductOption,
    ProductOptionValue,
    Variant,
    VariantOptionSelection
  }

  alias Store.Repo
  alias Store.Support.Errors.Error
  alias Store.Support.ID.BinaryUuidSort

  @type outcome ::
          {:ok, Variant.t()}
          | {:error, :invalid_selection}
          | {:error, :selection_ambiguous}
          | {:error, :out_of_stock}
          | {:error, Error.t()}

  @spec resolve_for_shop(Product.t(), %{optional(String.t()) => String.t()}) :: outcome()
  def resolve_for_shop(%Product{} = product, selection_by_option_slug)
      when is_map(selection_by_option_slug) do
    with {:ok, payload} <- availability_payload(product.id),
         :ok <- ensure_product_published(payload),
         {:ok, normalized_selection} <-
           normalize_slug_selection(payload, selection_by_option_slug),
         :ok <- ensure_required_selections(payload, normalized_selection) do
      resolve_normalized_selection(payload, normalized_selection)
    end
  end

  def resolve_for_shop(_product, _selection_by_option_slug),
    do: {:error, Error.new("VALIDATION_ERROR", "product and selection map are required")}

  @spec build_product_detail(Product.t(), %{optional(String.t()) => String.t()}) ::
          {:ok, map()} | {:error, Error.t()}
  def build_product_detail(%Product{} = product, selection_by_option_slug)
      when is_map(selection_by_option_slug) do
    with {:ok, payload} <- availability_payload(product.id),
         {:ok, normalized_selection} <-
           normalize_slug_selection(payload, selection_by_option_slug) do
      resolution =
        with :ok <- ensure_product_published(payload),
             :ok <- ensure_required_selections(payload, normalized_selection) do
          resolve_normalized_selection(payload, normalized_selection)
        else
          {:error, _reason} ->
            {:error, :invalid_selection}
        end

      {:ok,
       %{
         product: product,
         options: option_payload(payload),
         selected: normalized_selection,
         resolution: resolution_payload(resolution),
         availability_matrix: availability_matrix(payload, normalized_selection)
       }}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, _reason} -> {:error, Error.new("VALIDATION_ERROR", "invalid product detail query")}
    end
  end

  def build_product_detail(_product, _selection_by_option_slug),
    do: {:error, Error.new("VALIDATION_ERROR", "product and selection map are required")}

  @spec availability_payload(Ecto.UUID.t()) :: {:ok, map()} | {:error, Error.t()}
  def availability_payload(product_id) when is_binary(product_id) do
    AvailabilityCache.fetch(product_id, fn ->
      case Repo.get(Product, product_id) do
        nil -> {:error, Error.new("NOT_FOUND", "product not found")}
        product -> {:ok, build_payload(product)}
      end
    end)
    |> normalize_cache_result()
  end

  def availability_payload(_product_id),
    do: {:error, Error.new("VALIDATION_ERROR", "product_id must be a UUID string")}

  defp build_payload(%Product{} = product) do
    options = canonical_sort_options(load_options(product.id))
    option_ids = Enum.map(options, & &1.id)

    values_by_option_id = load_values_by_option_id(option_ids)

    variants =
      Variant
      |> where([variant], variant.product_id == ^product.id and variant.status == :active)
      |> Repo.all()

    variant_ids = Enum.map(variants, & &1.id)

    selections_by_variant_id = load_selections_by_variant_id(variant_ids)
    inventory_by_variant_id = load_inventory_by_variant_id(variant_ids)

    required_option_ids =
      options
      |> Enum.filter(& &1.selection_required)
      |> Enum.map(& &1.id)

    variant_rows =
      Enum.map(variants, fn variant ->
        selection_map = Map.get(selections_by_variant_id, variant.id, %{})

        required_complete? = required_complete?(required_option_ids, selection_map)

        %{
          variant: variant,
          selection_by_option_id: selection_map,
          required_complete?: required_complete?,
          sellable?: published?(product) and required_complete?,
          in_stock?: variant_in_stock?(inventory_by_variant_id, variant.id)
        }
      end)

    option_lookup = Map.new(options, &{&1.slug, &1})
    option_slug_by_id = Map.new(options, &{&1.id, &1.slug})

    value_lookup =
      Enum.reduce(values_by_option_id, %{}, fn {option_id, values}, acc ->
        add_value_lookup_entries(acc, Map.get(option_slug_by_id, option_id), values)
      end)

    %{
      product: product,
      options: options,
      values_by_option_id: values_by_option_id,
      required_option_ids: required_option_ids,
      option_lookup: option_lookup,
      value_lookup: value_lookup,
      variant_rows: variant_rows
    }
  end

  defp load_options(product_id) do
    ProductOption
    |> where([option], option.product_id == ^product_id)
    |> Repo.all()
  end

  defp add_value_lookup_entries(acc, option_slug, values) when is_binary(option_slug) do
    Enum.reduce(values, acc, fn value, value_acc ->
      Map.put(value_acc, {option_slug, value.slug}, value.id)
    end)
  end

  defp add_value_lookup_entries(acc, _option_slug, _values), do: acc

  defp load_values_by_option_id([]), do: %{}

  defp load_values_by_option_id(option_ids) do
    ProductOptionValue
    |> where([value], value.product_option_id in ^option_ids)
    |> Repo.all()
    |> Enum.group_by(& &1.product_option_id)
    |> Map.new(fn {option_id, values} -> {option_id, canonical_sort_values(values)} end)
  end

  defp load_selections_by_variant_id([]), do: %{}

  defp load_selections_by_variant_id(variant_ids) do
    VariantOptionSelection
    |> where([selection], selection.variant_id in ^variant_ids)
    |> Repo.all()
    |> Enum.group_by(& &1.variant_id)
    |> Map.new(fn {variant_id, selections} ->
      pair_map =
        Map.new(selections, fn selection ->
          {selection.product_option_id, selection.product_option_value_id}
        end)

      {variant_id, pair_map}
    end)
  end

  defp load_inventory_by_variant_id([]), do: %{}

  defp load_inventory_by_variant_id(variant_ids) do
    InventoryItem
    |> where([inventory], inventory.variant_id in ^variant_ids)
    |> Repo.all()
    |> Map.new(&{&1.variant_id, &1})
  end

  defp resolve_normalized_selection(payload, normalized_selection) do
    matching_rows = matching_rows(payload.variant_rows, normalized_selection)

    case matching_rows do
      [] ->
        {:error, :invalid_selection}

      [%{in_stock?: true, variant: variant}] ->
        {:ok, variant}

      [%{in_stock?: false}] ->
        {:error, :out_of_stock}

      [_ | _] ->
        {:error, :selection_ambiguous}
    end
  end

  defp matching_rows(variant_rows, normalized_selection) do
    Enum.filter(variant_rows, fn row ->
      row.sellable? and selection_matches?(row.selection_by_option_id, normalized_selection)
    end)
  end

  defp selection_matches?(variant_selection, normalized_selection) do
    Enum.all?(normalized_selection, fn {option_id, value_id} ->
      Map.get(variant_selection, option_id) == value_id
    end)
  end

  defp ensure_product_published(%{product: %Product{} = product}) do
    if published?(product), do: :ok, else: {:error, :invalid_selection}
  end

  defp normalize_slug_selection(payload, selection_by_option_slug) do
    selection_by_option_slug
    |> Enum.reduce_while({:ok, %{}}, fn {option_slug, value_slug}, {:ok, acc} ->
      with {:ok, option_slug} <- normalize_slug(option_slug),
           {:ok, value_slug} <- normalize_slug(value_slug),
           %ProductOption{id: option_id} <- Map.get(payload.option_lookup, option_slug),
           value_id when is_binary(value_id) <-
             Map.get(payload.value_lookup, {option_slug, value_slug}) do
        {:cont, {:ok, Map.put(acc, option_id, value_id)}}
      else
        _ -> {:halt, {:error, :invalid_selection}}
      end
    end)
  end

  defp ensure_required_selections(payload, normalized_selection) do
    missing_required =
      payload.required_option_ids
      |> Enum.reject(&Map.has_key?(normalized_selection, &1))

    if missing_required == [], do: :ok, else: {:error, :invalid_selection}
  end

  defp option_payload(payload) do
    Enum.map(payload.options, fn option ->
      values = Map.get(payload.values_by_option_id, option.id, [])

      %{
        id: option.id,
        slug: option.slug,
        name: option.name,
        position: option.position,
        selection_required: option.selection_required,
        values:
          Enum.map(values, fn value ->
            %{
              id: value.id,
              slug: value.slug,
              name: value.name,
              position: value.position
            }
          end)
      }
    end)
  end

  defp availability_matrix(payload, normalized_selection) do
    Enum.map(payload.options, fn option ->
      values = Map.get(payload.values_by_option_id, option.id, [])

      value_states =
        Enum.map(values, fn value ->
          candidate_selection = Map.put(normalized_selection, option.id, value.id)
          candidates = matching_rows(payload.variant_rows, candidate_selection)

          %{
            value_id: value.id,
            value_slug: value.slug,
            selectable: candidates != [],
            in_stock: Enum.any?(candidates, & &1.in_stock?)
          }
        end)

      %{
        option_id: option.id,
        option_slug: option.slug,
        selected_value_id: Map.get(normalized_selection, option.id),
        values: value_states
      }
    end)
  end

  defp resolution_payload({:ok, %Variant{} = variant}) do
    %{status: :ok, variant_id: variant.id, variant: variant, reason: nil}
  end

  defp resolution_payload({:error, reason})
       when reason in [:invalid_selection, :selection_ambiguous, :out_of_stock] do
    %{status: :error, variant_id: nil, variant: nil, reason: reason}
  end

  defp resolution_payload(_),
    do: %{status: :error, variant_id: nil, variant: nil, reason: :invalid_selection}

  defp published?(%Product{} = product),
    do: product.status == :published and not is_nil(product.published_at)

  defp required_complete?(required_option_ids, selection_map) do
    Enum.all?(required_option_ids, &Map.has_key?(selection_map, &1))
  end

  defp variant_in_stock?(inventory_by_variant_id, variant_id) do
    case Map.get(inventory_by_variant_id, variant_id) do
      %InventoryItem{allow_oversell: true} ->
        true

      %InventoryItem{} = inventory ->
        inventory.stock_on_hand - inventory.reserved_count > 0

      _ ->
        false
    end
  end

  defp canonical_sort_options(options) do
    Enum.sort_by(options, fn option ->
      {option.position || 0, BinaryUuidSort.normalize_raw16!(option.id)}
    end)
  end

  defp canonical_sort_values(values) do
    Enum.sort_by(values, fn value ->
      {value.position || 0, BinaryUuidSort.normalize_raw16!(value.id)}
    end)
  end

  defp normalize_slug(value) do
    value = value |> to_string() |> String.trim()

    if Regex.match?(~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/, value) do
      {:ok, value}
    else
      {:error, :invalid_selection}
    end
  end

  defp normalize_cache_result({:ok, payload}), do: {:ok, payload}
  defp normalize_cache_result({:error, %Error{} = error}), do: {:error, error}

  defp normalize_cache_result({:error, _reason}),
    do: {:error, Error.new("INTERNAL_ERROR", "availability cache failed")}
end
