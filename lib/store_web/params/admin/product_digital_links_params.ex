defmodule StoreWeb.Params.Admin.ProductDigitalLinksParams do
  @moduledoc """
  Params adapter for admin product/variant digital-link list query contracts.
  """

  alias Store.Digital.Queries.AdminProductDigitalLinkIndexQuery
  alias Store.Support.Errors.Error

  @spec index_query(map()) :: {:ok, AdminProductDigitalLinkIndexQuery.t()} | {:error, Error.t()}
  def index_query(params) when is_map(params), do: AdminProductDigitalLinkIndexQuery.new(params)

  def index_query(_params), do: {:error, Error.new("VALIDATION_ERROR", "params must be a map")}
end
