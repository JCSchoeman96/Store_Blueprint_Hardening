defmodule Store.Catalog.VariantResolver do
  @moduledoc """
  Deterministic product option -> sellable variant resolver.
  """

  alias Store.Catalog.{
    Product,
    ProductDetailProjection,
    ProductOption,
    Variant
  }

  alias Store.Catalog.Types.ProductDetail

  alias Store.Catalog.Types.ProductDetail.{
    AvailabilityCell,
    AvailabilityValue,
    Option,
    OptionValue,
    Resolution
  }

  alias Store.Support.Errors.Error

  @type outcome ::
          {:ok, Variant.t()}
          | {:error, :invalid_selection}
          | {:error, :selection_ambiguous}
          | {:error, :out_of_stock}
          | {:error, Error.t()}

  @spec resolve_for_shop(Product.t(), %{optional(String.t()) => String.t()}) :: outcome()
  def resolve_for_shop(%Product{} = product, selection_by_option_slug)
      when is_map(selection_by_option_slug) do
    with {:ok, payload} <- ProductDetailProjection.fetch(product),
         :ok <- ensure_product_published(payload, product),
         {:ok, normalized_selection} <-
           normalize_slug_selection(payload, selection_by_option_slug),
         :ok <- ensure_required_selections(payload, normalized_selection) do
      resolve_normalized_selection(payload, normalized_selection)
    end
  end

  def resolve_for_shop(_product, _selection_by_option_slug),
    do: {:error, Error.new("VALIDATION_ERROR", "product and selection map are required")}

  @spec build_product_detail(Product.t(), %{optional(String.t()) => String.t()}) ::
          {:ok, ProductDetail.t()} | {:error, Error.t()}
  def build_product_detail(%Product{} = product, selection_by_option_slug)
      when is_map(selection_by_option_slug) do
    case ProductDetailProjection.fetch(product) do
      {:ok, payload} -> build_product_detail(product, payload, selection_by_option_slug)
      {:error, _} = error -> error
    end
  end

  def build_product_detail(_product, _selection_by_option_slug),
    do: {:error, Error.new("VALIDATION_ERROR", "product and selection map are required")}

  @spec build_product_detail(Product.t(), map(), %{optional(String.t()) => String.t()}) ::
          {:ok, ProductDetail.t()} | {:error, Error.t()}
  def build_product_detail(%Product{} = product, payload, selection_by_option_slug)
      when is_map(payload) and is_map(selection_by_option_slug) do
    with :ok <- ensure_product_published(payload, product),
         {:ok, normalized_selection} <-
           normalize_slug_selection(payload, selection_by_option_slug) do
      resolution = build_resolution(payload, normalized_selection)

      {:ok,
       %ProductDetail{
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

  defp build_resolution(payload, normalized_selection) do
    case ensure_required_selections(payload, normalized_selection) do
      :ok -> resolve_normalized_selection(payload, normalized_selection)
      {:error, _reason} -> {:error, :invalid_selection}
    end
  end

  defp resolve_normalized_selection(payload, normalized_selection) do
    if payload.options == [] do
      resolve_no_options_default(payload)
    else
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
  end

  defp resolve_no_options_default(%{
         variant_rows: variant_rows,
         default_variant_id: default_variant_id
       }) do
    case Enum.find(variant_rows, fn row -> row.variant.id == default_variant_id end) do
      %{sellable?: true, in_stock?: true, variant: variant} ->
        {:ok, variant}

      %{sellable?: true, in_stock?: false} ->
        {:error, :out_of_stock}

      _ ->
        {:error, :invalid_selection}
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

  defp ensure_product_published(payload) do
    if payload[:published?], do: :ok, else: {:error, :invalid_selection}
  end

  defp ensure_product_published(payload, %Product{} = product) do
    payload
    |> Map.put(:published?, published?(product))
    |> ensure_product_published()
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

      %Option{
        id: option.id,
        slug: option.slug,
        name: option.name,
        position: option.position,
        selection_required: option.selection_required,
        values:
          Enum.map(values, fn value ->
            %OptionValue{
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

          %AvailabilityValue{
            value_id: value.id,
            value_slug: value.slug,
            selectable: candidates != [],
            in_stock: Enum.any?(candidates, & &1.in_stock?)
          }
        end)

      %AvailabilityCell{
        option_id: option.id,
        option_slug: option.slug,
        selected_value_id: Map.get(normalized_selection, option.id),
        values: value_states
      }
    end)
  end

  defp resolution_payload({:ok, %Variant{} = variant}) do
    %Resolution{status: :ok, variant_id: variant.id, variant: variant, reason: nil}
  end

  defp resolution_payload({:error, reason})
       when reason in [:invalid_selection, :selection_ambiguous, :out_of_stock] do
    %Resolution{status: :error, variant_id: nil, variant: nil, reason: reason}
  end

  defp resolution_payload(_),
    do: %Resolution{status: :error, variant_id: nil, variant: nil, reason: :invalid_selection}

  defp published?(%Product{} = product),
    do: product.status == :published and not is_nil(product.published_at)

  defp normalize_slug(value) do
    value = value |> to_string() |> String.trim()

    if Regex.match?(~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/, value) do
      {:ok, value}
    else
      {:error, :invalid_selection}
    end
  end
end
