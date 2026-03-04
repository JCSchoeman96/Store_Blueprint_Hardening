defmodule StoreWeb.Params.Subscriptions.UserSubscriptionIndexParams do
  @moduledoc """
  Params adapter for user subscription listing query contracts.
  """

  alias Store.Subscriptions.Queries.UserSubscriptionIndexQuery
  alias Store.Support.Errors.Error

  @spec query(map()) :: {:ok, UserSubscriptionIndexQuery.t()} | {:error, Error.t()}
  def query(params) when is_map(params), do: UserSubscriptionIndexQuery.new(params)

  def query(_params), do: {:error, Error.new("VALIDATION_ERROR", "params must be a map")}
end
