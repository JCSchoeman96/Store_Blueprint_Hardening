defmodule Store.Subscriptions.Sbh3003RetryExhaustionTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Store.Entitlements.EntitlementGrant
  alias Store.Entitlements.Facade, as: EntitlementsFacade
  alias Store.Subscriptions.{Facade, RenewalAttempt, Subscription}
  alias Store.SubscriptionsFixtures

  test "zero retries leaves the failed occurrence past due and dormant without suspension effects" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    customer = SubscriptionsFixtures.create_customer!("sbh_30_03_zero")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        max_retry_attempts: 0,
        entitlement_kind: :membership_access,
        entitlement_scope_key: "membership:sbh-30-03-zero"
      })

    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        next_renewal_at: DateTime.add(now, -1, :second)
      })

    assert {:ok, _grant} =
             EntitlementsFacade.issue_subscription_entitlement_for_system(subscription, plan)

    assert {:ok, %{due_count: 1, failed_count: 1}} =
             Facade.run_due_renewals_for_system(now: now, limit: 20)

    exhausted = fetch_subscription!(subscription.id)
    attempt = fetch_current_attempt!(subscription.id)

    assert exhausted.status == :past_due
    assert exhausted.past_due_since_at == now
    assert exhausted.dunning_attempt_count == 1
    assert exhausted.billing_status_reason == "PAYMENT_METHOD_REQUIRED"
    assert exhausted.next_retry_at == nil
    assert %DateTime{} = exhausted.retry_suppressed_at
    assert attempt.status == :failed
    assert attempt.failure_code == "PAYMENT_METHOD_REQUIRED"
    assert is_nil(exhausted.ended_at)
    assert is_nil(exhausted.canceled_at)
    assert is_nil(exhausted.canceled_reason)

    assert [%EntitlementGrant{status: :active}] = source_grants!(subscription.id)
    assert {:ok, []} = read_due_subscriptions(now)

    assert {:ok, %{due_count: 0, success_count: 0, failed_count: 0}} =
             Facade.run_due_renewals_for_system(now: now, limit: 20)

    assert fetch_subscription!(subscription.id).status == :past_due
    assert [%EntitlementGrant{status: :active}] = source_grants!(subscription.id)
  end

  test "the configured retry count is consumed once and exhaustion keeps the first failure anchor" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    customer = SubscriptionsFixtures.create_customer!("sbh_30_03_retries")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        max_retry_attempts: 3,
        retry_schedule_hours: [0, 24, 72]
      })

    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        next_renewal_at: DateTime.add(now, -1, :second)
      })

    assert {:ok, %{failed_count: 1}} = Facade.run_due_renewals_for_system(now: now, limit: 20)
    first_failure = fetch_subscription!(subscription.id)
    assert first_failure.dunning_attempt_count == 1
    assert first_failure.past_due_since_at == now
    assert first_failure.next_retry_at == now
    assert is_nil(first_failure.retry_suppressed_at)

    final_failure =
      Enum.reduce(2..4, first_failure, fn expected_count, previous ->
        retry_at = previous.next_retry_at
        assert %DateTime{} = retry_at

        assert {:ok, %{due_count: 1, failed_count: 1}} =
                 Facade.run_due_renewals_for_system(now: retry_at, limit: 20)

        updated = fetch_subscription!(subscription.id)
        assert updated.status == :past_due
        assert updated.dunning_attempt_count == expected_count
        assert updated.past_due_since_at == now
        updated
      end)

    assert final_failure.status == :past_due
    assert final_failure.dunning_attempt_count == 4
    assert final_failure.next_retry_at == nil
    assert %DateTime{} = final_failure.retry_suppressed_at
    assert {:ok, []} = read_due_subscriptions(DateTime.add(now, 10, :day))
    assert {:ok, %{due_count: 0, success_count: 0, failed_count: 0}} =
             Facade.run_due_renewals_for_system(now: DateTime.add(now, 10, :day), limit: 20)
  end

  defp read_due_subscriptions(now) do
    Subscription
    |> Ash.Query.for_read(:read_due_for_system, %{now: now, limit: 20})
    |> Ash.read(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp fetch_subscription!(id) do
    Subscription
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp fetch_current_attempt!(subscription_id) do
    RenewalAttempt
    |> Ash.Query.filter(expr(subscription_id == ^subscription_id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp source_grants!(subscription_id) do
    EntitlementGrant
    |> Ash.Query.filter(expr(source_type == :subscription and source_id == ^subscription_id))
    |> Ash.read!(domain: Store.Entitlements, authorize?: false, context: %{system?: true})
  end
end
