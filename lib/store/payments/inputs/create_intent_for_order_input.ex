defmodule Store.Payments.Inputs.CreateIntentForOrderInput do
  @moduledoc """
  Typed input for creating or reusing a payment intent for a checkout order.
  """

  alias Store.Payments.Providers
  alias Store.Support.Errors.Error

  @allowed_keys MapSet.new([:provider, "provider"])

  defstruct provider: :stripe

  @type t :: %__MODULE__{provider: :stripe}

  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(params) when is_map(params) do
    with :ok <- validate_keys(params) do
      provider =
        params
        |> Map.get(:provider, Map.get(params, "provider", Providers.default_provider()))
        |> Providers.normalize_provider()

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
end
