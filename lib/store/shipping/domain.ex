defmodule Store.Shipping do
  @moduledoc """
  Shipping domain for persisted methods/rules and deterministic quote options.
  """

  use Ash.Domain

  import Ash.Expr
  require Ash.Query

  alias Store.Shipping.Inputs.QuoteRequest

  alias Store.Shipping.Queries.{
    AdminShippingMethodsQuery,
    AdminShippingRateRulesQuery,
    AdminShippingZonesQuery
  }

  alias Store.Shipping.{QuoteHash, ShippingMethod, ShippingRateRule, ShippingZone}
  alias Store.Shipping.Types.{QuoteEvidence, QuoteOption}
  alias Store.Support.Errors.Error
  alias Store.Support.ID.BinaryUuidSort

  resources do
    resource(Store.Shipping.ShippingZone)
    resource(Store.Shipping.ShippingMethod)
    resource(Store.Shipping.ShippingRateRule)
  end

  @spec list_shipping_zones_for_admin(AdminShippingZonesQuery.t(), map()) ::
          {:ok, [ShippingZone.t()]} | {:error, term()}
  def list_shipping_zones_for_admin(%AdminShippingZonesQuery{limit: limit}, actor)
      when is_map(actor) do
    ShippingZone
    |> Ash.Query.for_read(:admin_index, %{limit: limit}, actor: actor)
    |> Ash.read(domain: __MODULE__, actor: actor)
  end

  @spec get_shipping_zone_for_admin(Ecto.UUID.t(), map()) ::
          {:ok, ShippingZone.t() | nil} | {:error, term()}
  def get_shipping_zone_for_admin(id, actor) when is_binary(id) and is_map(actor) do
    ShippingZone
    |> Ash.Query.for_read(:admin_get, %{id: id}, actor: actor)
    |> Ash.read_one(domain: __MODULE__, actor: actor)
  end

  @spec list_shipping_methods_for_admin(AdminShippingMethodsQuery.t(), map()) ::
          {:ok, [ShippingMethod.t()]} | {:error, term()}
  def list_shipping_methods_for_admin(%AdminShippingMethodsQuery{limit: limit}, actor)
      when is_map(actor) do
    ShippingMethod
    |> Ash.Query.for_read(:admin_index, %{limit: limit}, actor: actor)
    |> Ash.read(domain: __MODULE__, actor: actor)
  end

  @spec get_shipping_method_for_admin(Ecto.UUID.t(), map()) ::
          {:ok, ShippingMethod.t() | nil} | {:error, term()}
  def get_shipping_method_for_admin(id, actor) when is_binary(id) and is_map(actor) do
    ShippingMethod
    |> Ash.Query.for_read(:admin_get, %{id: id}, actor: actor)
    |> Ash.read_one(domain: __MODULE__, actor: actor)
  end

  @spec list_shipping_rate_rules_for_admin(AdminShippingRateRulesQuery.t(), map()) ::
          {:ok, [ShippingRateRule.t()]} | {:error, term()}
  def list_shipping_rate_rules_for_admin(
        %AdminShippingRateRulesQuery{
          limit: limit,
          shipping_zone_id: shipping_zone_id,
          shipping_method_id: shipping_method_id
        },
        actor
      )
      when is_map(actor) do
    ShippingRateRule
    |> Ash.Query.for_read(
      :admin_index,
      %{
        limit: limit,
        shipping_zone_id: shipping_zone_id,
        shipping_method_id: shipping_method_id
      },
      actor: actor
    )
    |> Ash.read(domain: __MODULE__, actor: actor)
  end

  @spec get_shipping_rate_rule_for_admin(Ecto.UUID.t(), map()) ::
          {:ok, ShippingRateRule.t() | nil} | {:error, term()}
  def get_shipping_rate_rule_for_admin(id, actor) when is_binary(id) and is_map(actor) do
    ShippingRateRule
    |> Ash.Query.for_read(:admin_get, %{id: id}, actor: actor)
    |> Ash.read_one(domain: __MODULE__, actor: actor)
  end

  @spec quote_options(QuoteRequest.t(), keyword()) ::
          {:ok, [QuoteOption.t()]} | {:error, Error.t()}
  def quote_options(request, opts \\ [])

  def quote_options(%QuoteRequest{} = request, opts) when is_list(opts) do
    now = Keyword.get(opts, :as_of, DateTime.utc_now() |> DateTime.truncate(:microsecond))

    query =
      ShippingRateRule
      |> Ash.Query.filter(expr(currency == ^request.currency_code and active == true))
      |> Ash.Query.load([:shipping_zone, :shipping_method])

    case Ash.read(query, domain: __MODULE__, authorize?: false, context: %{system?: true}) do
      {:ok, rules} ->
        rules
        |> Enum.filter(&eligible_rule?(&1, request, now))
        |> Enum.map(&to_quote_option(&1, request))
        |> Enum.sort_by(&quote_option_sort_tuple/1)
        |> then(&{:ok, &1})

      {:error, _error} ->
        {:error, Error.new("INTERNAL_ERROR", "unable to read shipping quote rules")}
    end
  end

  def quote_options(_request, _opts) do
    {:error, Error.new("VALIDATION_ERROR", "quote request is required")}
  end

  defp eligible_rule?(%ShippingRateRule{} = rule, %QuoteRequest{} = request, %DateTime{} = now) do
    zone = Map.get(rule, :shipping_zone)
    method = Map.get(rule, :shipping_method)

    method_active? = match?(%ShippingMethod{active: true}, method)

    method_active? and
      active_window?(rule.starts_at, rule.ends_at, now) and
      zone_eligible?(zone, request) and
      weight_eligible?(
        rule.weight_min_grams,
        rule.weight_max_grams,
        request.shipping_weight_grams
      )
  end

  defp active_window?(nil, nil, _now), do: true

  defp active_window?(starts_at, nil, now) when is_struct(starts_at, DateTime),
    do: DateTime.compare(starts_at, now) in [:lt, :eq]

  defp active_window?(nil, ends_at, now) when is_struct(ends_at, DateTime),
    do: DateTime.compare(now, ends_at) in [:lt, :eq]

  defp active_window?(starts_at, ends_at, now)
       when is_struct(starts_at, DateTime) and is_struct(ends_at, DateTime) do
    DateTime.compare(starts_at, now) in [:lt, :eq] and
      DateTime.compare(now, ends_at) in [:lt, :eq]
  end

  defp active_window?(_starts_at, _ends_at, _now), do: false

  defp zone_eligible?(nil, _request), do: true

  defp zone_eligible?(%ShippingZone{active: true} = zone, %QuoteRequest{} = request) do
    country_ok = zone.country_code == request.destination_country_code
    region_ok = is_nil(zone.region_code) or zone.region_code == request.destination_region_code
    country_ok and region_ok
  end

  defp zone_eligible?(_zone, _request), do: false

  defp weight_eligible?(nil, nil, _weight_grams), do: true

  defp weight_eligible?(min_grams, nil, weight_grams) when is_integer(min_grams),
    do: weight_grams >= min_grams

  defp weight_eligible?(nil, max_grams, weight_grams) when is_integer(max_grams),
    do: weight_grams <= max_grams

  defp weight_eligible?(min_grams, max_grams, weight_grams)
       when is_integer(min_grams) and is_integer(max_grams) do
    weight_grams >= min_grams and weight_grams <= max_grams
  end

  defp weight_eligible?(_min_grams, _max_grams, _weight_grams), do: false

  defp to_quote_option(%ShippingRateRule{} = rule, %QuoteRequest{} = request) do
    method = Map.fetch!(rule, :shipping_method)
    zone = Map.get(rule, :shipping_zone)

    evidence =
      %QuoteEvidence{
        currency_code: request.currency_code,
        amount_minor: Kernel.max(rule.shipping_cost_minor || 0, 0),
        shipping_weight_grams: request.shipping_weight_grams,
        destination_country_code: request.destination_country_code,
        destination_region_code: request.destination_region_code,
        destination_postal_code: request.destination_postal_code,
        shipping_method_code: method.code,
        shipping_rule_id: rule.id,
        zone_id: zone && zone.id,
        effective_from: rule.starts_at,
        effective_to: rule.ends_at
      }

    %QuoteOption{
      quote_hash: QuoteHash.hash_evidence(evidence),
      currency_code: evidence.currency_code,
      amount_minor: evidence.amount_minor,
      shipping_weight_grams: evidence.shipping_weight_grams,
      destination_country_code: evidence.destination_country_code,
      destination_region_code: evidence.destination_region_code,
      destination_postal_code: evidence.destination_postal_code,
      shipping_method_code: evidence.shipping_method_code,
      shipping_rule_id: evidence.shipping_rule_id,
      zone_id: evidence.zone_id,
      effective_from: evidence.effective_from,
      effective_to: evidence.effective_to,
      label: method.name
    }
  end

  defp quote_option_sort_tuple(%QuoteOption{} = option) do
    {
      option.amount_minor,
      option.shipping_method_code,
      uuid_sort_key(option.shipping_rule_id),
      uuid_sort_key(option.zone_id)
    }
  end

  defp uuid_sort_key(nil), do: {0, <<>>}

  defp uuid_sort_key(uuid) when is_binary(uuid) do
    {1, BinaryUuidSort.normalize_raw16!(uuid)}
  end
end
