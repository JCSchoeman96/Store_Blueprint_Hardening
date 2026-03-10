defmodule Store.Subscriptions.PerformanceTest do
  use Store.DataCase, async: false

  use Oban.Testing, repo: Store.DirectRepo

  alias Store.Entitlements.Cache, as: EntitlementsCache
  alias Store.Entitlements.Facade, as: EntitlementsFacade
  alias Store.Subscriptions.Facade, as: SubscriptionsFacade
  alias Store.Subscriptions.RenewalAttempt
  alias Store.SubscriptionsFixtures
  alias Store.Support.Telemetry.RepoStats

  test "due renewal job listing stays bounded across active, retryable, and suppressed subscriptions" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    active_due_customer = SubscriptionsFixtures.create_customer!("phase27_perf_active_due")

    %{subscription: active_due_subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(active_due_customer.id, variant, plan, %{
        provider_billing_ref: "pm_phase27_perf_active_due",
        next_renewal_at: DateTime.add(now, -5, :second)
      })

    future_customer = SubscriptionsFixtures.create_customer!("phase27_perf_future")

    _future_fixture =
      SubscriptionsFixtures.create_subscription_fixture!(future_customer.id, variant, plan, %{
        provider_billing_ref: "pm_phase27_perf_future",
        next_renewal_at: DateTime.add(now, 86_400, :second)
      })

    retryable_customer = SubscriptionsFixtures.create_customer!("phase27_perf_retryable")

    %{subscription: retryable_subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(retryable_customer.id, variant, plan, %{
        status: :past_due,
        billing_status_reason: "PAYMENT_FAILED",
        provider_billing_ref: "pm_phase27_perf_retryable",
        next_retry_at: DateTime.add(now, -5, :second)
      })

    suppressed_customer = SubscriptionsFixtures.create_customer!("phase27_perf_suppressed")

    %{subscription: suppressed_subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(suppressed_customer.id, variant, plan, %{
        status: :past_due,
        billing_status_reason: "SHIPPING_UNAVAILABLE",
        provider_billing_ref: "pm_phase27_perf_suppressed",
        next_retry_at: DateTime.add(now, -5, :second),
        retry_suppressed_at: DateTime.add(now, -30, :second)
      })

    {result, stats} =
      Oban.Testing.with_testing_mode(:manual, fn ->
        RepoStats.capture(fn ->
          SubscriptionsFacade.list_due_renewal_jobs_for_system(now: now, limit: 20)
        end)
      end)

    assert {:ok, jobs} = result

    assert Enum.map(jobs, & &1.subscription_id) |> MapSet.new() ==
             MapSet.new([active_due_subscription.id, retryable_subscription.id])

    refute Enum.any?(jobs, &(&1.subscription_id == suppressed_subscription.id))
    assert stats.query_count <= 6
  end

  test "entitlement set for user stays bounded on cold and warm reads" do
    customer = SubscriptionsFixtures.create_customer!("phase27_perf_entitlement_set")
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

    assert :ok = EntitlementsCache.invalidate_local(customer.id)

    {cold_result, cold_stats} =
      Oban.Testing.with_testing_mode(:manual, fn ->
        RepoStats.capture(fn ->
          EntitlementsFacade.entitlement_set_for_user(customer)
        end)
      end)

    assert {:ok, cold_set} = cold_result
    assert cold_set.user_id == customer.id
    assert cold_stats.query_count <= 2

    assert {:ok, _warmup_set} = EntitlementsFacade.entitlement_set_for_user(customer)

    {warm_result, warm_stats} =
      Oban.Testing.with_testing_mode(:manual, fn ->
        RepoStats.capture(fn ->
          EntitlementsFacade.entitlement_set_for_user(customer)
        end)
      end)

    assert {:ok, warm_set} = warm_result
    assert warm_set.user_id == customer.id
    assert warm_stats.query_count == 0
  end

  test "subscription detail read model stays bounded and caps renewal attempts" do
    customer = SubscriptionsFixtures.create_customer!("phase27_perf_detail")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    for idx <- 1..7 do
      RenewalAttempt
      |> Ash.Changeset.for_create(
        :create_or_reuse,
        %{
          subscription_id: subscription.id,
          period_start_at: DateTime.add(now, -idx * 86_400, :second),
          period_end_at: DateTime.add(now, -(idx - 1) * 86_400, :second),
          renewal_key: "perf-detail:#{subscription.id}:#{idx}",
          status: :failed,
          failure_code: "PAYMENT_FAILED",
          attempt_no: idx
        },
        context: %{system?: true}
      )
      |> Ash.create!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
    end

    {result, stats} =
      Oban.Testing.with_testing_mode(:manual, fn ->
        RepoStats.capture(fn ->
          SubscriptionsFacade.get_subscription_detail_for_user(customer, subscription.id)
        end)
      end)

    assert {:ok, detail} = result
    assert detail.subscription.id == subscription.id
    assert length(detail.renewal_attempts) == 5
    assert stats.query_count <= 14
  end
end
