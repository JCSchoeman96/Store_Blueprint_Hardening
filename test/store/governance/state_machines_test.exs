defmodule Store.Governance.StateMachinesTest do
  use Store.DataCase, async: false

  alias Store.Orders.Order
  alias Store.Payments.PaymentIntent

  test "order allows pending_payment to paid and paid to refunded" do
    order = create_order!()
    assert order.state == :pending_payment
    assert order.version == 1

    paid_order = update_order!(order, :mark_paid)
    assert paid_order.state == :paid
    assert paid_order.version == 2

    refunded_order = update_order!(paid_order, :mark_refunded)
    assert refunded_order.state == :refunded
    assert refunded_order.version == 3
  end

  test "order supports explicit payment_failed transition" do
    order = create_order!()
    failed_order = update_order!(order, :mark_payment_failed)

    assert failed_order.state == :payment_failed
    assert failed_order.version == 2
  end

  test "order forbidden transition returns INVALID_STATE_TRANSITION" do
    order = create_order!()

    assert {:error, error} =
             order
             |> Ash.Changeset.for_update(:mark_refunded, %{})
             |> Ash.update(domain: Store.Orders, authorize?: false)

    assert Exception.message(error) =~ "INVALID_STATE_TRANSITION"
  end

  test "order replay noop returns success without version bump" do
    order = create_order!()
    paid_order = update_order!(order, :mark_paid)
    replay_paid_order = update_order!(paid_order, :mark_paid)

    assert replay_paid_order.state == :paid
    assert replay_paid_order.version == paid_order.version
  end

  test "payment intent supports submit and mark_failed transitions" do
    intent = create_payment_intent!()
    assert intent.state == :created
    assert intent.version == 1

    submitted_intent = update_payment_intent!(intent, :submit)
    assert submitted_intent.state == :submitted
    assert submitted_intent.version == 2

    failed_intent = update_payment_intent!(submitted_intent, :mark_failed)
    assert failed_intent.state == :failed
    assert failed_intent.version == 3
  end

  test "payment intent forbidden transition returns INVALID_STATE_TRANSITION" do
    intent = create_payment_intent!()

    assert {:error, error} =
             intent
             |> Ash.Changeset.for_update(:mark_succeeded, %{})
             |> Ash.update(domain: Store.Payments, authorize?: false)

    assert Exception.message(error) =~ "INVALID_STATE_TRANSITION"
  end

  test "payment intent replay noop returns success without version bump" do
    intent = create_payment_intent!()
    submitted_intent = update_payment_intent!(intent, :submit)
    failed_intent = update_payment_intent!(submitted_intent, :mark_failed)
    replay_failed_intent = update_payment_intent!(failed_intent, :mark_failed)

    assert replay_failed_intent.state == :failed
    assert replay_failed_intent.version == failed_intent.version
  end

  defp create_order! do
    Order
    |> Ash.Changeset.for_create(:create, %{})
    |> Ash.create!(domain: Store.Orders, authorize?: false)
  end

  defp create_payment_intent! do
    PaymentIntent
    |> Ash.Changeset.for_create(:create, %{provider: :stripe})
    |> Ash.create!(domain: Store.Payments, authorize?: false)
  end

  defp update_order!(order, action) do
    order
    |> Ash.Changeset.for_update(action, %{})
    |> Ash.update!(domain: Store.Orders, authorize?: false)
  end

  defp update_payment_intent!(intent, action) do
    intent
    |> Ash.Changeset.for_update(action, %{})
    |> Ash.update!(domain: Store.Payments, authorize?: false)
  end
end
