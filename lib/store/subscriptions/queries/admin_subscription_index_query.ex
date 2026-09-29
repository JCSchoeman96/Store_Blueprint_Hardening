defmodule Store.Subscriptions.Queries.AdminSubscriptionIndexQuery do
  @moduledoc """
  Typed admin subscription listing query.
  """

  alias Store.Support.Errors.Error

  @allowed_keys MapSet.new([
                  "status",
                  :status,
                  "user_id",
                  :user_id,
                  "plan_key",
                  :plan_key,
                  "limit",
                  :limit,
                  "offset",
                  :offset
                ])
  @status_by_binary %{
    "pending" => :pending,
    "active" => :active,
    "past_due" => :past_due,
    "canceled" => :canceled,
    "expired" => :expired
  }

  @max_limit 200

  @enforce_keys [:status, :user_id, :plan_key, :limit, :offset]
  defstruct status: nil, user_id: nil, plan_key: nil, limit: 50, offset: 0

  @type t :: %__MODULE__{
          status: Store.Subscriptions.Types.SubscriptionStatus.t() | nil,
          user_id: Ecto.UUID.t() | nil,
          plan_key: String.t() | nil,
          limit: pos_integer(),
          offset: non_neg_integer()
        }

  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(params) when is_map(params) do
    with :ok <- validate_keys(params),
         {:ok, status} <- parse_optional_status(params),
         {:ok, user_id} <- parse_optional_uuid(params, :user_id),
         {:ok, plan_key} <- parse_optional_string(params, :plan_key),
         {:ok, limit} <- parse_limit(params),
         {:ok, offset} <- parse_offset(params) do
      {:ok,
       %__MODULE__{
         status: status,
         user_id: user_id,
         plan_key: plan_key,
         limit: limit,
         offset: offset
       }}
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

  defp parse_optional_status(params) do
    case Map.get(params, :status) || Map.get(params, "status") do
      nil ->
        {:ok, nil}

      "" ->
        {:ok, nil}

      value when is_atom(value) ->
        validate_status(value)

      value when is_binary(value) ->
        value
        |> String.trim()
        |> String.downcase()
        |> parse_status_binary()

      _ ->
        {:error, Error.new("VALIDATION_ERROR", "status is invalid")}
    end
  rescue
    ArgumentError ->
      {:error, Error.new("VALIDATION_ERROR", "status is invalid")}
  end

  defp validate_status(status)
       when status in [:pending, :active, :past_due, :canceled, :expired],
       do: {:ok, status}

  defp validate_status(_status), do: {:error, Error.new("VALIDATION_ERROR", "status is invalid")}

  defp parse_status_binary(value) do
    case Map.fetch(@status_by_binary, value) do
      {:ok, status} -> {:ok, status}
      :error -> validate_status(nil)
    end
  end

  defp parse_optional_uuid(params, key) do
    value = Map.get(params, key) || Map.get(params, Atom.to_string(key))

    case value do
      nil ->
        {:ok, nil}

      "" ->
        {:ok, nil}

      binary when is_binary(binary) ->
        case Ecto.UUID.cast(binary) do
          {:ok, uuid} -> {:ok, uuid}
          :error -> {:error, Error.new("VALIDATION_ERROR", "#{key} must be a valid UUID")}
        end

      _ ->
        {:error, Error.new("VALIDATION_ERROR", "#{key} must be a valid UUID")}
    end
  end

  defp parse_optional_string(params, key) do
    value = Map.get(params, key) || Map.get(params, Atom.to_string(key))

    case value do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      binary when is_binary(binary) -> {:ok, String.trim(binary)}
      _ -> {:error, Error.new("VALIDATION_ERROR", "#{key} must be a string")}
    end
  end

  defp parse_limit(params) do
    params
    |> fetch_int(:limit, 50)
    |> validate_int_range(1, @max_limit, "limit")
  end

  defp parse_offset(params) do
    params
    |> fetch_int(:offset, 0)
    |> validate_int_range(0, 1_000_000, "offset")
  end

  defp fetch_int(params, key, default) do
    case Map.get(params, key) || Map.get(params, Atom.to_string(key)) do
      nil ->
        {:ok, default}

      value when is_integer(value) ->
        {:ok, value}

      value when is_binary(value) ->
        parse_int(value)

      _ ->
        {:error, Error.new("VALIDATION_ERROR", "#{key} must be an integer")}
    end
  end

  defp parse_int(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> {:ok, parsed}
      _ -> {:error, Error.new("VALIDATION_ERROR", "value must be an integer")}
    end
  end

  defp validate_int_range({:ok, value}, min, max, _key) when value >= min and value <= max,
    do: {:ok, value}

  defp validate_int_range({:ok, _value}, _min, _max, key),
    do: {:error, Error.new("VALIDATION_ERROR", "#{key} is out of range")}

  defp validate_int_range({:error, _} = error, _min, _max, _key), do: error
end
