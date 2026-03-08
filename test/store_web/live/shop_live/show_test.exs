defmodule StoreWeb.ShopLive.ShowTest do
  use StoreWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Store.Catalog.Product
  alias Store.SubscriptionsFixtures
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

  test "/shop/:slug emits static and live-join telemetry with BEAM diagnostics", %{conn: conn} do
    product = published_product_fixture()
    parent = self()
    shop_live_handler = {__MODULE__, :shop_live, System.unique_integer([:positive])}
    catalog_handler = {__MODULE__, :catalog_detail, System.unique_integer([:positive])}

    :telemetry.attach(
      shop_live_handler,
      [:store, :shop_live, :product_detail],
      fn _event, measurements, metadata, pid ->
        send(pid, {:shop_live_detail, measurements, metadata})
      end,
      parent
    )

    :telemetry.attach(
      catalog_handler,
      [:store, :catalog, :product_detail, :public],
      fn _event, measurements, metadata, pid ->
        send(pid, {:catalog_detail, measurements, metadata})
      end,
      parent
    )

    try do
      {:ok, _view, html} = live(conn, ~p"/shop/#{product.slug}")

      assert html =~ product.title

      phases =
        1..2
        |> Enum.map(fn _ ->
          assert_receive {:shop_live_detail, measurements, metadata}
          assert metadata.slug == product.slug
          assert is_boolean(metadata.connected?)
          assert metadata.result == :ok
          assert is_binary(metadata.payload_hash)
          assert is_integer(measurements.reductions_delta)
          assert measurements.reductions_delta >= 0
          assert is_integer(measurements.memory_delta)
          metadata.phase
        end)
        |> MapSet.new()

      assert phases == MapSet.new([:static_render, :live_join])

      assert_receive {:catalog_detail, measurements, metadata}
      assert metadata.slug == product.slug
      assert metadata.result == :ok
      assert is_binary(metadata.payload_hash)
      assert is_integer(measurements.query_count)
      assert measurements.query_count > 0
      assert is_integer(measurements.encoded_payload_bytes)
      assert measurements.encoded_payload_bytes > 0
    after
      :telemetry.detach(shop_live_handler)
      :telemetry.detach(catalog_handler)
    end
  end

  test "/shop/:slug auto-selects a single active subscription plan and enables add to cart", %{
    conn: conn
  } do
    %{product: product, variant: variant} =
      SubscriptionsFixtures.create_subscription_sellable!(%{
        base_variant_price_minor: 1_000
      })

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        key: "solo-plan",
        name: "Solo Plan",
        amount_minor: 3_199
      })

    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    {:ok, view, html} = live(conn, ~p"/shop/#{product.slug}")

    assert html =~ "Solo Plan"
    assert html =~ "$31.99"
    refute has_element?(view, "#add-to-cart-handoff[disabled]")
  end

  test "/shop/:slug requires explicit selection when multiple active subscription plans exist", %{
    conn: conn
  } do
    %{product: product, variant: variant} =
      SubscriptionsFixtures.create_subscription_sellable!(%{
        base_variant_price_minor: 1_000
      })

    basic_plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        key: "basic-plan",
        name: "Basic Plan",
        amount_minor: 1_999
      })

    premium_plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        key: "premium-plan",
        name: "Premium Plan",
        amount_minor: 2_999
      })

    _basic_attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, basic_plan.id)
    _premium_attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, premium_plan.id)

    {:ok, view, html} = live(conn, ~p"/shop/#{product.slug}")

    assert html =~ "Basic Plan"
    assert html =~ "Premium Plan"
    assert has_element?(view, "#add-to-cart-handoff[disabled]")

    {:ok, selected_view, selected_html} =
      live(conn, ~p"/shop/#{product.slug}?subscription_plan_key=#{premium_plan.key}")

    assert selected_html =~ "$29.99"
    refute has_element?(selected_view, "#add-to-cart-handoff[disabled]")
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
