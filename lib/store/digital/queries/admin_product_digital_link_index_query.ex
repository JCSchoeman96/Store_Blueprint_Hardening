defmodule Store.Digital.Queries.AdminProductDigitalLinkIndexQuery do
  @moduledoc """
  Typed query contract for admin product/variant digital-link listing.
  """

  alias Store.Support.Errors.Error

  @default_limit 50
  @min_limit 1
  @max_limit 200
  @default_offset 0
  @max_offset 10_000

  @allowed_keys MapSet.new([
                  "limit",
                  :limit,
                  "offset",
                  :offset,
                  "product_id",
                  :product_id,
                  "variant_id",
                  :variant_id,
                  "digital_asset_id",
                  :digital_asset_id
                ])

  @enforce_keys [:limit, :offset]
  defstruct [:limit, :offset, :product_id, :variant_id, :digital_asset_id]

  @type t :: %__MODULE__{
          limit: pos_integer(),
          offset: non_neg_integer(),
          product_id: Ecto.UUID.t() | nil,
          variant_id: Ecto.UUID.t() | nil,
          digital_asset_id: Ecto.UUID.t() | nil
        }

  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(params) when is_map(params) do
    with :ok <- validate_keys(params),
         {:ok, limit} <- parse_limit(params),
         {:ok, offset} <- parse_offset(params),
         {:ok, product_id} <- parse_uuid(params, :product_id),
         {:ok, variant_id} <- parse_uuid(params, :variant_id),
         {:ok, digital_asset_id} <- parse_uuid(params, :digital_asset_id) do
      {:ok,
       %__MODULE__{
         limit: limit,
         offset: offset,
         product_id: product_id,
         variant_id: variant_id,
         digital_asset_id: digital_asset_id
       }}
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

  defp parse_uuid(params, key) do
    case Map.get(params, key) || Map.get(params, Atom.to_string(key)) do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      value when is_binary(value) -> cast_uuid(value, key)
      _ -> {:error, Error.new("VALIDATION_ERROR", "#{key} must be a UUID")}
    end
  end

  defp cast_uuid(value, key) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, Error.new("VALIDATION_ERROR", "#{key} must be a UUID")}
    end
  end

  defp validate_offset(value) when value in 0..@max_offset, do: {:ok, value}

  defp validate_offset(_value),
    do: {:error, Error.new("VALIDATION_ERROR", "offset is out of range")}

  defp clamp_limit(limit) when limit < @min_limit, do: @min_limit
  defp clamp_limit(limit) when limit > @max_limit, do: @max_limit
  defp clamp_limit(limit), do: limit
end
