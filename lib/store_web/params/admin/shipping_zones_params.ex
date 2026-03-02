defmodule StoreWeb.Params.Admin.ShippingZonesParams do
  @moduledoc """
  Params adapter for shipping-zone admin list contracts.
  """

  alias Store.Pricing.Queries.AdminShippingZonesQuery
  alias Store.Support.Errors.Error

  @allowed_params ~w(limit)

  @spec index_query(map()) :: {:ok, AdminShippingZonesQuery.t()} | {:error, Error.t()}
  def index_query(params) when is_map(params) do
    params
    |> Map.take(@allowed_params)
    |> AdminShippingZonesQuery.new()
  end

  def index_query(_params), do: {:error, Error.new("VALIDATION_ERROR", "params must be a map")}
end
