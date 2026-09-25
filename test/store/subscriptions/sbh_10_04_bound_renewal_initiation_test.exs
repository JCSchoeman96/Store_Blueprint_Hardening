defmodule Store.Subscriptions.Sbh1004BoundRenewalInitiationTest do
  use Store.DataCase, async: false

  import Ash.Expr
  import Ecto.Query
  require Ash.Query

  alias Store.Orders.{Order, OrderLineItem}
  alias Store.Payments.PaymentIntent
  alias Store.Repo

  alias Store.Subscriptions.Inputs.QueueSubscriptionPlanChangeInput

  alias Store.Subscriptions.{
    ContractChange,
    Facade,
    RenewalAttempt,
    Subscription
  }

  alias Store.SubscriptionsFixtures
  alias Store.Support.Telemetry.RepoStats
  alias Store.TestSupport.StripeAPIStub

  setup context do
    StripeAPIStub.setup_default(context)
  end

  test "new virtual renewal snapshot records the attempt's exact revision and payable contract" do
    fixture = create_due_renewal_fixture!("sbh_10_04_snapshot")

    {result, renewal_stats} =
      RepoStats.capture(fn ->
        Facade.process_due_subscription_renewal_for_system(fixture.subscription.id,
          now: fixture.now
        )
      end)

    assert {:ok, :processed} = result
    assert renewal_stats.query_count == 45

    attempt = fetch_attempt!(fixture.subscription.id)
    order = fetch_order!(attempt.order_id)
    payment_intent = fetch_payment_intent!(attempt.payment_intent_id)
    [line_item] = fetch_order_line_items!(order.id)

    assert attempt.charged_contract_version == 1
    assert attempt.plan_revision_id == fixture.revision.id
    assert attempt.variant_id == fixture.variant.id
    assert attempt.quantity == 2
    assert attempt.amount_minor == 1_300
    assert attempt.currency == "USD"

    assert line_item.variant_id_snapshot == attempt.variant_id
    assert line_item.quantity == attempt.quantity
    assert line_item.unit_price_minor == attempt.amount_minor
    assert line_item.currency == attempt.currency
    assert line_item.line_total_minor == attempt.amount_minor * attempt.quantity
    assert line_item.net_line_total_minor == attempt.amount_minor * attempt.quantity
    assert line_item.discount_allocated_minor == 0
    assert line_item.subscription_plan_id_snapshot == fixture.plan.id
    assert line_item.subscription_plan_revision_id_snapshot == attempt.plan_revision_id

    assert line_item.subscription_plan_key_snapshot ==
             attempt.charged_contract_snapshot["subscription_plan_key"]

    assert line_item.subscription_interval_unit_snapshot == "day"
    assert line_item.subscription_interval_count_snapshot == 1

    assert order.currency_code == attempt.currency
    assert order.items_subtotal_minor == attempt.amount_minor * attempt.quantity
    assert order.shipping_total_minor == 0
    assert order.grand_total_minor == attempt.amount_minor * attempt.quantity
    assert order.totals_finalized_at

    assert payment_intent.order_id == order.id
    assert payment_intent.amount_received_minor == order.grand_total_minor
    assert payment_intent.currency == order.currency_code
    assert payment_intent.payment_intent_key == "renewal:" <> attempt.renewal_key
  end

  test "retry keeps A after plan, catalog, and pending contract state changes" do
    fixture = create_due_renewal_fixture!("sbh_10_04_mutable_state")

    assert {:ok, :processed} =
             Facade.process_due_subscription_renewal_for_system(fixture.subscription.id,
               now: fixture.now
             )

    attempt = fetch_attempt!(fixture.subscription.id)
    order = fetch_order!(attempt.order_id)
    payment_intent = fetch_payment_intent!(attempt.payment_intent_id)
    [original_line] = fetch_order_line_items!(order.id)

    changed_plan =
      fixture.plan
      |> Ash.Changeset.for_update(
        :update,
        %{amount_minor: 9_900, currency: "EUR", interval_unit: :month, interval_count: 6},
        context: %{system?: true}
      )
      |> Ash.update!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    changed_variant =
      fixture.variant
      |> Ash.Changeset.for_update(
        :update,
        %{
          sku: "CHANGED-#{fixture.variant.id}",
          title: "Changed catalog title",
          currency_code: "EUR",
          price_minor: 8_800
        },
        context: %{system?: true}
      )
      |> Ash.update!(domain: Store.Catalog, authorize?: false, context: %{system?: true})

    target_plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        interval_unit: :month,
        interval_count: 3,
        amount_minor: 7_700,
        currency: "GBP"
      })

    SubscriptionsFixtures.attach_variant_plan!(changed_variant.id, target_plan.id)
    target_revision = SubscriptionsFixtures.create_plan_revision!(target_plan)

    {:ok, queued_subscription} =
      queue_plan_change(
        fixture.customer,
        fetch_subscription!(fixture.subscription.id),
        target_plan
      )

    target_id = queued_subscription.current_contract_change_id
    queued_target = fetch_contract_change!(target_id)

    assert changed_plan.amount_minor == 9_900
    assert changed_plan.currency == "EUR"
    assert changed_plan.interval_unit == :month
    assert changed_plan.interval_count == 6
    assert changed_variant.price_minor == 8_800
    assert changed_variant.currency_code == "EUR"
    assert queued_target.status == :queued
    assert queued_target.target_plan_revision_id == target_revision.id
    assert queued_subscription.pending_renewal_amount_minor == 7_700
    assert queued_subscription.pending_renewal_currency == "GBP"

    fail_attempt!(attempt)

    StripeAPIStub.stub_payment_intent(fn conn, params ->
      assert params["amount"] == "2600"
      assert params["currency"] == "usd"
      assert params["metadata[renewal_key]"] == attempt.renewal_key
      assert params["metadata[renewal_attempt_id]"] == attempt.id
      assert params["metadata[order_id]"] == order.id
      assert params["metadata[local_intent_id]"] == payment_intent.id
      assert params["metadata[subscription_id]"] == fixture.subscription.id
      assert Plug.Conn.get_req_header(conn, "idempotency-key") == [attempt.renewal_key]

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(StripeAPIStub.payment_intent_response(params)))
    end)

    assert {:ok, :processed} =
             Facade.process_due_subscription_renewal_for_system(fixture.subscription.id,
               now: fixture.now
             )

    retried_attempt = fetch_attempt!(fixture.subscription.id)
    retried_order = fetch_order!(retried_attempt.order_id)
    retried_intent = fetch_payment_intent!(retried_attempt.payment_intent_id)
    [retried_line] = fetch_order_line_items!(retried_order.id)

    assert retried_attempt.id == attempt.id
    assert retried_attempt.plan_revision_id == fixture.revision.id
    assert retried_attempt.variant_id == fixture.variant.id
    assert retried_attempt.quantity == 2
    assert retried_attempt.amount_minor == 1_300
    assert retried_attempt.currency == "USD"
    assert retried_attempt.contract_change_id == nil
    assert retried_attempt.payment_intent_id == payment_intent.id
    assert retried_order.id == order.id
    assert retried_order.grand_total_minor == 2_600
    assert retried_intent.id == payment_intent.id
    assert retried_intent.amount_received_minor == 2_600
    assert retried_intent.currency == "USD"
    assert retried_intent.order_id == order.id

    assert Map.take(retried_line, [
             :variant_id_snapshot,
             :quantity,
             :unit_price_minor,
             :currency,
             :line_total_minor,
             :net_line_total_minor,
             :subscription_plan_id_snapshot,
             :subscription_plan_revision_id_snapshot,
             :subscription_plan_key_snapshot,
             :subscription_interval_unit_snapshot,
             :subscription_interval_count_snapshot,
             :sku_snapshot,
             :variant_title_snapshot
           ]) ==
             Map.take(original_line, [
               :variant_id_snapshot,
               :quantity,
               :unit_price_minor,
               :currency,
               :line_total_minor,
               :net_line_total_minor,
               :subscription_plan_id_snapshot,
               :subscription_plan_revision_id_snapshot,
               :subscription_plan_key_snapshot,
               :subscription_interval_unit_snapshot,
               :subscription_interval_count_snapshot,
               :sku_snapshot,
               :variant_title_snapshot
             ])

    assert fetch_contract_change!(target_id).status == :queued

    assert fetch_subscription!(fixture.subscription.id).pending_subscription_plan_id ==
             target_plan.id
  end

  test "conflicting immutable renewal line fails closed and remains unchanged" do
    fixture = create_due_renewal_fixture!("sbh_10_04_order_mismatch")

    assert {:ok, :processed} =
             Facade.process_due_subscription_renewal_for_system(fixture.subscription.id,
               now: fixture.now
             )

    attempt = fetch_attempt!(fixture.subscription.id)
    [line_item] = fetch_order_line_items!(attempt.order_id)
    corrupted_unit_price = attempt.amount_minor + 1

    Repo.update_all(
      from(line in OrderLineItem, where: line.id == ^line_item.id),
      set: [unit_price_minor: corrupted_unit_price]
    )

    fail_attempt!(attempt)
    payment_intent_count = Repo.aggregate(PaymentIntent, :count, :id)
    StripeAPIStub.stub_unexpected!("conflicting Order evidence must stop before payment work")

    assert {:error, %{code: "VALIDATION_ERROR"}} =
             Facade.process_due_subscription_renewal_for_system(fixture.subscription.id,
               now: fixture.now
             )

    [unchanged_line] = fetch_order_line_items!(attempt.order_id)
    assert unchanged_line.unit_price_minor == corrupted_unit_price
    assert Repo.aggregate(PaymentIntent, :count, :id) == payment_intent_count
  end

  test "same-key PaymentIntent with wrong amount, currency, or Order fails before provider work" do
    mismatches = [
      {:amount_received_minor, 2_601},
      {:currency, "EUR"},
      {:order_id, :source_order},
      {:provider, :payfast}
    ]

    for {field, value} <- mismatches do
      fixture = create_due_renewal_fixture!("sbh_10_04_intent_#{field}")
      StripeAPIStub.stub_default()

      assert {:ok, :processed} =
               Facade.process_due_subscription_renewal_for_system(fixture.subscription.id,
                 now: fixture.now
               )

      attempt = fetch_attempt!(fixture.subscription.id)
      payment_intent = fetch_payment_intent!(attempt.payment_intent_id)
      mismatched_value = if value == :source_order, do: fixture.order.id, else: value

      Repo.update_all(
        from(intent in PaymentIntent, where: intent.id == ^payment_intent.id),
        set: [{field, mismatched_value}]
      )

      fail_attempt!(attempt)
      payment_intent_count = Repo.aggregate(PaymentIntent, :count, :id)

      StripeAPIStub.stub_unexpected!(
        "mismatched PaymentIntent evidence must stop before provider work"
      )

      assert {:error, %{code: "VALIDATION_ERROR"}} =
               Facade.process_due_subscription_renewal_for_system(fixture.subscription.id,
                 now: fixture.now
               )

      assert Repo.aggregate(PaymentIntent, :count, :id) == payment_intent_count
      assert fetch_payment_intent!(payment_intent.id) |> Map.fetch!(field) == mismatched_value
    end
  end

  test "an attempt cannot replace its recorded PaymentIntent with another identity" do
    fixture = create_due_renewal_fixture!("sbh_10_04_intent_identity")

    assert {:ok, :processed} =
             Facade.process_due_subscription_renewal_for_system(fixture.subscription.id,
               now: fixture.now
             )

    attempt = fetch_attempt!(fixture.subscription.id)
    original_intent_id = attempt.payment_intent_id
    other_intent = fetch_payment_intent_for_order!(fixture.order.id)

    assert other_intent.id != original_intent_id

    attempt
    |> Ash.Changeset.for_update(
      :mark_processing,
      %{order_id: attempt.order_id, payment_intent_id: other_intent.id},
      context: %{system?: true}
    )
    |> Ash.update!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
    |> fail_attempt!()

    StripeAPIStub.stub_unexpected!(
      "an attempt with a conflicting intent ID must stop before provider work"
    )

    assert {:error, %{code: "VALIDATION_ERROR"}} =
             Facade.process_due_subscription_renewal_for_system(fixture.subscription.id,
               now: fixture.now
             )

    assert fetch_attempt!(fixture.subscription.id).payment_intent_id == other_intent.id

    assert fetch_payment_intent!(original_intent_id).payment_intent_key ==
             "renewal:" <> attempt.renewal_key
  end

  defp create_due_renewal_fixture!(token) do
    customer = SubscriptionsFixtures.create_customer!(token)
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        interval_unit: :day,
        interval_count: 1,
        amount_minor: 1_300,
        currency: "USD"
      })

    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
    revision = SubscriptionsFixtures.create_plan_revision!(plan)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    fixture =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        started_at: DateTime.add(now, -86_410, :second),
        next_renewal_at: DateTime.add(now, -10, :second),
        quantity: 2,
        provider_billing_ref: "pm_#{token}"
      })

    Map.merge(fixture, %{
      customer: customer,
      variant: variant,
      plan: plan,
      revision: revision,
      now: now
    })
  end

  defp fetch_attempt!(subscription_id) do
    RenewalAttempt
    |> Ash.Query.filter(expr(subscription_id == ^subscription_id))
    |> Ash.Query.sort(inserted_at: :desc, id: :desc)
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp fail_attempt!(%RenewalAttempt{} = attempt) do
    attempt
    |> Ash.Changeset.for_update(
      :mark_failed,
      %{failure_code: "PAYMENT_FAILED", failure_message: "retry fixture"},
      context: %{system?: true}
    )
    |> Ash.update!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp fetch_subscription!(id) do
    Subscription
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp fetch_contract_change!(id) do
    ContractChange
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp queue_plan_change(actor, subscription, plan) do
    {:ok, input} =
      QueueSubscriptionPlanChangeInput.new(%{
        "subscription_id" => subscription.id,
        "subscription_plan_id" => plan.id
      })

    Facade.queue_subscription_plan_change_for_user(actor, subscription.id, input)
  end

  defp fetch_order!(id) do
    Order
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Orders, authorize?: false, context: %{system?: true})
  end

  defp fetch_payment_intent!(id) do
    PaymentIntent
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Payments, authorize?: false, context: %{system?: true})
  end

  defp fetch_payment_intent_for_order!(order_id) do
    PaymentIntent
    |> Ash.Query.filter(expr(order_id == ^order_id))
    |> Ash.Query.sort(inserted_at: :asc, id: :asc)
    |> Ash.read_one!(domain: Store.Payments, authorize?: false, context: %{system?: true})
  end

  defp fetch_order_line_items!(order_id) do
    OrderLineItem
    |> Ash.Query.filter(expr(order_id == ^order_id))
    |> Ash.Query.sort(line_no: :asc)
    |> Ash.read!(domain: Store.Orders, authorize?: false, context: %{system?: true})
  end
end
