defmodule StoreWeb.CartCheckoutLiveTest do
  use StoreWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Store.Carts.Facade, as: CartsFacade
  alias Store.Carts.Inputs.CartItemInput
  alias Store.Carts.Queries.CartLoadQuery
  alias Store.Checkout
  alias Store.Checkout.Inputs.CheckoutStartInput
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

  test "start checkout redirects to placeholder with checkout_key", %{conn: conn} do
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

  test "/checkout placeholder is read-only and keyed by checkout_key", %{conn: conn} do
    %{variant_id: variant_id} = published_product_fixture()
    token = Ash.UUIDv7.generate()
    conn = with_cart_token(conn, token)

    assert {:ok, add_input} = CartItemInput.new(%{"variant_id" => variant_id, "qty" => 1})
    assert {:ok, _cart} = CartsFacade.add_item_for_user(nil, token, add_input)

    assert {:ok, start_input} = CheckoutStartInput.new(%{})
    assert {:ok, start_result} = Checkout.start_from_cart(nil, token, start_input)

    {:ok, _view, html} = live(conn, "/checkout?checkout_key=#{start_result.checkout_key}")

    assert html =~ "Phase 20 placeholder"
    assert html =~ start_result.checkout_key
    assert html =~ "This page is read-only."

    assert html =~
             "No pricing snapshots, reservations, or payment intents are created here in Phase 20."

    refute html =~ "Start Checkout"
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
end
