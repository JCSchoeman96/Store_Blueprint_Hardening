defmodule StoreWeb.ShopLive.ShowTest do
  use StoreWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Store.Catalog.Product
  alias Store.SubscriptionsFixtures
  alias Store.TestFixtures

  setup do
    previous = Application.get_env(:store, :live_warm_load_jitter_ms)
    Application.put_env(:store, :live_warm_load_jitter_ms, {0, 0})

    on_exit(fn ->
      Application.put_env(:store, :live_warm_load_jitter_ms, previous)
    end)

    :ok
  end

  test "/shop renders published products", %{conn: conn} do
    product = published_product_fixture()

    {:ok, view, _html} = live(conn, ~p"/shop")
    html = render_until(view, product.title)

    assert html =~ product.title
    assert html =~ "View Product"
  end

  test "/shop/:slug renders a published product detail page", %{conn: conn} do
    product = published_product_fixture()

    {:ok, view, _html} = live(conn, ~p"/shop/#{product.slug}")
    html = render_until(view, product.title)

    assert html =~ product.title
    assert html =~ product.slug
    assert html =~ "Add to Cart"
  end

  test "/shop emits static-to-live mount telemetry with zero-query static pass", %{conn: conn} do
    _product = published_product_fixture()
    parent = self()
    handler = {__MODULE__, :shop_index_mount, System.unique_integer([:positive])}

    :telemetry.attach(
      handler,
      [:store, :shop_live, :index, :mount],
      fn _event, measurements, metadata, pid ->
        send(pid, {:shop_index_mount, measurements, metadata})
      end,
      parent
    )

    try do
      {:ok, view, _html} = live(conn, ~p"/shop")
      _ = render_until(view, "View Product")

      assert_receive {:shop_index_mount, measurements, %{phase: :static} = metadata}
      assert measurements.query_count == 0
      assert metadata.result == :ok

      assert_receive {:shop_index_mount, measurements, %{phase: :live} = metadata}
      assert is_integer(measurements.query_count)
      assert metadata.result == :ok
    after
      :telemetry.detach(handler)
    end
  end

  test "/shop/:slug emits static and live-join telemetry with BEAM diagnostics", %{conn: conn} do
    product = published_product_fixture()
    parent = self()
    shop_live_handler = {__MODULE__, :shop_live, System.unique_integer([:positive])}
    catalog_handler = {__MODULE__, :catalog_detail, System.unique_integer([:positive])}
    mount_handler = {__MODULE__, :shop_show_mount, System.unique_integer([:positive])}

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

    :telemetry.attach(
      mount_handler,
      [:store, :shop_live, :show, :mount],
      fn _event, measurements, metadata, pid ->
        send(pid, {:shop_show_mount, measurements, metadata})
      end,
      parent
    )

    try do
      {:ok, view, _html} = live(conn, ~p"/shop/#{product.slug}")
      html = render_until(view, product.title)

      assert html =~ product.title

      details =
        1..2
        |> Enum.map(fn _ ->
          assert_receive {:shop_live_detail, measurements, metadata}
          assert metadata.slug == product.slug
          assert is_boolean(metadata.connected?)
          assert metadata.result == :ok
          assert is_integer(measurements.reductions_delta)
          assert measurements.reductions_delta >= 0
          assert is_integer(measurements.memory_delta)
          {metadata.phase, metadata.payload_hash}
        end)
        |> Map.new()

      assert Map.keys(details) |> MapSet.new() == MapSet.new([:static_render, :live_join])
      assert details.static_render == nil
      assert is_binary(details.live_join)

      assert_receive {:shop_show_mount, measurements, %{phase: :static} = metadata}
      assert measurements.query_count == 0
      assert metadata.result == :ok

      assert_receive {:shop_show_mount, measurements, %{phase: :live} = metadata}
      assert is_integer(measurements.query_count)
      assert metadata.result == :ok

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
      :telemetry.detach(mount_handler)
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

    {:ok, view, _html} = live(conn, ~p"/shop/#{product.slug}")
    html = render_until(view, "Solo Plan")

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

    {:ok, view, _html} = live(conn, ~p"/shop/#{product.slug}")
    html = render_until(view, "Basic Plan")

    assert html =~ "Basic Plan"
    assert html =~ "Premium Plan"
    assert has_element?(view, "#add-to-cart-handoff[disabled]")

    {:ok, selected_view, _selected_html} =
      live(conn, ~p"/shop/#{product.slug}?subscription_plan_key=#{premium_plan.key}")

    selected_html = render_until(selected_view, "$29.99")

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

  defp render_until(view, needle, attempts \\ 20)

  defp render_until(view, needle, attempts) when attempts > 0 do
    html = render(view)

    if html =~ needle do
      html
    else
      Process.sleep(20)
      render_until(view, needle, attempts - 1)
    end
  end

  defp render_until(view, _needle, 0), do: render(view)
end
