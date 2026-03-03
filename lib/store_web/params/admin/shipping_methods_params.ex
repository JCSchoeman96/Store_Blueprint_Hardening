defmodule StoreWeb.Params.Admin.ShippingMethodsParams do
  @moduledoc """
  Params adapter for shipping-method admin list contracts.
  """

  alias Store.Shipping.Queries.AdminShippingMethodsQuery
  alias Store.Support.Errors.Error

  @spec index_query(map()) :: {:ok, AdminShippingMethodsQuery.t()} | {:error, Error.t()}
  def index_query(params) when is_map(params), do: AdminShippingMethodsQuery.new(params)

  def index_query(_params), do: {:error, Error.new("VALIDATION_ERROR", "params must be a map")}
end
