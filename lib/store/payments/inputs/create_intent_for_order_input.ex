defmodule Store.Payments.Inputs.CreateIntentForOrderInput do
  @moduledoc """
  Typed input for creating or reusing a payment intent for a checkout order.
  """

  alias Store.Payments.Providers
  alias Store.Support.Errors.Error

  @allowed_keys MapSet.new([:provider, "provider"])

  @enforce_keys [:provider]
  defstruct provider: nil

  @type t :: %__MODULE__{provider: Providers.known_provider()}

  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(params) when is_map(params) do
    with :ok <- validate_keys(params),
         {:ok, provider} <- normalize_provider(params) do
      {:ok, %__MODULE__{provider: provider}}
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

  defp normalize_provider(params) do
    case Map.get(params, :provider, Map.get(params, "provider")) do
      nil ->
        {:error,
         Error.new(
           "PAYMENT_PROVIDER_SELECTION_REQUIRED",
           "payment provider selection is required"
         )}

      provider_input ->
        case Providers.normalize_provider(provider_input) do
          known when known in [:stripe, :payfast, :paystack, :yoco, :peach_payments] ->
            {:ok, known}

          :unknown ->
            {:error,
             Error.new(
               "PAYMENT_PROVIDER_UNSUPPORTED",
               "payment provider is not supported"
             )}
        end
    end
  end
end
