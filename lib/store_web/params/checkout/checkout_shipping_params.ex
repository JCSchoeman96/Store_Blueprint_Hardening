defmodule StoreWeb.Params.Checkout.CheckoutShippingParams do
  @moduledoc """
  Params adapter for checkout shipping input.
  """

  alias Store.Checkout.Inputs.CheckoutShippingInput
  alias Store.Support.Errors.Error

  @spec input(map()) :: {:ok, CheckoutShippingInput.t()} | {:error, Error.t()}
  def input(params) when is_map(params), do: CheckoutShippingInput.new(params)
  def input(_params), do: {:error, Error.new("VALIDATION_ERROR", "params must be a map")}
end
