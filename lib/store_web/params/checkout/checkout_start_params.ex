defmodule StoreWeb.Params.Checkout.CheckoutStartParams do
  @moduledoc """
  Params adapter for checkout start input.
  """

  alias Store.Checkout.Inputs.CheckoutStartInput
  alias Store.Support.Errors.Error

  @spec input(map()) :: {:ok, CheckoutStartInput.t()} | {:error, Error.t()}
  def input(params) when is_map(params), do: CheckoutStartInput.new(params)
  def input(_params), do: {:error, Error.new("VALIDATION_ERROR", "params must be a map")}
end
