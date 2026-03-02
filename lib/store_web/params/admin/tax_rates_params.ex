defmodule StoreWeb.Params.Admin.TaxRatesParams do
  @moduledoc """
  Params adapter for tax-rate admin list contracts.
  """

  alias Store.Pricing.Queries.AdminTaxRatesQuery
  alias Store.Support.Errors.Error

  @spec index_query(map()) :: {:ok, AdminTaxRatesQuery.t()} | {:error, Error.t()}
  def index_query(params) when is_map(params), do: AdminTaxRatesQuery.new(params)

  def index_query(_params), do: {:error, Error.new("VALIDATION_ERROR", "params must be a map")}
end
