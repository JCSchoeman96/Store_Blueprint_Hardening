defmodule Store.Subscriptions.ReplayConcurrencyTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Store.Subscriptions.{Facade, RenewalAttempt, Scheduler, Subscription}
  alias Store.SubscriptionsFixtures

  test "concurrent renewal ticks do not double-extend the same subscription period" do
    customer = SubscriptionsFixtures.create_customer!("phase26_sub_concurrency")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: "pm_phase26_race",
        next_renewal_at: DateTime.add(now, -5, :second)
      })

    expected_period = Scheduler.next_period(subscription.current_period_end_at, plan)

    results =
      1..2
      |> Enum.map(fn _ ->
        Task.async(fn -> Facade.run_due_renewals_for_system(now: now, limit: 50) end)
      end)
      |> Enum.map(&Task.await(&1, 5_000))

    assert Enum.all?(results, &match?({:ok, _}, &1))

    renewed = fetch_subscription!(subscription.id)
    assert renewed.current_period_end_at == expected_period.current_period_end_at
    assert renewed.next_renewal_at == expected_period.next_renewal_at

    attempts = list_attempts!(subscription.id)
    assert length(attempts) == 1
    assert hd(attempts).status == :succeeded
  end

  defp fetch_subscription!(id) do
    Subscription
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
    |> List.first()
  end

  defp list_attempts!(subscription_id) do
    RenewalAttempt
    |> Ash.Query.filter(expr(subscription_id == ^subscription_id))
    |> Ash.Query.sort(inserted_at: :desc, id: :desc)
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end
end
