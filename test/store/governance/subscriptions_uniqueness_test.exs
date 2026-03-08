defmodule Store.Governance.SubscriptionsUniquenessTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Store.Entitlements.EntitlementGrant
  alias Store.Subscriptions.{RenewalAttempt, Subscription}
  alias Store.SubscriptionsFixtures

  test "subscription create_from_order_line is idempotent by source_order_line_item_id" do
    customer = SubscriptionsFixtures.create_customer!("phase26_uni_sub")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{subscription: first, line_item: line_item, order: order} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: "pm_uni",
        status: :active
      })

    attrs = %{
      user_id: customer.id,
      subscription_plan_id: plan.id,
      variant_id: variant.id,
      status: :active,
      provider: :stripe,
      billing_mode: :merchant_managed,
      quantity: first.quantity,
      renewal_amount_minor: first.renewal_amount_minor,
      renewal_currency: first.renewal_currency,
      membership_key: first.membership_key,
      started_at: first.started_at,
      current_period_start_at: first.current_period_start_at,
      current_period_end_at: first.current_period_end_at,
      next_renewal_at: first.next_renewal_at,
      dunning_attempt_count: first.dunning_attempt_count,
      source_order_id: order.id,
      source_order_line_item_id: line_item.id
    }

    assert {:ok, second} =
             Subscription
             |> Ash.Changeset.for_create(:create_from_order_line, attrs,
               context: %{system?: true}
             )
             |> Ash.create(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert second.id == first.id

    assert 1 ==
             Subscription
             |> Ash.Query.filter(expr(source_order_line_item_id == ^line_item.id))
             |> Ash.count!(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )
  end

  test "renewal attempt create_or_reuse is idempotent by subscription_id + renewal_key" do
    customer = SubscriptionsFixtures.create_customer!("phase26_uni_attempt")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: "pm_uni_attempt"
      })

    key = "sub:#{subscription.id}:end:#{DateTime.to_iso8601(subscription.current_period_end_at)}"

    attrs = %{
      subscription_id: subscription.id,
      period_start_at: subscription.current_period_start_at,
      period_end_at: subscription.current_period_end_at,
      renewal_key: key,
      status: :pending
    }

    assert {:ok, first} =
             RenewalAttempt
             |> Ash.Changeset.for_create(:create_or_reuse, attrs, context: %{system?: true})
             |> Ash.create(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert {:ok, second} =
             RenewalAttempt
             |> Ash.Changeset.for_create(:create_or_reuse, attrs, context: %{system?: true})
             |> Ash.create(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert first.id == second.id

    assert 1 ==
             RenewalAttempt
             |> Ash.Query.filter(
               expr(subscription_id == ^subscription.id and renewal_key == ^key)
             )
             |> Ash.count!(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )
  end

  test "entitlement issue is idempotent by user+scope+source uniqueness" do
    customer = SubscriptionsFixtures.create_customer!("phase26_uni_entitlement")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        entitlement_kind: :membership_access,
        entitlement_scope_key: "membership:unique"
      })

    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan)

    attrs = %{
      user_id: customer.id,
      kind: :membership_access,
      scope_key: "membership:unique",
      source_kind: :subscription,
      source_id: subscription.id,
      status: :active,
      valid_from_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
      valid_to_at: subscription.current_period_end_at
    }

    assert {:ok, first} =
             EntitlementGrant
             |> Ash.Changeset.for_create(:issue, attrs, context: %{system?: true})
             |> Ash.create(
               domain: Store.Entitlements,
               authorize?: false,
               context: %{system?: true}
             )

    assert {:ok, second} =
             EntitlementGrant
             |> Ash.Changeset.for_create(:issue, attrs, context: %{system?: true})
             |> Ash.create(
               domain: Store.Entitlements,
               authorize?: false,
               context: %{system?: true}
             )

    assert first.id == second.id

    assert 1 ==
             EntitlementGrant
             |> Ash.Query.filter(
               expr(source_kind == :subscription and source_id == ^subscription.id)
             )
             |> Ash.count!(
               domain: Store.Entitlements,
               authorize?: false,
               context: %{system?: true}
             )
  end
end
