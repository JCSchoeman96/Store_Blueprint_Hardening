defmodule Store.Subscriptions.RenewalCollectionAttempts.StartInput do
  @moduledoc """
  Typed system input for starting or replaying one renewal collection.
  """

  alias Store.Support.Errors.Error

  @enforce_keys [:renewal_attempt_id, :now]
  defstruct [:renewal_attempt_id, :now]

  @type t :: %__MODULE__{
          renewal_attempt_id: Ecto.UUID.t(),
          now: DateTime.t()
        }

  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(params) when is_map(params) do
    with {:ok, renewal_attempt_id} <- parse_uuid(params),
         {:ok, now} <- parse_now(params) do
      {:ok,
       %__MODULE__{
         renewal_attempt_id: renewal_attempt_id,
         now: DateTime.truncate(now, :microsecond)
       }}
    end
  end

  def new(_params),
    do: {:error, Error.new("VALIDATION_ERROR", "renewal collection input must be a map")}

  defp parse_uuid(params) do
    case value(params, :renewal_attempt_id) do
      raw when is_binary(raw) ->
        case Ecto.UUID.cast(raw) do
          {:ok, uuid} -> {:ok, uuid}
          :error -> invalid("renewal_attempt_id must be a valid UUID")
        end

      _ ->
        invalid("renewal_attempt_id must be a valid UUID")
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
