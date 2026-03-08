defmodule Store.Subscriptions.Inputs.StartSubscriptionPaymentMethodUpdateInput do
  @moduledoc """
  Typed input for starting an inline subscription payment-method update flow.
  """

  alias Store.Support.Errors.Error

  @enforce_keys [:subscription_id]
  defstruct [:subscription_id]

  @type t :: %__MODULE__{subscription_id: Ecto.UUID.t()}

  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(params) when is_map(params) do
    case Map.get(params, :subscription_id) || Map.get(params, "subscription_id") do
      value when is_binary(value) ->
        case Ecto.UUID.cast(value) do
          {:ok, uuid} ->
            {:ok, %__MODULE__{subscription_id: uuid}}

          :error ->
            {:error, Error.new("VALIDATION_ERROR", "subscription_id must be a valid UUID")}
        end

      _ ->
        {:error, Error.new("VALIDATION_ERROR", "subscription_id must be a valid UUID")}
    end
  end

  def new(_params), do: {:error, Error.new("VALIDATION_ERROR", "params must be a map")}
end
