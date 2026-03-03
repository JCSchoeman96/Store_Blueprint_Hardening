defmodule Store.Shipping.Queries.AdminShippingMethodsQuery do
  @moduledoc """
  Normalized query contract for admin shipping-method list reads.
  """

  alias Store.Support.Errors.Error

  @default_limit 20
  @min_limit 1
  @max_limit 100
  @allowed_keys MapSet.new(["limit", :limit])

  @enforce_keys [:limit]
  defstruct [:limit]

  @type t :: %__MODULE__{limit: pos_integer()}

  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(params) when is_map(params) do
    with :ok <- validate_keys(params),
         {:ok, limit} <- parse_limit(params) do
      {:ok, %__MODULE__{limit: limit}}
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

  defp parse_limit(params) do
    case Map.get(params, :limit) || Map.get(params, "limit") do
      nil -> {:ok, @default_limit}
      value when is_integer(value) -> {:ok, clamp_limit(value)}
      value when is_binary(value) -> parse_limit_string(value)
      _ -> {:error, Error.new("VALIDATION_ERROR", "limit must be an integer")}
    end
  end

  defp parse_limit_string(value) do
    case Integer.parse(value) do
      {parsed, ""} -> {:ok, clamp_limit(parsed)}
      _ -> {:error, Error.new("VALIDATION_ERROR", "limit must be an integer")}
    end
  end

  defp clamp_limit(limit) when limit < @min_limit, do: @min_limit
  defp clamp_limit(limit) when limit > @max_limit, do: @max_limit
  defp clamp_limit(limit), do: limit
end
