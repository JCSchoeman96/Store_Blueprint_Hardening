defmodule Store.Subscriptions.PerformanceTest do
  use Store.DataCase, async: false

  alias Store.Entitlements.Facade, as: EntitlementsFacade
  alias Store.Entitlements.Queries.UserEntitlementIndexQuery
  alias Store.Subscriptions.Facade, as: SubscriptionsFacade
  alias Store.SubscriptionsFixtures

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

    {result, query_count} =
      with_query_counter(fn ->
        SubscriptionsFacade.run_due_renewals_for_system(now: now, limit: 10)
      end)

    assert {:ok, %{due_count: 1}} = result
    assert query_count <= 20
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

    {result, query_count} =
      with_query_counter(fn ->
        EntitlementsFacade.list_entitlements_for_user(customer, query)
      end)

    assert {:ok, [_ | _]} = result
    assert query_count <= 5
  end

  defp with_query_counter(fun) when is_function(fun, 0) do
    ref = make_ref()
    handler_id = "phase26_query_counter_#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach(
      handler_id,
      [:store, :repo, :query],
      fn _event, _measurements, _metadata, _config ->
        send(parent, {ref, :query})
      end,
      nil
    )

    try do
      result = fun.()
      {result, drain_query_messages(ref, 0)}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_query_messages(ref, acc) do
    receive do
      {^ref, :query} -> drain_query_messages(ref, acc + 1)
    after
      0 -> acc
    end
  end
end
