defmodule StoreWeb.Params.Entitlements.UserEntitlementIndexParams do
  @moduledoc """
  Params adapter for user entitlement listing query contracts.
  """

  alias Store.Entitlements.Queries.UserEntitlementIndexQuery
  alias Store.Support.Errors.Error

  @spec query(map()) :: {:ok, UserEntitlementIndexQuery.t()} | {:error, Error.t()}
  def query(params) when is_map(params), do: UserEntitlementIndexQuery.new(params)

  def query(_params), do: {:error, Error.new("VALIDATION_ERROR", "params must be a map")}
end
