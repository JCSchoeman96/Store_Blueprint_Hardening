defmodule Store.Pricing.Facade do
  @moduledoc """
  Consumer-scoped pricing surfaces for admin reads and writes.
  """

  alias Store.Pricing
  alias Store.Pricing.Queries.AdminTaxRatesQuery
  alias Store.Pricing.TaxRate
  alias Store.Shipping.Facade, as: ShippingFacade
  alias Store.Shipping.Queries.{AdminShippingRateRulesQuery, AdminShippingZonesQuery}
  alias Store.Shipping.{ShippingRateRule, ShippingZone}
  alias Store.Support.Errors.Normalize

  @spec list_shipping_zones_for_admin(map(), AdminShippingZonesQuery.t()) ::
          {:ok, [ShippingZone.t()]} | {:error, term()}
  def list_shipping_zones_for_admin(actor, %AdminShippingZonesQuery{} = query)
      when is_map(actor) do
    case ShippingFacade.list_shipping_zones_for_admin(actor, query) do
      {:ok, zones} -> {:ok, zones}
      {:error, error} -> {:error, Normalize.normalize(error)}
    end
  end

  @spec get_shipping_zone_for_admin(map(), Ecto.UUID.t()) ::
          {:ok, ShippingZone.t() | nil} | {:error, term()}
  def get_shipping_zone_for_admin(actor, id) when is_map(actor) and is_binary(id) do
    case ShippingFacade.get_shipping_zone_for_admin(actor, id) do
      {:ok, zone} -> {:ok, zone}
      {:error, error} -> {:error, Normalize.normalize(error)}
    end
  end

  @spec create_shipping_zone_for_admin(map(), map(), keyword()) ::
          {:ok, ShippingZone.t()} | {:error, term()}
  def create_shipping_zone_for_admin(actor, attrs, opts)
      when is_map(actor) and is_map(attrs) and is_list(opts) do
    ShippingFacade.create_shipping_zone_for_admin(actor, attrs, opts)
  end

  @spec update_shipping_zone_for_admin(map(), Ecto.UUID.t(), map(), keyword()) ::
          {:ok, ShippingZone.t()} | {:error, term()}
  def update_shipping_zone_for_admin(actor, id, attrs, opts)
      when is_map(actor) and is_binary(id) and is_map(attrs) and is_list(opts) do
    ShippingFacade.update_shipping_zone_for_admin(actor, id, attrs, opts)
  end

  @spec list_shipping_rates_for_admin(map(), AdminShippingRateRulesQuery.t()) ::
          {:ok, [ShippingRateRule.t()]} | {:error, term()}
  def list_shipping_rates_for_admin(actor, %AdminShippingRateRulesQuery{} = query)
      when is_map(actor) do
    case ShippingFacade.list_shipping_rate_rules_for_admin(actor, query) do
      {:ok, rates} -> {:ok, rates}
      {:error, error} -> {:error, Normalize.normalize(error)}
    end
  end

  @spec get_shipping_rate_for_admin(map(), Ecto.UUID.t()) ::
          {:ok, ShippingRateRule.t() | nil} | {:error, term()}
  def get_shipping_rate_for_admin(actor, id) when is_map(actor) and is_binary(id) do
    case ShippingFacade.get_shipping_rate_rule_for_admin(actor, id) do
      {:ok, rate} -> {:ok, rate}
      {:error, error} -> {:error, Normalize.normalize(error)}
    end
  end

  @spec list_tax_rates_for_admin(map(), AdminTaxRatesQuery.t()) ::
          {:ok, [TaxRate.t()]} | {:error, term()}
  def list_tax_rates_for_admin(actor, %AdminTaxRatesQuery{} = query) when is_map(actor) do
    case Pricing.list_tax_rates_for_admin(query, actor) do
      {:ok, rates} -> {:ok, rates}
      {:error, error} -> {:error, Normalize.normalize(error)}
    end
  end

  @spec get_tax_rate_for_admin(map(), Ecto.UUID.t()) ::
          {:ok, TaxRate.t() | nil} | {:error, term()}
  def get_tax_rate_for_admin(actor, id) when is_map(actor) and is_binary(id) do
    case Pricing.get_tax_rate_for_admin(id, actor) do
      {:ok, rate} -> {:ok, rate}
      {:error, error} -> {:error, Normalize.normalize(error)}
    end
  end
end
