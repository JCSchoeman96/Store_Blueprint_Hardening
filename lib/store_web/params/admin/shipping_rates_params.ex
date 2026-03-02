defmodule StoreWeb.Params.Admin.ShippingRatesParams do
  @moduledoc """
  Params adapter for shipping-rate admin list contracts.
  """

  alias Store.Pricing.Queries.AdminShippingRatesQuery
  alias Store.Support.Errors.Error

  @spec index_query(map()) :: {:ok, AdminShippingRatesQuery.t()} | {:error, Error.t()}
  def index_query(params) when is_map(params), do: AdminShippingRatesQuery.new(params)

  def index_query(_params), do: {:error, Error.new("VALIDATION_ERROR", "params must be a map")}
end
