defmodule StoreWeb.Params.Payments.PaymentIntentIndexParams do
  @moduledoc """
  Params adapter for payment-intent index query contracts.
  """

  alias Store.Payments.Queries.PaymentIntentIndexQuery
  alias Store.Support.Errors.Error

  @spec query(map()) :: {:ok, PaymentIntentIndexQuery.t()} | {:error, Error.t()}
  def query(params) when is_map(params), do: PaymentIntentIndexQuery.new(params)

  def query(_params), do: {:error, Error.new("VALIDATION_ERROR", "params must be a map")}
end
