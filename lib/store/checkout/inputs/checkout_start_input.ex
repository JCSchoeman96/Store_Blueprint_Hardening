defmodule Store.Checkout.Inputs.CheckoutStartInput do
  @moduledoc """
  Typed input contract for checkout start from cart.
  """

  alias Store.Support.Errors.Error

  defstruct []

  @type t :: %__MODULE__{}

  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(params) when is_map(params) do
    case Map.keys(params) do
      [] ->
        {:ok, %__MODULE__{}}

      keys ->
        {:error,
         Error.new(
           "VALIDATION_ERROR",
           "unknown params: #{Enum.map_join(keys, ", ", &to_string/1)}"
         )}
    end
  end

  def new(_params), do: {:error, Error.new("VALIDATION_ERROR", "params must be a map")}
end
