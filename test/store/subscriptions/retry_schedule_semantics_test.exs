defmodule Store.Subscriptions.RetryScheduleSemanticsTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Store.Subscriptions.{Facade, Scheduler, Subscription}
  alias Store.SubscriptionsFixtures

  @reference DateTime.from_naive!(~N[2026-01-01 00:00:00], "Etc/UTC")

  test "uses configured retry offsets from the first retryable failure" do
    plan = %{retry_schedule_hours: [0, 24, 72]}

    assert Scheduler.next_retry_at(@reference, 0, plan) == @reference

    assert Scheduler.next_retry_at(@reference, 1, plan) ==
             DateTime.add(@reference, 24, :hour)

    assert Scheduler.next_retry_at(@reference, 2, plan) ==
             DateTime.add(@reference, 72, :hour)
  end

  test "normalizes retry schedules and reports exhaustion after the final offset" do
    plan = %{"retry_schedule_hours" => [72, -1, "24", 0, 24, 72]}

    assert Scheduler.next_retry_at(@reference, 0, plan) == @reference
    assert Scheduler.next_retry_at(@reference, 1, plan) == DateTime.add(@reference, 24, :hour)
    assert Scheduler.next_retry_at(@reference, 2, plan) == DateTime.add(@reference, 72, :hour)
    assert Scheduler.next_retry_at(@reference, 3, plan) == :exhausted
    assert Scheduler.next_retry_at(@reference, 4, plan) == :exhausted
  end

  test "uses the normalized fallback for empty or invalid schedules" do
    assert Scheduler.next_retry_at(@reference, 0, %{retry_schedule_hours: []}) ==
             DateTime.add(@reference, 24, :hour)

    assert Scheduler.next_retry_at(@reference, 2, %{retry_schedule_hours: [:invalid]}) ==
             DateTime.add(@reference, 120, :hour)
  end

  test "anchors the dunning episode at the first failure and preserves it on retries" do
    now =
      DateTime.from_naive!(~N[2026-02-01 12:00:00], "Etc/UTC")
      |> DateTime.truncate(:microsecond)

    retry_now = DateTime.add(now, 1, :second)
    customer = SubscriptionsFixtures.create_customer!("sbh_30_02_anchor")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        next_renewal_at: DateTime.add(now, -1, :second)
      })

    assert {:ok, %{failed_count: 1}} = Facade.run_due_renewals_for_system(now: now, limit: 20)

    first_failure = fetch_subscription!(subscription.id)
    assert first_failure.status == :past_due
    assert DateTime.compare(first_failure.past_due_since_at, now) == :eq
    assert DateTime.compare(first_failure.next_retry_at, now) == :eq

    assert {:ok, %{failed_count: 1}} =
             Facade.run_due_renewals_for_system(now: retry_now, limit: 20)

    second_failure = fetch_subscription!(subscription.id)
    assert second_failure.status == :past_due
    assert DateTime.compare(second_failure.past_due_since_at, now) == :eq

    assert DateTime.compare(second_failure.next_retry_at, DateTime.add(now, 24, :hour)) ==
             :eq
  end

  defp fetch_subscription!(id) do
    Subscription
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end
end
