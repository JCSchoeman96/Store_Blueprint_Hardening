defmodule Store.Subscriptions.AccessEffectTargetOrderReconciliationTest do
  use Store.DataCase, async: false

  require Ash.Query
  import Ash.Expr

  alias Store.Repo
  alias Store.Subscriptions.Facade
  alias Store.Subscriptions.Inputs.EstablishAccessEffectInput
  alias Store.SubscriptionsFixtures

  @through_updated_at ~U[2026-10-23 12:00:00.000000Z]

  test "reconciliation repairs a stale effective target without churn when evidence already matches" do
    fixture = subscription_fixture!()
    subscription = fixture.subscription
    revision = fixture.revision

    stale =
      establish_effect!(
        subscription,
        revision,
        %{valid_from_at: ~U[2020-01-01 00:00:00.000000Z]}
      )

    bump_aggregate_version!(subscription.id)
    bump_aggregate_version!(subscription.id)
    subscription = reload_subscription!(subscription.id)

    set_updated_at!([stale], ~U[2026-10-23 11:00:00.000000Z])

    assert {:ok, result} =
             Facade.run_access_effect_target_order_reconciliation_for_system(
               limit: 50,
               as_of: @through_updated_at,
               skip_non_effective: true
             )

    assert result.repaired_count == 1
    assert result.noop_count == 0
    assert result.already_covered_count == 0

    rows = access_effect_rows!(subscription.id)
    assert length(rows) == 2
    assert Enum.any?(rows, &(&1.status == "superseded"))
    assert Enum.any?(
             rows,
             &(&1.status == "required" and &1.source_version == subscription.aggregate_version)
           )
  end

  test "reconciliation already_covered when target evidence matches current subscription" do
    fixture = subscription_fixture!()
    subscription = fixture.subscription
    revision = fixture.revision

    effect =
      establish_effect!(
        subscription,
        revision,
        %{
          valid_from_at: subscription.current_period_start_at,
          valid_until_at: subscription.current_period_end_at
        }
      )

    set_updated_at!([effect], ~U[2026-10-23 11:00:00.000000Z])

    assert {:ok, result} =
             Facade.run_access_effect_target_order_reconciliation_for_system(
               limit: 50,
               as_of: @through_updated_at,
               skip_non_effective: true
             )

    assert result.already_covered_count == 1
    assert result.repaired_count == 0
    assert length(access_effect_rows!(subscription.id)) == 1
  end

  defp subscription_fixture! do
    customer =
      SubscriptionsFixtures.create_customer!("f05_reconcile_#{Ecto.UUID.generate()}")

    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        entitlement_kind: :membership_access,
        entitlement_scope_key: "f05-members"
      })

    SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan)
  end

  defp establish_effect!(subscription, revision, overrides) do
    attrs =
      %{
        subscription_id: subscription.id,
        source_version: Map.get(overrides, :source_version, subscription.aggregate_version),
        disposition: :effective,
        entitlement_kind: revision.entitlement_kind,
        entitlement_scope_key: revision.entitlement_scope_key,
        valid_from_at: Map.get(overrides, :valid_from_at, subscription.current_period_start_at),
        valid_until_at: subscription.current_period_end_at,
        source_order_line_item_id: subscription.source_order_line_item_id,
        contract_change_id: subscription.current_contract_change_id,
        plan_revision_id: revision.id
      }

    assert {:ok, input} = EstablishAccessEffectInput.new(attrs)
    assert {:ok, effect} = Facade.establish_access_effect_for_system(input)
    effect
  end

  defp bump_aggregate_version!(subscription_id) do
    Repo.query!("UPDATE subscriptions SET aggregate_version = aggregate_version + 1 WHERE id = $1", [
      Ecto.UUID.dump!(subscription_id)
    ])
  end

  defp reload_subscription!(id) do
    Store.Subscriptions.Subscription
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp set_updated_at!(effects, updated_at) do
    Enum.each(effects, fn effect ->
      Repo.query!("UPDATE access_effects SET updated_at = $2 WHERE id = $1", [
        Ecto.UUID.dump!(effect.id),
        updated_at
      ])
    end)
  end

  defp access_effect_rows!(subscription_id) do
    {:ok, result} =
      Repo.query(
        """
        SELECT id::text, status, disposition, source_version, valid_from_at, valid_until_at
        FROM access_effects
        WHERE subscription_id = $1
        ORDER BY source_version ASC
        """,
        [Ecto.UUID.dump!(subscription_id)]
      )

    result.rows
    |> Enum.map(fn [id, status, disposition, source_version, from_at, until_at] ->
      %{
        id: id,
        status: status,
        disposition: disposition,
        source_version: source_version,
        valid_from_at: from_at,
        valid_until_at: until_at
      }
    end)
  end
end
