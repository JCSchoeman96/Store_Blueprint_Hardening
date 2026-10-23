defmodule Store.Subscriptions.AccessEffectTargetOrderTest do
  use ExUnit.Case, async: true

  alias Store.Subscriptions.AccessEffect
  alias Store.Subscriptions.AccessEffectTargetOrder
  alias Store.Subscriptions.PlanRevision
  alias Store.Subscriptions.RenewalAttempt
  alias Store.Subscriptions.Subscription

  @period_start ~U[2026-01-01 00:00:00.000000Z]
  @period_end ~U[2026-02-01 00:00:00.000000Z]
  @line_item_id Ecto.UUID.generate()
  @plan_revision_id Ecto.UUID.generate()
  @subscription_id Ecto.UUID.generate()

  describe "derive_current_target/2" do
    test "active subscription with entitlement pair uses current period boundaries" do
      subscription = %Subscription{
        id: @subscription_id,
        status: :active,
        source_order_line_item_id: @line_item_id,
        current_contract_change_id: nil,
        current_plan_revision_id: @plan_revision_id,
        current_period_start_at: @period_start,
        current_period_end_at: @period_end
      }

      revision = %PlanRevision{
        id: @plan_revision_id,
        entitlement_kind: :membership_access,
        entitlement_scope_key: "gold"
      }

      assert {:ok, derived} = AccessEffectTargetOrder.derive_current_target(subscription, revision)

      assert derived.disposition == :effective
      assert derived.entitlement_kind == :membership_access
      assert derived.entitlement_scope_key == "gold"
      assert derived.valid_from_at == @period_start
      assert derived.valid_until_at == @period_end
    end

    test "active nil/nil pair keeps nil start and period end" do
      subscription = %Subscription{
        id: @subscription_id,
        status: :past_due,
        source_order_line_item_id: @line_item_id,
        current_contract_change_id: nil,
        current_plan_revision_id: @plan_revision_id,
        current_period_start_at: @period_start,
        current_period_end_at: @period_end
      }

      revision = %PlanRevision{
        id: @plan_revision_id,
        entitlement_kind: nil,
        entitlement_scope_key: nil
      }

      assert {:ok, derived} = AccessEffectTargetOrder.derive_current_target(subscription, revision)
      assert derived.valid_from_at == nil
      assert derived.valid_until_at == @period_end
    end

    test "canceled subscription is non-effective nil target" do
      subscription = %Subscription{
        id: @subscription_id,
        status: :canceled,
        source_order_line_item_id: @line_item_id,
        current_contract_change_id: nil,
        current_plan_revision_id: @plan_revision_id
      }

      assert {:ok, derived} = AccessEffectTargetOrder.derive_current_target(subscription, nil)
      assert derived.disposition == :non_effective
      assert derived.entitlement_kind == nil
      assert derived.valid_until_at == nil
    end

    test "pending subscription fails closed" do
      subscription = %Subscription{
        id: @subscription_id,
        status: :pending,
        source_order_line_item_id: @line_item_id,
        current_plan_revision_id: @plan_revision_id
      }

      assert {:error, %{code: "TARGET_ORDER_UNSUPPORTED_STATE"}} =
               AccessEffectTargetOrder.derive_current_target(subscription, nil)
    end
  end

  describe "target_evidence_equal?/2" do
    test "ignores source version differences via effect comparison" do
      base = %{
        disposition: :effective,
        entitlement_kind: :membership_access,
        entitlement_scope_key: "gold",
        valid_from_at: @period_start,
        valid_until_at: @period_end,
        source_order_line_item_id: @line_item_id,
        contract_change_id: nil,
        plan_revision_id: @plan_revision_id
      }

      effect =
        struct(AccessEffect, Map.merge(base, %{id: Ecto.UUID.generate(), source_version: 3}))

      assert AccessEffectTargetOrder.covered?(effect, base)
    end
  end

  describe "charged_renewal_establish_attrs/3" do
    test "nil/nil charged snapshot does not fabricate valid_from_at" do
      subscription = %Subscription{
        id: @subscription_id,
        aggregate_version: 4,
        source_order_line_item_id: @line_item_id,
        current_contract_change_id: nil
      }

      attempt = %RenewalAttempt{
        period_start_at: @period_start,
        period_end_at: @period_end,
        plan_revision_id: @plan_revision_id
      }

      target = %{entitlement_kind: nil, entitlement_scope_key: nil}

      attrs =
        AccessEffectTargetOrder.charged_renewal_establish_attrs(subscription, attempt, target)

      assert attrs.valid_from_at == nil
      assert attrs.valid_until_at == @period_end
      assert attrs.source_version == 4
    end
  end
end
