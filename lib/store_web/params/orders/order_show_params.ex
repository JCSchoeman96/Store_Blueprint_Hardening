defmodule StoreWeb.Params.Orders.OrderShowParams do
  @moduledoc """
  Params adapter for order show/get query contracts.
  """

  alias Store.Orders.Queries.OrderShowQuery
  alias Store.Support.Errors.Error

  @spec query(map()) :: {:ok, OrderShowQuery.t()} | {:error, Error.t()}
  def query(params) when is_map(params), do: OrderShowQuery.new(params)

  def query(_params), do: {:error, Error.new("VALIDATION_ERROR", "params must be a map")}
end
