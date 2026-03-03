defmodule StoreWeb.Params.Admin.DigitalAssetsParams do
  @moduledoc """
  Params adapter for admin digital-asset list query contracts.
  """

  alias Store.Digital.Queries.AdminDigitalAssetIndexQuery
  alias Store.Support.Errors.Error

  @spec index_query(map()) :: {:ok, AdminDigitalAssetIndexQuery.t()} | {:error, Error.t()}
  def index_query(params) when is_map(params), do: AdminDigitalAssetIndexQuery.new(params)

  def index_query(_params), do: {:error, Error.new("VALIDATION_ERROR", "params must be a map")}
end
