defmodule Store.Subscriptions.RenewalCollectionAttempts.CancellationReservationInput do
  @moduledoc false

  alias Store.Support.Errors.Error

  @enforce_keys [:renewal_attempt_id]
  defstruct [:renewal_attempt_id]

  @type t :: %__MODULE__{renewal_attempt_id: Ecto.UUID.t()}

  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(params) when is_map(params) do
    case Map.get(params, :renewal_attempt_id) do
      value when is_binary(value) ->
        case Ecto.UUID.cast(value) do
          {:ok, uuid} -> {:ok, %__MODULE__{renewal_attempt_id: uuid}}
          :error -> invalid("renewal_attempt_id must be a valid UUID")
        end

      _ ->
        invalid("renewal_attempt_id must be a valid UUID")
    end
  end

  def new(_params), do: invalid("cancellation reservation input must be a map")

  defp invalid(message), do: {:error, Error.new("VALIDATION_ERROR", message)}
end
