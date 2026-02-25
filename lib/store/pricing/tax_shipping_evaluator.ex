defmodule Store.Pricing.TaxShippingEvaluator do
  @moduledoc """
  Pure deterministic tax and shipping evaluator.
  """

  alias Store.Pricing.TaxShippingContract

  alias Store.Pricing.TaxShippingContract.{
    Input,
    Line,
    LineTax,
    Output,
    ShippingRateCandidate,
    TaxRateCandidate
  }

  alias Store.Support.Errors.Error
  alias Store.Support.ID.BinaryUuidSort

  @max_uuid_sort_key <<255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
                       255>>

  @type result :: {:ok, Output.t()} | {:error, Error.t()}

  @spec evaluate(Input.t() | map()) :: result()
  def evaluate(input) do
    input = TaxShippingContract.to_input!(input)

    with :ok <- validate_input(input),
         {:ok, shipping_selection} <- select_shipping(input),
         {:ok, line_taxes} <- compute_line_taxes(input),
         {:ok, shipping_tax} <- compute_shipping_tax(input, shipping_selection) do
      line_tax_total_minor = Enum.reduce(line_taxes, 0, &(&1.tax_minor + &2))
      tax_total_minor = line_tax_total_minor + shipping_tax.shipping_tax_minor

      order_total_minor =
        input.subtotal_minor + shipping_selection.shipping_cost_minor_effective + tax_total_minor

      {:ok,
       %Output{
         currency: input.currency,
         destination_country_code: input.destination_country_code,
         destination_region_code: input.destination_region_code,
         destination_postal_code: input.destination_postal_code,
         subtotal_minor: input.subtotal_minor,
         selected_shipping_rate_id: shipping_selection.selected_shipping_rate_id,
         selected_shipping_rate_code: shipping_selection.selected_shipping_rate_code,
         shipping_cost_minor_original: shipping_selection.shipping_cost_minor_original,
         shipping_cost_minor_effective: shipping_selection.shipping_cost_minor_effective,
         free_shipping_applied: shipping_selection.free_shipping_applied,
         free_shipping_reason: shipping_selection.free_shipping_reason,
         shipping_tax_rate_id: shipping_tax.shipping_tax_rate_id,
         shipping_tax_rate_code: shipping_tax.shipping_tax_rate_code,
         shipping_tax_rate_bps: shipping_tax.shipping_tax_rate_bps,
         shipping_tax_minor: shipping_tax.shipping_tax_minor,
         tax_total_minor: tax_total_minor,
         order_total_minor: order_total_minor,
         line_taxes: line_taxes,
         tax_as_of: input.as_of
       }}
    end
  rescue
    KeyError ->
      {:error, Error.new("VALIDATION_ERROR", "Missing required tax/shipping input")}

    ArgumentError ->
      {:error, Error.new("VALIDATION_ERROR", "Invalid tax/shipping input")}
  end

  defp validate_input(%Input{} = input) do
    [
      validate_as_of(input),
      validate_currency(input),
      validate_destination(input),
      validate_subtotal(input),
      validate_shipping_weight(input),
      validate_lines(input),
      validate_shipping_candidates(input),
      validate_tax_candidates(input)
    ]
    |> Enum.find(:ok, &match?({:error, _}, &1))
  end

  defp validate_as_of(%Input{} = input) do
    if is_struct(input.as_of, DateTime) do
      :ok
    else
      {:error, Error.new("VALIDATION_ERROR", "as_of must be a DateTime")}
    end
  end

  defp validate_currency(%Input{} = input) do
    if valid_non_empty_string?(input.currency) do
      :ok
    else
      {:error, Error.new("VALIDATION_ERROR", "currency must be present")}
    end
  end

  defp validate_destination(%Input{} = input) do
    if valid_non_empty_string?(input.destination_country_code) do
      :ok
    else
      {:error, Error.new("INVALID_ADDRESS", "destination country_code is required")}
    end
  end

  defp validate_subtotal(%Input{} = input) do
    if is_integer(input.subtotal_minor) and input.subtotal_minor >= 0 do
      :ok
    else
      {:error, Error.new("VALIDATION_ERROR", "subtotal_minor must be non-negative")}
    end
  end

  defp validate_shipping_weight(%Input{} = input) do
    if is_integer(input.shipping_weight_grams) and input.shipping_weight_grams >= 0 do
      :ok
    else
      {:error, Error.new("VALIDATION_ERROR", "shipping_weight_grams must be non-negative")}
    end
  end

  defp validate_lines(%Input{} = input) do
    if is_list(input.lines) and input.lines != [] and Enum.all?(input.lines, &valid_line?/1) do
      :ok
    else
      {:error, Error.new("VALIDATION_ERROR", "lines must be non-empty and valid")}
    end
  end

  defp validate_shipping_candidates(%Input{} = input) do
    if Enum.all?(input.shipping_rates, &valid_shipping_candidate?/1) do
      :ok
    else
      {:error, Error.new("VALIDATION_ERROR", "invalid shipping rate candidate")}
    end
  end

  defp validate_tax_candidates(%Input{} = input) do
    if Enum.all?(input.tax_rates, &valid_tax_candidate?/1) do
      :ok
    else
      {:error, Error.new("VALIDATION_ERROR", "invalid tax rate candidate")}
    end
  end

  defp valid_line?(%Line{} = line) do
    is_integer(line.line_no) and line.line_no > 0 and
      is_integer(line.net_line_total_minor) and line.net_line_total_minor >= 0 and
      valid_non_empty_string?(line.tax_category_snapshot)
  end

  defp valid_shipping_candidate?(%ShippingRateCandidate{} = candidate) do
    valid_non_empty_string?(candidate.code) and
      is_integer(candidate.shipping_cost_minor) and candidate.shipping_cost_minor >= 0 and
      valid_weight_bounds?(candidate.weight_min_grams, candidate.weight_max_grams)
  end

  defp valid_tax_candidate?(%TaxRateCandidate{} = candidate) do
    valid_non_empty_string?(candidate.code) and valid_non_empty_string?(candidate.country_code) and
      is_integer(candidate.rate_basis_points) and candidate.rate_basis_points >= 0
  end

  defp valid_weight_bounds?(nil, nil), do: true
  defp valid_weight_bounds?(min_grams, nil), do: is_integer(min_grams) and min_grams >= 0
  defp valid_weight_bounds?(nil, max_grams), do: is_integer(max_grams) and max_grams >= 0

  defp valid_weight_bounds?(min_grams, max_grams) do
    is_integer(min_grams) and is_integer(max_grams) and min_grams >= 0 and max_grams >= min_grams
  end

  defp select_shipping(%Input{shipping_enabled?: false}) do
    {:ok,
     %{
       selected_shipping_rate_id: nil,
       selected_shipping_rate_code: nil,
       shipping_cost_minor_original: 0,
       shipping_cost_minor_effective: 0,
       free_shipping_applied: false,
       free_shipping_reason: nil
     }}
  end

  defp select_shipping(%Input{} = input) do
    eligible =
      input.shipping_rates
      |> Enum.filter(&shipping_rate_eligible?(&1, input))
      |> Enum.map(&to_shipping_selection(&1, input))

    case eligible do
      [] ->
        {:error, Error.new("SHIPPING_RATE_NOT_FOUND", "No eligible shipping rate found")}

      _ ->
        selected =
          eligible
          |> Enum.sort_by(&shipping_winner_tuple/1)
          |> List.first()

        {:ok, selected}
    end
  end

  defp shipping_rate_eligible?(%ShippingRateCandidate{} = candidate, %Input{} = input) do
    candidate.active? and within_window?(candidate.starts_at, candidate.ends_at, input.as_of) and
      destination_matches?(candidate.country_code, candidate.region_code, input) and
      weight_matches?(
        candidate.weight_min_grams,
        candidate.weight_max_grams,
        input.shipping_weight_grams
      )
  end

  defp destination_matches?(nil, nil, _input), do: true

  defp destination_matches?(country_code, region_code, %Input{} = input) do
    country_ok? =
      case country_code do
        nil -> true
        code -> String.upcase(code) == String.upcase(input.destination_country_code)
      end

    region_ok? =
      case region_code do
        nil ->
          true

        code ->
          input.destination_region_code != nil and
            String.upcase(code) == String.upcase(input.destination_region_code)
      end

    country_ok? and region_ok?
  end

  defp weight_matches?(nil, nil, _grams), do: true
  defp weight_matches?(min_grams, nil, grams), do: is_integer(min_grams) and grams >= min_grams
  defp weight_matches?(nil, max_grams, grams), do: is_integer(max_grams) and grams <= max_grams

  defp weight_matches?(min_grams, max_grams, grams) do
    is_integer(min_grams) and is_integer(max_grams) and grams >= min_grams and grams <= max_grams
  end

  defp to_shipping_selection(%ShippingRateCandidate{} = candidate, %Input{} = input) do
    threshold_applies? =
      is_integer(candidate.free_over_subtotal_minor) and
        input.subtotal_minor >= candidate.free_over_subtotal_minor

    coupon_applies? = input.free_shipping_coupon? and candidate.allow_free_shipping_coupon

    free_shipping_applied = threshold_applies? or coupon_applies?

    free_shipping_reason =
      cond do
        threshold_applies? -> "THRESHOLD"
        coupon_applies? -> "COUPON"
        true -> nil
      end

    %{
      selected_shipping_rate_id: candidate.id,
      selected_shipping_rate_code: candidate.code,
      shipping_cost_minor_original: candidate.shipping_cost_minor,
      shipping_cost_minor_effective:
        if(free_shipping_applied, do: 0, else: candidate.shipping_cost_minor),
      free_shipping_applied: free_shipping_applied,
      free_shipping_reason: free_shipping_reason
    }
  end

  defp shipping_winner_tuple(selection) do
    {
      selection.shipping_cost_minor_effective,
      id_sort_key(selection.selected_shipping_rate_id),
      String.downcase(selection.selected_shipping_rate_code || "")
    }
  end

  defp compute_line_taxes(%Input{tax_enabled?: false}) do
    {:ok, []}
  end

  defp compute_line_taxes(%Input{} = input) do
    input.lines
    |> Enum.sort_by(&line_sort_tuple/1)
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
      case select_tax_rate_for_line(line, input) do
        {:ok, selected_rate} ->
          tax_minor =
            round_half_up_minor(line.net_line_total_minor, selected_rate.rate_basis_points)

          line_tax = %LineTax{
            line_id: line.line_id,
            line_no: line.line_no,
            tax_minor: tax_minor,
            tax_rate_id: selected_rate.id,
            tax_rate_code: selected_rate.code,
            tax_rate_bps: selected_rate.rate_basis_points,
            tax_category_snapshot: normalize_key(line.tax_category_snapshot)
          }

          {:cont, {:ok, [line_tax | acc]}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, line_taxes} ->
        {:ok, Enum.reverse(line_taxes)}

      {:error, _reason} = error ->
        error
    end
  end

  defp select_tax_rate_for_line(%Line{} = line, %Input{} = input) do
    eligible =
      input.tax_rates
      |> Enum.filter(&tax_rate_eligible_for_line?(&1, line, input))

    case eligible do
      [] ->
        {:error, Error.new("TAX_RATE_NOT_FOUND", "No applicable tax rate found")}

      _ ->
        selected =
          eligible
          |> Enum.sort_by(&line_tax_selector_tuple(&1, line, input))
          |> List.first()

        {:ok, selected}
    end
  end

  defp tax_rate_eligible_for_line?(
         %TaxRateCandidate{} = candidate,
         %Line{} = line,
         %Input{} = input
       ) do
    candidate.active? and within_window?(candidate.starts_at, candidate.ends_at, input.as_of) and
      normalize_key(candidate.country_code) == normalize_key(input.destination_country_code) and
      region_matches?(candidate.region_code, input.destination_region_code) and
      tax_category_matches?(candidate.product_tax_category, line.tax_category_snapshot)
  end

  defp tax_category_matches?(nil, _line_category), do: true

  defp tax_category_matches?(rate_category, line_category) do
    normalize_key(rate_category) == normalize_key(line_category)
  end

  defp region_matches?(nil, _destination_region), do: true
  defp region_matches?(_region, nil), do: false

  defp region_matches?(region_code, destination_region) do
    normalize_key(region_code) == normalize_key(destination_region)
  end

  defp line_tax_selector_tuple(%TaxRateCandidate{} = candidate, %Line{} = line, %Input{} = input) do
    specificity = line_tax_specificity(candidate, line, input.destination_region_code)

    {
      -specificity,
      candidate.precedence_rank,
      id_sort_key(candidate.id),
      String.downcase(candidate.code)
    }
  end

  defp line_tax_specificity(
         %TaxRateCandidate{} = candidate,
         %Line{} = line,
         destination_region_code
       ) do
    region_specific? =
      candidate.region_code != nil and
        region_matches?(candidate.region_code, destination_region_code)

    category_specific? =
      candidate.product_tax_category != nil and
        tax_category_matches?(candidate.product_tax_category, line.tax_category_snapshot)

    cond do
      region_specific? and category_specific? -> 4
      region_specific? -> 3
      category_specific? -> 2
      true -> 1
    end
  end

  defp compute_shipping_tax(%Input{tax_enabled?: false}, _shipping_selection) do
    {:ok,
     %{
       shipping_tax_minor: 0,
       shipping_tax_rate_id: nil,
       shipping_tax_rate_code: nil,
       shipping_tax_rate_bps: nil
     }}
  end

  defp compute_shipping_tax(%Input{} = input, shipping_selection) do
    shipping_minor = shipping_selection.shipping_cost_minor_effective

    if shipping_minor <= 0 do
      {:ok,
       %{
         shipping_tax_minor: 0,
         shipping_tax_rate_id: nil,
         shipping_tax_rate_code: nil,
         shipping_tax_rate_bps: nil
       }}
    else
      eligible =
        input.tax_rates
        |> Enum.filter(&shipping_tax_rate_eligible?(&1, input))

      case eligible do
        [] ->
          {:ok,
           %{
             shipping_tax_minor: 0,
             shipping_tax_rate_id: nil,
             shipping_tax_rate_code: nil,
             shipping_tax_rate_bps: nil
           }}

        _ ->
          selected =
            eligible
            |> Enum.sort_by(&shipping_tax_selector_tuple(&1, input))
            |> List.first()

          shipping_tax_minor = round_half_up_minor(shipping_minor, selected.rate_basis_points)

          {:ok,
           %{
             shipping_tax_minor: shipping_tax_minor,
             shipping_tax_rate_id: selected.id,
             shipping_tax_rate_code: selected.code,
             shipping_tax_rate_bps: selected.rate_basis_points
           }}
      end
    end
  end

  defp shipping_tax_rate_eligible?(%TaxRateCandidate{} = candidate, %Input{} = input) do
    candidate.active? and candidate.shipping_taxable and
      within_window?(candidate.starts_at, candidate.ends_at, input.as_of) and
      normalize_key(candidate.country_code) == normalize_key(input.destination_country_code) and
      region_matches?(candidate.region_code, input.destination_region_code) and
      (candidate.product_tax_category == nil or
         normalize_key(candidate.product_tax_category) == "SHIPPING")
  end

  defp shipping_tax_selector_tuple(%TaxRateCandidate{} = candidate, %Input{} = input) do
    specificity = shipping_tax_specificity(candidate, input.destination_region_code)

    {
      -specificity,
      candidate.precedence_rank,
      id_sort_key(candidate.id),
      String.downcase(candidate.code)
    }
  end

  defp shipping_tax_specificity(%TaxRateCandidate{} = candidate, destination_region_code) do
    region_specific? =
      candidate.region_code != nil and
        region_matches?(candidate.region_code, destination_region_code)

    category_specific? = normalize_key(candidate.product_tax_category) == "SHIPPING"

    cond do
      region_specific? and category_specific? -> 4
      region_specific? -> 3
      category_specific? -> 2
      true -> 1
    end
  end

  defp line_sort_tuple(%Line{} = line) do
    {line.line_no, id_sort_key(line.line_id)}
  end

  defp within_window?(starts_at, ends_at, as_of) do
    starts_ok? =
      case starts_at do
        nil -> true
        %DateTime{} = starts -> DateTime.compare(as_of, starts) in [:eq, :gt]
      end

    ends_ok? =
      case ends_at do
        nil -> true
        %DateTime{} = ends -> DateTime.compare(as_of, ends) in [:eq, :lt]
      end

    starts_ok? and ends_ok?
  end

  defp round_half_up_minor(amount_minor, rate_basis_points)
       when is_integer(amount_minor) and is_integer(rate_basis_points) and amount_minor >= 0 and
              rate_basis_points >= 0 do
    div(amount_minor * rate_basis_points + 5_000, 10_000)
  end

  defp id_sort_key(nil), do: @max_uuid_sort_key

  defp id_sort_key(id) do
    case BinaryUuidSort.normalize_raw16(id) do
      {:ok, raw16} -> raw16
      :error -> @max_uuid_sort_key
    end
  end

  defp valid_non_empty_string?(value), do: is_binary(value) and String.trim(value) != ""
  defp normalize_key(nil), do: nil
  defp normalize_key(value) when is_binary(value), do: value |> String.trim() |> String.upcase()
end
