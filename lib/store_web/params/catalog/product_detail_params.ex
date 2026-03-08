defmodule StoreWeb.Params.Catalog.ProductDetailParams do
  @moduledoc """
  Web params adapter for storefront product-detail query contract.
  """

  alias Store.Catalog.Queries.ProductDetailQuery
  alias Store.Support.Errors.Error

  @reserved_keys MapSet.new(["slug", "subscription_plan_key"])

  @spec query(map()) :: {:ok, ProductDetailQuery.t()} | {:error, Error.t()}
  def query(params) when is_map(params) do
    slug = Map.get(params, "slug") || Map.get(params, :slug)

    selection =
      params
      |> Enum.reduce(%{}, fn {key, value}, acc ->
        key = to_string(key)

        if MapSet.member?(@reserved_keys, key) do
          acc
        else
          Map.put(acc, key, value)
        end
      end)

    ProductDetailQuery.new(%{slug: slug, selection: selection})
    |> then(fn
      {:ok, query} ->
        {:ok,
         %{
           query
           | subscription_plan_key:
               Map.get(params, "subscription_plan_key") || Map.get(params, :subscription_plan_key)
         }}

      {:error, _} = error ->
        error
    end)
  end

  def query(_params), do: {:error, Error.new("VALIDATION_ERROR", "params must be a map")}
end
