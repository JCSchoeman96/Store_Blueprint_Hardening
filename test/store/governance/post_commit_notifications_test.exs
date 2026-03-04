defmodule Store.Governance.PostCommitNotificationsTest do
  use Store.DataCase, async: false

  alias Store.Orders.{Order, OrderLineItem}
  alias Store.Payments.PaymentIntent
  alias Store.Support.Time
  alias Store.TestFixtures

  test "payment success apply-once path runs without missed notifications" do
    order = create_order!()
    payment_intent = create_submitted_payment_intent!(order.id)

    assert {:ok, first} = Store.Payments.apply_payment_success_once(payment_intent.id)
    assert first.applied? == true

    assert {:ok, second} = Store.Payments.apply_payment_success_once(payment_intent.id)
    assert second.applied? == false
  end

  test "refund request create and replay paths run without missed notifications" do
    %{order: order, payment_intent: payment_intent} = create_refundable_order_fixture!()

    admin = TestFixtures.register_user!(email: TestFixtures.unique_email("admin_notify_gate"))
    _admin_role = TestFixtures.assign_role!(admin, :admin)

    attrs = %{
      order_id: order.id,
      payment_intent_id: payment_intent.id,
      requested_amount_minor: 1000,
      currency: "USD",
      provider: :stripe,
      reason: "requested_by_admin",
      line_item_ids: [],
      idempotency_key: "refund:notify:#{System.unique_integer([:positive])}"
    }

    context = %{step_up_at_mono_usec: Time.now_mono_usec()}

    assert {:ok, first} = Store.Payments.request_refund(attrs, actor: admin, context: context)
    assert {:ok, second} = Store.Payments.request_refund(attrs, actor: admin, context: context)
    assert first.id == second.id
  end

  defp create_refundable_order_fixture! do
    order =
      create_order!()
      |> mark_order_paid!()

    payment_intent = create_succeeded_payment_intent!(order.id, 10_000, "USD")
    create_order_snapshot_line_item!(order.id, 10_000, "USD")

    %{order: order, payment_intent: payment_intent}
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

  defp create_submitted_payment_intent!(order_id) do
    intent =
      PaymentIntent
      |> Ash.Changeset.for_create(
        :create,
        %{order_id: order_id, amount_received_minor: 1_000, provider: :stripe}
      )
      |> Ash.create!(domain: Store.Payments, authorize?: false)

    intent
    |> Ash.Changeset.for_update(:submit, %{}, context: %{system?: true})
    |> Ash.update!(domain: Store.Payments, authorize?: false, context: %{system?: true})
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
      sku_snapshot: "SKU-NOTIFY-1",
      product_title_snapshot: "Notify Test Product",
      variant_title_snapshot: "Default",
      discount_allocated_minor: 0,
      net_line_total_minor: net_line_total_minor
    })
    |> Ash.create!(domain: Store.Orders, authorize?: false)
  end

  defp unique_order_ref do
    "ORDNOTIFY#{System.unique_integer([:positive])}"
  end
end
