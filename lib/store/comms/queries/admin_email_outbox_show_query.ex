defmodule Store.Comms.Queries.AdminEmailOutboxShowQuery do
  @moduledoc """
  Typed query contract for admin single outbox reads.
  """

  alias Store.Support.Errors.Error

  @enforce_keys [:id]
  defstruct [:id]

  @type t :: %__MODULE__{id: Ecto.UUID.t()}

  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(params) when is_map(params) do
    id = Map.get(params, :id) || Map.get(params, "id")

    if is_binary(id) and id != "" do
      {:ok, %__MODULE__{id: id}}
    else
      {:error, Error.new("VALIDATION_ERROR", "id is required")}
    end
  end

  def new(_params), do: {:error, Error.new("VALIDATION_ERROR", "params must be a map")}
end
