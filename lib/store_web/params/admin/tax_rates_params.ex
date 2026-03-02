defmodule StoreWeb.Params.Admin.TaxRatesParams do
  @moduledoc """
  Params adapter for tax-rate admin list contracts.
  """

  alias Store.Pricing.Queries.AdminTaxRatesQuery
  alias Store.Support.Errors.Error

  @allowed_params ~w(limit)

  @spec index_query(map()) :: {:ok, AdminTaxRatesQuery.t()} | {:error, Error.t()}
  def index_query(params) when is_map(params) do
    params
    |> Map.take(@allowed_params)
    |> AdminTaxRatesQuery.new()
  end

  def index_query(_params), do: {:error, Error.new("VALIDATION_ERROR", "params must be a map")}
end
