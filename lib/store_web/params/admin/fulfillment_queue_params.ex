defmodule StoreWeb.Params.Admin.FulfillmentQueueParams do
  @moduledoc """
  Params adapter for fulfillment admin queue list contracts.
  """

  alias Store.Fulfillment.Queries.AdminFulfillmentQueueQuery
  alias Store.Support.Errors.Error

  @spec index_query(map()) :: {:ok, AdminFulfillmentQueueQuery.t()} | {:error, Error.t()}
  def index_query(params) when is_map(params), do: AdminFulfillmentQueueQuery.new(params)

  def index_query(_params), do: {:error, Error.new("VALIDATION_ERROR", "params must be a map")}
end
