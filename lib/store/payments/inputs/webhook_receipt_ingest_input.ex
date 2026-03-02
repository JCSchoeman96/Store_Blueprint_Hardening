defmodule Store.Payments.Inputs.WebhookReceiptIngestInput do
  @moduledoc """
  Typed input contract for webhook receipt ingest operations.
  """

  alias Store.Support.Errors.Error

  @allowed_keys MapSet.new([
                  "provider",
                  :provider,
                  "raw_body",
                  :raw_body,
                  "headers",
                  :headers,
                  "idempotency_key",
                  :idempotency_key,
                  "payload_sha256",
                  :payload_sha256,
                  "received_at",
                  :received_at
                ])

  @enforce_keys [:provider, :raw_body, :headers]
  defstruct [:provider, :raw_body, :headers, :idempotency_key, :payload_sha256, :received_at]

  @type t :: %__MODULE__{
          provider: String.t(),
          raw_body: String.t(),
          headers: map(),
          idempotency_key: String.t() | nil,
          payload_sha256: String.t() | nil,
          received_at: DateTime.t() | nil
        }

  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(params) when is_map(params) do
    with :ok <- validate_keys(params),
         {:ok, provider} <- parse_required_string(params, :provider),
         {:ok, raw_body} <- parse_required_string(params, :raw_body),
         {:ok, headers} <- parse_headers(params),
         {:ok, idempotency_key} <- parse_optional_string(params, :idempotency_key),
         {:ok, payload_sha256} <- parse_optional_string(params, :payload_sha256),
         {:ok, received_at} <- parse_optional_datetime(params, :received_at) do
      {:ok,
       %__MODULE__{
         provider: provider,
         raw_body: raw_body,
         headers: headers,
         idempotency_key: idempotency_key,
         payload_sha256: payload_sha256,
         received_at: received_at
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

  defp parse_required_string(params, key) do
    case Map.get(params, key) || Map.get(params, Atom.to_string(key)) do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      _ ->
        {:error, Error.new("VALIDATION_ERROR", "#{key} is required")}
    end
  end

  defp parse_optional_string(params, key) do
    case Map.get(params, key) || Map.get(params, Atom.to_string(key)) do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, Error.new("VALIDATION_ERROR", "#{key} must be a string")}
    end
  end

  defp parse_headers(params) do
    case Map.get(params, :headers) || Map.get(params, "headers") do
      value when is_map(value) -> {:ok, value}
      _ -> {:error, Error.new("VALIDATION_ERROR", "headers must be a map")}
    end
  end

  defp parse_optional_datetime(params, key) do
    case Map.get(params, key) || Map.get(params, Atom.to_string(key)) do
      nil ->
        {:ok, nil}

      %DateTime{} = datetime ->
        {:ok, datetime}

      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} -> {:ok, datetime}
          _ -> {:error, Error.new("VALIDATION_ERROR", "#{key} must be ISO8601")}
        end

      _ ->
        {:error, Error.new("VALIDATION_ERROR", "#{key} must be a datetime")}
    end
  end
end
