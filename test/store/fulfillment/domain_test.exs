defmodule Store.Fulfillment.DomainTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Store.Admin.Authorization
  alias Store.Carts.Facade, as: CartsFacade
  alias Store.Carts.Inputs.CartItemInput
  alias Store.Checkout
  alias Store.Checkout.Inputs.{CheckoutFinalizeInput, CheckoutShippingInput, CheckoutStartInput}
  alias Store.Fulfillment
  alias Store.Fulfillment.Facade, as: FulfillmentFacade
  alias Store.Orders.Facade, as: OrdersFacade
  alias Store.Orders.{Order, OrderLineItem}
  alias Store.Pricing.TaxRate
  alias Store.Shipping.Facade, as: ShippingFacade
  alias Store.Shipping.Inputs.QuoteRequest
  alias Store.Shipping.{ShippingMethod, ShippingRateRule, ShippingZone}
  alias Store.TestFixtures

  test "ensure_fulfillment_for_paid_order rejects unpaid and paid-unfinalized orders" do
    order =
      Order
      |> Ash.Changeset.for_create(:create, %{
        order_ref: "PH22_UNPAID_#{System.unique_integer([:positive])}"
      })
      |> Ash.create!(domain: Store.Orders, authorize?: false, context: %{system?: true})

    assert {:error, unpaid_error} = Fulfillment.ensure_fulfillment_for_paid_order(order.id)
    assert unpaid_error.code == "INVALID_STATE_TRANSITION"

    paid_unfinalized_order =
      order
      |> Ash.Changeset.for_update(:mark_paid, %{}, context: %{system?: true})
      |> Ash.update!(domain: Store.Orders, authorize?: false, context: %{system?: true})

    assert {:error, unfinalized_error} =
             Fulfillment.ensure_fulfillment_for_paid_order(paid_unfinalized_order.id)

    assert unfinalized_error.code == "VALIDATION_ERROR"
  end

  test "ensure_fulfillment_for_paid_order is idempotent for duplicate calls" do
    checkout = setup_paid_finalized_checkout!()

    assert {:ok, first} = Fulfillment.ensure_fulfillment_for_paid_order(checkout.order_id)
    assert first.idempotent? == false

    assert {:ok, second} = Fulfillment.ensure_fulfillment_for_paid_order(checkout.order_id)
    assert second.idempotent? == true
    assert second.fulfillment_order.id == first.fulfillment_order.id
  end

  test "fulfillment items are created from immutable order line snapshots" do
    checkout = setup_paid_finalized_checkout!()
    assert {:ok, result} = Fulfillment.ensure_fulfillment_for_paid_order(checkout.order_id)

    assert {:ok, line_items} =
             OrderLineItem
             |> Ash.Query.filter(expr(order_id == ^checkout.order_id))
             |> Ash.read(domain: Store.Orders, authorize?: false, context: %{system?: true})

    assert line_items != []

    snapshot_by_line_id = Map.new(line_items, &{&1.id, &1})

    assert {:ok, fulfillment_order} =
             Fulfillment.get_fulfillment_by_order_id(checkout.order_id)

    assert fulfillment_order.id == result.fulfillment_order.id

    Enum.each(fulfillment_order.items, fn item ->
      line_item = Map.fetch!(snapshot_by_line_id, item.order_line_item_id)
      assert item.variant_id == line_item.variant_id_snapshot
      assert item.quantity == line_item.quantity
      assert item.product_title_snapshot == line_item.product_title_snapshot
      assert item.variant_title_snapshot == line_item.variant_title_snapshot
    end)
  end

  test "support can pack/ship/deliver but cannot cancel fulfillment" do
    support = support_actor!()
    assert Authorization.has_any_role?(support, [:support])

    support_actor = %{id: support.id, role: :support}
    checkout = setup_paid_finalized_checkout!()
    assert {:ok, ensured} = Fulfillment.ensure_fulfillment_for_paid_order(checkout.order_id)
    fulfillment_id = ensured.fulfillment_order.id

    assert {:error, cancel_error} =
             FulfillmentFacade.cancel_fulfillment_for_admin(support_actor, fulfillment_id, %{})

    assert cancel_error.code == "FORBIDDEN"

    assert {:ok, packed} =
             FulfillmentFacade.mark_packed_for_support(support_actor, fulfillment_id)

    assert packed.state == :packed

    tracking_ref = "TRK_#{System.unique_integer([:positive])}"

    assert {:ok, shipped} =
             FulfillmentFacade.mark_shipped_for_support(support_actor, fulfillment_id, %{
               "carrier" => "DHL",
               "tracking_ref" => tracking_ref
             })

    assert shipped.fulfillment_order.state == :shipped
    assert shipped.shipment.state == :in_transit
    assert shipped.shipment.tracking_ref == tracking_ref

    assert {:ok, delivered} =
             FulfillmentFacade.mark_delivered_for_support(support_actor, fulfillment_id)

    assert delivered.fulfillment_order.state == :delivered
  end

  test "customer order detail shows own fulfillment and hides other users fulfillment" do
    owner = TestFixtures.register_user!(email: TestFixtures.unique_email("phase22_owner"))
    other = TestFixtures.register_user!(email: TestFixtures.unique_email("phase22_other"))

    checkout = setup_paid_finalized_checkout!(owner)
    assert {:ok, ensured} = Fulfillment.ensure_fulfillment_for_paid_order(checkout.order_id)

    assert {:ok, owner_detail} = OrdersFacade.get_order_detail_for_user(owner, checkout.order_ref)
    assert owner_detail.fulfillment_order.id == ensured.fulfillment_order.id

    assert {:ok, nil} = OrdersFacade.get_order_detail_for_user(other, checkout.order_ref)
  end

  defp setup_paid_finalized_checkout!(user \\ nil) do
    token = Ash.UUIDv7.generate()
    actor = user || %{cart_token: token}
    variant_id = published_variant_id!()
    _shipping_setup = create_shipping_rules_and_tax!()

    assert {:ok, add_input} = CartItemInput.new(%{"variant_id" => variant_id, "qty" => 1})
    assert {:ok, _cart} = CartsFacade.add_item_for_user(user, token, add_input)
    assert {:ok, start_input} = CheckoutStartInput.new(%{})
    assert {:ok, start_result} = Checkout.start_from_cart(user, token, start_input)

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

    assert {:ok, finalize_input} = CheckoutFinalizeInput.new(%{})

    assert {:ok, _finalized_checkout} =
             Checkout.finalize_totals(actor, start_result.checkout_key, finalize_input)

    order =
      Order
      |> Ash.Query.filter(expr(id == ^start_result.order_id))
      |> Ash.read_one!(domain: Store.Orders, authorize?: false, context: %{system?: true})

    _paid_order =
      order
      |> Ash.Changeset.for_update(:mark_paid, %{}, context: %{system?: true})
      |> Ash.update!(domain: Store.Orders, authorize?: false, context: %{system?: true})

    %{
      order_id: start_result.order_id,
      order_ref: start_result.order_ref,
      actor: actor
    }
  end

  defp quote_selection!(attrs) do
    {:ok, request} = QuoteRequest.new(attrs)
    {:ok, [option | _]} = ShippingFacade.quote_options_for_system(request)
    %{quote_hash: option.quote_hash, shipping_method_code: option.shipping_method_code}
  end

  defp create_shipping_rules_and_tax! do
    unique = System.unique_integer([:positive])

    method =
      ShippingMethod
      |> Ash.Changeset.for_create(
        :create,
        %{code: "GROUND_#{unique}", name: "Ground #{unique}", active: true, sort_order: 100},
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

    _rule =
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

  defp published_variant_id! do
    admin =
      TestFixtures.register_user!(email: TestFixtures.unique_email("phase22_fulfillment_admin"))

    _role = TestFixtures.assign_role!(admin, :admin)

    product =
      Store.Catalog.Product
      |> Ash.Changeset.for_create(
        :create_draft,
        %{
          slug: "phase22-fulfillment-#{System.unique_integer([:positive])}",
          title: "Phase 22 Fulfillment Product",
          base_variant_sku: "P22-FUL-#{System.unique_integer([:positive])}",
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

    published.default_variant_id
  end

  defp support_actor! do
    support = TestFixtures.register_user!(email: TestFixtures.unique_email("phase22_support"))
    _role = TestFixtures.assign_role!(support, :support)
    support
  end
end
