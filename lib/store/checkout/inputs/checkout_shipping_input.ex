defmodule Store.Checkout.Inputs.CheckoutShippingInput do
  @moduledoc """
  Typed shipping input contract for checkout.
  """

  alias Store.Support.Errors.Error

  @allowed_keys MapSet.new([
                  :recipient_name,
                  "recipient_name",
                  :address_line1,
                  "address_line1",
                  :address_line2,
                  "address_line2",
                  :city,
                  "city",
                  :country_code,
                  "country_code",
                  :region_code,
                  "region_code",
                  :postal_code,
                  "postal_code",
                  :phone,
                  "phone",
                  :quote_hash,
                  "quote_hash",
                  :shipping_method_code,
                  "shipping_method_code"
                ])

  @enforce_keys [
    :address_line1,
    :city,
    :country_code,
    :region_code,
    :postal_code,
    :quote_hash,
    :shipping_method_code
  ]
  defstruct [
    :recipient_name,
    :address_line1,
    :address_line2,
    :city,
    :country_code,
    :region_code,
    :postal_code,
    :phone,
    :quote_hash,
    :shipping_method_code
  ]

  @type t :: %__MODULE__{
          recipient_name: String.t() | nil,
          address_line1: String.t(),
          address_line2: String.t() | nil,
          city: String.t(),
          country_code: String.t(),
          region_code: String.t(),
          postal_code: String.t(),
          phone: String.t() | nil,
          quote_hash: String.t(),
          shipping_method_code: String.t()
        }

  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(params) when is_map(params) do
    with :ok <- validate_keys(params),
         {:ok, address_line1} <- fetch_required(params, :address_line1),
         {:ok, city} <- fetch_required(params, :city),
         {:ok, country_code} <- fetch_required(params, :country_code),
         {:ok, region_code} <- fetch_required(params, :region_code),
         {:ok, postal_code} <- fetch_required(params, :postal_code),
         {:ok, quote_hash} <- fetch_required(params, :quote_hash),
         {:ok, shipping_method_code} <- fetch_required(params, :shipping_method_code),
         {:ok, recipient_name} <- fetch_optional(params, :recipient_name),
         {:ok, address_line2} <- fetch_optional(params, :address_line2),
         {:ok, phone} <- fetch_optional(params, :phone) do
      {:ok,
       %__MODULE__{
         recipient_name: recipient_name,
         address_line1: address_line1,
         address_line2: address_line2,
         city: city,
         country_code: String.upcase(country_code),
         region_code: String.upcase(region_code),
         postal_code: postal_code,
         phone: phone,
         quote_hash: String.trim(quote_hash),
         shipping_method_code: String.upcase(String.trim(shipping_method_code))
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

  defp fetch_required(params, key) do
    value = Map.get(params, key) || Map.get(params, Atom.to_string(key))

    case value do
      string when is_binary(string) ->
        trimmed = String.trim(string)

        if trimmed == "" do
          {:error, Error.new("VALIDATION_ERROR", "#{key} is required")}
        else
          {:ok, trimmed}
        end

      _ ->
        {:error, Error.new("VALIDATION_ERROR", "#{key} is required")}
    end
  end

  defp fetch_optional(params, key) do
    value = Map.get(params, key) || Map.get(params, Atom.to_string(key))

    case value do
      nil ->
        {:ok, nil}

      string when is_binary(string) ->
        trimmed = String.trim(string)
        if trimmed == "", do: {:ok, nil}, else: {:ok, trimmed}

      _ ->
        {:error, Error.new("VALIDATION_ERROR", "#{key} must be a string")}
    end
  end
end
