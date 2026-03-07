defmodule Store.Subscriptions.PerformanceTest do
  use Store.DataCase, async: false

  alias Store.Entitlements.Facade, as: EntitlementsFacade
  alias Store.Entitlements.Queries.UserEntitlementIndexQuery
  alias Store.Subscriptions.Facade, as: SubscriptionsFacade
  alias Store.SubscriptionsFixtures
  alias Store.Support.Telemetry.RepoStats

  test "renewal tick query count stays bounded for a single due subscription" do
    customer = SubscriptionsFixtures.create_customer!("phase26_perf_due")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    _fixture =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: "pm_phase26_perf",
        next_renewal_at: DateTime.add(now, -5, :second)
      })

    {result, stats} =
      RepoStats.capture(fn ->
        SubscriptionsFacade.run_due_renewals_for_system(now: now, limit: 10)
      end)

    assert {:ok, %{due_count: 1}} = result
    assert stats.query_count <= 20
  end

  test "entitlement list for user is served with bounded query count" do
    customer = SubscriptionsFixtures.create_customer!("phase26_perf_entitlements")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        entitlement_kind: :digital_library,
        entitlement_scope_key: "library:perf"
      })

    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan)

    assert {:ok, _} =
             EntitlementsFacade.issue_subscription_entitlement_for_system(subscription, plan)

    assert {:ok, query} = UserEntitlementIndexQuery.new(%{"limit" => "50"})

    {result, stats} =
      RepoStats.capture(fn ->
        EntitlementsFacade.list_entitlements_for_user(customer, query)
      end)

    assert {:ok, [_ | _]} = result
    assert stats.query_count <= 5
  end
end
