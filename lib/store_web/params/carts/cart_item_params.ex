defmodule StoreWeb.Params.Carts.CartItemParams do
  @moduledoc """
  Params adapter for cart line mutation input.
  """

  alias Store.Carts.Inputs.CartItemInput
  alias Store.Support.Errors.Error

  @spec input(map()) :: {:ok, CartItemInput.t()} | {:error, Error.t()}
  def input(params) when is_map(params) do
    normalized =
      params
      |> Map.put_new_lazy("qty", fn ->
        Map.get(params, "quantity") || Map.get(params, :quantity)
      end)
      |> Map.take([
        "variant_id",
        :variant_id,
        "qty",
        :qty,
        "subscription_plan_id",
        :subscription_plan_id
      ])

    CartItemInput.new(normalized)
  end

  def input(_params), do: {:error, Error.new("VALIDATION_ERROR", "params must be a map")}
end
