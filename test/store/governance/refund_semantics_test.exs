defmodule Store.Governance.RefundSemanticsTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Store.Orders.{Order, OrderLineItem}
  alias Store.Payments.{PaymentIntent, Refund}
  alias Store.Support.Errors.Error
  alias Store.Support.Time
  alias Store.TestFixtures

  test "refund requires admin role and recent step-up" do
    %{order: order, payment_intent: payment_intent} = create_refundable_order_fixture!()

    support = TestFixtures.register_user!(email: TestFixtures.unique_email("support_refund"))
    _support_role = TestFixtures.assign_role!(support, :support)

    attrs = refund_request_attrs(order.id, payment_intent.id, 1000)

    assert {:error, %Error{code: "FORBIDDEN"}} =
             Store.Payments.request_refund(
               attrs,
               actor: support,
               context: %{step_up_at_mono_usec: Time.now_mono_usec()}
             )

    admin = TestFixtures.register_user!(email: TestFixtures.unique_email("admin_refund"))
    _admin_role = TestFixtures.assign_role!(admin, :admin)

    assert {:error, %Error{code: "STEP_UP_REQUIRED"}} =
             Store.Payments.request_refund(attrs, actor: admin, context: %{})

    assert {:ok, refund} =
             Store.Payments.request_refund(
               attrs,
               actor: admin,
               context: %{step_up_at_mono_usec: Time.now_mono_usec()}
             )

    assert refund.state == :requested
  end

  test "duplicate refund request returns existing and mismatch reuse is rejected" do
    %{order: order, payment_intent: payment_intent} = create_refundable_order_fixture!()

    admin = TestFixtures.register_user!(email: TestFixtures.unique_email("admin_idempotency"))
    _admin_role = TestFixtures.assign_role!(admin, :admin)

    common_idempotency_key = "refund:manual:idempotency:key:001"

    attrs =
      refund_request_attrs(order.id, payment_intent.id, 2000)
      |> Map.put(:idempotency_key, common_idempotency_key)

    assert {:ok, first} =
             Store.Payments.request_refund(
               attrs,
               actor: admin,
               context: %{step_up_at_mono_usec: Time.now_mono_usec()}
             )

    assert {:ok, second} =
             Store.Payments.request_refund(
               attrs,
               actor: admin,
               context: %{step_up_at_mono_usec: Time.now_mono_usec()}
             )

    assert first.id == second.id

    mismatch_attrs =
      attrs
      |> Map.put(:requested_amount_minor, 1000)
      |> Map.put(:reason, "different")

    assert {:error, %Error{code: "IDEMPOTENCY_KEY_REUSE_MISMATCH"}} =
             Store.Payments.request_refund(
               mismatch_attrs,
               actor: admin,
               context: %{step_up_at_mono_usec: Time.now_mono_usec()}
             )
  end

  test "refund request cannot exceed refundable remaining and currency must match payment intent" do
    %{order: order, payment_intent: payment_intent} = create_refundable_order_fixture!()

    admin = TestFixtures.register_user!(email: TestFixtures.unique_email("admin_bounds"))
    _admin_role = TestFixtures.assign_role!(admin, :admin)

    first_attrs = refund_request_attrs(order.id, payment_intent.id, 7000)
    second_attrs = refund_request_attrs(order.id, payment_intent.id, 4000)

    assert {:ok, _first_refund} =
             Store.Payments.request_refund(
               first_attrs,
               actor: admin,
               context: %{step_up_at_mono_usec: Time.now_mono_usec()}
             )

    assert {:error, %Error{code: "REFUND_EXCEEDS_REFUNDABLE"}} =
             Store.Payments.request_refund(
               second_attrs,
               actor: admin,
               context: %{step_up_at_mono_usec: Time.now_mono_usec()}
             )

    assert {:error, %Error{code: "CURRENCY_MISMATCH"}} =
             Store.Payments.request_refund(
               refund_request_attrs(order.id, payment_intent.id, 1000, "EUR"),
               actor: admin,
               context: %{step_up_at_mono_usec: Time.now_mono_usec()}
             )
  end

  test "concurrent refund requests are serialized by payment intent lock" do
    %{order: order, payment_intent: payment_intent} = create_refundable_order_fixture!()

    admin = TestFixtures.register_user!(email: TestFixtures.unique_email("admin_locking"))
    _admin_role = TestFixtures.assign_role!(admin, :admin)

    context = %{step_up_at_mono_usec: Time.now_mono_usec()}

    attrs_a =
      refund_request_attrs(order.id, payment_intent.id, 6000)
      |> Map.put(:idempotency_key, "refund:concurrency:key:a")

    attrs_b =
      refund_request_attrs(order.id, payment_intent.id, 6000)
      |> Map.put(:idempotency_key, "refund:concurrency:key:b")

    task_a =
      Task.async(fn ->
        Store.Payments.request_refund(attrs_a, actor: admin, context: context)
      end)

    task_b =
      Task.async(fn ->
        Store.Payments.request_refund(attrs_b, actor: admin, context: context)
      end)

    results = [Task.await(task_a, 15_000), Task.await(task_b, 15_000)]

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1

    assert Enum.count(results, &match?({:error, %Error{code: "REFUND_EXCEEDS_REFUNDABLE"}}, &1)) ==
             1

    count =
      Refund
      |> Ash.Query.filter(expr(order_id == ^order.id and payment_intent_id == ^payment_intent.id))
      |> Ash.count!(domain: Store.Payments, authorize?: false)

    assert count == 1
  end

  defp create_refundable_order_fixture! do
    order = create_order!()
    paid_order = mark_order_paid!(order)
    payment_intent = create_succeeded_payment_intent!(paid_order.id, 10_000, "USD")
    create_order_snapshot_line_item!(paid_order.id, 10_000, "USD")

    %{order: paid_order, payment_intent: payment_intent}
  end

  defp create_order! do
    Order
    |> Ash.Changeset.for_create(:create, %{order_ref: unique_order_ref()})
    |> Ash.create!(domain: Store.Orders, authorize?: false)
  end

  defp mark_order_paid!(order) do
    order
    |> Ash.Changeset.for_update(:mark_paid, %{}, context: %{system?: true})
    |> Ash.update!(domain: Store.Orders, authorize?: false, context: %{system?: true})
  end

  defp create_succeeded_payment_intent!(order_id, amount_received_minor, currency) do
    intent =
      PaymentIntent
      |> Ash.Changeset.for_create(:create, %{
        order_id: order_id,
        amount_received_minor: amount_received_minor,
        currency: currency,
        provider: :stripe
      })
      |> Ash.create!(domain: Store.Payments, authorize?: false)

    submitted_intent =
      intent
      |> Ash.Changeset.for_update(:submit, %{}, context: %{system?: true})
      |> Ash.update!(domain: Store.Payments, authorize?: false, context: %{system?: true})

    submitted_intent
    |> Ash.Changeset.for_update(:mark_succeeded, %{}, context: %{system?: true})
    |> Ash.update!(domain: Store.Payments, authorize?: false, context: %{system?: true})
  end

  defp create_order_snapshot_line_item!(order_id, net_line_total_minor, currency) do
    OrderLineItem
    |> Ash.Changeset.for_create(:create, %{
      order_id: order_id,
      line_no: 1,
      currency: currency,
      quantity: 1,
      unit_price_minor: net_line_total_minor,
      line_total_minor: net_line_total_minor,
      sku_snapshot: "SKU-REFUND-1",
      product_title_snapshot: "Refund Test Product",
      variant_title_snapshot: "Default",
      discount_allocated_minor: 0,
      net_line_total_minor: net_line_total_minor
    })
    |> Ash.create!(domain: Store.Orders, authorize?: false)
  end

  defp refund_request_attrs(order_id, payment_intent_id, amount_minor, currency \\ "USD") do
    %{
      order_id: order_id,
      payment_intent_id: payment_intent_id,
      requested_amount_minor: amount_minor,
      currency: currency,
      provider: :stripe,
      reason: "requested_by_admin",
      line_item_ids: []
    }
  end

  defp unique_order_ref do
    "ORDREFUND#{System.unique_integer([:positive])}"
  end
end
