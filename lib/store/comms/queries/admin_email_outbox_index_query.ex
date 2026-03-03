defmodule Store.Comms.Queries.AdminEmailOutboxIndexQuery do
  @moduledoc """
  Normalized query contract for admin outbox list reads.
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
                  "state",
                  :state,
                  "template_kind",
                  :template_kind
                ])

  @enforce_keys [:limit, :offset]
  defstruct [:limit, :offset, :state, :template_kind]

  @type t :: %__MODULE__{
          limit: pos_integer(),
          offset: non_neg_integer(),
          state: Store.Comms.Types.EmailOutboxState.t() | nil,
          template_kind: Store.Comms.Types.EmailTemplateKind.t() | nil
        }

  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(params) when is_map(params) do
    with :ok <- validate_keys(params),
         {:ok, limit} <- parse_limit(params),
         {:ok, offset} <- parse_offset(params),
         {:ok, state} <- parse_state(params),
         {:ok, template_kind} <- parse_template_kind(params) do
      {:ok, %__MODULE__{limit: limit, offset: offset, state: state, template_kind: template_kind}}
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
      "processing" -> {:ok, :processing}
      "sent" -> {:ok, :sent}
      "failed" -> {:ok, :failed}
      _ -> {:error, Error.new("VALIDATION_ERROR", "state is invalid")}
    end
  end

  defp cast_state(state) when state in [:pending, :processing, :sent, :failed], do: {:ok, state}
  defp cast_state(_state), do: {:error, Error.new("VALIDATION_ERROR", "state is invalid")}

  defp parse_template_kind(params) do
    case Map.get(params, :template_kind) || Map.get(params, "template_kind") do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      value when is_atom(value) -> cast_template_kind(value)
      value when is_binary(value) -> cast_template_kind_string(value)
      _ -> {:error, Error.new("VALIDATION_ERROR", "template_kind is invalid")}
    end
  end

  defp cast_template_kind_string(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> case do
      "order_receipt" -> {:ok, :order_receipt}
      "refund_requested" -> {:ok, :refund_requested}
      "refund_processed" -> {:ok, :refund_processed}
      _ -> {:error, Error.new("VALIDATION_ERROR", "template_kind is invalid")}
    end
  end

  defp cast_template_kind(kind)
       when kind in [:order_receipt, :refund_requested, :refund_processed],
       do: {:ok, kind}

  defp cast_template_kind(_kind),
    do: {:error, Error.new("VALIDATION_ERROR", "template_kind is invalid")}

  defp validate_offset(value) when value in 0..@max_offset, do: {:ok, value}

  defp validate_offset(_value),
    do: {:error, Error.new("VALIDATION_ERROR", "offset is out of range")}

  defp clamp_limit(limit) when limit < @min_limit, do: @min_limit
  defp clamp_limit(limit) when limit > @max_limit, do: @max_limit
  defp clamp_limit(limit), do: limit
end
