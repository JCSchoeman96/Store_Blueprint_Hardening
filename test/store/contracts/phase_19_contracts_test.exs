defmodule Store.Contracts.Phase19ContractsTest do
  use ExUnit.Case, async: true

  alias Store.Catalog.Queries.{ProductAdminIndexQuery, ProductIndexQuery}
  alias StoreWeb.Params.Catalog.{ProductAdminIndexParams, ProductIndexParams}

  test "storefront product index query validates allowed keys and sort/page coercion" do
    assert {:ok, %ProductIndexQuery{sort: :price_desc, page: 2, page_size: 15}} =
             ProductIndexQuery.new(%{"sort" => "price_desc", "page" => "2", "page_size" => "15"})

    assert {:error, error} = ProductIndexQuery.new(%{"bad" => "value"})
    assert error.code == "VALIDATION_ERROR"
  end

  test "admin product index query validates status and sort" do
    assert {:ok, %ProductAdminIndexQuery{status: :draft, sort: :title_asc}} =
             ProductAdminIndexQuery.new(%{"status" => "draft", "sort" => "title_asc"})

    assert {:error, invalid_status} = ProductAdminIndexQuery.new(%{"status" => "nope"})
    assert invalid_status.code == "VALIDATION_ERROR"
  end

  test "web params adapters delegate to catalog query contracts" do
    assert {:ok, %ProductIndexQuery{}} = ProductIndexParams.index_query(%{})
    assert {:ok, %ProductAdminIndexQuery{}} = ProductAdminIndexParams.index_query(%{})

    assert {:error, storefront_error} = ProductIndexParams.index_query(%{"unknown" => "x"})
    assert storefront_error.code == "VALIDATION_ERROR"

    assert {:error, admin_error} = ProductAdminIndexParams.index_query(%{"unknown" => "x"})
    assert admin_error.code == "VALIDATION_ERROR"
  end
end
