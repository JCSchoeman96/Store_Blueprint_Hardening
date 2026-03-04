defmodule Store.Governance.SubscriptionsPolicyMatrixTest do
  use Store.DataCase, async: false

  alias Store.Subscriptions.Facade
  alias Store.Subscriptions.Queries.{AdminSubscriptionIndexQuery, UserSubscriptionIndexQuery}
  alias Store.SubscriptionsFixtures
  alias Store.TestFixtures

  test "customer subscription reads are self-scoped and cross-account cancellation is denied" do
    customer_a = SubscriptionsFixtures.create_customer!("phase26_policy_customer_a")
    customer_b = SubscriptionsFixtures.create_customer!("phase26_policy_customer_b")

    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{subscription: subscription_a} =
      SubscriptionsFixtures.create_subscription_fixture!(customer_a.id, variant, plan, %{
        provider_billing_ref: "pm_policy_a"
      })

    %{subscription: subscription_b} =
      SubscriptionsFixtures.create_subscription_fixture!(customer_b.id, variant, plan, %{
        provider_billing_ref: "pm_policy_b"
      })

    assert {:ok, user_query} = UserSubscriptionIndexQuery.new(%{})
    assert {:ok, subscriptions} = Facade.list_subscriptions_for_user(customer_a, user_query)
    assert Enum.map(subscriptions, & &1.id) == [subscription_a.id]

    assert {:ok, nil} = Facade.get_subscription_for_user(customer_a, subscription_b.id)

    assert {:error, error} =
             Facade.cancel_subscription_for_user(customer_a, subscription_b.id, :now)

    assert error.code == "SUBSCRIPTION_NOT_FOUND"
  end

  test "support can read admin subscription index but cannot mutate lifecycle transitions" do
    support =
      TestFixtures.register_user!(email: TestFixtures.unique_email("phase26_policy_support"))

    _role = TestFixtures.assign_role!(support, :support)

    customer = SubscriptionsFixtures.create_customer!("phase26_policy_customer")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: "pm_policy_support"
      })

    assert {:ok, admin_query} = AdminSubscriptionIndexQuery.new(%{})
    assert {:ok, subscriptions} = Facade.list_subscriptions_for_admin(support, admin_query)
    assert Enum.any?(subscriptions, &(&1.id == subscription.id))

    assert {:error, error} = Facade.cancel_subscription_for_admin(support, subscription.id, :now)
    assert error.code in ["FORBIDDEN", "UNAUTHORIZED"]
  end
end
