defmodule Store.Carts.Queries.CartLoadQuery do
  @moduledoc """
  Typed cart view query contract.
  """

  alias Store.Support.Errors.Error

  @allowed_keys MapSet.new(["include_items", :include_items])

  @enforce_keys [:include_items]
  defstruct include_items: true

  @type t :: %__MODULE__{include_items: boolean()}

  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(params) when is_map(params) do
    with :ok <- validate_keys(params),
         {:ok, include_items} <- parse_boolean(params, :include_items, true) do
      {:ok, %__MODULE__{include_items: include_items}}
    end
  end

  def new(_params), do: {:error, Error.new("VALIDATION_ERROR", "params must be a map")}

  defp validate_keys(params) do
    unknown =
      params
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(@allowed_keys, &1))

    case unknown do
      [] ->
        :ok

      _ ->
        {:error,
         Error.new(
           "VALIDATION_ERROR",
           "unknown params: #{Enum.map_join(unknown, ", ", &to_string/1)}"
         )}
    end
  end

  defp parse_boolean(params, key, default) do
    case Map.get(params, key) || Map.get(params, Atom.to_string(key)) do
      nil -> {:ok, default}
      true -> {:ok, true}
      false -> {:ok, false}
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      _ -> {:error, Error.new("VALIDATION_ERROR", "#{key} must be a boolean")}
    end
  end
end
