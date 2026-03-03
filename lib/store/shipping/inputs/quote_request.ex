defmodule Store.Shipping.Inputs.QuoteRequest do
  @moduledoc """
  Typed request contract for shipping quote options.
  """

  alias Store.Support.Errors.Error

  @allowed_keys MapSet.new([
                  :destination_country_code,
                  "destination_country_code",
                  :destination_region_code,
                  "destination_region_code",
                  :destination_postal_code,
                  "destination_postal_code",
                  :currency_code,
                  "currency_code",
                  :shipping_weight_grams,
                  "shipping_weight_grams"
                ])

  @enforce_keys [:destination_country_code, :currency_code, :shipping_weight_grams]
  defstruct [
    :destination_country_code,
    :destination_region_code,
    :destination_postal_code,
    :currency_code,
    :shipping_weight_grams
  ]

  @type t :: %__MODULE__{
          destination_country_code: String.t(),
          destination_region_code: String.t() | nil,
          destination_postal_code: String.t() | nil,
          currency_code: String.t(),
          shipping_weight_grams: non_neg_integer()
        }

  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(params) when is_map(params) do
    with :ok <- validate_keys(params),
         {:ok, country_code} <- fetch_required_string(params, :destination_country_code),
         {:ok, currency_code} <- fetch_required_string(params, :currency_code),
         {:ok, shipping_weight_grams} <- fetch_non_negative_int(params, :shipping_weight_grams),
         {:ok, region_code} <- fetch_optional_string(params, :destination_region_code),
         {:ok, postal_code} <- fetch_optional_string(params, :destination_postal_code) do
      {:ok,
       %__MODULE__{
         destination_country_code: String.upcase(country_code),
         destination_region_code: upcase_or_nil(region_code),
         destination_postal_code: postal_code,
         currency_code: String.upcase(currency_code),
         shipping_weight_grams: shipping_weight_grams
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

  defp fetch_required_string(params, key) do
    value = Map.get(params, key) || Map.get(params, Atom.to_string(key))

    case value do
      str when is_binary(str) ->
        trimmed = String.trim(str)

        if trimmed == "",
          do: {:error, Error.new("VALIDATION_ERROR", "#{key} is required")},
          else: {:ok, trimmed}

      _ ->
        {:error, Error.new("VALIDATION_ERROR", "#{key} is required")}
    end
  end

  defp fetch_optional_string(params, key) do
    value = Map.get(params, key) || Map.get(params, Atom.to_string(key))

    case value do
      nil ->
        {:ok, nil}

      str when is_binary(str) ->
        trimmed = String.trim(str)
        if trimmed == "", do: {:ok, nil}, else: {:ok, trimmed}

      _ ->
        {:error, Error.new("VALIDATION_ERROR", "#{key} must be a string")}
    end
  end

  defp fetch_non_negative_int(params, key) do
    value = Map.get(params, key) || Map.get(params, Atom.to_string(key))

    case value do
      n when is_integer(n) and n >= 0 ->
        {:ok, n}

      str when is_binary(str) ->
        case Integer.parse(str) do
          {n, ""} when n >= 0 -> {:ok, n}
          _ -> {:error, Error.new("VALIDATION_ERROR", "#{key} must be a non-negative integer")}
        end

      _ ->
        {:error, Error.new("VALIDATION_ERROR", "#{key} must be a non-negative integer")}
    end
  end

  defp upcase_or_nil(nil), do: nil
  defp upcase_or_nil(value), do: String.upcase(value)
end
