defmodule StoreWeb.ShopLive.ShowTest do
  use StoreWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Store.Catalog.Product
  alias Store.TestFixtures

  test "/shop renders published products", %{conn: conn} do
    product = published_product_fixture()

    {:ok, _view, html} = live(conn, ~p"/shop")

    assert html =~ product.title
    assert html =~ "View Product"
  end

  test "/shop/:slug renders a published product detail page", %{conn: conn} do
    product = published_product_fixture()

    {:ok, _view, html} = live(conn, ~p"/shop/#{product.slug}")

    assert html =~ product.title
    assert html =~ product.slug
    assert html =~ "Add to Cart"
  end

  defp published_product_fixture do
    admin = TestFixtures.register_user!(email: TestFixtures.unique_email("shop_show_admin"))
    _role = TestFixtures.assign_role!(admin, :admin)
    slug = "shop-show-#{System.unique_integer([:positive])}"

    product =
      Product
      |> Ash.Changeset.for_create(
        :create_draft,
        %{
          slug: slug,
          title: "Shop Show Product",
          subtitle: "Live storefront detail",
          base_variant_sku: "SHOP-SHOW-#{System.unique_integer([:positive])}",
          base_variant_currency_code: "USD",
          base_variant_price_minor: 2_500,
          base_variant_stock_on_hand: 10
        }
      )
      |> Ash.create!(domain: Store.Catalog, actor: admin)

    product
    |> Ash.Changeset.for_update(:publish, %{})
    |> Ash.update!(domain: Store.Catalog, actor: admin)
  end
end
