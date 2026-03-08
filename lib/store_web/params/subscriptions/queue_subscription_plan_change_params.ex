defmodule StoreWeb.Params.Subscriptions.QueueSubscriptionPlanChangeParams do
  @moduledoc """
  Params adapter for queued subscription plan changes.
  """

  alias Store.Subscriptions.Inputs.QueueSubscriptionPlanChangeInput
  alias Store.Support.Errors.Error

  @spec input(map()) :: {:ok, QueueSubscriptionPlanChangeInput.t()} | {:error, Error.t()}
  def input(params) when is_map(params), do: QueueSubscriptionPlanChangeInput.new(params)

  def input(_params), do: {:error, Error.new("VALIDATION_ERROR", "params must be a map")}
end
