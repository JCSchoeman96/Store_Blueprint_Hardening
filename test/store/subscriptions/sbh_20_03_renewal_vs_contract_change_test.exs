defmodule Store.Subscriptions.Sbh2003RenewalVsContractChangeTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Store.Subscriptions.{ContractChange, Facade, RenewalAttempt}

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

  test "a plan change after B composes from the contract bound to the renewal" do
    fixture = fixture!("bound_plan")
    bound_plan = SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 2_900})
    SubscriptionsFixtures.attach_variant_plan!(fixture.variant.id, bound_plan.id)
    bound_revision = SubscriptionsFixtures.create_plan_revision!(bound_plan)

    assert {:ok, queued_bound} =
             queue_plan_change(fixture.customer, fixture.subscription.id, bound_plan)

    attempt = bind_renewal!(%{fixture | subscription: queued_bound})
    target_plan = SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 4_300})
    SubscriptionsFixtures.attach_variant_plan!(fixture.variant.id, target_plan.id)
    target_revision = SubscriptionsFixtures.create_plan_revision!(target_plan)

    assert attempt.plan_revision_id == bound_revision.id

    assert {:ok, queued} =
             queue_plan_change(fixture.customer, attempt.subscription_id, target_plan)

    contract_change = fetch_contract_change!(queued.current_contract_change_id)

    assert contract_change.predecessor_contract_change_id ==
             queued_bound.current_contract_change_id

    assert contract_change.target_plan_revision_id == target_revision.id
    assert contract_change.target_variant_id == fixture.variant.id
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
    SubscriptionsFixtures.attach_variant_plan!(target_variant.id, bound_plan.id)

    assert attempt.plan_revision_id == bound_revision.id

    assert {:ok, queued} =
             queue_variant_change(fixture.customer, attempt.subscription_id, target_variant)

    contract_change = fetch_contract_change!(queued.current_contract_change_id)

    assert contract_change.target_plan_revision_id == bound_revision.id
    assert contract_change.target_variant_id == target_variant.id
    assert contract_change.target_amount_minor == bound_revision.amount_minor
    assert contract_change.target_currency == bound_revision.currency
    assert queued.change_effective_at == attempt.period_end_at
  end

  defp fixture!(suffix) do
    customer = SubscriptionsFixtures.create_customer!("sbh_20_03_#{suffix}")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        next_renewal_at: DateTime.add(now, -10, :second),
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
