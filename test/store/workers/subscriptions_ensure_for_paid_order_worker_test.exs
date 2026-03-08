defmodule Store.Workers.SubscriptionsEnsureForPaidOrderWorkerTest do
  use Store.DataCase, async: false
  use Oban.Testing, repo: Store.DirectRepo

  import Ash.Expr
  require Ash.Query

  alias Store.Subscriptions.{StoredPaymentMethod, Subscription, SubscriptionItem}
  alias Store.SubscriptionsFixtures
  alias Store.Workers.EnsureSubscriptionsForPaidOrderWorker

  test "worker creates subscriptions from paid order and is replay-safe across duplicate runs" do
    customer = SubscriptionsFixtures.create_customer!("phase26_worker_ensure")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        entitlement_kind: :membership_access,
        entitlement_scope_key: "membership:worker"
      })

    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{order: order} =
      SubscriptionsFixtures.create_paid_order_with_subscription_line!(
        customer.id,
        variant,
        plan,
        %{
          provider_customer_ref: "cus_worker_001",
          provider_billing_ref: "pm_worker_001"
        }
      )

    assert :ok = perform_job(EnsureSubscriptionsForPaidOrderWorker, %{"order_id" => order.id})
    assert :ok = perform_job(EnsureSubscriptionsForPaidOrderWorker, %{"order_id" => order.id})

    subscription_ids =
      Subscription
      |> Ash.Query.filter(expr(source_order_id == ^order.id))
      |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
      |> Enum.map(& &1.id)

    assert length(subscription_ids) == 1

    assert 1 ==
             SubscriptionItem
             |> Ash.Query.filter(expr(subscription_id in ^subscription_ids))
             |> Ash.count!(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    [subscription] =
      Subscription
      |> Ash.Query.filter(expr(id in ^subscription_ids))
      |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    assert subscription.provider_customer_ref == "cus_worker_001"
    assert subscription.provider_billing_ref == "pm_worker_001"
    assert is_binary(subscription.stored_payment_method_id)

    assert 1 ==
             StoredPaymentMethod
             |> Ash.Query.filter(
               expr(
                 user_id == ^customer.id and provider_customer_ref == ^"cus_worker_001" and
                   provider_payment_method_ref == ^"pm_worker_001"
               )
             )
             |> Ash.count!(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )
  end
end
