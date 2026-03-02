defmodule StoreWeb.Params.Catalog.ProductAdminIndexParams do
  @moduledoc """
  Params adapter for admin catalog product index query contract.
  """

  alias Store.Catalog.Queries.ProductAdminIndexQuery
  alias Store.Support.Errors.Error

  @spec index_query(map()) :: {:ok, ProductAdminIndexQuery.t()} | {:error, Error.t()}
  def index_query(params) when is_map(params), do: ProductAdminIndexQuery.new(params)

  def index_query(_params), do: {:error, Error.new("VALIDATION_ERROR", "params must be a map")}
end
