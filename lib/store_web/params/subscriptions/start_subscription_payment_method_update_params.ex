defmodule StoreWeb.Params.Subscriptions.StartSubscriptionPaymentMethodUpdateParams do
  @moduledoc """
  Params adapter for starting a subscription payment-method update flow.
  """

  alias Store.Subscriptions.Inputs.StartSubscriptionPaymentMethodUpdateInput
  alias Store.Support.Errors.Error

  @spec input(map()) ::
          {:ok, StartSubscriptionPaymentMethodUpdateInput.t()} | {:error, Error.t()}
  def input(params) when is_map(params), do: StartSubscriptionPaymentMethodUpdateInput.new(params)

  def input(_params), do: {:error, Error.new("VALIDATION_ERROR", "params must be a map")}
end
