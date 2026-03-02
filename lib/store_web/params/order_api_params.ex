defmodule StoreWeb.Params.OrderApiParams do
  @moduledoc """
  Params adapter for Order API query contracts.
  """

  alias Store.Orders.Queries.OrderForApiQuery
  alias Store.Support.Errors.Error

  @spec show_query(map()) :: {:ok, OrderForApiQuery.t()} | {:error, Error.t()}
  def show_query(params) when is_map(params), do: OrderForApiQuery.new(params)

  def show_query(_params), do: {:error, Error.new("VALIDATION_ERROR", "params must be a map")}
end
