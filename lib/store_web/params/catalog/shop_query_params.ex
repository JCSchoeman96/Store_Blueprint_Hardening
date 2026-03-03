defmodule StoreWeb.Params.Catalog.ShopQueryParams do
  @moduledoc """
  Web params adapter for storefront shop listing query contract.
  """

  alias Store.Catalog.Queries.ShopQuery
  alias Store.Support.Errors.Error

  @spec query(map()) :: {:ok, ShopQuery.t()} | {:error, Error.t()}
  def query(params) when is_map(params), do: ShopQuery.new(params)
  def query(_params), do: {:error, Error.new("VALIDATION_ERROR", "params must be a map")}
end
