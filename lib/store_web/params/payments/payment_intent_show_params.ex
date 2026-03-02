defmodule StoreWeb.Params.Payments.PaymentIntentShowParams do
  @moduledoc """
  Params adapter for payment-intent show/get query contracts.
  """

  alias Store.Payments.Queries.PaymentIntentShowQuery
  alias Store.Support.Errors.Error

  @spec query(map()) :: {:ok, PaymentIntentShowQuery.t()} | {:error, Error.t()}
  def query(params) when is_map(params), do: PaymentIntentShowQuery.new(params)

  def query(_params), do: {:error, Error.new("VALIDATION_ERROR", "params must be a map")}
end
