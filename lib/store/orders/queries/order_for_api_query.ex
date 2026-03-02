defmodule Store.Orders.Queries.OrderForApiQuery do
  @moduledoc """
  Normalized query contract for API order reads.
  """

  alias Store.Support.Errors.Error

  @enforce_keys [:id]
  defstruct [:id]

  @type t :: %__MODULE__{id: String.t()}

  @allowed_keys MapSet.new(["id", :id])

  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(params) when is_map(params) do
    with :ok <- validate_keys(params),
         {:ok, id} <- validate_id(params) do
      {:ok, %__MODULE__{id: id}}
    end
  end

  def new(_params),
    do: {:error, Error.new("VALIDATION_ERROR", "params must be a map")}

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

  defp validate_id(params) do
    id = Map.get(params, :id) || Map.get(params, "id")

    case Ecto.UUID.cast(id) do
      {:ok, normalized} -> {:ok, normalized}
      :error -> {:error, Error.new("VALIDATION_ERROR", "id must be a valid UUID")}
    end
  end
end
