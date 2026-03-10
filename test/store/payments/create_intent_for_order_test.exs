defmodule Store.Payments.CreateIntentForOrderTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Store.Carts.Facade, as: CartsFacade
  alias Store.Carts.Inputs.CartItemInput
  alias Store.Checkout
  alias Store.Checkout.Inputs.{CheckoutFinalizeInput, CheckoutShippingInput, CheckoutStartInput}
  alias Store.Digital.{DigitalAsset, ProductDigitalLink}
  alias Store.Payments
  alias Store.Payments.Inputs.CreateIntentForOrderInput
  alias Store.Payments.PaymentIntent
  alias Store.Pricing.TaxRate
  alias Store.Shipping.Facade, as: ShippingFacade
  alias Store.Shipping.Inputs.QuoteRequest
  alias Store.Shipping.{ShippingMethod, ShippingRateRule, ShippingZone}
  alias Store.TestFixtures
  alias Store.TestSupport.StripeAPIStub

  setup context do
    previous = Application.get_env(:store, :payments, [])
    StripeAPIStub.setup_default(context)

    on_exit(fn ->
      Application.put_env(:store, :payments, previous)
    end)

    :ok
  end

  test "create_intent_for_order requires finalized totals" do
    token = Ash.UUIDv7.generate()
    actor = %{cart_token: token}
    variant_id = published_variant_id!()

    assert {:ok, add_input} = CartItemInput.new(%{"variant_id" => variant_id, "qty" => 1})
    assert {:ok, _cart} = CartsFacade.add_item_for_user(nil, token, add_input)

    assert {:ok, start_input} = CheckoutStartInput.new(%{})
    assert {:ok, checkout_start} = Checkout.start_from_cart(nil, token, start_input)

    assert {:ok, create_intent_input} = CreateIntentForOrderInput.new(%{"provider" => "stripe"})

    assert {:error, error} =
             Payments.create_intent_for_order(
               actor,
               checkout_start.checkout_key,
               create_intent_input
             )

    assert error.code == "VALIDATION_ERROR"
  end

  test "create_intent_for_order uses finalized totals and is idempotent" do
    token = Ash.UUIDv7.generate()
    actor = %{cart_token: token}
    variant_id = published_variant_id!()
    create_pricing_rules!()

    assert {:ok, add_input} = CartItemInput.new(%{"variant_id" => variant_id, "qty" => 2})
    assert {:ok, _cart} = CartsFacade.add_item_for_user(nil, token, add_input)

    assert {:ok, start_input} = CheckoutStartInput.new(%{})
    assert {:ok, checkout_start} = Checkout.start_from_cart(nil, token, start_input)

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
             Checkout.set_shipping(actor, checkout_start.checkout_key, shipping_input)

    assert {:ok, finalize_input} = CheckoutFinalizeInput.new(%{})

    assert {:ok, finalized_checkout} =
             Checkout.finalize_totals(actor, checkout_start.checkout_key, finalize_input)

    assert finalized_checkout.totals_finalized?
    assert finalized_checkout.grand_total_minor > 0

    assert {:ok, create_intent_input} = CreateIntentForOrderInput.new(%{"provider" => "stripe"})

    assert {:ok, first} =
             Payments.create_intent_for_order(
               actor,
               checkout_start.checkout_key,
               create_intent_input
             )

    assert first.amount_minor == finalized_checkout.grand_total_minor
    assert first.currency == finalized_checkout.currency_code
    assert first.state == :submitted
    assert is_binary(first.provider_session_id)
    assert is_binary(first.redirect_url)

    assert {:ok, second} =
             Payments.create_intent_for_order(
               actor,
               checkout_start.checkout_key,
               create_intent_input
             )

    assert second.payment_intent_id == first.payment_intent_id
    assert second.payment_intent_key == first.payment_intent_key
    assert second.duplicate? == true
  end

  test "create_intent_for_order denies guest actor when checkout includes digital-linked items" do
    token = Ash.UUIDv7.generate()
    guest_actor = %{cart_token: token}
    {variant_id, _admin, _product} = published_variant_with_admin!()
    create_digital_link_for_variant!(variant_id)
    create_pricing_rules!()

    assert {:ok, add_input} = CartItemInput.new(%{"variant_id" => variant_id, "qty" => 1})
    assert {:ok, _cart} = CartsFacade.add_item_for_user(nil, token, add_input)

    assert {:ok, start_input} = CheckoutStartInput.new(%{})
    assert {:ok, checkout_start} = Checkout.start_from_cart(nil, token, start_input)

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
               "recipient_name" => "Digital Guest",
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
             Checkout.set_shipping(guest_actor, checkout_start.checkout_key, shipping_input)

    assert {:ok, finalize_input} = CheckoutFinalizeInput.new(%{})

    assert {:ok, _finalized_checkout} =
             Checkout.finalize_totals(guest_actor, checkout_start.checkout_key, finalize_input)

    assert {:ok, create_intent_input} = CreateIntentForOrderInput.new(%{"provider" => "stripe"})

    assert {:error, error} =
             Payments.create_intent_for_order(
               guest_actor,
               checkout_start.checkout_key,
               create_intent_input
             )

    assert error.code == "DIGITAL_GRANT_DENIED"
  end

  test "create_intent_for_order rejects unknown provider input before persisting" do
    token = Ash.UUIDv7.generate()
    actor = %{cart_token: token}
    variant_id = published_variant_id!()
    create_pricing_rules!()

    assert {:ok, add_input} = CartItemInput.new(%{"variant_id" => variant_id, "qty" => 1})
    assert {:ok, _cart} = CartsFacade.add_item_for_user(nil, token, add_input)

    assert {:ok, start_input} = CheckoutStartInput.new(%{})
    assert {:ok, checkout_start} = Checkout.start_from_cart(nil, token, start_input)

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
               "recipient_name" => "Provider Test",
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
             Checkout.set_shipping(actor, checkout_start.checkout_key, shipping_input)

    assert {:ok, finalize_input} = CheckoutFinalizeInput.new(%{})

    assert {:ok, _finalized_checkout} =
             Checkout.finalize_totals(actor, checkout_start.checkout_key, finalize_input)

    assert {:error, error} = CreateIntentForOrderInput.new(%{"provider" => "not_real"})
    assert error.code == "PAYMENT_PROVIDER_UNSUPPORTED"

    assert 0 ==
             PaymentIntent
             |> Ash.Query.filter(expr(order_id == ^checkout_start.order_id))
             |> Ash.count!(domain: Store.Payments, authorize?: false)
  end

  test "create_intent_for_order rejects disabled provider and does not persist intent" do
    Application.put_env(:store, :payments,
      enabled_providers: [],
      stripe: [webhook_secret: "whsec_test_only_change_me"]
    )

    token = Ash.UUIDv7.generate()
    actor = %{cart_token: token}
    variant_id = published_variant_id!()
    create_pricing_rules!()

    assert {:ok, add_input} = CartItemInput.new(%{"variant_id" => variant_id, "qty" => 1})
    assert {:ok, _cart} = CartsFacade.add_item_for_user(nil, token, add_input)

    assert {:ok, start_input} = CheckoutStartInput.new(%{})
    assert {:ok, checkout_start} = Checkout.start_from_cart(nil, token, start_input)

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
               "recipient_name" => "Provider Disabled Test",
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
             Checkout.set_shipping(actor, checkout_start.checkout_key, shipping_input)

    assert {:ok, finalize_input} = CheckoutFinalizeInput.new(%{})

    assert {:ok, _finalized_checkout} =
             Checkout.finalize_totals(actor, checkout_start.checkout_key, finalize_input)

    assert {:ok, create_intent_input} = CreateIntentForOrderInput.new(%{"provider" => "stripe"})

    assert {:error, error} =
             Payments.create_intent_for_order(
               actor,
               checkout_start.checkout_key,
               create_intent_input
             )

    assert error.code == "PAYMENT_PROVIDER_DISABLED"

    assert 0 ==
             PaymentIntent
             |> Ash.Query.filter(expr(order_id == ^checkout_start.order_id))
             |> Ash.count!(domain: Store.Payments, authorize?: false)
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

  defp published_variant_id! do
    {variant_id, _admin, _product} = published_variant_with_admin!()
    variant_id
  end

  defp published_variant_with_admin! do
    admin = TestFixtures.register_user!(email: TestFixtures.unique_email("phase21_pay_admin"))
    _role = TestFixtures.assign_role!(admin, :admin)

    product =
      Store.Catalog.Product
      |> Ash.Changeset.for_create(
        :create_draft,
        %{
          slug: "phase21-pay-#{System.unique_integer([:positive])}",
          title: "Phase 21 Pay Product",
          base_variant_sku: "P21-PAY-#{System.unique_integer([:positive])}",
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

  defp create_digital_link_for_variant!(variant_id) do
    digital_asset =
      DigitalAsset
      |> Ash.Changeset.for_create(:create, %{
        key: "phase24-digital-link-#{System.unique_integer([:positive])}",
        title: "Phase 24 Digital Link",
        content_type: "application/pdf",
        byte_size: 1024,
        storage_provider: "s3",
        storage_bucket: "downloads-bucket",
        storage_object_key: "assets/phase24.pdf",
        status: :active
      })
      |> Ash.create!(domain: Store.Digital, authorize?: false, context: %{system?: true})

    ProductDigitalLink
    |> Ash.Changeset.for_create(
      :create,
      %{
        variant_id: variant_id,
        digital_asset_id: digital_asset.id,
        position: 0
      },
      context: %{system?: true}
    )
    |> Ash.create!(domain: Store.Digital, authorize?: false, context: %{system?: true})
  end
end
