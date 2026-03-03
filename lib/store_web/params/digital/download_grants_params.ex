defmodule StoreWeb.Params.Digital.DownloadGrantsParams do
  @moduledoc """
  Params adapter for customer download-grant list query contracts.
  """

  alias Store.Digital.Queries.DownloadGrantIndexQuery
  alias Store.Support.Errors.Error

  @spec index_query(map()) :: {:ok, DownloadGrantIndexQuery.t()} | {:error, Error.t()}
  def index_query(params) when is_map(params), do: DownloadGrantIndexQuery.new(params)

  def index_query(_params), do: {:error, Error.new("VALIDATION_ERROR", "params must be a map")}
end
