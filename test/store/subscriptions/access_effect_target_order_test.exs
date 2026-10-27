defmodule Store.Subscriptions.AccessEffectTargetOrderTest do
  use ExUnit.Case, async: true

  alias Store.Subscriptions.AccessEffect
  alias Store.Subscriptions.AccessEffectTargetOrder
  alias Store.Subscriptions.PlanRevision
  alias Store.Subscriptions.RenewalAttempt
  alias Store.Subscriptions.Subscription

  @period_start ~U[2026-01-01 00:00:00.000000Z]
  @period_end ~U[2026-02-01 00:00:00.000000Z]
  @boundary ~U[2026-01-08 00:00:00.000000Z]
  @line_item_id Ecto.UUID.generate()
  @plan_revision_id Ecto.UUID.generate()
  @funded_revision_id Ecto.UUID.generate()
  @attempt_id Ecto.UUID.generate()
  @subscription_id Ecto.UUID.generate()
  @contract_change_y Ecto.UUID.generate()
  @contract_change_x Ecto.UUID.generate()

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

      assert {:ok, derived} =
               AccessEffectTargetOrder.derive_current_target(subscription, revision)

      assert derived.disposition == :effective
      assert derived.entitlement_kind == :membership_access
      assert derived.entitlement_scope_key == "gold"
      assert derived.valid_from_at == @period_start
      assert derived.valid_until_at == @period_end
    end

    test "active nil/nil pair keeps nil start and period end" do
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
        entitlement_kind: nil,
        entitlement_scope_key: nil
      }

      assert {:ok, derived} =
               AccessEffectTargetOrder.derive_current_target(subscription, revision)

      assert derived.valid_from_at == nil
      assert derived.valid_until_at == @period_end
    end

    test "past_due derive_current_target requires bound attempt authority" do
      subscription = %Subscription{
        id: @subscription_id,
        status: :past_due,
        source_order_line_item_id: @line_item_id,
        current_plan_revision_id: @plan_revision_id,
        current_period_start_at: @period_start,
        current_period_end_at: @period_end,
        failed_payment_boundary_at: @boundary
      }

      revision = %PlanRevision{
        id: @plan_revision_id,
        entitlement_kind: nil,
        entitlement_scope_key: nil
      }

      assert {:error, %{code: "TARGET_ORDER_UNPROVABLE"}} =
               AccessEffectTargetOrder.derive_current_target(subscription, revision)
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

  describe "derive_keep_during_grace_target/3" do
    test "uses funded composition and subscription provenance, not attempt contract change" do
      subscription = %Subscription{
        id: @subscription_id,
        status: :past_due,
        source_order_line_item_id: @line_item_id,
        current_contract_change_id: @contract_change_y,
        current_plan_revision_id: @funded_revision_id,
        current_period_start_at: @period_start,
        current_period_end_at: @period_end,
        failed_payment_boundary_at: @boundary,
        past_due_since_at: @period_start,
        current_dunning_renewal_attempt_id: @attempt_id
      }

      attempt = %RenewalAttempt{
        id: @attempt_id,
        subscription_id: @subscription_id,
        contract_change_id: @contract_change_x,
        plan_revision_id: Ecto.UUID.generate(),
        period_start_at: @period_end,
        period_end_at: DateTime.add(@period_end, 30, :day)
      }

      funded_revision = %PlanRevision{
        id: @funded_revision_id,
        entitlement_kind: :membership_access,
        entitlement_scope_key: "funded-a"
      }

      assert {:ok, derived} =
               AccessEffectTargetOrder.derive_keep_during_grace_target(
                 subscription,
                 attempt,
                 funded_revision
               )

      assert derived.disposition == :effective
      assert derived.entitlement_kind == :membership_access
      assert derived.entitlement_scope_key == "funded-a"
      assert derived.valid_from_at == @period_start
      assert derived.valid_until_at == @boundary
      assert derived.plan_revision_id == @funded_revision_id
      assert derived.contract_change_id == @contract_change_y
    end

    test "nil/nil funded pair is EFFECTIVE with nil start and grace boundary" do
      subscription = %Subscription{
        id: @subscription_id,
        status: :past_due,
        source_order_line_item_id: @line_item_id,
        current_contract_change_id: nil,
        current_plan_revision_id: @funded_revision_id,
        current_period_start_at: @period_start,
        current_period_end_at: @period_end,
        failed_payment_boundary_at: @boundary,
        past_due_since_at: @period_start,
        current_dunning_renewal_attempt_id: @attempt_id
      }

      attempt = %RenewalAttempt{
        id: @attempt_id,
        subscription_id: @subscription_id,
        period_start_at: @period_end,
        period_end_at: DateTime.add(@period_end, 30, :day)
      }

      funded_revision = %PlanRevision{
        id: @funded_revision_id,
        entitlement_kind: nil,
        entitlement_scope_key: nil
      }

      assert {:ok, derived} =
               AccessEffectTargetOrder.derive_keep_during_grace_target(
                 subscription,
                 attempt,
                 funded_revision
               )

      assert derived.valid_from_at == nil
      assert derived.valid_until_at == @boundary
    end

    test "rejects half-pairs, missing boundary, owner mismatch, and period mismatch" do
      base_subscription = %Subscription{
        id: @subscription_id,
        status: :past_due,
        source_order_line_item_id: @line_item_id,
        current_plan_revision_id: @funded_revision_id,
        current_period_start_at: @period_start,
        current_period_end_at: @period_end,
        failed_payment_boundary_at: @boundary,
        past_due_since_at: @period_start,
        current_dunning_renewal_attempt_id: @attempt_id
      }

      attempt = %RenewalAttempt{
        id: @attempt_id,
        subscription_id: @subscription_id,
        period_start_at: @period_end,
        period_end_at: DateTime.add(@period_end, 30, :day)
      }

      half_revision = %PlanRevision{
        id: @funded_revision_id,
        entitlement_kind: :membership_access,
        entitlement_scope_key: nil
      }

      assert {:error, %{code: "TARGET_ORDER_UNPROVABLE"}} =
               AccessEffectTargetOrder.derive_keep_during_grace_target(
                 base_subscription,
                 attempt,
                 half_revision
               )

      assert {:error, %{code: "TARGET_ORDER_UNPROVABLE"}} =
               AccessEffectTargetOrder.derive_keep_during_grace_target(
                 Map.put(base_subscription, :failed_payment_boundary_at, nil),
                 attempt,
                 %PlanRevision{
                   id: @funded_revision_id,
                   entitlement_kind: nil,
                   entitlement_scope_key: nil
                 }
               )

      wrong_owner = %RenewalAttempt{
        id: Ecto.UUID.generate(),
        subscription_id: @subscription_id,
        period_start_at: @period_end,
        period_end_at: DateTime.add(@period_end, 30, :day)
      }

      assert {:error, %{code: "TARGET_ORDER_UNPROVABLE"}} =
               AccessEffectTargetOrder.derive_keep_during_grace_target(
                 base_subscription,
                 wrong_owner,
                 %PlanRevision{
                   id: @funded_revision_id,
                   entitlement_kind: nil,
                   entitlement_scope_key: nil
                 }
               )

      wrong_period = %RenewalAttempt{
        id: @attempt_id,
        subscription_id: @subscription_id,
        period_start_at: DateTime.add(@period_end, 1, :day),
        period_end_at: DateTime.add(@period_end, 31, :day)
      }

      assert {:error, %{code: "TARGET_ORDER_UNPROVABLE"}} =
               AccessEffectTargetOrder.derive_keep_during_grace_target(
                 base_subscription,
                 wrong_period,
                 %PlanRevision{
                   id: @funded_revision_id,
                   entitlement_kind: nil,
                   entitlement_scope_key: nil
                 }
               )
    end

    test "rejects malformed pair interval and funded revision identity mismatch" do
      funded_revision = %PlanRevision{
        id: @funded_revision_id,
        entitlement_kind: :membership_access,
        entitlement_scope_key: "gold"
      }

      attempt = %RenewalAttempt{
        id: @attempt_id,
        subscription_id: @subscription_id,
        period_start_at: @period_end,
        period_end_at: DateTime.add(@period_end, 30, :day)
      }

      invalid_interval = %Subscription{
        id: @subscription_id,
        status: :past_due,
        source_order_line_item_id: @line_item_id,
        current_plan_revision_id: @funded_revision_id,
        current_period_start_at: @boundary,
        current_period_end_at: @period_end,
        failed_payment_boundary_at: @period_start,
        past_due_since_at: @period_start,
        current_dunning_renewal_attempt_id: @attempt_id
      }

      assert {:error, %{code: "TARGET_ORDER_UNPROVABLE"}} =
               AccessEffectTargetOrder.derive_keep_during_grace_target(
                 invalid_interval,
                 attempt,
                 funded_revision
               )

      assert {:error, %{code: "TARGET_ORDER_UNPROVABLE"}} =
               AccessEffectTargetOrder.derive_keep_during_grace_target(
                 Map.put(invalid_interval, :past_due_since_at, nil),
                 attempt,
                 funded_revision
               )

      wrong_revision = %PlanRevision{
        id: Ecto.UUID.generate(),
        entitlement_kind: :membership_access,
        entitlement_scope_key: "gold"
      }

      valid_subscription = %Subscription{
        id: @subscription_id,
        status: :past_due,
        source_order_line_item_id: @line_item_id,
        current_plan_revision_id: @funded_revision_id,
        current_period_start_at: @period_start,
        current_period_end_at: @period_end,
        failed_payment_boundary_at: @boundary,
        past_due_since_at: @period_start,
        current_dunning_renewal_attempt_id: @attempt_id
      }

      assert {:error, %{code: "TARGET_ORDER_UNPROVABLE"}} =
               AccessEffectTargetOrder.derive_keep_during_grace_target(
                 valid_subscription,
                 attempt,
                 wrong_revision
               )
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
