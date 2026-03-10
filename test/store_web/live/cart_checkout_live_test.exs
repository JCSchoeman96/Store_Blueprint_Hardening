defmodule StoreWeb.CartCheckoutLiveTest do
  use StoreWeb.ConnCase, async: false

  import Ash.Expr
  require Ash.Query
  import Phoenix.LiveViewTest

  alias Store.Carts.Facade, as: CartsFacade
  alias Store.Carts.Inputs.CartItemInput
  alias Store.Carts.Queries.CartLoadQuery
  alias Store.Catalog.InventoryItem
  alias Store.Checkout
  alias Store.Checkout.Inputs.{CheckoutShippingInput, CheckoutStartInput}
  alias Store.Orders.Order
  alias Store.Pricing.TaxRate
  alias Store.Repo
  alias Store.Shipping.Facade, as: ShippingFacade
  alias Store.Shipping.Inputs.QuoteRequest
  alias Store.Shipping.{ShippingMethod, ShippingRateRule, ShippingZone}
  alias Store.TestFixtures

  test "guest can view/update/remove cart lines", %{conn: conn} do
    %{title: title, variant_id: variant_id} = published_product_fixture()
    token = Ash.UUIDv7.generate()
    conn = with_cart_token(conn, token)

    assert {:ok, add_input} = CartItemInput.new(%{"variant_id" => variant_id, "qty" => 2})
    assert {:ok, _cart} = CartsFacade.add_item_for_user(nil, token, add_input)

    {:ok, cart_view, html} = live(conn, ~p"/cart")
    assert html =~ title

    cart_view
    |> element("form[phx-submit='update_qty']")
    |> render_submit(%{"variant_id" => variant_id, "qty" => "4"})

    assert {:ok, query} = CartLoadQuery.new(%{"include_items" => true})
    assert {:ok, cart_view_after_update} = CartsFacade.get_cart_view_for_user(nil, token, query)
    assert [%{qty: 4}] = Enum.filter(cart_view_after_update.items, &(&1.variant_id == variant_id))

    cart_view
    |> element("#remove-#{variant_id}")
    |> render_click()

    assert render(cart_view) =~ "Your cart is empty."
  end

  test "start checkout redirects to checkout page with checkout_key", %{conn: conn} do
    %{variant_id: variant_id} = published_product_fixture()
    token = Ash.UUIDv7.generate()
    conn = with_cart_token(conn, token)

    assert {:ok, add_input} = CartItemInput.new(%{"variant_id" => variant_id, "qty" => 2})
    assert {:ok, _cart} = CartsFacade.add_item_for_user(nil, token, add_input)

    {:ok, cart_view, _html} = live(conn, ~p"/cart")
    cart_view |> element("#start-checkout") |> render_click()

    {redirect_path, _flash} = assert_redirect(cart_view)
    assert String.starts_with?(redirect_path, "/checkout?checkout_key=")

    %URI{query: query} = URI.parse(redirect_path)
    %{"checkout_key" => checkout_key} = URI.decode_query(query || "")
    assert {:error, denied} = Checkout.get_draft_for_user(nil, checkout_key)
    assert denied.code == "NOT_FOUND"
    assert {:ok, _draft} = Checkout.get_draft_for_user(%{cart_token: token}, checkout_key)
  end

  test "/checkout renders phase 21 flow keyed by checkout_key", %{conn: conn} do
    %{variant_id: variant_id} = published_product_fixture()
    token = Ash.UUIDv7.generate()
    conn = with_cart_token(conn, token)

    assert {:ok, add_input} = CartItemInput.new(%{"variant_id" => variant_id, "qty" => 1})
    assert {:ok, _cart} = CartsFacade.add_item_for_user(nil, token, add_input)

    assert {:ok, start_input} = CheckoutStartInput.new(%{})
    assert {:ok, start_result} = Checkout.start_from_cart(nil, token, start_input)

    {:ok, _view, html} = live(conn, "/checkout?checkout_key=#{start_result.checkout_key}")

    assert html =~ "Review shipping, finalize totals, then continue to payment."
    assert html =~ "Save Shipping"
    assert html =~ "Finalize Totals"
    assert html =~ "Continue To Payment"
  end

  test "payment return route is read-only and does not mutate order state", %{conn: conn} do
    %{variant_id: variant_id} = published_product_fixture()
    token = Ash.UUIDv7.generate()
    conn = with_cart_token(conn, token)

    assert {:ok, add_input} = CartItemInput.new(%{"variant_id" => variant_id, "qty" => 1})
    assert {:ok, _cart} = CartsFacade.add_item_for_user(nil, token, add_input)

    assert {:ok, start_input} = CheckoutStartInput.new(%{})
    assert {:ok, start_result} = Checkout.start_from_cart(nil, token, start_input)

    {:ok, _view, html} = live(conn, "/checkout/return?checkout_key=#{start_result.checkout_key}")

    assert html =~ "Payment return received. This page is read-only"

    assert {:ok, [order]} =
             Order
             |> Ash.Query.filter(expr(id == ^start_result.order_id))
             |> Ash.read(domain: Store.Orders, authorize?: false)

    assert order.state == :pending_payment
  end

  test "checkout live shows explicit out-of-stock message on finalize failure", %{conn: conn} do
    checkout = setup_checkout_with_shipping!()
    conn = with_cart_token(conn, checkout.token)

    inventory = Repo.get_by!(InventoryItem, variant_id: checkout.variant_id)

    assert {:ok, _updated_inventory} =
             inventory
             |> Ash.Changeset.for_update(
               :set_on_hand,
               %{stock_on_hand: 0, allow_oversell: false},
               context: %{system?: true}
             )
             |> Ash.update(domain: Store.Catalog, authorize?: false, context: %{system?: true})

    {:ok, view, _html} = live(conn, "/checkout?checkout_key=#{checkout.checkout_key}")

    view
    |> element("#finalize-totals")
    |> render_click()

    assert render(view) =~
             "One or more items are no longer available. Review your cart and try again."
  end

  defp with_cart_token(conn, token) do
    conn
    |> init_test_session(%{})
    |> Plug.Test.put_req_cookie("cart_token", token)
  end

  defp published_product_fixture do
    admin = TestFixtures.register_user!(email: TestFixtures.unique_email("phase20_live_admin"))
    _role = TestFixtures.assign_role!(admin, :admin)

    slug = "phase20-live-#{System.unique_integer([:positive])}"

    product =
      Store.Catalog.Product
      |> Ash.Changeset.for_create(
        :create_draft,
        %{
          slug: slug,
          title: "Phase 20 Live Product",
          base_variant_sku: "P20-LIVE-#{System.unique_integer([:positive])}",
          base_variant_currency_code: "USD",
          base_variant_price_minor: 2_000,
          base_variant_stock_on_hand: 25
        }
      )
      |> Ash.create!(domain: Store.Catalog, actor: admin)

    published =
      product
      |> Ash.Changeset.for_update(:publish, %{})
      |> Ash.update!(domain: Store.Catalog, actor: admin)

    %{slug: published.slug, title: published.title, variant_id: published.default_variant_id}
  end

  defp setup_checkout_with_shipping! do
    %{variant_id: variant_id} = published_product_fixture()
    token = Ash.UUIDv7.generate()
    actor = %{cart_token: token}
    _shipping_setup = create_pricing_rules!()

    assert {:ok, add_input} = CartItemInput.new(%{"variant_id" => variant_id, "qty" => 1})
    assert {:ok, _cart} = CartsFacade.add_item_for_user(nil, token, add_input)
    assert {:ok, start_input} = CheckoutStartInput.new(%{})
    assert {:ok, start_result} = Checkout.start_from_cart(nil, token, start_input)

    selection =
      quote_selection!(%{
        destination_country_code: "US",
        destination_region_code: "CA",
        destination_postal_code: "94105",
        currency_code: "USD",
        shipping_weight_grams: 0
      })

    assert {:ok, shipping_input} =
             CheckoutShippingInput.new(%{
               "recipient_name" => "Jane Customer",
               "address_line1" => "1 Main St",
               "city" => "San Francisco",
               "country_code" => "US",
               "region_code" => "CA",
               "postal_code" => "94105",
               "phone" => "555-555-1212",
               "quote_hash" => selection.quote_hash,
               "shipping_method_code" => selection.shipping_method_code
             })

    assert {:ok, _checkout} =
             Checkout.set_shipping(actor, start_result.checkout_key, shipping_input)

    %{token: token, checkout_key: start_result.checkout_key, variant_id: variant_id}
  end

  defp create_pricing_rules! do
    unique = System.unique_integer([:positive])
    method_code = "GROUND-#{unique}"

    method =
      ShippingMethod
      |> Ash.Changeset.for_create(
        :create,
        %{code: method_code, name: "Ground #{unique}", active: true, sort_order: 100},
        context: %{system?: true}
      )
      |> Ash.create!(domain: Store.Shipping, authorize?: false, context: %{system?: true})

    zone =
      ShippingZone
      |> Ash.Changeset.for_create(
        :create,
        %{code: "US-CA-#{unique}", country_code: "US", region_code: "CA", active: true},
        context: %{system?: true}
      )
      |> Ash.create!(domain: Store.Shipping, authorize?: false, context: %{system?: true})

    _rate =
      ShippingRateRule
      |> Ash.Changeset.for_create(
        :create,
        %{
          code: "GROUND_RULE_#{unique}",
          shipping_zone_id: zone.id,
          shipping_method_id: method.id,
          currency: "USD",
          shipping_cost_minor: 500,
          active: true,
          precedence_rank: 10
        },
        context: %{system?: true}
      )
      |> Ash.create!(domain: Store.Shipping, authorize?: false, context: %{system?: true})

    _tax =
      TaxRate
      |> Ash.Changeset.for_create(
        :create,
        %{
          code: "CA-STANDARD-#{unique}",
          country_code: "US",
          region_code: "CA",
          product_tax_category: "STANDARD",
          rate_basis_points: 800,
          shipping_taxable: true,
          active: true,
          precedence_rank: 10
        },
        context: %{system?: true}
      )
      |> Ash.create!(domain: Store.Pricing, authorize?: false, context: %{system?: true})
  end

  defp quote_selection!(attrs) do
    {:ok, request} = QuoteRequest.new(attrs)
    {:ok, [option | _]} = ShippingFacade.quote_options_for_system(request)

    %{
      quote_hash: option.quote_hash,
      shipping_method_code: option.shipping_method_code
    }
  end
end
