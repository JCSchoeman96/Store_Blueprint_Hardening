defmodule Store.Catalog.FacadePublicProductTest do
  use Store.DataCase, async: false

  alias Store.Catalog.Facade, as: CatalogFacade
  alias Store.Catalog.Product
  alias Store.Catalog.Queries.ProductDetailQuery
  alias Store.Catalog.Types.ProductDetail
  alias Store.TestFixtures

  test "get_product_for_public returns a published product by slug" do
    %{slug: slug} = published_product_fixture()

    assert {:ok, product} = CatalogFacade.get_product_for_public(nil, slug)
    assert %Product{} = product
    assert product.slug == slug
    assert product.status == :published
  end

  test "get_product_detail_for_public returns the ProductDetail contract" do
    %{slug: slug} = published_product_fixture()

    assert {:ok, query} = ProductDetailQuery.new(%{slug: slug, selection: %{}})
    assert {:ok, detail} = CatalogFacade.get_product_detail_for_public(nil, query)
    assert %ProductDetail{} = detail
    assert %Product{} = detail.product
    assert is_list(detail.options)
    assert is_map(detail.selected)
    assert %ProductDetail.Resolution{} = detail.resolution
    assert is_list(detail.availability_matrix)
  end

  defp published_product_fixture do
    admin = TestFixtures.register_user!(email: TestFixtures.unique_email("shop_public_admin"))
    _role = TestFixtures.assign_role!(admin, :admin)
    slug = "shop-public-#{System.unique_integer([:positive])}"

    product =
      Product
      |> Ash.Changeset.for_create(
        :create_draft,
        %{
          slug: slug,
          title: "Shop Public Product",
          base_variant_sku: "SHOP-PUBLIC-#{System.unique_integer([:positive])}",
          base_variant_currency_code: "USD",
          base_variant_price_minor: 2_000,
          base_variant_stock_on_hand: 10
        }
      )
      |> Ash.create!(domain: Store.Catalog, actor: admin)

    product
    |> Ash.Changeset.for_update(:publish, %{})
    |> Ash.update!(domain: Store.Catalog, actor: admin)
  end
end
