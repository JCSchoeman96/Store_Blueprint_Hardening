defmodule StoreWeb.Params.Orders.OrderIndexParams do
  @moduledoc """
  Params adapter for order index query contracts.
  """

  alias Store.Orders.Queries.OrderIndexQuery
  alias Store.Support.Errors.Error

  @spec query(map()) :: {:ok, OrderIndexQuery.t()} | {:error, Error.t()}
  def query(params) when is_map(params), do: OrderIndexQuery.new(params)

  def query(_params), do: {:error, Error.new("VALIDATION_ERROR", "params must be a map")}
end
