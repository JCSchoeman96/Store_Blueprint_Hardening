defmodule Store.Pricing.Facade do
  @moduledoc """
  Consumer-scoped pricing surfaces for admin reads and writes.
  """

  alias Store.Pricing

  alias Store.Pricing.Queries.{
    AdminShippingRatesQuery,
    AdminShippingZonesQuery,
    AdminTaxRatesQuery
  }

  alias Store.Pricing.{ShippingRate, ShippingZone, TaxRate}
  alias Store.Support.Errors.Error
  alias Store.Support.Errors.Normalize

  @spec list_shipping_zones_for_admin(map(), AdminShippingZonesQuery.t()) ::
          {:ok, [ShippingZone.t()]} | {:error, term()}
  def list_shipping_zones_for_admin(actor, %AdminShippingZonesQuery{} = query)
      when is_map(actor) do
    case Pricing.list_shipping_zones_for_admin(query, actor) do
      {:ok, zones} -> {:ok, zones}
      {:error, error} -> {:error, Normalize.normalize(error)}
    end
  end

  @spec get_shipping_zone_for_admin(map(), Ecto.UUID.t()) ::
          {:ok, ShippingZone.t() | nil} | {:error, term()}
  def get_shipping_zone_for_admin(actor, id) when is_map(actor) and is_binary(id) do
    case Pricing.get_shipping_zone_for_admin(id, actor) do
      {:ok, zone} -> {:ok, zone}
      {:error, error} -> {:error, Normalize.normalize(error)}
    end
  end

  @spec create_shipping_zone_for_admin(map(), map(), keyword()) ::
          {:ok, ShippingZone.t()} | {:error, term()}
  def create_shipping_zone_for_admin(actor, attrs, opts)
      when is_map(actor) and is_map(attrs) and is_list(opts) do
    context = Keyword.get(opts, :context, %{})

    ShippingZone
    |> Ash.Changeset.for_create(:create, attrs, context: context)
    |> Ash.create(domain: Pricing, actor: actor, context: context)
    |> normalize_result()
  end

  @spec update_shipping_zone_for_admin(map(), Ecto.UUID.t(), map(), keyword()) ::
          {:ok, ShippingZone.t()} | {:error, term()}
  def update_shipping_zone_for_admin(actor, id, attrs, opts)
      when is_map(actor) and is_binary(id) and is_map(attrs) and is_list(opts) do
    context = Keyword.get(opts, :context, %{})

    case Pricing.get_shipping_zone_for_admin(id, actor) do
      {:ok, %ShippingZone{} = shipping_zone} ->
        shipping_zone
        |> Ash.Changeset.for_update(:update, attrs, context: context)
        |> Ash.update(domain: Pricing, actor: actor, context: context)
        |> normalize_result()

      {:ok, nil} ->
        {:error, Error.new("NOT_FOUND", "Shipping zone not found")}

      {:error, error} ->
        {:error, Normalize.normalize(error)}
    end
  end

  @spec list_shipping_rates_for_admin(map(), AdminShippingRatesQuery.t()) ::
          {:ok, [ShippingRate.t()]} | {:error, term()}
  def list_shipping_rates_for_admin(actor, %AdminShippingRatesQuery{} = query)
      when is_map(actor) do
    case Pricing.list_shipping_rates_for_admin(query, actor) do
      {:ok, rates} -> {:ok, rates}
      {:error, error} -> {:error, Normalize.normalize(error)}
    end
  end

  @spec get_shipping_rate_for_admin(map(), Ecto.UUID.t()) ::
          {:ok, ShippingRate.t() | nil} | {:error, term()}
  def get_shipping_rate_for_admin(actor, id) when is_map(actor) and is_binary(id) do
    case Pricing.get_shipping_rate_for_admin(id, actor) do
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

  defp normalize_result({:ok, result}), do: {:ok, result}
  defp normalize_result({:error, error}), do: {:error, Normalize.normalize(error)}
end
