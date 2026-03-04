defmodule Store.Subscriptions.FacadeTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Store.Entitlements.EntitlementGrant
  alias Store.Entitlements.Facade, as: EntitlementsFacade
  alias Store.Subscriptions.Facade, as: SubscriptionsFacade
  alias Store.Subscriptions.{RenewalAttempt, Subscription, SubscriptionItem}
  alias Store.SubscriptionsFixtures

  test "create_subscriptions_from_paid_order_for_system is replay-safe and issues entitlements" do
    customer = SubscriptionsFixtures.create_customer!("phase26_sub_create")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        entitlement_kind: :membership_access,
        entitlement_scope_key: "membership:gold"
      })

    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{order: order} =
      SubscriptionsFixtures.create_paid_order_with_subscription_line!(customer.id, variant, plan)

    assert {:ok, first} =
             SubscriptionsFacade.create_subscriptions_from_paid_order_for_system(order.id)

    assert first.subscription_line_count == 1
    assert first.created_count == 1
    assert first.skipped_count == 0
    assert first.entitlement_issued_count == 1

    assert {:ok, second} =
             SubscriptionsFacade.create_subscriptions_from_paid_order_for_system(order.id)

    assert second.subscription_line_count == 1
    assert second.created_count == 0
    assert second.skipped_count == 1
    assert second.entitlement_issued_count == 0

    assert 1 == count_subscriptions_for_order_line(order.id)
    assert 1 == count_subscription_items_for_order(order.id)
    assert 1 == count_entitlements_for_order(order.id)
  end

  test "run_due_renewals_for_system extends period and refreshes entitlement validity" do
    customer = SubscriptionsFixtures.create_customer!("phase26_sub_renew_success")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        entitlement_kind: :digital_library,
        entitlement_scope_key: "library:all"
      })

    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: "pm_phase26_success",
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    assert {:ok, _grant} =
             EntitlementsFacade.issue_subscription_entitlement_for_system(subscription, plan)

    previous_period_end = subscription.current_period_end_at

    assert {:ok, result} = SubscriptionsFacade.run_due_renewals_for_system(now: now, limit: 20)
    assert result.due_count == 1
    assert result.success_count == 1
    assert result.failed_count == 0

    renewed = fetch_subscription!(subscription.id)
    assert DateTime.compare(renewed.current_period_end_at, previous_period_end) == :gt
    assert renewed.status == :active

    attempt = fetch_latest_attempt!(renewed.id)
    assert attempt.status == :succeeded

    entitlement = fetch_entitlement!(renewed.id)
    assert entitlement.status == :active
    assert entitlement.valid_to_at == renewed.current_period_end_at
  end

  test "run_due_renewals_for_system marks subscription past_due and attempt failed when chargeability is missing" do
    customer = SubscriptionsFixtures.create_customer!("phase26_sub_renew_fail")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    assert {:ok, result} = SubscriptionsFacade.run_due_renewals_for_system(now: now, limit: 20)
    assert result.due_count == 1
    assert result.success_count == 0
    assert result.failed_count == 1

    updated = fetch_subscription!(subscription.id)
    assert updated.status == :past_due
    assert updated.billing_status_reason == "SUBSCRIPTION_MISSING_BILLING_REFERENCE"

    attempt = fetch_latest_attempt!(updated.id)
    assert attempt.status == :failed
    assert attempt.failure_code == "SUBSCRIPTION_MISSING_BILLING_REFERENCE"
  end

  test "run_due_renewals_for_system expires subscriptions past grace and revokes entitlements" do
    customer = SubscriptionsFixtures.create_customer!("phase26_sub_grace")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        grace_period_days: 1,
        entitlement_kind: :membership_access,
        entitlement_scope_key: "membership:silver"
      })

    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    old_past_due = DateTime.add(now, -172_800, :second)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: nil,
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    assert {:ok, past_due_subscription} =
             subscription
             |> Ash.Changeset.for_update(
               :mark_past_due_transition,
               %{past_due_since_at: old_past_due, billing_status_reason: "test"},
               context: %{system?: true}
             )
             |> Ash.update(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert {:ok, _grant} =
             EntitlementsFacade.issue_subscription_entitlement_for_system(
               past_due_subscription,
               plan
             )

    assert {:ok, result} = SubscriptionsFacade.run_due_renewals_for_system(now: now, limit: 20)
    assert result.due_count == 1
    assert result.success_count == 1
    assert result.failed_count == 0

    expired = fetch_subscription!(subscription.id)
    assert expired.status == :expired

    entitlement = fetch_entitlement!(subscription.id)
    assert entitlement.status == :revoked
    assert entitlement.revoked_reason == "grace_expired"
  end

  test "create_subscriptions_from_paid_order_for_system fails closed when provider selection is missing" do
    customer = SubscriptionsFixtures.create_customer!("phase26_sub_missing_provider")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{order: order} =
      SubscriptionsFixtures.create_paid_order_with_subscription_line!(
        customer.id,
        variant,
        plan,
        %{
          create_payment_intent?: false
        }
      )

    assert {:error, error} =
             SubscriptionsFacade.create_subscriptions_from_paid_order_for_system(order.id)

    assert error.code == "SUBSCRIPTION_PROVIDER_SELECTION_REQUIRED"
    assert 0 == count_subscriptions_for_order_line(order.id)
  end

  defp count_subscriptions_for_order_line(order_id) do
    Subscription
    |> Ash.Query.filter(expr(source_order_id == ^order_id))
    |> Ash.count!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp count_subscription_items_for_order(order_id) do
    subscription_ids =
      Subscription
      |> Ash.Query.filter(expr(source_order_id == ^order_id))
      |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
      |> Enum.map(& &1.id)

    SubscriptionItem
    |> Ash.Query.filter(expr(subscription_id in ^subscription_ids))
    |> Ash.count!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp count_entitlements_for_order(order_id) do
    subscription_ids =
      Subscription
      |> Ash.Query.filter(expr(source_order_id == ^order_id))
      |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
      |> Enum.map(& &1.id)

    EntitlementGrant
    |> Ash.Query.filter(expr(source_kind == :subscription and source_id in ^subscription_ids))
    |> Ash.count!(domain: Store.Entitlements, authorize?: false, context: %{system?: true})
  end

  defp fetch_subscription!(subscription_id) do
    Subscription
    |> Ash.Query.filter(expr(id == ^subscription_id))
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
    |> List.first()
  end

  defp fetch_latest_attempt!(subscription_id) do
    RenewalAttempt
    |> Ash.Query.filter(expr(subscription_id == ^subscription_id))
    |> Ash.Query.sort(inserted_at: :desc, id: :desc)
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
    |> List.first()
  end

  defp fetch_entitlement!(subscription_id) do
    EntitlementGrant
    |> Ash.Query.filter(expr(source_kind == :subscription and source_id == ^subscription_id))
    |> Ash.read!(domain: Store.Entitlements, authorize?: false, context: %{system?: true})
    |> List.first()
  end
end
