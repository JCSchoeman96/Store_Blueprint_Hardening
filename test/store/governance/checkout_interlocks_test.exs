defmodule Store.Governance.CheckoutInterlocksTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Store.OrderFixtures
  alias Store.Orders.{Order, PaymentApplication}
  alias Store.Payments.PaymentIntent
  alias Store.Support.Errors.Error
  alias Store.Support.ID.UUIDv7
  alias Store.TestFixtures

  setup do
    previous = Application.get_env(:store, :payments, [])

    on_exit(fn ->
      Application.put_env(:store, :payments, previous)
    end)

    :ok
  end

  test "begin_checkout is idempotent for same canonical input" do
    as_of = ~U[2026-02-25 18:00:00Z]
    line_a = %{variant_id: UUIDv7.generate(), quantity: 2}
    line_b = %{variant_id: UUIDv7.generate(), quantity: 1}

    attrs = %{
      user_id: UUIDv7.generate(),
      currency: "usd",
      as_of: as_of,
      pricing_contract_version: "phase-13-v1",
      tax_shipping_inputs: %{
        shipping_country_code: "US",
        shipping_region_code: "CA",
        shipping_postal_code: "94105"
      },
      line_items: [line_b, line_a]
    }

    assert {:ok, first} = Store.Orders.begin_checkout(attrs)
    assert {:ok, second} = Store.Orders.begin_checkout(%{attrs | line_items: [line_a, line_b]})

    assert first.order.id == second.order.id
    assert first.checkout_key == second.checkout_key
    assert first.cart_fingerprint == second.cart_fingerprint
    assert first.duplicate? == false
    assert second.duplicate? == true
    assert second.order.state == :pending_payment
  end

  test "begin_checkout key changes when deterministic pricing inputs differ" do
    line = %{variant_id: UUIDv7.generate(), quantity: 1}

    base_attrs = %{
      user_id: UUIDv7.generate(),
      currency: "USD",
      as_of: ~U[2026-02-25 18:00:00Z],
      pricing_contract_version: "phase-13-v1",
      tax_shipping_inputs: %{shipping_country_code: "US", shipping_region_code: "CA"},
      line_items: [line]
    }

    assert {:ok, first} = Store.Orders.begin_checkout(base_attrs)

    assert {:ok, second} =
             Store.Orders.begin_checkout(%{
               base_attrs
               | tax_shipping_inputs: %{shipping_country_code: "US", shipping_region_code: "TX"}
             })

    refute first.checkout_key == second.checkout_key
    refute first.order.id == second.order.id
  end

  test "create_or_reuse_payment_intent is idempotent for same key payload" do
    order = create_order!()

    attrs = %{
      order_id: order.id,
      amount_received_minor: 10_000,
      currency: "usd",
      provider: "stripe"
    }

    assert {:ok, first} = Store.Payments.create_or_reuse_payment_intent(attrs)
    assert {:ok, second} = Store.Payments.create_or_reuse_payment_intent(attrs)

    assert first.payment_intent.id == second.payment_intent.id
    assert first.payment_intent_key == second.payment_intent_key
    assert first.duplicate? == false
    assert second.duplicate? == true
  end

  test "cannot create new payment intent while another is in-flight" do
    order = create_order!()

    assert {:ok, first} =
             Store.Payments.create_or_reuse_payment_intent(%{
               order_id: order.id,
               amount_received_minor: 10_000,
               currency: "USD",
               provider: "stripe"
             })

    _submitted = submit_payment_intent!(first.payment_intent)

    assert {:error, %Error{code: "PAYMENT_INTENT_DUPLICATE"}} =
             Store.Payments.create_or_reuse_payment_intent(%{
               order_id: order.id,
               amount_received_minor: 12_000,
               currency: "USD",
               provider: "stripe"
             })
  end

  test "cannot create new payment intent after succeeded payment exists" do
    order = create_order!()

    assert {:ok, first} =
             Store.Payments.create_or_reuse_payment_intent(%{
               order_id: order.id,
               amount_received_minor: 10_000,
               currency: "USD",
               provider: "stripe"
             })

    first.payment_intent
    |> submit_payment_intent!()
    |> mark_succeeded_payment_intent!()

    assert {:error, %Error{code: "PAYMENT_ALREADY_SUCCEEDED"}} =
             Store.Payments.create_or_reuse_payment_intent(%{
               order_id: order.id,
               amount_received_minor: 12_000,
               currency: "USD",
               provider: "stripe"
             })
  end

  test "apply_payment_success_once is replay-safe and inserts one payment_application" do
    order = create_customer_order!()
    payment_intent = create_submitted_payment_intent!(order.id)

    assert {:ok, first_result} = Store.Payments.apply_payment_success_once(payment_intent.id)
    assert first_result.applied? == true

    assert {:ok, second_result} = Store.Payments.apply_payment_success_once(payment_intent.id)
    assert second_result.applied? == false

    assert 1 ==
             PaymentApplication
             |> Ash.Query.filter(expr(order_id == ^order.id))
             |> Ash.count!(domain: Store.Orders, authorize?: false)

    assert :paid == fetch_order!(order.id).state
    assert :succeeded == fetch_payment_intent!(payment_intent.id).state
  end

  test "create_or_reuse_payment_intent fails closed for missing or unsupported provider" do
    order = create_order!()

    assert {:error, %Error{code: "PAYMENT_PROVIDER_SELECTION_REQUIRED"}} =
             Store.Payments.create_or_reuse_payment_intent(%{
               order_id: order.id,
               amount_received_minor: 10_000,
               currency: "USD"
             })

    assert {:error, %Error{code: "PAYMENT_PROVIDER_UNSUPPORTED"}} =
             Store.Payments.create_or_reuse_payment_intent(%{
               order_id: order.id,
               amount_received_minor: 10_000,
               currency: "USD",
               provider: "nope"
             })

    assert 0 ==
             PaymentIntent
             |> Ash.Query.filter(expr(order_id == ^order.id))
             |> Ash.count!(domain: Store.Payments, authorize?: false)
  end

  test "create_or_reuse_payment_intent fails closed for disabled providers" do
    Application.put_env(:store, :payments,
      enabled_providers: [],
      stripe: [webhook_secret: "whsec_test_only_change_me"]
    )

    order = create_order!()

    assert {:error, %Error{code: "PAYMENT_PROVIDER_DISABLED"}} =
             Store.Payments.create_or_reuse_payment_intent(%{
               order_id: order.id,
               amount_received_minor: 10_000,
               currency: "USD",
               provider: "stripe"
             })

    assert 0 ==
             PaymentIntent
             |> Ash.Query.filter(expr(order_id == ^order.id))
             |> Ash.count!(domain: Store.Payments, authorize?: false)
  end

  defp create_order! do
    Order
    |> Ash.Changeset.for_create(:create, %{})
    |> Ash.create!(domain: Store.Orders, authorize?: false)
  end

  defp create_customer_order! do
    %{order: order} =
      OrderFixtures.create_customer_order!(
        email: TestFixtures.unique_email("checkout_interlocks_customer")
      )

    order
  end

  defp create_submitted_payment_intent!(order_id) do
    PaymentIntent
    |> Ash.Changeset.for_create(
      :create,
      %{order_id: order_id, amount_received_minor: 1_000, provider: :stripe}
    )
    |> Ash.create!(domain: Store.Payments, authorize?: false)
    |> submit_payment_intent!()
  end

  defp submit_payment_intent!(payment_intent) do
    payment_intent
    |> Ash.Changeset.for_update(:submit, %{}, context: %{system?: true})
    |> Ash.update!(domain: Store.Payments, authorize?: false, context: %{system?: true})
  end

  defp mark_succeeded_payment_intent!(payment_intent) do
    payment_intent
    |> Ash.Changeset.for_update(:mark_succeeded, %{}, context: %{system?: true})
    |> Ash.update!(domain: Store.Payments, authorize?: false, context: %{system?: true})
  end

  defp fetch_order!(id) do
    assert {:ok, [order]} =
             Order
             |> Ash.Query.filter(expr(id == ^id))
             |> Ash.read(domain: Store.Orders, authorize?: false)

    order
  end

  defp fetch_payment_intent!(id) do
    assert {:ok, [payment_intent]} =
             PaymentIntent
             |> Ash.Query.filter(expr(id == ^id))
             |> Ash.read(domain: Store.Payments, authorize?: false)

    payment_intent
  end
end
