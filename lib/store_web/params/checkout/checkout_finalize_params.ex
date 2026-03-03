defmodule StoreWeb.Params.Checkout.CheckoutFinalizeParams do
  @moduledoc """
  Params adapter for checkout totals finalization input.
  """

  alias Store.Checkout.Inputs.CheckoutFinalizeInput
  alias Store.Support.Errors.Error

  @spec input(map()) :: {:ok, CheckoutFinalizeInput.t()} | {:error, Error.t()}
  def input(params) when is_map(params), do: CheckoutFinalizeInput.new(params)
  def input(_params), do: {:error, Error.new("VALIDATION_ERROR", "params must be a map")}
end
