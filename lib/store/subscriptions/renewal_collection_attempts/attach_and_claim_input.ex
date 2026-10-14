defmodule Store.Subscriptions.RenewalCollectionAttempts.AttachAndClaimInput do
  @moduledoc false

  alias Store.Support.Errors.Error

  @enforce_keys [
    :collection_attempt_id,
    :renewal_attempt_id,
    :subscription_id,
    :payment_intent_id,
    :expected_epoch,
    :now
  ]
  defstruct [
    :collection_attempt_id,
    :renewal_attempt_id,
    :subscription_id,
    :payment_intent_id,
    :expected_epoch,
    :now
  ]

  @type t :: %__MODULE__{
          collection_attempt_id: Ecto.UUID.t(),
          renewal_attempt_id: Ecto.UUID.t(),
          subscription_id: Ecto.UUID.t(),
          payment_intent_id: Ecto.UUID.t(),
          expected_epoch: pos_integer(),
          now: DateTime.t()
        }

  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(params) when is_map(params) do
    with {:ok, collection_attempt_id} <- required_uuid(params, :collection_attempt_id),
         {:ok, renewal_attempt_id} <- required_uuid(params, :renewal_attempt_id),
         {:ok, subscription_id} <- required_uuid(params, :subscription_id),
         {:ok, payment_intent_id} <- required_uuid(params, :payment_intent_id),
         {:ok, expected_epoch} <- required_epoch(params),
         {:ok, now} <- required_now(params) do
      {:ok,
       %__MODULE__{
         collection_attempt_id: collection_attempt_id,
         renewal_attempt_id: renewal_attempt_id,
         subscription_id: subscription_id,
         payment_intent_id: payment_intent_id,
         expected_epoch: expected_epoch,
         now: DateTime.truncate(now, :microsecond)
       }}
    end
  end

  def new(_params), do: invalid("typed collection attach and claim input is required")

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

  defp required_epoch(params) do
    case Map.get(params, :expected_epoch) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _ -> invalid("expected_epoch must be a positive integer")
    end
  end

  defp required_now(params) do
    case Map.get(params, :now) do
      %DateTime{} = now -> {:ok, now}
      _ -> invalid("now must be a DateTime")
    end
  end

  defp invalid(message), do: {:error, Error.new("VALIDATION_ERROR", message)}
end
