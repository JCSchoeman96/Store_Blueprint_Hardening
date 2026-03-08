defmodule StoreWeb.Params.Subscriptions.QueueSubscriptionVariantChangeParams do
  @moduledoc """
  Params adapter for queued subscription variant changes.
  """

  alias Store.Subscriptions.Inputs.QueueSubscriptionVariantChangeInput
  alias Store.Support.Errors.Error

  @spec input(map()) :: {:ok, QueueSubscriptionVariantChangeInput.t()} | {:error, Error.t()}
  def input(params) when is_map(params), do: QueueSubscriptionVariantChangeInput.new(params)

  def input(_params), do: {:error, Error.new("VALIDATION_ERROR", "params must be a map")}
end
