defmodule Store.Pricing do
  @moduledoc """
  Pricing domain for persisted discount definitions and deterministic evaluation.
  """

  use Ash.Domain

  import Ash.Expr
  require Ash.Query

  alias Store.Pricing.{
    Contract,
    Coupon,
    Evaluator,
    Promotion,
    ShippingRate,
    ShippingZone,
    TaxRate,
    TaxShippingContract,
    TaxShippingEvaluator
  }

  alias Store.Support.Errors.Error

  resources do
    resource(Store.Pricing.Coupon)
    resource(Store.Pricing.Promotion)
    resource(Store.Pricing.ShippingZone)
    resource(Store.Pricing.ShippingRate)
    resource(Store.Pricing.TaxRate)
  end

  @type evaluate_quote_opts :: [authorize?: boolean(), actor: term(), context: map()]

  @spec evaluate_quote(map(), evaluate_quote_opts()) ::
          {:ok, %{input: Contract.Input.t(), output: Contract.Output.t()}} | {:error, Error.t()}
  def evaluate_quote(attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    with {:ok, input} <- build_input(attrs, opts),
         {:ok, output} <- Evaluator.evaluate(input) do
      {:ok, %{input: input, output: output}}
    end
  end

  @spec evaluate_tax_shipping_quote(map(), evaluate_quote_opts()) ::
          {:ok,
           %{
             input: TaxShippingContract.Input.t(),
             output: TaxShippingContract.Output.t()
           }}
          | {:error, Error.t()}
  def evaluate_tax_shipping_quote(attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    with {:ok, input} <- build_tax_shipping_input(attrs, opts),
         {:ok, output} <- TaxShippingEvaluator.evaluate(input) do
      {:ok, %{input: input, output: output}}
    end
  end

  @spec build_input(map(), evaluate_quote_opts()) ::
          {:ok, Contract.Input.t()} | {:error, Error.t()}
  def build_input(attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    with {:ok, as_of} <- fetch_datetime(attrs, :as_of),
         {:ok, currency} <- fetch_string(attrs, :currency),
         {:ok, lines} <- fetch_lines(attrs),
         {:ok, promotions} <- fetch_promotions(attrs, opts),
         {:ok, coupon} <- fetch_coupon(attrs, opts) do
      eligibility = Map.get(attrs, :eligibility, %{})

      input =
        Contract.to_input!(%{
          as_of: as_of,
          currency: currency,
          lines: lines,
          promotions: promotions,
          coupon: coupon,
          eligibility: eligibility
        })

      {:ok, input}
    end
  rescue
    KeyError ->
      {:error, Error.new("VALIDATION_ERROR", "Missing required pricing input")}

    ArgumentError ->
      {:error, Error.new("VALIDATION_ERROR", "Invalid pricing input")}
  end

  @spec build_tax_shipping_input(map(), evaluate_quote_opts()) ::
          {:ok, TaxShippingContract.Input.t()} | {:error, Error.t()}
  def build_tax_shipping_input(attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    with {:ok, as_of} <- fetch_datetime(attrs, :as_of),
         {:ok, currency} <- fetch_string(attrs, :currency),
         {:ok, country_code} <- fetch_string(attrs, :destination_country_code),
         {:ok, region_code} <- fetch_optional_string(attrs, :destination_region_code),
         {:ok, postal_code} <- fetch_optional_string(attrs, :destination_postal_code),
         {:ok, subtotal_minor} <- fetch_non_negative_integer(attrs, :subtotal_minor),
         {:ok, shipping_weight_grams} <- fetch_non_negative_integer(attrs, :shipping_weight_grams),
         {:ok, lines} <- fetch_tax_shipping_lines(attrs),
         {:ok, shipping_rates} <- fetch_shipping_rate_candidates(currency, opts),
         {:ok, tax_rates} <- fetch_tax_rate_candidates(country_code, opts) do
      input =
        TaxShippingContract.to_input!(%{
          as_of: as_of,
          currency: currency,
          destination_country_code: String.upcase(country_code),
          destination_region_code: to_upcase_or_nil(region_code),
          destination_postal_code: postal_code,
          subtotal_minor: subtotal_minor,
          shipping_weight_grams: shipping_weight_grams,
          lines: lines,
          shipping_rates: shipping_rates,
          tax_rates: tax_rates,
          free_shipping_coupon?: Map.get(attrs, :free_shipping_coupon?, false),
          shipping_enabled?: Map.get(attrs, :shipping_enabled?, true),
          tax_enabled?: Map.get(attrs, :tax_enabled?, true)
        })

      {:ok, input}
    end
  rescue
    KeyError ->
      {:error, Error.new("VALIDATION_ERROR", "Missing required tax/shipping input")}

    ArgumentError ->
      {:error, Error.new("VALIDATION_ERROR", "Invalid tax/shipping input")}
  end

  @spec candidate_from_coupon(Coupon.t()) :: Contract.Candidate.t()
  def candidate_from_coupon(%Coupon{} = coupon) do
    %Contract.Candidate{
      id: coupon.id,
      source_kind: :coupon,
      code: coupon.code,
      discount_minor: coupon.discount_minor,
      starts_at: coupon.starts_at,
      ends_at: coupon.ends_at,
      active?: coupon.active,
      exclusive?: false,
      combinable?: coupon.combinable_with_promotions,
      allow_with_exclusive?: coupon.allow_with_exclusive,
      exclusive_priority: 0,
      precedence_rank: coupon.precedence_rank,
      inserted_at: coupon.inserted_at,
      eligibility_key: coupon.eligibility_key
    }
  end

  @spec candidate_from_promotion(Promotion.t()) :: Contract.Candidate.t()
  def candidate_from_promotion(%Promotion{} = promotion) do
    %Contract.Candidate{
      id: promotion.id,
      source_kind: :promotion,
      code: promotion.code,
      discount_minor: promotion.discount_minor,
      starts_at: promotion.starts_at,
      ends_at: promotion.ends_at,
      active?: promotion.active,
      exclusive?: promotion.exclusive,
      combinable?: promotion.combinable,
      allow_with_exclusive?: false,
      exclusive_priority: promotion.exclusive_priority,
      precedence_rank: promotion.precedence_rank,
      inserted_at: promotion.inserted_at,
      eligibility_key: promotion.eligibility_key
    }
  end

  defp fetch_lines(attrs) do
    lines = Map.get(attrs, :lines, [])

    if is_list(lines) and lines != [] do
      {:ok, lines}
    else
      {:error, Error.new("VALIDATION_ERROR", "Pricing lines are required")}
    end
  end

  defp fetch_tax_shipping_lines(attrs) do
    lines = Map.get(attrs, :lines, [])

    if is_list(lines) and lines != [] do
      {:ok, Enum.map(lines, &TaxShippingContract.to_line!/1)}
    else
      {:error, Error.new("VALIDATION_ERROR", "Tax/shipping lines are required")}
    end
  rescue
    KeyError ->
      {:error, Error.new("VALIDATION_ERROR", "Invalid tax/shipping line input")}

    ArgumentError ->
      {:error, Error.new("VALIDATION_ERROR", "Invalid tax/shipping line input")}
  end

  defp fetch_promotions(attrs, opts) do
    promotion_ids = Map.get(attrs, :promotion_ids, [])

    query =
      case promotion_ids do
        [] -> Promotion
        ids when is_list(ids) -> Ash.Query.filter(Promotion, expr(id in ^ids))
      end

    case Ash.read(query, domain: __MODULE__, authorize?: Keyword.get(opts, :authorize?, false)) do
      {:ok, promotions} -> {:ok, Enum.map(promotions, &candidate_from_promotion/1)}
      {:error, _error} -> {:error, Error.new("INTERNAL_ERROR", "Unable to read promotions")}
    end
  end

  defp fetch_coupon(attrs, opts) do
    case Map.get(attrs, :coupon_code) do
      nil ->
        {:ok, nil}

      code when is_binary(code) ->
        normalized_code = String.upcase(String.trim(code))

        query = Ash.Query.filter(Coupon, expr(code == ^normalized_code))

        case Ash.read(query,
               domain: __MODULE__,
               authorize?: Keyword.get(opts, :authorize?, false)
             ) do
          {:ok, [coupon]} -> {:ok, candidate_from_coupon(coupon)}
          {:ok, []} -> {:error, Error.new("INVALID_COUPON", "Coupon not found")}
          {:ok, _many} -> {:error, Error.new("INTERNAL_ERROR", "Coupon code is not unique")}
          {:error, _error} -> {:error, Error.new("INTERNAL_ERROR", "Unable to read coupon")}
        end

      _other ->
        {:error, Error.new("VALIDATION_ERROR", "Coupon code must be a string")}
    end
  end

  defp fetch_datetime(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, %DateTime{} = datetime} -> {:ok, datetime}
      _ -> {:error, Error.new("VALIDATION_ERROR", "#{key} must be a DateTime")}
    end
  end

  defp fetch_string(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, Error.new("VALIDATION_ERROR", "#{key} must be a non-empty string")}
    end
  end

  defp fetch_optional_string(attrs, key) do
    case Map.get(attrs, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, String.trim(value)}
      _ -> {:error, Error.new("VALIDATION_ERROR", "#{key} must be a string or nil")}
    end
  end

  defp fetch_non_negative_integer(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_integer(value) and value >= 0 ->
        {:ok, value}

      _ ->
        {:error, Error.new("VALIDATION_ERROR", "#{key} must be a non-negative integer")}
    end
  end

  defp fetch_shipping_rate_candidates(currency, opts) do
    query = Ash.Query.filter(ShippingRate, expr(currency == ^currency))

    with {:ok, rates} <-
           Ash.read(query, domain: __MODULE__, authorize?: Keyword.get(opts, :authorize?, false)),
         {:ok, zones_by_id} <- fetch_shipping_zones_by_id(rates, opts) do
      rates
      |> Enum.map(&shipping_candidate_from_rate(&1, zones_by_id))
      |> Enum.reject(&is_nil/1)
      |> then(&{:ok, &1})
    else
      {:error, _reason} ->
        {:error, Error.new("INTERNAL_ERROR", "Unable to read shipping rates")}
    end
  end

  defp fetch_shipping_zones_by_id(rates, opts) do
    zone_ids =
      rates
      |> Enum.map(& &1.shipping_zone_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case zone_ids do
      [] ->
        {:ok, %{}}

      ids ->
        query = Ash.Query.filter(ShippingZone, expr(id in ^ids))

        case Ash.read(query,
               domain: __MODULE__,
               authorize?: Keyword.get(opts, :authorize?, false)
             ) do
          {:ok, zones} -> {:ok, Map.new(zones, &{&1.id, &1})}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp shipping_candidate_from_rate(rate, zones_by_id) do
    zone = Map.get(zones_by_id, rate.shipping_zone_id)

    cond do
      rate.shipping_zone_id != nil and zone == nil ->
        nil

      rate.shipping_zone_id != nil and zone.active != true ->
        nil

      true ->
        %TaxShippingContract.ShippingRateCandidate{
          id: rate.id,
          code: rate.code,
          shipping_cost_minor: rate.shipping_cost_minor,
          country_code: zone && zone.country_code,
          region_code: zone && zone.region_code,
          weight_min_grams: rate.weight_min_grams,
          weight_max_grams: rate.weight_max_grams,
          free_over_subtotal_minor: rate.free_over_subtotal_minor,
          allow_free_shipping_coupon: rate.allow_free_shipping_coupon,
          starts_at: rate.starts_at,
          ends_at: rate.ends_at,
          active?: rate.active,
          precedence_rank: rate.precedence_rank
        }
    end
  end

  defp fetch_tax_rate_candidates(country_code, opts) do
    normalized_country = String.upcase(country_code)
    query = Ash.Query.filter(TaxRate, expr(country_code == ^normalized_country))

    case Ash.read(query, domain: __MODULE__, authorize?: Keyword.get(opts, :authorize?, false)) do
      {:ok, rates} ->
        {:ok,
         Enum.map(rates, fn rate ->
           %TaxShippingContract.TaxRateCandidate{
             id: rate.id,
             code: rate.code,
             country_code: rate.country_code,
             region_code: rate.region_code,
             product_tax_category: rate.product_tax_category,
             rate_basis_points: rate.rate_basis_points,
             shipping_taxable: rate.shipping_taxable,
             starts_at: rate.starts_at,
             ends_at: rate.ends_at,
             active?: rate.active,
             precedence_rank: rate.precedence_rank
           }
         end)}

      {:error, _reason} ->
        {:error, Error.new("INTERNAL_ERROR", "Unable to read tax rates")}
    end
  end

  defp to_upcase_or_nil(nil), do: nil
  defp to_upcase_or_nil(value), do: value |> String.trim() |> String.upcase()
end
