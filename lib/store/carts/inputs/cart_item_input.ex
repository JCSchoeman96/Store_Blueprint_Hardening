defmodule Store.Carts.Inputs.CartItemInput do
  @moduledoc """
  Typed cart line input contract for add/update mutations.
  """

  alias Store.Support.Errors.Error
  alias Store.Support.ID.UUIDv7

  @max_qty 99
  @allowed_keys MapSet.new(["variant_id", :variant_id, "qty", :qty])

  @enforce_keys [:variant_id, :qty]
  defstruct [:variant_id, :qty]

  @type t :: %__MODULE__{variant_id: Ecto.UUID.t(), qty: pos_integer()}

  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(params) when is_map(params) do
    with :ok <- validate_keys(params),
         {:ok, variant_id} <- parse_variant_id(params),
         {:ok, qty} <- parse_qty(params) do
      {:ok, %__MODULE__{variant_id: variant_id, qty: qty}}
    end
  end

  def new(_params), do: {:error, Error.new("VALIDATION_ERROR", "params must be a map")}

  @spec max_qty() :: pos_integer()
  def max_qty, do: @max_qty

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

  defp parse_variant_id(params) do
    variant_id = Map.get(params, :variant_id) || Map.get(params, "variant_id")

    cond do
      not is_binary(variant_id) ->
        {:error, Error.new("VALIDATION_ERROR", "variant_id must be a UUID string")}

      not UUIDv7.valid?(variant_id) ->
        {:error, Error.new("VALIDATION_ERROR", "variant_id must be a valid UUID")}

      true ->
        {:ok, variant_id}
    end
  end

  defp parse_qty(params) do
    params
    |> fetch_qty()
    |> normalize_qty()
  end

  defp fetch_qty(params), do: Map.get(params, :qty) || Map.get(params, "qty")

  defp normalize_qty(qty) when is_integer(qty), do: validate_qty_range(qty)

  defp normalize_qty(qty) when is_binary(qty) do
    case Integer.parse(qty) do
      {parsed, ""} -> validate_qty_range(parsed)
      _ -> qty_error()
    end
  end

  defp normalize_qty(_qty), do: qty_error()

  defp validate_qty_range(qty) when qty >= 1 and qty <= @max_qty, do: {:ok, qty}
  defp validate_qty_range(_qty), do: qty_error()

  defp qty_error,
    do: {:error, Error.new("VALIDATION_ERROR", "qty must be an integer from 1 to 99")}
end
