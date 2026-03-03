defmodule StoreWeb.Params.Admin.ShippingZonesParams do
  @moduledoc """
  Params adapter for shipping-zone admin list contracts.
  """

  alias Store.Shipping.Queries.AdminShippingZonesQuery
  alias Store.Support.Errors.Error

  @spec index_query(map()) :: {:ok, AdminShippingZonesQuery.t()} | {:error, Error.t()}
  def index_query(params) when is_map(params), do: AdminShippingZonesQuery.new(params)

  def index_query(_params), do: {:error, Error.new("VALIDATION_ERROR", "params must be a map")}
end
