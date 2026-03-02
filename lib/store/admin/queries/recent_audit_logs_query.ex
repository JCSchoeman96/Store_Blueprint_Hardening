defmodule Store.Admin.Queries.RecentAuditLogsQuery do
  @moduledoc """
  Normalized query contract for bounded recent audit-log reads.
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
        keys = Enum.map_join(unknown_keys, ", ", &to_string/1)
        {:error, Error.new("VALIDATION_ERROR", "unknown params: #{keys}")}
    end
  end

  defp parse_limit(params) do
    case Map.get(params, :limit) || Map.get(params, "limit") do
      nil ->
        {:ok, @default_limit}

      value when is_integer(value) ->
        validate_range(value)

      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} -> validate_range(parsed)
          _ -> {:error, Error.new("VALIDATION_ERROR", limit_error_message())}
        end

      _other ->
        {:error, Error.new("VALIDATION_ERROR", limit_error_message())}
    end
  end

  defp validate_range(value) when value in @min_limit..@max_limit, do: {:ok, value}
  defp validate_range(_value), do: {:error, Error.new("VALIDATION_ERROR", limit_error_message())}

  defp limit_error_message do
    "limit must be an integer between #{@min_limit} and #{@max_limit}"
  end
end
