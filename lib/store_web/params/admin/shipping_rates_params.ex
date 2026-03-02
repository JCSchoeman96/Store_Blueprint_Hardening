defmodule StoreWeb.Params.Admin.ShippingRatesParams do
  @moduledoc """
  Params adapter for shipping-rate admin list contracts.
  """

  alias Store.Pricing.Queries.AdminShippingRatesQuery
  alias Store.Support.Errors.Error

  @allowed_params ~w(limit shipping_zone_id)

  @spec index_query(map()) :: {:ok, AdminShippingRatesQuery.t()} | {:error, Error.t()}
  def index_query(params) when is_map(params) do
    params
    |> Map.take(@allowed_params)
    |> AdminShippingRatesQuery.new()
  end

  def index_query(_params), do: {:error, Error.new("VALIDATION_ERROR", "params must be a map")}
end
