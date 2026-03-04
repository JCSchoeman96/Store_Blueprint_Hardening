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
    params
    |> Map.get(:provider, Map.get(params, "provider"))
    |> normalize_provider_input()
  end

  defp normalize_provider_input(nil), do: {:error, Providers.selection_required_error()}

  defp normalize_provider_input(provider_input) do
    case Providers.normalize_provider(provider_input) do
      :unknown ->
        {:error, Error.new("PAYMENT_PROVIDER_UNSUPPORTED", "payment provider is not supported")}

      known ->
        {:ok, known}
    end
  end
end
