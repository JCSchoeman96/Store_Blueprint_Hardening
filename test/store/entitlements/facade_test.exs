defmodule Store.Entitlements.FacadeTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Store.Entitlements.{EntitlementGrant, Facade}
  alias Store.SubscriptionsFixtures

  test "issue_subscription_entitlement_for_system upserts and refreshes validity window" do
    customer = SubscriptionsFixtures.create_customer!("phase26_entitlement_issue")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        entitlement_kind: :membership_access,
        entitlement_scope_key: "membership:gold"
      })

    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan)

    assert {:ok, initial} = Facade.issue_subscription_entitlement_for_system(subscription, plan)
    assert initial.status == :active
    assert initial.valid_to_at == subscription.current_period_end_at

    assert {:ok, _revoked_count} =
             Facade.revoke_subscription_entitlements_for_system(subscription.id, "test_revoke")

    later_period_end = DateTime.add(subscription.current_period_end_at, 2_592_000, :second)

    assert {:ok, updated_subscription} =
             subscription
             |> Ash.Changeset.for_update(
               :extend_period,
               %{
                 current_period_start_at: subscription.current_period_end_at,
                 current_period_end_at: later_period_end,
                 next_renewal_at: later_period_end
               },
               context: %{system?: true}
             )
             |> Ash.update(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert {:ok, upserted} =
             Facade.issue_subscription_entitlement_for_system(updated_subscription, plan)

    assert upserted.id == initial.id
    assert upserted.status == :active
    assert upserted.revoked_at == nil
    assert upserted.revoked_reason == nil
    assert upserted.valid_to_at == later_period_end
  end

  test "revoke_subscription_entitlements_for_system revokes all grants for subscription source" do
    customer = SubscriptionsFixtures.create_customer!("phase26_entitlement_revoke")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        entitlement_kind: :digital_library,
        entitlement_scope_key: "library:premium"
      })

    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan)

    assert {:ok, _grant} = Facade.issue_subscription_entitlement_for_system(subscription, plan)

    assert {:ok, revoked_count} =
             Facade.revoke_subscription_entitlements_for_system(subscription.id, "canceled_now")

    assert revoked_count == 1

    grant = fetch_entitlement!(subscription.id)
    assert grant.status == :revoked
    assert grant.revoked_reason == "canceled_now"
  end

  defp fetch_entitlement!(subscription_id) do
    EntitlementGrant
    |> Ash.Query.filter(expr(source_kind == :subscription and source_id == ^subscription_id))
    |> Ash.read!(domain: Store.Entitlements, authorize?: false, context: %{system?: true})
    |> List.first()
  end
end
