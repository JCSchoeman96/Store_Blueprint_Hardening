defmodule Store.Subscriptions.ReplayConcurrencyTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Store.Subscriptions.{Facade, RenewalAttempt, Subscription}
  alias Store.SubscriptionsFixtures

  test "concurrent renewal ticks create one renewal attempt and do not advance before reconciliation" do
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

    current_period_end = subscription.current_period_end_at
    current_next_renewal_at = subscription.next_renewal_at

    results =
      1..2
      |> Enum.map(fn _ ->
        Task.async(fn -> Facade.run_due_renewals_for_system(now: now, limit: 50) end)
      end)
      |> Enum.map(&Task.await(&1, 5_000))

    assert Enum.all?(results, &match?({:ok, _}, &1))

    renewed = fetch_subscription!(subscription.id)
    assert renewed.current_period_end_at == current_period_end
    assert renewed.next_renewal_at == current_next_renewal_at

    attempts = list_attempts!(subscription.id)
    assert length(attempts) == 1
    assert hd(attempts).status == :processing
    assert is_binary(hd(attempts).order_id)
    assert is_binary(hd(attempts).payment_intent_id)
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
