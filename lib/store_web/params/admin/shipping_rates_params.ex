defmodule StoreWeb.Params.Admin.ShippingRatesParams do
  @moduledoc """
  Params adapter for shipping-rate admin list contracts.
  """

  alias Store.Shipping.Queries.AdminShippingRateRulesQuery
  alias Store.Support.Errors.Error

  @spec index_query(map()) :: {:ok, AdminShippingRateRulesQuery.t()} | {:error, Error.t()}
  def index_query(params) when is_map(params), do: AdminShippingRateRulesQuery.new(params)

  def index_query(_params), do: {:error, Error.new("VALIDATION_ERROR", "params must be a map")}
end
