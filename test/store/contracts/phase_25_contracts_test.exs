defmodule Store.Contracts.Phase25ContractsTest do
  use ExUnit.Case, async: true

  alias Store.Catalog.Queries.{ProductDetailQuery, ShopQuery}
  alias StoreWeb.Params.Catalog.{ProductDetailParams, ShopQueryParams}

  test "shop query contract delegates storefront listing parsing" do
    assert {:ok, %ShopQuery{sort: :price_desc, page: 2, page_size: 15}} =
             ShopQuery.new(%{"sort" => "price_desc", "page" => "2", "page_size" => "15"})

    assert {:error, error} = ShopQuery.new(%{"unknown" => "value"})
    assert error.code == "VALIDATION_ERROR"
  end

  test "product detail query validates slug and selection map" do
    assert {:ok, %ProductDetailQuery{slug: "phase25-shirt", selection: selection}} =
             ProductDetailQuery.new(%{
               "slug" => "phase25-shirt",
               "selection" => %{"size" => "m", "color" => "black"}
             })

    assert selection == %{"size" => "m", "color" => "black"}

    assert {:error, error} =
             ProductDetailQuery.new(%{"slug" => "not valid", "selection" => %{}})

    assert error.code == "VALIDATION_ERROR"
  end

  test "web params adapters build typed phase 25 query structs" do
    assert {:ok, %ShopQuery{}} = ShopQueryParams.query(%{})

    assert {:ok, %ProductDetailQuery{slug: "phase25-shirt", selection: selection}} =
             ProductDetailParams.query(%{
               "slug" => "phase25-shirt",
               "size" => "m",
               "color" => "black"
             })

    assert selection == %{"size" => "m", "color" => "black"}
  end
end
