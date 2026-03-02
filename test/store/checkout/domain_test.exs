defmodule Store.CheckoutTest do
  use Store.DataCase, async: false

  alias Store.Carts.Facade, as: CartsFacade
  alias Store.Carts.Inputs.CartItemInput
  alias Store.Checkout
  alias Store.Checkout.Inputs.CheckoutStartInput
  alias Store.Orders.{InventoryReservation, Order, OrderLineItem}
  alias Store.TestFixtures

  test "start_from_cart is idempotent for same cart version and issues new draft after mutation" do
    token = Ash.UUIDv7.generate()
    variant_id = published_variant_id!()

    assert {:ok, add_input} = CartItemInput.new(%{"variant_id" => variant_id, "qty" => 1})
    assert {:ok, _cart} = CartsFacade.add_item_for_user(nil, token, add_input)

    assert {:ok, start_input} = CheckoutStartInput.new(%{})

    assert {:ok, first} = Checkout.start_from_cart(nil, token, start_input)
    assert {:ok, second} = Checkout.start_from_cart(nil, token, start_input)

    assert first.checkout_key == second.checkout_key
    assert first.cart_version == second.cart_version
    assert first.duplicate? == false
    assert second.duplicate? == true

    assert {:ok, update_input} = CartItemInput.new(%{"variant_id" => variant_id, "qty" => 2})

    assert {:ok, _cart_after_update} =
             CartsFacade.update_item_qty_for_user(nil, token, update_input)

    assert {:ok, third} = Checkout.start_from_cart(nil, token, start_input)
    refute third.checkout_key == first.checkout_key
    assert third.cart_version == first.cart_version + 1
  end

  test "start_from_cart rejects unpublished sellables" do
    token = Ash.UUIDv7.generate()
    {variant_id, admin, product} = published_variant_with_admin!()

    assert {:ok, add_input} = CartItemInput.new(%{"variant_id" => variant_id, "qty" => 1})
    assert {:ok, _cart} = CartsFacade.add_item_for_user(nil, token, add_input)

    _draft_product =
      product
      |> Ash.Changeset.for_update(:unpublish, %{})
      |> Ash.update!(domain: Store.Catalog, actor: admin)

    assert {:ok, start_input} = CheckoutStartInput.new(%{})
    assert {:error, error} = Checkout.start_from_cart(nil, token, start_input)
    assert error.code == "VALIDATION_ERROR"
  end

  test "phase 20 start_from_cart creates no reservations snapshots or orders" do
    token = Ash.UUIDv7.generate()
    variant_id = published_variant_id!()

    baseline_orders = Ash.count!(Order, domain: Store.Orders, authorize?: false)

    baseline_line_items =
      Ash.count!(OrderLineItem, domain: Store.Orders, authorize?: false)

    baseline_reservations =
      Ash.count!(InventoryReservation, domain: Store.Orders, authorize?: false)

    assert {:ok, add_input} = CartItemInput.new(%{"variant_id" => variant_id, "qty" => 1})
    assert {:ok, _cart} = CartsFacade.add_item_for_user(nil, token, add_input)

    assert {:ok, start_input} = CheckoutStartInput.new(%{})
    assert {:ok, _draft} = Checkout.start_from_cart(nil, token, start_input)

    assert Ash.count!(Order, domain: Store.Orders, authorize?: false) == baseline_orders

    assert Ash.count!(OrderLineItem, domain: Store.Orders, authorize?: false) ==
             baseline_line_items

    assert Ash.count!(InventoryReservation, domain: Store.Orders, authorize?: false) ==
             baseline_reservations
  end

  test "guest draft requires matching cart token for get_draft_for_user" do
    token = Ash.UUIDv7.generate()
    wrong_token = Ash.UUIDv7.generate()
    variant_id = published_variant_id!()

    assert {:ok, add_input} = CartItemInput.new(%{"variant_id" => variant_id, "qty" => 1})
    assert {:ok, _cart} = CartsFacade.add_item_for_user(nil, token, add_input)

    assert {:ok, start_input} = CheckoutStartInput.new(%{})
    assert {:ok, start_result} = Checkout.start_from_cart(nil, token, start_input)

    assert {:error, denied_nil} = Checkout.get_draft_for_user(nil, start_result.checkout_key)
    assert denied_nil.code == "NOT_FOUND"

    assert {:error, denied_wrong_token} =
             Checkout.get_draft_for_user(%{cart_token: wrong_token}, start_result.checkout_key)

    assert denied_wrong_token.code == "NOT_FOUND"

    assert {:ok, _draft} =
             Checkout.get_draft_for_user(%{cart_token: token}, start_result.checkout_key)
  end

  test "user draft requires matching user for get_draft_for_user" do
    token = Ash.UUIDv7.generate()
    variant_id = published_variant_id!()
    user = TestFixtures.register_user!(email: TestFixtures.unique_email("checkout_user_owner"))

    other_user =
      TestFixtures.register_user!(email: TestFixtures.unique_email("checkout_user_other"))

    assert {:ok, add_input} = CartItemInput.new(%{"variant_id" => variant_id, "qty" => 1})
    assert {:ok, _cart} = CartsFacade.add_item_for_user(user, token, add_input)

    assert {:ok, start_input} = CheckoutStartInput.new(%{})
    assert {:ok, start_result} = Checkout.start_from_cart(user, token, start_input)

    assert {:error, denied} = Checkout.get_draft_for_user(other_user, start_result.checkout_key)
    assert denied.code == "NOT_FOUND"

    assert {:ok, draft} = Checkout.get_draft_for_user(user, start_result.checkout_key)
    assert draft.user_id == user.id
  end

  defp published_variant_id! do
    {variant_id, _admin, _product} = published_variant_with_admin!()
    variant_id
  end

  defp published_variant_with_admin! do
    admin = TestFixtures.register_user!(email: TestFixtures.unique_email("checkout_admin"))
    _role = TestFixtures.assign_role!(admin, :admin)

    product =
      Store.Catalog.Product
      |> Ash.Changeset.for_create(
        :create_draft,
        %{
          slug: "phase20-checkout-#{System.unique_integer([:positive])}",
          title: "Phase 20 Checkout Product",
          base_variant_sku: "P20-CHK-#{System.unique_integer([:positive])}",
          base_variant_currency_code: "USD",
          base_variant_price_minor: 2_000,
          base_variant_stock_on_hand: 50
        }
      )
      |> Ash.create!(domain: Store.Catalog, actor: admin)

    published =
      product
      |> Ash.Changeset.for_update(:publish, %{})
      |> Ash.update!(domain: Store.Catalog, actor: admin)

    {published.default_variant_id, admin, published}
  end
end
