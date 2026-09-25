defmodule Store.Subscriptions.Sbh1003RenewalContractSnapshotTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Store.Orders.Order
  alias Store.Payments.PaymentIntent

  alias Store.Subscriptions.{
    ContractChange,
    Facade,
    RenewalAttempt,
    Scheduler,
    Subscription
  }

  alias Store.Subscriptions.Inputs.{
    QueueSubscriptionPlanChangeInput,
    QueueSubscriptionVariantChangeInput
  }

  alias Store.SubscriptionsFixtures
  alias Store.Support.Telemetry.RepoStats
  alias Store.TestSupport.StripeAPIStub

  setup context do
    StripeAPIStub.setup_default(context)
  end

  test "queued plan and variant renewal binds after an unrelated subscription update" do
    customer = SubscriptionsFixtures.create_customer!("sbh_10_03_queued_target")
    %{variant: live_variant} = SubscriptionsFixtures.create_subscription_sellable!()
    %{variant: target_variant} = SubscriptionsFixtures.create_subscription_sellable!()

    live_plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        interval_unit: :day,
        interval_count: 1,
        amount_minor: 1_100,
        currency: "USD"
      })

    target_plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        interval_unit: :month,
        interval_count: 2,
        amount_minor: 4_700,
        currency: "EUR"
      })

    for variant <- [live_variant, target_variant], plan <- [live_plan, target_plan] do
      SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
    end

    target_revision = SubscriptionsFixtures.create_plan_revision!(target_plan)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, live_variant, live_plan, %{
        started_at: DateTime.add(now, -86_410, :second),
        next_renewal_at: DateTime.add(now, -10, :second),
        quantity: 2,
        provider_billing_ref: "pm_sbh_10_03_target"
      })

    assert {:ok, queued_plan} = queue_plan_change(customer, subscription, target_plan)

    assert {:ok, queued} =
             queue_variant_change(customer, queued_plan, target_variant)

    contract_change_id = queued.current_contract_change_id
    queued_contract_change = fetch_contract_change!(contract_change_id)

    assert queued_contract_change.status == :queued
    assert queued_contract_change.target_plan_revision_id == target_revision.id
    assert queued_contract_change.target_variant_id == target_variant.id
    assert queued_contract_change.target_quantity == 2
    assert queued_contract_change.target_amount_minor == 4_700
    assert queued_contract_change.target_currency == "EUR"

    assert queued.pending_subscription_plan_id == target_plan.id
    assert queued.pending_variant_id == target_variant.id
    assert queued.pending_renewal_amount_minor == 4_700
    assert queued.pending_renewal_currency == "EUR"
    assert queued.change_effective_at == queued.current_period_end_at
    assert queued_contract_change.ordering_version == queued.aggregate_version

    assert {:ok, _updated_subscription} =
             queued
             |> Ash.Changeset.for_update(
               :set_provider_billing_reference,
               %{provider_billing_ref: "pm_sbh_10_03_target_after_queue"},
               context: %{system?: true}
             )
             |> Ash.update(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    before_consumption = fetch_subscription!(subscription.id)

    assert before_consumption.current_contract_change_id == contract_change_id
    assert before_consumption.aggregate_version == queued.aggregate_version + 1
    assert queued_contract_change.ordering_version != before_consumption.aggregate_version
    assert before_consumption.pending_subscription_plan_id == target_plan.id
    assert before_consumption.pending_variant_id == target_variant.id
    assert before_consumption.pending_renewal_amount_minor == 4_700
    assert before_consumption.pending_renewal_currency == "EUR"
    assert before_consumption.change_effective_at == before_consumption.current_period_end_at

    expected_period =
      Scheduler.next_period(before_consumption.current_period_end_at, target_revision)

    StripeAPIStub.stub_payment_intent(fn conn, params ->
      attempt_id = params["metadata[renewal_attempt_id]"]
      assert is_binary(attempt_id)
      bound_attempt = fetch_attempt!(attempt_id)
      bound_change = fetch_contract_change!(contract_change_id)
      bound_subscription = fetch_subscription!(subscription.id)

      assert bound_attempt.charged_contract_version == 1
      assert bound_attempt.plan_revision_id == target_revision.id
      assert bound_attempt.contract_change_id == contract_change_id
      assert bound_attempt.variant_id == target_variant.id
      assert bound_attempt.quantity == 2
      assert bound_attempt.amount_minor == 4_700
      assert bound_attempt.currency == "EUR"
      assert bound_change.status == :bound_to_renewal
      assert bound_subscription.current_contract_change_id == nil
      assert bound_subscription.pending_variant_id == nil
      assert bound_subscription.pending_subscription_plan_id == nil
      assert bound_subscription.pending_renewal_amount_minor == nil
      assert bound_subscription.pending_renewal_currency == nil
      assert bound_subscription.change_effective_at == nil

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(StripeAPIStub.payment_intent_response(params)))
    end)

    assert {:ok, :processed} =
             Facade.process_due_subscription_renewal_for_system(subscription.id, now: now)

    attempt = fetch_attempt_for_subscription!(subscription.id)
    contract_change = fetch_contract_change!(contract_change_id)
    after_consumption = fetch_subscription!(subscription.id)
    order = fetch_order!(attempt.order_id)
    payment_intent = fetch_payment_intent!(attempt.payment_intent_id)

    assert attempt.charged_contract_version == 1
    assert attempt.plan_revision_id == target_revision.id
    assert attempt.variant_id == target_variant.id
    assert attempt.quantity == 2
    assert attempt.amount_minor == 4_700
    assert attempt.currency == "EUR"
    assert attempt.contract_change_id == contract_change_id
    assert attempt.expected_subscription_version == before_consumption.aggregate_version
    assert attempt.period_start_at == before_consumption.current_period_end_at
    assert attempt.period_end_at == expected_period.current_period_end_at
    assert attempt.charged_contract_snapshot["interval_unit"] == "month"
    assert attempt.charged_contract_snapshot["interval_count"] == 2
    refute Map.has_key?(attempt.charged_contract_snapshot, "amount_minor")
    refute Map.has_key?(attempt.charged_contract_snapshot, "currency")

    assert attempt.charged_contract_snapshot["access_on_past_due"] ==
             Atom.to_string(target_revision.access_on_past_due)

    assert contract_change.status == :bound_to_renewal

    assert {:error, _reason} =
             contract_change
             |> Ash.Changeset.for_update(:bind_to_renewal, %{}, context: %{system?: true})
             |> Ash.update(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert after_consumption.current_contract_change_id == nil

    assert Map.take(after_consumption, [
             :pending_variant_id,
             :pending_subscription_plan_id,
             :pending_renewal_amount_minor,
             :pending_renewal_currency,
             :change_effective_at
           ]) == %{
             pending_variant_id: nil,
             pending_subscription_plan_id: nil,
             pending_renewal_amount_minor: nil,
             pending_renewal_currency: nil,
             change_effective_at: nil
           }

    assert after_consumption.aggregate_version == before_consumption.aggregate_version + 1
    assert order.grand_total_minor == 9_400
    assert payment_intent.amount_received_minor == 9_400

    later_plan = SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 8_900})
    SubscriptionsFixtures.attach_variant_plan!(live_variant.id, later_plan.id)
    later_revision = SubscriptionsFixtures.create_plan_revision!(later_plan)
    assert {:ok, later_target} = queue_plan_change(customer, after_consumption, later_plan)

    assert {:ok, :processed} =
             Facade.process_due_subscription_renewal_for_system(subscription.id, now: now)

    assert fetch_attempt!(attempt.id).plan_revision_id == target_revision.id
    assert fetch_attempt!(attempt.id).contract_change_id == contract_change_id
    assert fetch_attempt!(attempt.id).amount_minor == 4_700

    assert fetch_contract_change!(Map.fetch!(later_target, :current_contract_change_id)).status ==
             :queued

    assert later_revision.id != fetch_attempt!(attempt.id).plan_revision_id

    payment_intent
    |> Ash.Changeset.for_update(:mark_succeeded, %{}, context: %{system?: true})
    |> Ash.update!(domain: Store.Payments, authorize?: false, context: %{system?: true})

    order
    |> Ash.Changeset.for_update(:mark_paid, %{}, context: %{system?: true})
    |> Ash.update!(domain: Store.Orders, authorize?: false, context: %{system?: true})

    before_guard_subscription = fetch_subscription!(subscription.id)

    assert {:error, %{code: "VALIDATION_ERROR"}} =
             Facade.reconcile_paid_subscription_renewal_for_system(order.id,
               renewal_attempt_id: attempt.id
             )

    assert fetch_attempt!(attempt.id).status == :processing

    assert fetch_subscription!(subscription.id).aggregate_version ==
             before_guard_subscription.aggregate_version
  end

  test "unchanged live renewal binds its exact current revision without a subscription write" do
    %{subscription: subscription, revision: revision, now: now} =
      create_due_live_fixture!("sbh_10_03_live")

    before = fetch_subscription!(subscription.id)

    {result, stats} =
      RepoStats.capture(fn ->
        Facade.process_due_subscription_renewal_for_system(subscription.id, now: now)
      end)

    assert {:ok, :processed} = result
    assert stats.query_count <= 64

    attempt = fetch_attempt_for_subscription!(subscription.id)
    after_binding = fetch_subscription!(subscription.id)

    assert attempt.charged_contract_version == 1
    assert attempt.plan_revision_id == revision.id
    assert attempt.variant_id == before.variant_id
    assert attempt.quantity == before.quantity
    assert attempt.amount_minor == before.renewal_amount_minor
    assert attempt.currency == before.renewal_currency
    assert attempt.contract_change_id == nil
    assert attempt.expected_subscription_version == before.aggregate_version
    assert after_binding.aggregate_version == before.aggregate_version
  end

  test "a retired current PlanRevision remains the exact renewal authority" do
    %{subscription: subscription, revision: current_revision, plan: plan, now: now} =
      create_due_live_fixture!("sbh_10_03_retired")

    assert {:ok, retired_revision} =
             current_revision
             |> Ash.Changeset.for_update(:retire, %{}, context: %{system?: true})
             |> Ash.update(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    replacement =
      SubscriptionsFixtures.create_plan_revision!(plan, %{
        interval_unit: :month,
        interval_count: 3,
        amount_minor: 9_100
      })

    assert retired_revision.status == :retired
    assert replacement.status == :effective

    assert {:ok, :processed} =
             Facade.process_due_subscription_renewal_for_system(subscription.id, now: now)

    attempt = fetch_attempt_for_subscription!(subscription.id)
    assert attempt.plan_revision_id == current_revision.id

    assert attempt.period_end_at ==
             Scheduler.next_period(subscription.current_period_end_at, current_revision)
             |> Map.fetch!(:current_period_end_at)

    assert attempt.charged_contract_snapshot["interval_count"] == current_revision.interval_count
  end

  test "a bound retry uses the occurrence's captured grace policy" do
    customer = SubscriptionsFixtures.create_customer!("sbh_10_03_retry_policy")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    live_plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        interval_unit: :day,
        grace_period_days: 0
      })

    target_plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        interval_unit: :month,
        grace_period_days: 14,
        amount_minor: 3_800,
        currency: "EUR"
      })

    SubscriptionsFixtures.attach_variant_plan!(variant.id, live_plan.id)
    SubscriptionsFixtures.attach_variant_plan!(variant.id, target_plan.id)
    target_revision = SubscriptionsFixtures.create_plan_revision!(target_plan)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, live_plan, %{
        started_at: DateTime.add(now, -86_410, :second),
        provider_billing_ref: "pm_sbh_10_03_retry_policy",
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    assert {:ok, _queued} = queue_plan_change(customer, subscription, target_plan)

    assert {:ok, :processed} =
             Facade.process_due_subscription_renewal_for_system(subscription.id, now: now)

    attempt = fetch_attempt_for_subscription!(subscription.id)
    assert attempt.charged_contract_snapshot["grace_period_days"] == 14

    later_plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        interval_unit: :year,
        interval_count: 1,
        amount_minor: 9_900,
        currency: "GBP"
      })

    SubscriptionsFixtures.attach_variant_plan!(variant.id, later_plan.id)
    later_revision = SubscriptionsFixtures.create_plan_revision!(later_plan)

    assert {:ok, later_target} =
             queue_plan_change(customer, fetch_subscription!(subscription.id), later_plan)

    later_target_id = later_target.current_contract_change_id

    attempt
    |> Ash.Changeset.for_update(
      :mark_failed,
      %{failure_code: "PAYMENT_FAILED", failure_message: "retry proof", attempt_no: 2},
      context: %{system?: true}
    )
    |> Ash.update!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    subscription = fetch_subscription!(subscription.id)

    subscription
    |> Ash.Changeset.for_update(
      :mark_past_due_transition,
      %{
        billing_status_reason: "PAYMENT_FAILED",
        past_due_since_at: DateTime.add(now, -8 * 86_400, :second),
        dunning_attempt_count: 1,
        next_retry_at: DateTime.add(now, -10, :second)
      },
      context: %{system?: true}
    )
    |> Ash.update!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    assert {:ok, :processed} =
             Facade.process_due_subscription_renewal_for_system(subscription.id, now: now)

    retried_subscription = fetch_subscription!(subscription.id)
    retried_attempt = fetch_attempt!(attempt.id)

    assert retried_subscription.status == :past_due
    assert retried_attempt.status == :processing
    assert retried_attempt.plan_revision_id == target_revision.id
    assert retried_attempt.contract_change_id == attempt.contract_change_id
    assert retried_attempt.variant_id == attempt.variant_id
    assert retried_attempt.quantity == attempt.quantity
    assert retried_attempt.amount_minor == 3_800
    assert retried_attempt.currency == "EUR"
    assert retried_attempt.period_end_at == attempt.period_end_at
    assert retried_attempt.charged_contract_snapshot["interval_unit"] == "month"
    assert retried_attempt.charged_contract_snapshot["grace_period_days"] == 14
    assert later_revision.id != retried_attempt.plan_revision_id
    assert fetch_contract_change!(later_target_id).status == :queued
  end

  test "mutable SubscriptionPlan cadence and price do not rewrite B evidence" do
    %{subscription: subscription, revision: revision, plan: plan, now: now} =
      create_due_live_fixture!("sbh_10_03_plan_drift")

    plan
    |> Ash.Changeset.for_update(
      :update,
      %{interval_unit: :month, interval_count: 12, amount_minor: 99_900, currency: "EUR"},
      context: %{system?: true}
    )
    |> Ash.update!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    assert {:ok, :processed} =
             Facade.process_due_subscription_renewal_for_system(subscription.id, now: now)

    attempt = fetch_attempt_for_subscription!(subscription.id)

    assert attempt.plan_revision_id == revision.id
    assert attempt.amount_minor == subscription.renewal_amount_minor
    assert attempt.currency == subscription.renewal_currency

    assert attempt.period_end_at ==
             Scheduler.next_period(subscription.current_period_end_at, revision)
             |> Map.fetch!(:current_period_end_at)

    assert attempt.charged_contract_snapshot["interval_unit"] ==
             Atom.to_string(revision.interval_unit)

    assert attempt.charged_contract_snapshot["interval_count"] == revision.interval_count
    refute Map.has_key?(attempt.charged_contract_snapshot, "amount_minor")
    refute Map.has_key?(attempt.charged_contract_snapshot, "currency")
  end

  test "a compatibility-unbound attempt fails closed and stays unbound" do
    %{subscription: subscription, revision: revision, now: now} =
      create_due_live_fixture!("sbh_10_03_compat")

    orders_before = Store.Repo.aggregate(Order, :count, :id)
    intents_before = Store.Repo.aggregate(PaymentIntent, :count, :id)

    next_period = Scheduler.next_period(subscription.current_period_end_at, revision)
    renewal_key = Scheduler.renewal_key(subscription.id, next_period.current_period_end_at)

    legacy_attempt =
      RenewalAttempt
      |> Ash.Changeset.for_create(
        :create_or_reuse,
        %{
          subscription_id: subscription.id,
          period_start_at: subscription.current_period_end_at,
          period_end_at: next_period.current_period_end_at,
          renewal_key: renewal_key,
          status: :pending
        },
        context: %{system?: true}
      )
      |> Ash.create!(
        domain: Store.Subscriptions,
        authorize?: false,
        context: %{system?: true}
      )

    StripeAPIStub.stub_unexpected!("compatibility attempt must fail before provider work")

    assert {:error, %{code: "VALIDATION_ERROR"}} =
             Facade.process_due_subscription_renewal_for_system(subscription.id, now: now)

    attempt = fetch_attempt!(legacy_attempt.id)
    assert attempt.charged_contract_version == nil
    assert attempt.plan_revision_id == nil
    assert attempt.contract_change_id == nil
    assert Store.Repo.aggregate(Order, :count, :id) == orders_before
    assert Store.Repo.aggregate(PaymentIntent, :count, :id) == intents_before
  end

  test "a historical unbound attempt with paid evidence cannot enter reconciliation" do
    %{subscription: subscription, now: now} =
      create_due_live_fixture!("sbh_10_03_unbound_paid_reconciliation")

    assert {:ok, :processed} =
             Facade.process_due_subscription_renewal_for_system(subscription.id, now: now)

    attempt = fetch_attempt_for_subscription!(subscription.id)
    order = fetch_order!(attempt.order_id)
    payment_intent = fetch_payment_intent!(attempt.payment_intent_id)

    payment_intent
    |> Ash.Changeset.for_update(:mark_succeeded, %{}, context: %{system?: true})
    |> Ash.update!(domain: Store.Payments, authorize?: false, context: %{system?: true})

    order
    |> Ash.Changeset.for_update(:mark_paid, %{}, context: %{system?: true})
    |> Ash.update!(domain: Store.Orders, authorize?: false, context: %{system?: true})

    clear_renewal_attempt_binding!(attempt.id)

    historical_attempt = fetch_attempt!(attempt.id)
    paid_order = fetch_order!(order.id)
    succeeded_payment_intent = fetch_payment_intent!(payment_intent.id)
    before_subscription = fetch_subscription!(subscription.id)

    assert historical_attempt.charged_contract_version == nil
    assert paid_order.state == :paid
    assert succeeded_payment_intent.state == :succeeded

    assert {:error, %{code: "VALIDATION_ERROR"}} =
             Facade.reconcile_paid_subscription_renewal_for_system(order.id,
               renewal_attempt_id: attempt.id
             )

    attempt_after_reconciliation = fetch_attempt!(attempt.id)
    subscription_after_reconciliation = fetch_subscription!(subscription.id)

    assert Map.take(attempt_after_reconciliation, [
             :charged_contract_version,
             :plan_revision_id,
             :variant_id,
             :quantity,
             :amount_minor,
             :currency,
             :contract_change_id,
             :expected_subscription_version,
             :charged_contract_snapshot,
             :status,
             :updated_at
           ]) ==
             Map.take(historical_attempt, [
               :charged_contract_version,
               :plan_revision_id,
               :variant_id,
               :quantity,
               :amount_minor,
               :currency,
               :contract_change_id,
               :expected_subscription_version,
               :charged_contract_snapshot,
               :status,
               :updated_at
             ])

    assert Map.take(subscription_after_reconciliation, [
             :current_period_start_at,
             :current_period_end_at,
             :next_renewal_at,
             :current_plan_revision_id,
             :subscription_plan_id,
             :variant_id,
             :quantity,
             :renewal_amount_minor,
             :renewal_currency,
             :aggregate_version,
             :current_contract_change_id,
             :pending_subscription_plan_id,
             :pending_variant_id,
             :pending_renewal_amount_minor,
             :pending_renewal_currency,
             :change_effective_at
           ]) ==
             Map.take(before_subscription, [
               :current_period_start_at,
               :current_period_end_at,
               :next_renewal_at,
               :current_plan_revision_id,
               :subscription_plan_id,
               :variant_id,
               :quantity,
               :renewal_amount_minor,
               :renewal_currency,
               :aggregate_version,
               :current_contract_change_id,
               :pending_subscription_plan_id,
               :pending_variant_id,
               :pending_renewal_amount_minor,
               :pending_renewal_currency,
               :change_effective_at
             ])
  end

  test "the database rejects partial binding evidence without a discriminator" do
    %{subscription: subscription, revision: revision} =
      create_due_live_fixture!("sbh_10_03_partial_evidence")

    period = Scheduler.next_period(subscription.current_period_end_at, revision)

    result =
      RenewalAttempt
      |> Ash.Changeset.for_create(
        :create_or_reuse,
        %{
          subscription_id: subscription.id,
          period_start_at: period.current_period_start_at,
          period_end_at: period.current_period_end_at,
          renewal_key: Scheduler.renewal_key(subscription.id, period.current_period_end_at),
          plan_revision_id: revision.id,
          status: :pending
        },
        context: %{system?: true}
      )
      |> Ash.create(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    assert {:error, _reason} = result
    assert list_attempts!(subscription.id) == []
  end

  test "a ContractChange owned by another Subscription cannot be consumed" do
    %{subscription: subscription, now: now} = create_due_live_fixture!("sbh_10_03_wrong_owner")

    %{customer: other_customer, subscription: other_subscription, variant: other_variant} =
      create_due_live_fixture!("sbh_10_03_target_owner")

    foreign_target_plan =
      SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 6_600, currency: "EUR"})

    SubscriptionsFixtures.attach_variant_plan!(other_variant.id, foreign_target_plan.id)
    SubscriptionsFixtures.create_plan_revision!(foreign_target_plan)

    assert {:ok, queued} =
             queue_plan_change(other_customer, other_subscription, foreign_target_plan)

    foreign_target_id = Map.fetch!(queued, :current_contract_change_id)

    Store.Repo.query!(
      "UPDATE subscriptions SET current_contract_change_id = $2 WHERE id = $1",
      [Ecto.UUID.dump!(subscription.id), Ecto.UUID.dump!(foreign_target_id)]
    )

    attempts_before = Store.Repo.aggregate(RenewalAttempt, :count, :id)
    StripeAPIStub.stub_unexpected!("foreign ContractChange must fail before provider work")

    assert {:error, %{code: "VALIDATION_ERROR"}} =
             Facade.process_due_subscription_renewal_for_system(subscription.id, now: now)

    assert Store.Repo.aggregate(RenewalAttempt, :count, :id) == attempts_before
    assert fetch_contract_change!(foreign_target_id).status == :queued

    assert fetch_subscription!(other_subscription.id).current_contract_change_id ==
             foreign_target_id
  end

  test "ContractChange price disagreement with its exact revision fails closed" do
    customer = SubscriptionsFixtures.create_customer!("sbh_10_03_price_mismatch")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    live_plan = SubscriptionsFixtures.create_subscription_plan!(%{interval_unit: :day})

    target_plan =
      SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 5_500, currency: "EUR"})

    SubscriptionsFixtures.attach_variant_plan!(variant.id, live_plan.id)
    SubscriptionsFixtures.attach_variant_plan!(variant.id, target_plan.id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, live_plan, %{
        started_at: DateTime.add(now, -86_410, :second),
        provider_billing_ref: "pm_sbh_10_03_price_mismatch",
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    SubscriptionsFixtures.create_plan_revision!(target_plan)
    assert {:ok, queued} = queue_plan_change(customer, subscription, target_plan)
    target_id = Map.fetch!(queued, :current_contract_change_id)

    Store.Repo.query!(
      "UPDATE contract_changes SET target_amount_minor = target_amount_minor + 1 WHERE id = $1",
      [Ecto.UUID.dump!(target_id)]
    )

    attempts_before = Store.Repo.aggregate(RenewalAttempt, :count, :id)
    StripeAPIStub.stub_unexpected!("mismatched ContractChange price must fail closed")

    assert {:error, %{code: "VALIDATION_ERROR"}} =
             Facade.process_due_subscription_renewal_for_system(subscription.id, now: now)

    assert Store.Repo.aggregate(RenewalAttempt, :count, :id) == attempts_before
    assert fetch_contract_change!(target_id).status == :queued
    assert fetch_subscription!(subscription.id).current_contract_change_id == target_id
  end

  test "a stale target consumer cannot clear a later queued ContractChange" do
    customer = SubscriptionsFixtures.create_customer!("sbh_10_03_stale_consumer")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    live_plan = SubscriptionsFixtures.create_subscription_plan!()
    first_target_plan = SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 2_800})
    second_target_plan = SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 6_200})

    SubscriptionsFixtures.attach_variant_plan!(variant.id, live_plan.id)
    SubscriptionsFixtures.attach_variant_plan!(variant.id, first_target_plan.id)
    SubscriptionsFixtures.attach_variant_plan!(variant.id, second_target_plan.id)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, live_plan)

    SubscriptionsFixtures.create_plan_revision!(first_target_plan)
    SubscriptionsFixtures.create_plan_revision!(second_target_plan)
    assert {:ok, first_queued} = queue_plan_change(customer, subscription, first_target_plan)
    stale_subscription = fetch_subscription!(subscription.id)

    assert {:ok, second_queued} =
             queue_plan_change(customer, fetch_subscription!(subscription.id), second_target_plan)

    second_target_id = Map.fetch!(second_queued, :current_contract_change_id)
    assert second_target_id != Map.fetch!(first_queued, :current_contract_change_id)

    stale_result =
      stale_subscription
      |> Ash.Changeset.for_update(
        :consume_contract_change_for_renewal,
        %{
          current_contract_change_id: nil,
          pending_variant_id: nil,
          pending_subscription_plan_id: nil,
          pending_renewal_amount_minor: nil,
          pending_renewal_currency: nil,
          change_effective_at: nil
        },
        context: %{system?: true}
      )
      |> Ash.update(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    assert {:error, _reason} = stale_result
    latest = fetch_subscription!(subscription.id)

    assert latest.current_contract_change_id == second_target_id
    assert latest.pending_subscription_plan_id == second_target_plan.id
    assert latest.pending_renewal_amount_minor == 6_200
    assert latest.pending_renewal_currency == second_target_plan.currency
    assert latest.change_effective_at == second_queued.change_effective_at
    assert latest.aggregate_version == second_queued.aggregate_version
    assert fetch_contract_change!(second_target_id).status == :queued
  end

  test "normal RenewalAttempt update actions cannot mutate charged-contract fields" do
    %{subscription: subscription, now: now} = create_due_live_fixture!("sbh_10_03_write_guard")

    assert {:ok, :processed} =
             Facade.process_due_subscription_renewal_for_system(subscription.id, now: now)

    attempt = fetch_attempt_for_subscription!(subscription.id)
    bound_revision_id = attempt.plan_revision_id

    result =
      attempt
      |> Ash.Changeset.for_update(
        :mark_failed,
        %{
          failure_code: "PAYMENT_FAILED",
          charged_contract_version: nil,
          plan_revision_id: Ecto.UUID.generate(),
          amount_minor: 1
        },
        context: %{system?: true}
      )
      |> Ash.update(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    assert {:error, _reason} = result
    reloaded = fetch_attempt!(attempt.id)
    assert reloaded.charged_contract_version == 1
    assert reloaded.plan_revision_id == bound_revision_id
    assert reloaded.amount_minor == attempt.amount_minor
  end

  test "concurrent renewal workers share one queued-target binding" do
    customer = SubscriptionsFixtures.create_customer!("sbh_10_03_concurrent")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    live_plan = SubscriptionsFixtures.create_subscription_plan!(%{interval_unit: :day})

    target_plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        interval_unit: :month,
        interval_count: 4,
        amount_minor: 7_700,
        currency: "EUR"
      })

    SubscriptionsFixtures.attach_variant_plan!(variant.id, live_plan.id)
    SubscriptionsFixtures.attach_variant_plan!(variant.id, target_plan.id)
    target_revision = SubscriptionsFixtures.create_plan_revision!(target_plan)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, live_plan, %{
        started_at: DateTime.add(now, -86_410, :second),
        provider_billing_ref: "pm_sbh_10_03_concurrent",
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    assert {:ok, queued} = queue_plan_change(customer, subscription, target_plan)
    target_id = Map.fetch!(queued, :current_contract_change_id)

    results =
      1..2
      |> Enum.map(fn _ ->
        Task.async(fn ->
          Facade.process_due_subscription_renewal_for_system(subscription.id, now: now)
        end)
      end)
      |> Enum.map(&Task.await(&1, 10_000))

    assert Enum.all?(results, &match?({:ok, _}, &1))
    attempts = list_attempts!(subscription.id)
    assert length(attempts) == 1
    assert hd(attempts).plan_revision_id == target_revision.id
    assert hd(attempts).contract_change_id == target_id
    assert hd(attempts).charged_contract_version == 1
    assert fetch_contract_change!(target_id).status == :bound_to_renewal

    assert fetch_subscription!(subscription.id).aggregate_version ==
             subscription.aggregate_version + 2
  end

  defp queue_plan_change(actor, subscription, plan) do
    {:ok, input} =
      QueueSubscriptionPlanChangeInput.new(%{
        "subscription_id" => subscription.id,
        "subscription_plan_id" => plan.id
      })

    Facade.queue_subscription_plan_change_for_user(actor, subscription.id, input)
  end

  defp queue_variant_change(actor, subscription, variant) do
    {:ok, input} =
      QueueSubscriptionVariantChangeInput.new(%{
        "subscription_id" => subscription.id,
        "variant_id" => variant.id
      })

    Facade.queue_subscription_variant_change_for_user(actor, subscription.id, input)
  end

  defp clear_renewal_attempt_binding!(attempt_id) do
    Store.Repo.query!(
      """
      UPDATE renewal_attempts
      SET plan_revision_id = NULL,
          variant_id = NULL,
          quantity = NULL,
          amount_minor = NULL,
          currency = NULL,
          contract_change_id = NULL,
          expected_subscription_version = NULL,
          charged_contract_version = NULL,
          charged_contract_snapshot = NULL
      WHERE id = $1
      """,
      [Ecto.UUID.dump!(attempt_id)]
    )
  end

  defp fetch_subscription!(id) do
    Subscription
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp fetch_attempt_for_subscription!(subscription_id) do
    RenewalAttempt
    |> Ash.Query.filter(expr(subscription_id == ^subscription_id))
    |> Ash.Query.sort(inserted_at: :desc, id: :desc)
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp fetch_attempt!(id) do
    RenewalAttempt
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp list_attempts!(subscription_id) do
    RenewalAttempt
    |> Ash.Query.filter(expr(subscription_id == ^subscription_id))
    |> Ash.Query.sort(inserted_at: :desc, id: :desc)
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp create_due_live_fixture!(token, plan_overrides \\ %{}) do
    customer = SubscriptionsFixtures.create_customer!(token)
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan_attrs =
      Map.merge(
        %{
          interval_unit: :day,
          interval_count: 1,
          amount_minor: 1_300,
          currency: "USD"
        },
        plan_overrides
      )

    plan = SubscriptionsFixtures.create_subscription_plan!(plan_attrs)

    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    fixture =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        started_at: DateTime.add(now, -86_410, :second),
        provider_billing_ref: "pm_#{token}",
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    Map.merge(fixture, %{customer: customer, variant: variant, plan: plan, now: now})
  end

  defp fetch_contract_change!(id) do
    ContractChange
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
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
end
