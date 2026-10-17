defmodule Store.Payments.Inputs.ValidateRenewalCollectionOutcomeInput do
  @moduledoc false

  alias Store.Support.Errors.Error

  @outcomes [
    :requires_action,
    :verified_success,
    :verified_terminal_financial_non_success
  ]

  @enforce_keys [:payment_attempt_id, :payment_intent_id, :financial_outcome]
  defstruct [:payment_attempt_id, :payment_intent_id, :financial_outcome]

  @type t :: %__MODULE__{
          payment_attempt_id: Ecto.UUID.t(),
          payment_intent_id: Ecto.UUID.t(),
          financial_outcome: atom()
        }

  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(params) when is_map(params) do
    with {:ok, payment_attempt_id} <- required_uuid(params, :payment_attempt_id),
         {:ok, payment_intent_id} <- required_uuid(params, :payment_intent_id),
         {:ok, financial_outcome} <- required_outcome(params) do
      {:ok,
       %__MODULE__{
         payment_attempt_id: payment_attempt_id,
         payment_intent_id: payment_intent_id,
         financial_outcome: financial_outcome
       }}
    end
  end

  def new(_params), do: invalid("typed renewal collection outcome identity is required")

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

  defp required_outcome(params) do
    case Map.get(params, :financial_outcome) do
      outcome when outcome in @outcomes -> {:ok, outcome}
      _ -> invalid("financial_outcome must be a certified collection outcome")
    end
  end

  defp invalid(message), do: {:error, Error.new("VALIDATION_ERROR", message)}
end
