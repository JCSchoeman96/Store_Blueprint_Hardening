defmodule Store.Fulfillment.Queries.AdminFulfillmentShowQuery do
  @moduledoc """
  Normalized query contract for admin fulfillment order show reads.
  """

  alias Store.Support.Errors.Error

  @allowed_keys MapSet.new(["id", :id])

  @enforce_keys [:id]
  defstruct [:id]

  @type t :: %__MODULE__{id: Ecto.UUID.t()}

  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(params) when is_map(params) do
    with :ok <- validate_keys(params),
         {:ok, id} <- parse_id(params) do
      {:ok, %__MODULE__{id: id}}
    end
  end

  def new(_params), do: {:error, Error.new("VALIDATION_ERROR", "params must be a map")}

  defp validate_keys(params) do
    unknown_keys =
      params
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(@allowed_keys, &1))

    case unknown_keys do
      [] ->
        :ok

      _ ->
        {:error,
         Error.new(
           "VALIDATION_ERROR",
           "unknown params: #{Enum.map_join(unknown_keys, ", ", &to_string/1)}"
         )}
    end
  end

  defp parse_id(params) do
    case Map.get(params, :id) || Map.get(params, "id") do
      value when is_binary(value) ->
        case Ecto.UUID.cast(value) do
          {:ok, id} -> {:ok, id}
          :error -> {:error, Error.new("VALIDATION_ERROR", "id must be a valid UUID")}
        end

      _ ->
        {:error, Error.new("VALIDATION_ERROR", "id is required")}
    end
  end
end
