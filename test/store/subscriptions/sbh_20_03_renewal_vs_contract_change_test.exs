defmodule Store.Subscriptions.Sbh2003RenewalVsContractChangeTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Store.Subscriptions.{ContractChange, Facade, RenewalAttempt, Subscription}

  alias Store.Subscriptions.Inputs.{
    QueueSubscriptionPlanChangeInput,
    QueueSubscriptionVariantChangeInput
  }

  alias Store.SubscriptionsFixtures
  alias Store.TestSupport.StripeAPIStub

  setup context do
    StripeAPIStub.setup_default(context)
  end

  test "a plan change queued after B takes effect at the bound renewal end" do
    fixture = fixture!("unchanged_plan")
    attempt = bind_renewal!(fixture)

    target_plan = SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 3_700})
    SubscriptionsFixtures.attach_variant_plan!(fixture.variant.id, target_plan.id)
    revision = SubscriptionsFixtures.create_plan_revision!(target_plan)

    assert {:ok, queued} =
             queue_plan_change(fixture.customer, attempt.subscription_id, target_plan)

    contract_change = fetch_contract_change!(queued.current_contract_change_id)

    assert contract_change.status == :queued
    assert contract_change.target_plan_revision_id == revision.id
    assert contract_change.target_variant_id == fixture.variant.id
    assert contract_change.target_amount_minor == revision.amount_minor
    assert contract_change.target_currency == revision.currency
    assert queued.change_effective_at == attempt.period_end_at
  end

  test "a legacy subscription without period end queues at next renewal" do
    fixture = fixture!("legacy_period_end")
    effective_at = DateTime.add(fixture.now, 86_400, :second)

    subscription =
      fixture.subscription
      |> Ash.Changeset.for_update(
        :extend_period,
        %{current_period_end_at: nil, next_renewal_at: effective_at},
        context: %{system?: true}
      )
      |> Ash.update!(
        domain: Store.Subscriptions,
        authorize?: false,
        context: %{system?: true}
      )

    target_plan = SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 3_700})
    SubscriptionsFixtures.attach_variant_plan!(fixture.variant.id, target_plan.id)
    SubscriptionsFixtures.create_plan_revision!(target_plan)

    assert %Subscription{} = subscription
    assert {:ok, queued} = queue_plan_change(fixture.customer, subscription.id, target_plan)
    assert queued.change_effective_at == effective_at
  end

  test "a plan change after B composes from the contract bound to the renewal" do
    fixture = fixture!("bound_plan")
    %{variant: bound_variant} = SubscriptionsFixtures.create_subscription_sellable!()
    SubscriptionsFixtures.attach_variant_plan!(bound_variant.id, fixture.plan.id)

    assert {:ok, queued_variant} =
             queue_variant_change(fixture.customer, fixture.subscription.id, bound_variant)

    attempt = bind_renewal!(%{fixture | subscription: queued_variant})
    target_plan = SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 4_300})
    SubscriptionsFixtures.attach_variant_plan!(fixture.variant.id, target_plan.id)
    SubscriptionsFixtures.attach_variant_plan!(bound_variant.id, target_plan.id)
    target_revision = SubscriptionsFixtures.create_plan_revision!(target_plan)

    assert attempt.variant_id == bound_variant.id
    assert attempt.quantity == 3

    assert {:ok, queued} =
             queue_plan_change(fixture.customer, attempt.subscription_id, target_plan)

    contract_change = fetch_contract_change!(queued.current_contract_change_id)
    bound_contract_change = fetch_contract_change!(attempt.contract_change_id)

    assert contract_change.predecessor_contract_change_id == attempt.contract_change_id
    assert bound_contract_change.status == :bound_to_renewal
    assert contract_change.target_plan_revision_id == target_revision.id
    assert contract_change.target_variant_id == attempt.variant_id
    assert contract_change.target_quantity == attempt.quantity
    assert contract_change.target_amount_minor == target_revision.amount_minor
    assert queued.change_effective_at == attempt.period_end_at
  end

  test "a variant change after B preserves the plan bound to the renewal" do
    fixture = fixture!("bound_variant")
    bound_plan = SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 2_600})
    SubscriptionsFixtures.attach_variant_plan!(fixture.variant.id, bound_plan.id)
    bound_revision = SubscriptionsFixtures.create_plan_revision!(bound_plan)

    assert {:ok, queued_bound} =
             queue_plan_change(fixture.customer, fixture.subscription.id, bound_plan)

    attempt = bind_renewal!(%{fixture | subscription: queued_bound})
    %{variant: target_variant} = SubscriptionsFixtures.create_subscription_sellable!()
    SubscriptionsFixtures.attach_variant_plan!(target_variant.id, fixture.plan.id)
    SubscriptionsFixtures.attach_variant_plan!(target_variant.id, bound_plan.id)

    assert attempt.plan_revision_id == bound_revision.id

    assert {:ok, queued} =
             queue_variant_change(fixture.customer, attempt.subscription_id, target_variant)

    contract_change = fetch_contract_change!(queued.current_contract_change_id)
    bound_contract_change = fetch_contract_change!(attempt.contract_change_id)

    assert contract_change.predecessor_contract_change_id == attempt.contract_change_id
    assert bound_contract_change.status == :bound_to_renewal
    assert contract_change.target_plan_revision_id == attempt.plan_revision_id
    assert contract_change.target_variant_id == target_variant.id
    assert contract_change.target_amount_minor == attempt.amount_minor
    assert contract_change.target_currency == attempt.currency
    assert queued.change_effective_at == attempt.period_end_at
  end

  defp fixture!(suffix) do
    customer = SubscriptionsFixtures.create_customer!("sbh_20_03_#{suffix}")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!(%{interval_unit: :day})
    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    due_boundary = DateTime.add(now, -10, :second)
    started_at = DateTime.add(due_boundary, -86_400, :second)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        started_at: started_at,
        quantity: 3,
        provider_billing_ref: "pm_sbh_20_03_#{suffix}"
      })

    %{customer: customer, variant: variant, plan: plan, subscription: subscription, now: now}
  end

  defp bind_renewal!(fixture) do
    assert {:ok, :processed} =
             Facade.process_due_subscription_renewal_for_system(fixture.subscription.id,
               now: fixture.now
             )

    fetch_latest_attempt!(fixture.subscription.id)
  end

  defp queue_plan_change(actor, subscription_id, plan) do
    {:ok, input} =
      QueueSubscriptionPlanChangeInput.new(%{
        "subscription_id" => subscription_id,
        "subscription_plan_id" => plan.id
      })

    Facade.queue_subscription_plan_change_for_user(actor, subscription_id, input)
  end

  defp queue_variant_change(actor, subscription_id, variant) do
    {:ok, input} =
      QueueSubscriptionVariantChangeInput.new(%{
        "subscription_id" => subscription_id,
        "variant_id" => variant.id
      })

    Facade.queue_subscription_variant_change_for_user(actor, subscription_id, input)
  end

  defp fetch_latest_attempt!(subscription_id) do
    RenewalAttempt
    |> Ash.Query.filter(expr(subscription_id == ^subscription_id))
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp fetch_contract_change!(id) do
    ContractChange
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end
end
