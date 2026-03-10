defmodule Store.CheckoutTest do
  use Store.DataCase, async: false

  import Ash.Expr
  import Ecto.Query
  require Ash.Query

  alias Store.Carts.Cart
  alias Store.Carts.Facade, as: CartsFacade
  alias Store.Carts.Inputs.CartItemInput
  alias Store.Catalog.InventoryItem
  alias Store.Checkout
  alias Store.Checkout.Inputs.{CheckoutFinalizeInput, CheckoutShippingInput, CheckoutStartInput}
  alias Store.Orders.{InventoryReservation, Order, OrderAdjustment, OrderLineItem}
  alias Store.Pricing.TaxRate
  alias Store.Repo
  alias Store.Shipping.Facade, as: ShippingFacade
  alias Store.Shipping.Inputs.QuoteRequest
  alias Store.Shipping.{ShippingMethod, ShippingRateRule, ShippingZone}
  alias Store.SubscriptionsFixtures
  alias Store.TestFixtures

  setup do
    previous_flags = Application.get_env(:store, :subscription_features, [])

    on_exit(fn ->
      Application.put_env(:store, :subscription_features, previous_flags)
    end)

    :ok
  end

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

  test "parallel start_from_cart returns only success or canonical domain errors" do
    variant_id = published_variant_id!()
    assert {:ok, start_input} = CheckoutStartInput.new(%{})

    results =
      1..20
      |> Task.async_stream(
        fn _index ->
          token = Ash.UUIDv7.generate()

          assert {:ok, add_input} = CartItemInput.new(%{"variant_id" => variant_id, "qty" => 1})
          assert {:ok, _cart} = CartsFacade.add_item_for_user(nil, token, add_input)

          Checkout.start_from_cart(nil, token, start_input)
        end,
        max_concurrency: 20,
        timeout: 15_000,
        ordered: false
      )
      |> Enum.map(fn
        {:ok, result} -> result
        other -> flunk("unexpected task result: #{inspect(other)}")
      end)

    assert Enum.all?(results, fn
             {:ok, %{checkout_key: checkout_key, duplicate?: duplicate?}}
             when is_binary(checkout_key) and is_boolean(duplicate?) ->
               true

             {:error, %{code: code}} ->
               code in [
                 "STALE_RECORD",
                 "CHECKOUT_DUPLICATE",
                 "RESERVATION_CONFLICT",
                 "OUT_OF_STOCK"
               ]

             _ ->
               false
           end)
  end

  test "start_from_cart isolates guest checkout keys across carts with identical timestamps" do
    variant_id = published_variant_id!()
    token_a = Ash.UUIDv7.generate()
    token_b = Ash.UUIDv7.generate()
    fixed_time = ~U[2026-03-10 15:00:00.000000Z]

    assert {:ok, add_input} = CartItemInput.new(%{"variant_id" => variant_id, "qty" => 1})
    assert {:ok, _cart} = CartsFacade.add_item_for_user(nil, token_a, add_input)
    assert {:ok, _cart} = CartsFacade.add_item_for_user(nil, token_b, add_input)

    cart_ids =
      Cart
      |> where([cart], cart.token in ^[token_a, token_b] and cart.status == :active)
      |> select([cart], cart.id)
      |> Repo.all()

    assert length(cart_ids) == 2

    Repo.update_all(from(cart in Cart, where: cart.id in ^cart_ids),
      set: [updated_at: fixed_time]
    )

    assert {:ok, start_input} = CheckoutStartInput.new(%{})
    assert {:ok, first} = Checkout.start_from_cart(nil, token_a, start_input)
    assert {:ok, second} = Checkout.start_from_cart(nil, token_b, start_input)

    refute first.checkout_key == second.checkout_key
    assert first.duplicate? == false
    assert second.duplicate? == false
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

  test "start_from_cart creates checkout/order linkage without snapshot or inventory hold evidence" do
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
    assert {:ok, start_result} = Checkout.start_from_cart(nil, token, start_input)

    assert Ash.count!(Order, domain: Store.Orders, authorize?: false) == baseline_orders + 1

    assert Ash.count!(OrderLineItem, domain: Store.Orders, authorize?: false) ==
             baseline_line_items

    assert Ash.count!(InventoryReservation, domain: Store.Orders, authorize?: false) ==
             baseline_reservations

    assert {:ok, second_start_result} = Checkout.start_from_cart(nil, token, start_input)
    assert second_start_result.order_id == start_result.order_id

    assert Ash.count!(Order, domain: Store.Orders, authorize?: false) == baseline_orders + 1
  end

  test "finalize_totals writes snapshot + holds exactly once and is idempotent" do
    token = Ash.UUIDv7.generate()
    actor = %{cart_token: token}
    variant_id = published_variant_id!()
    create_pricing_rules!()

    baseline_line_items =
      Ash.count!(OrderLineItem, domain: Store.Orders, authorize?: false)

    baseline_reservations =
      Ash.count!(InventoryReservation, domain: Store.Orders, authorize?: false)

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

    assert Ash.count!(OrderLineItem, domain: Store.Orders, authorize?: false) ==
             baseline_line_items

    assert Ash.count!(InventoryReservation, domain: Store.Orders, authorize?: false) ==
             baseline_reservations

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

    assert {:ok, _checkout_with_shipping} =
             Checkout.set_shipping(actor, start_result.checkout_key, shipping_input)

    assert {:ok, finalize_input} = CheckoutFinalizeInput.new(%{})

    assert {:ok, first_finalize} =
             Checkout.finalize_totals(actor, start_result.checkout_key, finalize_input)

    assert first_finalize.totals_finalized?

    assert Ash.count!(OrderLineItem, domain: Store.Orders, authorize?: false) ==
             baseline_line_items + 1

    assert Ash.count!(InventoryReservation, domain: Store.Orders, authorize?: false) ==
             baseline_reservations + 1

    assert {:ok, second_finalize} =
             Checkout.finalize_totals(actor, start_result.checkout_key, finalize_input)

    assert second_finalize.order_id == first_finalize.order_id
    assert second_finalize.totals_finalized?

    assert Ash.count!(OrderLineItem, domain: Store.Orders, authorize?: false) ==
             baseline_line_items + 1

    assert Ash.count!(InventoryReservation, domain: Store.Orders, authorize?: false) ==
             baseline_reservations + 1

    shipping_adjustments_count =
      OrderAdjustment
      |> Ash.Query.filter(expr(order_id == ^first_finalize.order_id and kind == "shipping"))
      |> Ash.count!(domain: Store.Orders, authorize?: false)

    assert shipping_adjustments_count == 1
  end

  test "finalize_totals rejects tampered quote evidence hash payload" do
    checkout = setup_checkout_with_shipping!()

    order = load_order!(checkout.order_id)

    assert {:ok, _tampered_order} =
             order
             |> Ash.Changeset.for_update(
               :set_shipping_quote_evidence,
               %{shipping_quote_amount_minor: checkout.selection.amount_minor + 1},
               context: %{system?: true}
             )
             |> Ash.update(domain: Store.Orders, authorize?: false, context: %{system?: true})

    assert {:ok, finalize_input} = CheckoutFinalizeInput.new(%{})

    assert {:error, error} =
             Checkout.finalize_totals(checkout.actor, checkout.checkout_key, finalize_input)

    assert error.code == "VALIDATION_ERROR"
  end

  test "finalize_totals succeeds using stored quote evidence after rule changes" do
    checkout = setup_checkout_with_shipping!()

    assert {:ok, _updated_rule} =
             checkout.shipping_setup.rule
             |> Ash.Changeset.for_update(
               :update,
               %{shipping_cost_minor: checkout.selection.amount_minor + 9_999, active: false},
               context: %{system?: true}
             )
             |> Ash.update(domain: Store.Shipping, authorize?: false, context: %{system?: true})

    assert {:ok, finalize_input} = CheckoutFinalizeInput.new(%{})

    assert {:ok, finalized_checkout} =
             Checkout.finalize_totals(checkout.actor, checkout.checkout_key, finalize_input)

    assert finalized_checkout.totals_finalized?
    assert finalized_checkout.shipping_total_minor == checkout.selection.amount_minor
  end

  test "start_from_cart blocks a new membership checkout when another pending membership order exists" do
    enable_subscription_purchase!()

    token = Ash.UUIDv7.generate()
    customer = SubscriptionsFixtures.create_customer!("checkout_membership_pending")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        entitlement_kind: :membership_access,
        entitlement_scope_key: "membership:checkout-pending"
      })

    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    assert {:ok, add_input} =
             CartItemInput.new(%{
               "variant_id" => variant.id,
               "subscription_plan_id" => plan.id,
               "qty" => 1
             })

    assert {:ok, _cart} = CartsFacade.add_item_for_user(customer, token, add_input)
    assert {:ok, start_input} = CheckoutStartInput.new(%{})
    assert {:ok, _started} = Checkout.start_from_cart(customer, token, start_input)

    assert {:ok, update_input} =
             CartItemInput.new(%{
               "variant_id" => variant.id,
               "subscription_plan_id" => plan.id,
               "qty" => 2
             })

    assert {:ok, _cart} = CartsFacade.update_item_qty_for_user(customer, token, update_input)

    assert {:error, error} = Checkout.start_from_cart(customer, token, start_input)
    assert error.code == "SUBSCRIPTION_DUPLICATE"
  end

  test "finalize_totals returns structured unavailable variant details when inventory is gone" do
    checkout = setup_checkout_with_shipping!()

    inventory = Repo.get_by!(InventoryItem, variant_id: checkout.variant_id)

    assert {:ok, _updated_inventory} =
             inventory
             |> Ash.Changeset.for_update(
               :set_on_hand,
               %{stock_on_hand: 0, allow_oversell: false},
               context: %{system?: true}
             )
             |> Ash.update(domain: Store.Catalog, authorize?: false, context: %{system?: true})

    assert {:ok, finalize_input} = CheckoutFinalizeInput.new(%{})

    assert {:error, error} =
             Checkout.finalize_totals(checkout.actor, checkout.checkout_key, finalize_input)

    assert error.code == "OUT_OF_STOCK"

    assert [%{variant_id: variant_id, requested_quantity: 1, reserved_quantity: 0}] =
             error.meta.unavailable_variants

    assert error.meta.unavailable_variant_ids == [checkout.variant_id]
    assert variant_id == checkout.variant_id
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

    rate =
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

    tax =
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

    %{
      method: method,
      zone: zone,
      rule: rate,
      tax: tax
    }
  end

  defp quote_selection!(attrs) do
    {:ok, request} = QuoteRequest.new(attrs)
    {:ok, [option | _]} = ShippingFacade.quote_options_for_system(request)

    %{
      quote_hash: option.quote_hash,
      shipping_method_code: option.shipping_method_code,
      amount_minor: option.amount_minor
    }
  end

  defp setup_checkout_with_shipping! do
    token = Ash.UUIDv7.generate()
    actor = %{cart_token: token}
    variant_id = published_variant_id!()
    shipping_setup = create_pricing_rules!()

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

    assert {:ok, _checkout_with_shipping} =
             Checkout.set_shipping(actor, start_result.checkout_key, shipping_input)

    %{
      actor: actor,
      checkout_key: start_result.checkout_key,
      order_id: start_result.order_id,
      variant_id: variant_id,
      selection: selection,
      shipping_setup: shipping_setup
    }
  end

  defp load_order!(order_id) do
    Order
    |> Ash.Query.filter(expr(id == ^order_id))
    |> Ash.read_one!(domain: Store.Orders, authorize?: false, context: %{system?: true})
  end

  defp enable_subscription_purchase! do
    current_flags = Application.get_env(:store, :subscription_features, [])

    Application.put_env(
      :store,
      :subscription_features,
      Keyword.merge(current_flags, expose_purchase?: true)
    )
  end
end
