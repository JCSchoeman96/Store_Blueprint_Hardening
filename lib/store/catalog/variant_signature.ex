defmodule Store.Catalog.VariantSignature do
  @moduledoc """
  Deterministic variant selection signature service.
  """

  import Ecto.Query

  alias Store.Catalog.{
    AvailabilityCache,
    ProductOption,
    StockFastPath,
    Variant,
    VariantOptionSelection
  }

  alias Store.Repo
  alias Store.Support.Errors.Error
  alias Store.Support.ID.BinaryUuidSort

  @type signature :: binary()

  @spec sync_variant_signature(Ecto.UUID.t()) :: :ok | {:error, Error.t()}
  def sync_variant_signature(variant_id) when is_binary(variant_id) do
    case Repo.get(Variant, variant_id) do
      nil ->
        {:error, Error.new("NOT_FOUND", "variant not found")}

      %Variant{} = variant ->
        ordered_options = ordered_options_for_product(variant.product_id)
        selections = selections_for_variant(variant.id)

        case build_signature(ordered_options, selections) do
          {:ok, signature} ->
            persist_signature(variant, signature)

          {:incomplete_required, _missing_option_ids} ->
            handle_incomplete_required(variant)
        end
    end
  end

  def sync_variant_signature(_variant_id),
    do: {:error, Error.new("VALIDATION_ERROR", "variant_id must be a UUID string")}

  @spec build_signature([map()], [VariantOptionSelection.t()]) ::
          {:ok, signature()} | {:incomplete_required, [Ecto.UUID.t()]}
  def build_signature(product_options, selections)
      when is_list(product_options) and is_list(selections) do
    ordered_options = canonical_sort_options(product_options)

    selections_by_option_id =
      Map.new(selections, fn selection ->
        {selection.product_option_id, selection.product_option_value_id}
      end)

    {missing_required, signature_parts} =
      Enum.reduce(ordered_options, {[], []}, fn option, {missing, parts} ->
        selection_value_id = Map.get(selections_by_option_id, option.id)

        cond do
          is_binary(selection_value_id) ->
            pair =
              [
                BinaryUuidSort.normalize_raw16!(option.id),
                BinaryUuidSort.normalize_raw16!(selection_value_id)
              ]

            {missing, [pair | parts]}

          option.selection_required ->
            {[option.id | missing], parts}

          true ->
            {missing, parts}
        end
      end)

    case Enum.reverse(missing_required) do
      [] -> {:ok, signature_parts |> Enum.reverse() |> IO.iodata_to_binary()}
      missing -> {:incomplete_required, missing}
    end
  end

  def build_signature(_product_options, _selections), do: {:incomplete_required, []}

  @spec ordered_options_for_product(Ecto.UUID.t()) :: [ProductOption.t()]
  def ordered_options_for_product(product_id) when is_binary(product_id) do
    ProductOption
    |> where([option], option.product_id == ^product_id)
    |> Repo.all()
    |> canonical_sort_options()
  end

  def ordered_options_for_product(_product_id), do: []

  defp canonical_sort_options(options) do
    Enum.sort_by(options, fn option ->
      {option.position || 0, BinaryUuidSort.normalize_raw16!(option.id)}
    end)
  end

  defp selections_for_variant(variant_id) do
    VariantOptionSelection
    |> where([selection], selection.variant_id == ^variant_id)
    |> Repo.all()
  end

  defp persist_signature(%Variant{} = variant, signature) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    try do
      {updated_count, _} =
        Variant
        |> where([record], record.id == ^variant.id)
        |> Repo.update_all(set: [selection_signature: signature, updated_at: now])

      if updated_count == 1 do
        _ = AvailabilityCache.invalidate_product(variant.product_id)
        _ = StockFastPath.invalidate_variant_ids([variant.id])
        :ok
      else
        {:error, Error.new("STALE_RECORD", "variant changed while updating signature")}
      end
    rescue
      error in Ecto.ConstraintError ->
        if error.constraint == "variants_unique_active_selection_signature_index" do
          {:error,
           Error.new(
             "VALIDATION_ERROR",
             "active variant option combination must be unique per product"
           )}
        else
          reraise error, __STACKTRACE__
        end

      error in Postgrex.Error ->
        if unique_violation?(error) do
          {:error,
           Error.new(
             "VALIDATION_ERROR",
             "active variant option combination must be unique per product"
           )}
        else
          reraise error, __STACKTRACE__
        end
    end
  end

  defp handle_incomplete_required(%Variant{status: :active}) do
    {:error,
     Error.new(
       "VALIDATION_ERROR",
       "active variant must include exactly one selection for each required option"
     )}
  end

  defp handle_incomplete_required(%Variant{} = variant), do: persist_signature(variant, nil)

  defp unique_violation?(%Postgrex.Error{postgres: %{code: :unique_violation}}), do: true
  defp unique_violation?(%Postgrex.Error{postgres: %{code: "23505"}}), do: true
  defp unique_violation?(_error), do: false
end
