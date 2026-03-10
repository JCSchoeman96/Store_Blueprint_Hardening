defmodule Store.Payments.ProviderFaultIsolationTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Ecto.Adapters.SQL
  alias Store.Carts.Facade, as: CartsFacade
  alias Store.Carts.Inputs.CartItemInput
  alias Store.Checkout
  alias Store.Checkout.Inputs.{CheckoutFinalizeInput, CheckoutShippingInput, CheckoutStartInput}
  alias Store.Payments
  alias Store.Payments.Inputs.CreateIntentForOrderInput
  alias Store.Payments.PaymentIntent
  alias Store.Pricing.TaxRate
  alias Store.Shipping.Facade, as: ShippingFacade
  alias Store.Shipping.Inputs.QuoteRequest
  alias Store.Shipping.{ShippingMethod, ShippingRateRule, ShippingZone}
  alias Store.Support.Errors.Error
  alias Store.TestFixtures
  alias Store.TestSupport.StripeAPIStub

  @activity_query """
  SELECT
    COUNT(*) FILTER (WHERE state = 'idle in transaction')::bigint AS idle_in_transaction,
    COUNT(*) FILTER (WHERE state = 'active' AND wait_event_type = 'Lock')::bigint AS lock_waiters
  FROM pg_stat_activity
  WHERE datname = current_database()
    AND backend_type = 'client backend'
    AND pid <> pg_backend_pid()
  """

  setup context do
    previous_payments = Application.get_env(:store, :payments, [])
    previous_fault = Application.get_env(:store, :payment_provider_fault_injection, [])
    StripeAPIStub.setup_default(context)

    on_exit(fn ->
      Application.put_env(:store, :payments, previous_payments)
      Application.put_env(:store, :payment_provider_fault_injection, previous_fault)
    end)

    :ok
  end

  test "slow provider delay does not leave Postgres idle in transaction during create_intent_for_order" do
    %{actor: actor, checkout_key: checkout_key, order_id: order_id} = prepare_checkout_context!()
    assert {:ok, input} = CreateIntentForOrderInput.new(%{"provider" => "stripe"})
    baseline = activity_snapshot!()

    notify_ref = make_ref()

    Application.put_env(:store, :payment_provider_fault_injection,
      provider: "stripe",
      mode: :slow,
      delay_ms: 750,
      notify_pid: self(),
      notify_ref: notify_ref
    )

    task =
      Task.async(fn ->
        Payments.create_intent_for_order(actor, checkout_key, input)
      end)

    assert_receive {:payment_provider_fault, :slow, :entered, ^notify_ref}, 1_000

    %{rows: [[idle_in_transaction, lock_waiters]]} =
      SQL.query!(Store.DirectRepo, @activity_query, [])

    assert idle_in_transaction == baseline.idle_in_transaction
    assert lock_waiters == baseline.lock_waiters

    assert {:ok, result} = Task.await(task, 2_000)
    assert result.order_id == order_id
    assert is_binary(result.provider_session_id)
  end

  test "timeout fault returns PAYMENT_PROVIDER_TIMEOUT and does not create duplicate payment intents on retry" do
    %{actor: actor, checkout_key: checkout_key, order_id: order_id} = prepare_checkout_context!()
    assert {:ok, input} = CreateIntentForOrderInput.new(%{"provider" => "stripe"})

    Application.put_env(:store, :payment_provider_fault_injection,
      provider: "stripe",
      mode: :timeout,
      delay_ms: 50
    )

    assert {:error, %Error{code: "PAYMENT_PROVIDER_TIMEOUT"}} =
             Payments.create_intent_for_order(actor, checkout_key, input)

    first_intent = fetch_payment_intent_for_order!(order_id)
    assert first_intent.state == :created
    assert is_nil(first_intent.provider_session_id)

    Application.put_env(:store, :payment_provider_fault_injection, [])

    assert {:ok, retried} = Payments.create_intent_for_order(actor, checkout_key, input)
    assert retried.payment_intent_id == first_intent.id
    assert retried.payment_intent_key == first_intent.payment_intent_key
    assert retried.duplicate? == true
    assert is_binary(retried.provider_session_id)

    assert 1 == payment_intent_count_for_order(order_id)
  end

  test "error fault returns PAYMENT_PROVIDER_DOWN and does not create duplicate payment intents on retry" do
    %{actor: actor, checkout_key: checkout_key, order_id: order_id} = prepare_checkout_context!()
    assert {:ok, input} = CreateIntentForOrderInput.new(%{"provider" => "stripe"})

    Application.put_env(:store, :payment_provider_fault_injection,
      provider: "stripe",
      mode: :error,
      delay_ms: 0
    )

    assert {:error, %Error{code: "PAYMENT_PROVIDER_DOWN"}} =
             Payments.create_intent_for_order(actor, checkout_key, input)

    first_intent = fetch_payment_intent_for_order!(order_id)
    assert first_intent.state == :created
    assert is_nil(first_intent.provider_session_id)

    Application.put_env(:store, :payment_provider_fault_injection, [])

    assert {:ok, retried} = Payments.create_intent_for_order(actor, checkout_key, input)
    assert retried.payment_intent_id == first_intent.id
    assert retried.payment_intent_key == first_intent.payment_intent_key
    assert retried.duplicate? == true
    assert is_binary(retried.provider_session_id)

    assert 1 == payment_intent_count_for_order(order_id)
  end

  defp prepare_checkout_context! do
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
               "recipient_name" => "Fault Injection Customer",
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

    %{
      actor: actor,
      checkout_key: checkout_start.checkout_key,
      order_id: checkout_start.order_id
    }
  end

  defp fetch_payment_intent_for_order!(order_id) do
    assert {:ok, [payment_intent]} =
             PaymentIntent
             |> Ash.Query.filter(expr(order_id == ^order_id))
             |> Ash.read(domain: Store.Payments, authorize?: false)

    payment_intent
  end

  defp activity_snapshot! do
    %{rows: [[idle_in_transaction, lock_waiters]]} =
      SQL.query!(Store.DirectRepo, @activity_query, [])

    %{idle_in_transaction: idle_in_transaction, lock_waiters: lock_waiters}
  end

  defp payment_intent_count_for_order(order_id) do
    PaymentIntent
    |> Ash.Query.filter(expr(order_id == ^order_id))
    |> Ash.count!(domain: Store.Payments, authorize?: false)
  end

  defp create_pricing_rules! do
    unique = System.unique_integer([:positive])
    method_code = "GROUND-FAULT-#{unique}"

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
        %{code: "US-CA-FAULT-#{unique}", country_code: "US", region_code: "CA", active: true},
        context: %{system?: true}
      )
      |> Ash.create!(domain: Store.Shipping, authorize?: false, context: %{system?: true})

    _rate =
      ShippingRateRule
      |> Ash.Changeset.for_create(
        :create,
        %{
          code: "GROUND_RULE_FAULT_#{unique}",
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
          code: "CA-STANDARD-FAULT-#{unique}",
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
    admin = TestFixtures.register_user!(email: TestFixtures.unique_email("phase29_fault_admin"))
    _role = TestFixtures.assign_role!(admin, :admin)

    product =
      Store.Catalog.Product
      |> Ash.Changeset.for_create(
        :create_draft,
        %{
          slug: "phase29-fault-#{System.unique_integer([:positive])}",
          title: "Phase 29 Fault Product",
          base_variant_sku: "P29-FAULT-#{System.unique_integer([:positive])}",
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
end
