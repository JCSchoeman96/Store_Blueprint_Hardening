defmodule StoreWeb.Params.Catalog.ProductIndexParams do
  @moduledoc """
  Params adapter for storefront catalog product index query contract.
  """

  alias Store.Catalog.Queries.ProductIndexQuery
  alias Store.Support.Errors.Error

  @spec index_query(map()) :: {:ok, ProductIndexQuery.t()} | {:error, Error.t()}
  def index_query(params) when is_map(params), do: ProductIndexQuery.new(params)
  def index_query(_params), do: {:error, Error.new("VALIDATION_ERROR", "params must be a map")}
end
