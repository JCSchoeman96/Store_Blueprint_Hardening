defmodule StoreWeb.Params.Payments.CreateIntentForOrderParams do
  @moduledoc """
  Params adapter for create-intent-for-order input.
  """

  alias Store.Payments.Inputs.CreateIntentForOrderInput
  alias Store.Support.Errors.Error

  @spec input(map()) :: {:ok, CreateIntentForOrderInput.t()} | {:error, Error.t()}
  def input(params) when is_map(params), do: CreateIntentForOrderInput.new(params)
  def input(_params), do: {:error, Error.new("VALIDATION_ERROR", "params must be a map")}
end
