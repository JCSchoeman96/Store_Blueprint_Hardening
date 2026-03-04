defmodule Store.Catalog.Inputs.CartLineInput do
  @moduledoc """
  Typed cart line input that normalizes product identity to variant identity.
  """

  import Ash.Expr
  require Ash.Query

  alias Store.Catalog.Product
  alias Store.Catalog.Variant
  alias Store.Support.Errors.Error

  @allowed_keys MapSet.new([
                  "product_id",
                  :product_id,
                  "variant_id",
                  :variant_id,
                  "subscription_plan_id",
                  :subscription_plan_id,
                  "quantity",
                  :quantity
                ])

  @enforce_keys [:variant_id, :quantity]
  defstruct [:variant_id, :subscription_plan_id, :quantity]

  @type t :: %__MODULE__{
          variant_id: Ecto.UUID.t(),
          subscription_plan_id: Ecto.UUID.t() | nil,
          quantity: pos_integer()
        }

  @spec new(map()) :: {:ok, map()} | {:error, Error.t()}
  def new(params) when is_map(params) do
    with :ok <- validate_keys(params),
         {:ok, quantity} <- parse_quantity(params),
         {:ok, product_id} <- parse_optional_uuid(params, :product_id),
         {:ok, variant_id} <- parse_optional_uuid(params, :variant_id),
         {:ok, subscription_plan_id} <- parse_optional_uuid(params, :subscription_plan_id),
         {:ok, normalized_variant_id} <- normalize_variant_id(product_id, variant_id) do
      {:ok,
       %__MODULE__{
         variant_id: normalized_variant_id,
         subscription_plan_id: subscription_plan_id,
         quantity: quantity
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

  defp parse_quantity(params) do
    case Map.get(params, :quantity) || Map.get(params, "quantity") do
      int when is_integer(int) and int > 0 ->
        {:ok, int}

      str when is_binary(str) ->
        case Integer.parse(str) do
          {parsed, ""} when parsed > 0 -> {:ok, parsed}
          _ -> {:error, Error.new("VALIDATION_ERROR", "quantity must be a positive integer")}
        end

      _ ->
        {:error, Error.new("VALIDATION_ERROR", "quantity must be a positive integer")}
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

  defp normalize_variant_id(nil, nil) do
    {:error, Error.new("VALIDATION_ERROR", "either product_id or variant_id is required")}
  end

  defp normalize_variant_id(nil, variant_id), do: ensure_variant_exists(variant_id)

  defp normalize_variant_id(product_id, nil) do
    case Product
         |> Ash.Query.for_read(:get_for_admin, %{id: product_id})
         |> Ash.read_one(domain: Store.Catalog, authorize?: false, context: %{system?: true}) do
      {:ok, %Product{default_variant_id: default_variant_id}}
      when is_binary(default_variant_id) ->
        {:ok, default_variant_id}

      {:ok, _} ->
        {:error, Error.new("VALIDATION_ERROR", "product default variant is missing")}

      {:error, _} ->
        {:error, Error.new("VALIDATION_ERROR", "product_id is not valid")}
    end
  end

  defp normalize_variant_id(product_id, variant_id) do
    with {:ok, normalized_variant_id} <- ensure_variant_exists(variant_id),
         {:ok, product_variant_id} <- normalize_variant_id(product_id, nil) do
      if normalized_variant_id == product_variant_id do
        {:ok, normalized_variant_id}
      else
        {:error, Error.new("VALIDATION_ERROR", "product_id and variant_id must match")}
      end
    end
  end

  defp ensure_variant_exists(variant_id) do
    case Variant
         |> Ash.Query.for_read(:read, %{})
         |> Ash.Query.filter(expr(id == ^variant_id))
         |> Ash.read_one(domain: Store.Catalog, authorize?: false, context: %{system?: true}) do
      {:ok, %Variant{id: id}} -> {:ok, id}
      _ -> {:error, Error.new("VALIDATION_ERROR", "variant_id is not valid")}
    end
  end
end
