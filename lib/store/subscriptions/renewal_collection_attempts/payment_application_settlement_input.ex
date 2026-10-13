defmodule Store.Subscriptions.RenewalCollectionAttempts.PaymentApplicationSettlementInput do
  @moduledoc false

  alias Store.Support.Errors.Error

  @enforce_keys [:collection_attempt_id, :order_id, :renewal_attempt_id, :payment_intent_id]
  defstruct [:collection_attempt_id, :order_id, :renewal_attempt_id, :payment_intent_id]

  @type t :: %__MODULE__{
          collection_attempt_id: Ecto.UUID.t(),
          order_id: Ecto.UUID.t(),
          renewal_attempt_id: Ecto.UUID.t(),
          payment_intent_id: Ecto.UUID.t()
        }

  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(params) when is_map(params) do
    with {:ok, collection_attempt_id} <- required_uuid(params, :collection_attempt_id),
         {:ok, order_id} <- required_uuid(params, :order_id),
         {:ok, renewal_attempt_id} <- required_uuid(params, :renewal_attempt_id),
         {:ok, payment_intent_id} <- required_uuid(params, :payment_intent_id) do
      {:ok,
       %__MODULE__{
         collection_attempt_id: collection_attempt_id,
         order_id: order_id,
         renewal_attempt_id: renewal_attempt_id,
         payment_intent_id: payment_intent_id
       }}
    end
  end

  def new(_params), do: invalid("exact collection settlement identity is required")

  defp required_uuid(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) ->
        case Ecto.UUID.cast(value) do
          {:ok, uuid} -> {:ok, uuid}
          :error -> invalid("#{key} must be a valid UUID")
        end

      _ ->
        invalid("#{key} must be a valid UUID")
    end
  end

  defp invalid(message), do: {:error, Error.new("VALIDATION_ERROR", message)}
end
