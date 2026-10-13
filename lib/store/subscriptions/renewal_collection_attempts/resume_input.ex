defmodule Store.Subscriptions.RenewalCollectionAttempts.ResumeInput do
  @moduledoc "Typed system input for resuming a fenced collection at its next epoch."

  alias Store.Support.Errors.Error

  @enforce_keys [:collection_attempt_id, :expected_epoch, :now]
  defstruct [:collection_attempt_id, :expected_epoch, :now]

  @type t :: %__MODULE__{
          collection_attempt_id: Ecto.UUID.t(),
          expected_epoch: pos_integer(),
          now: DateTime.t()
        }

  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(params) when is_map(params) do
    with {:ok, collection_attempt_id} <- parse_uuid(params),
         {:ok, expected_epoch} <- parse_epoch(params),
         {:ok, now} <- parse_now(params) do
      {:ok,
       %__MODULE__{
         collection_attempt_id: collection_attempt_id,
         expected_epoch: expected_epoch,
         now: DateTime.truncate(now, :microsecond)
       }}
    end
  end

  def new(_params),
    do: {:error, Error.new("VALIDATION_ERROR", "resume input must be a map")}

  defp parse_uuid(params) do
    case value(params, :collection_attempt_id) do
      raw when is_binary(raw) ->
        case Ecto.UUID.cast(raw) do
          {:ok, uuid} -> {:ok, uuid}
          :error -> invalid("collection_attempt_id must be a valid UUID")
        end

      _ ->
        invalid("collection_attempt_id must be a valid UUID")
    end
  end

  defp parse_epoch(params) do
    case value(params, :expected_epoch) do
      epoch when is_integer(epoch) and epoch > 0 -> {:ok, epoch}
      _ -> invalid("expected_epoch must be a positive integer")
    end
  end

  defp parse_now(params) do
    case value(params, :now) do
      %DateTime{} = now -> {:ok, now}
      _ -> invalid("now must be a DateTime")
    end
  end

  defp value(params, key), do: Map.get(params, key) || Map.get(params, Atom.to_string(key))
  defp invalid(message), do: {:error, Error.new("VALIDATION_ERROR", message)}
end
