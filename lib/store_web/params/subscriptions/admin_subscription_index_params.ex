defmodule StoreWeb.Params.Subscriptions.AdminSubscriptionIndexParams do
  @moduledoc """
  Params adapter for admin subscription listing query contracts.
  """

  alias Store.Subscriptions.Queries.AdminSubscriptionIndexQuery
  alias Store.Support.Errors.Error

  @spec query(map()) :: {:ok, AdminSubscriptionIndexQuery.t()} | {:error, Error.t()}
  def query(params) when is_map(params), do: AdminSubscriptionIndexQuery.new(params)

  def query(_params), do: {:error, Error.new("VALIDATION_ERROR", "params must be a map")}
end
