defmodule Store.Subscriptions.Inputs.QueueSubscriptionPlanChangeInput do
  @moduledoc """
  Typed boundary-change input for queueing a subscription plan change.
  """

  alias Store.Support.Errors.Error

  @enforce_keys [:subscription_id, :subscription_plan_id]
  defstruct [:subscription_id, :subscription_plan_id]

  @type t :: %__MODULE__{
          subscription_id: Ecto.UUID.t(),
          subscription_plan_id: Ecto.UUID.t()
        }

  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(params) when is_map(params) do
    with {:ok, subscription_id} <- parse_uuid(params, :subscription_id),
         {:ok, subscription_plan_id} <- parse_uuid(params, :subscription_plan_id) do
      {:ok,
       %__MODULE__{
         subscription_id: subscription_id,
         subscription_plan_id: subscription_plan_id
       }}
    end
  end

  def new(_params), do: {:error, Error.new("VALIDATION_ERROR", "params must be a map")}

  defp parse_uuid(params, key) do
    case Map.get(params, key) || Map.get(params, Atom.to_string(key)) do
      value when is_binary(value) ->
        case Ecto.UUID.cast(value) do
          {:ok, uuid} -> {:ok, uuid}
          :error -> {:error, Error.new("VALIDATION_ERROR", "#{key} must be a valid UUID")}
        end

      _ ->
        {:error, Error.new("VALIDATION_ERROR", "#{key} must be a valid UUID")}
    end
  end
end
