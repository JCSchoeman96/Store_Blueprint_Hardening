defmodule Store.Digital.Queries.DownloadGrantIndexQuery do
  @moduledoc """
  Typed query contract for customer download-grant listing.
  """

  alias Store.Support.Errors.Error

  @default_limit 20
  @min_limit 1
  @max_limit 100
  @default_offset 0
  @max_offset 10_000

  @allowed_keys MapSet.new([
                  "limit",
                  :limit,
                  "offset",
                  :offset,
                  "status",
                  :status
                ])

  @enforce_keys [:limit, :offset]
  defstruct [:limit, :offset, :status]

  @type t :: %__MODULE__{
          limit: pos_integer(),
          offset: non_neg_integer(),
          status: :active | :revoked | :expired | nil
        }

  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(params) when is_map(params) do
    with :ok <- validate_keys(params),
         {:ok, limit} <- parse_limit(params),
         {:ok, offset} <- parse_offset(params),
         {:ok, status} <- parse_status(params) do
      {:ok, %__MODULE__{limit: limit, offset: offset, status: status}}
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

  defp parse_offset(params) do
    case Map.get(params, :offset) || Map.get(params, "offset") do
      nil -> {:ok, @default_offset}
      value when is_integer(value) -> validate_offset(value)
      value when is_binary(value) -> parse_offset_string(value)
      _ -> {:error, Error.new("VALIDATION_ERROR", "offset must be an integer")}
    end
  end

  defp parse_offset_string(value) do
    case Integer.parse(value) do
      {parsed, ""} -> validate_offset(parsed)
      _ -> {:error, Error.new("VALIDATION_ERROR", "offset must be an integer")}
    end
  end

  defp parse_status(params) do
    case normalize_status(Map.get(params, :status) || Map.get(params, "status")) do
      {:ok, status} ->
        {:ok, status}

      :error ->
        {:error, Error.new("VALIDATION_ERROR", "status is invalid")}
    end
  end

  defp normalize_status(nil), do: {:ok, nil}
  defp normalize_status(""), do: {:ok, nil}
  defp normalize_status(:active), do: {:ok, :active}
  defp normalize_status(:revoked), do: {:ok, :revoked}
  defp normalize_status(:expired), do: {:ok, :expired}
  defp normalize_status("active"), do: {:ok, :active}
  defp normalize_status("revoked"), do: {:ok, :revoked}
  defp normalize_status("expired"), do: {:ok, :expired}
  defp normalize_status(_value), do: :error

  defp validate_offset(value) when value in 0..@max_offset, do: {:ok, value}

  defp validate_offset(_value),
    do: {:error, Error.new("VALIDATION_ERROR", "offset is out of range")}

  defp clamp_limit(limit) when limit < @min_limit, do: @min_limit
  defp clamp_limit(limit) when limit > @max_limit, do: @max_limit
  defp clamp_limit(limit), do: limit
end
