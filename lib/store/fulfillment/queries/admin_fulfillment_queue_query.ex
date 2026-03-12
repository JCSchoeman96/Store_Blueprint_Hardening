defmodule Store.Fulfillment.Queries.AdminFulfillmentQueueQuery do
  @moduledoc """
  Normalized query contract for admin fulfillment queue list reads.
  """

  alias Store.Support.Errors.Error

  @default_limit 20
  @min_limit 1
  @max_limit 100

  @allowed_keys MapSet.new([
                  "limit",
                  :limit,
                  "after",
                  :after,
                  "before",
                  :before,
                  "state",
                  :state
                ])

  @enforce_keys [:limit]
  defstruct [:limit, :after, :before, :state]

  @type t :: %__MODULE__{
          limit: pos_integer(),
          after: String.t() | nil,
          before: String.t() | nil,
          state: Store.Fulfillment.Types.FulfillmentOrderState.t() | nil
        }

  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(params) when is_map(params) do
    with :ok <- validate_keys(params),
         {:ok, limit} <- parse_limit(params),
         {:ok, after_cursor} <- parse_cursor(params, :after),
         {:ok, before_cursor} <- parse_cursor(params, :before),
         :ok <- validate_cursor_direction(after_cursor, before_cursor),
         {:ok, state} <- parse_state(params) do
      {:ok, %__MODULE__{limit: limit, after: after_cursor, before: before_cursor, state: state}}
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

  defp parse_cursor(params, key) do
    case Map.get(params, key) || Map.get(params, Atom.to_string(key)) do
      nil -> {:ok, nil}
      value when is_binary(value) -> validate_cursor(value, key)
      _ -> {:error, Error.new("VALIDATION_ERROR", "#{key} must be a string")}
    end
  end

  defp parse_state(params) do
    case Map.get(params, :state) || Map.get(params, "state") do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      value when is_atom(value) -> cast_state(value)
      value when is_binary(value) -> cast_state_string(value)
      _ -> {:error, Error.new("VALIDATION_ERROR", "state is invalid")}
    end
  end

  defp cast_state_string(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> case do
      "pending" -> {:ok, :pending}
      "packed" -> {:ok, :packed}
      "shipped" -> {:ok, :shipped}
      "delivered" -> {:ok, :delivered}
      "canceled" -> {:ok, :canceled}
      _ -> {:error, Error.new("VALIDATION_ERROR", "state is invalid")}
    end
  end

  defp cast_state(state) when state in [:pending, :packed, :shipped, :delivered, :canceled],
    do: {:ok, state}

  defp cast_state(_state), do: {:error, Error.new("VALIDATION_ERROR", "state is invalid")}

  defp validate_cursor(value, key) do
    trimmed = String.trim(value)

    if trimmed == "" do
      {:error, Error.new("VALIDATION_ERROR", "#{key} must not be blank")}
    else
      {:ok, trimmed}
    end
  end

  defp validate_cursor_direction(nil, nil), do: :ok
  defp validate_cursor_direction(_after_cursor, nil), do: :ok
  defp validate_cursor_direction(nil, _before_cursor), do: :ok

  defp validate_cursor_direction(_after_cursor, _before_cursor) do
    {:error, Error.new("VALIDATION_ERROR", "after and before are mutually exclusive")}
  end

  defp clamp_limit(limit) when limit < @min_limit, do: @min_limit
  defp clamp_limit(limit) when limit > @max_limit, do: @max_limit
  defp clamp_limit(limit), do: limit
end
