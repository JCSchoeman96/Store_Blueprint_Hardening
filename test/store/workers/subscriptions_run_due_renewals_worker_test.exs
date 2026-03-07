defmodule Store.Workers.SubscriptionsRunDueRenewalsWorkerTest do
  use Store.DataCase, async: false
  use Oban.Testing, repo: Store.DirectRepo

  import Ash.Expr
  require Ash.Query

  alias Store.Subscriptions.{RenewalAttempt, Subscription}
  alias Store.SubscriptionsFixtures
  alias Store.Workers.RunDueSubscriptionRenewalsWorker

  test "worker processes due renewals and advances subscription period once" do
    customer = SubscriptionsFixtures.create_customer!("phase26_worker_due")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: "pm_phase26_worker",
        next_renewal_at: DateTime.add(now, -30, :second)
      })

    previous_period_end = subscription.current_period_end_at

    assert :ok = perform_job(RunDueSubscriptionRenewalsWorker, %{"limit" => 50})

    renewed = fetch_subscription!(subscription.id)
    assert DateTime.compare(renewed.current_period_end_at, previous_period_end) == :gt

    attempt = fetch_latest_attempt!(subscription.id)
    assert attempt.status == :succeeded
  end

  defp fetch_subscription!(id) do
    Subscription
    |> Ash.Query.filter(expr(id == ^id))
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
end
