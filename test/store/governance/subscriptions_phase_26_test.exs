defmodule Store.Governance.SubscriptionsPhase26Test do
  use ExUnit.Case, async: true

  alias Store.Support.Governance.{SurfaceRegistry, UniquenessRegistry}

  test "phase 25 and phase 27 docs pin subscription scope boundaries around phase 26" do
    phase_25 = File.read!("docs/phases/phase_25_variable_products_variants.md")
    phase_26 = File.read!("docs/phases/phase_26_simple_subscriptions.md")
    phase_27 = File.read!("docs/phases/phase_27_variable_subscriptions.md")

    assert phase_25 =~ "Subscription variants (handled in subscription phases)"
    assert phase_26 =~ "Variable subscriptions (variants + subscription plan coupling)"
    assert phase_27 =~ "Phase 26 (Simple subscriptions)"
  end

  test "surface registry includes phase 26 subscriptions and entitlements facades" do
    subscriptions_exports = SurfaceRegistry.allowed_exports(Store.Subscriptions.Facade)
    entitlements_exports = SurfaceRegistry.allowed_exports(Store.Entitlements.Facade)

    assert {:create_subscriptions_from_paid_order_for_system, 1} in subscriptions_exports
    assert {:ensure_membership_purchase_allowed_for_system, 2} in subscriptions_exports
    assert {:list_due_renewal_jobs_for_system, 1} in subscriptions_exports
    assert {:process_due_subscription_renewal_for_system, 2} in subscriptions_exports
    assert {:run_due_renewals_for_system, 0} in subscriptions_exports
    assert {:run_due_renewals_for_system, 1} in subscriptions_exports
    assert {:list_subscriptions_for_user, 2} in subscriptions_exports

    assert {:list_entitlements_for_user, 2} in entitlements_exports
    assert {:entitlement_set_for_user, 1} in entitlements_exports
    assert {:issue_subscription_entitlement_for_system, 2} in entitlements_exports
    assert {:revoke_subscription_entitlements_for_system, 2} in entitlements_exports
  end

  test "uniqueness registry includes phase 26 subscription and entitlement constraints" do
    active_keys = UniquenessRegistry.active_now() |> Enum.map(& &1.key) |> MapSet.new()

    assert MapSet.subset?(
             MapSet.new([
               :subscription_plans_key,
               :variant_subscription_plans_variant_subscription_plan,
               :stored_payment_methods_provider_customer_payment_method,
               :subscriptions_source_order_line_item_id,
               :subscriptions_provider_provider_subscription_id,
               :subscription_items_source_order_line_item_id,
               :renewal_attempts_subscription_renewal_key,
               :entitlement_grants_user_scope_source
             ]),
             active_keys
           )
  end

  test "router and route inventory include subscription account/admin surfaces" do
    router = File.read!("lib/store_web/router.ex")
    route_inventory = File.read!("docs/governance/route_inventory.md")

    assert router =~ "live(\"/account/subscriptions\", SubscriptionsLive.Index, :index)"
    assert router =~ "live(\"/account/subscriptions/:id\", SubscriptionsLive.Show, :show)"
    assert router =~ "live(\"/admin/subscriptions\", Admin.Subscriptions.IndexLive, :index)"
    assert router =~ "live(\"/admin/subscriptions/:id\", Admin.Subscriptions.ShowLive, :show)"

    assert route_inventory =~ "| GET | `/account/subscriptions` |"
    assert route_inventory =~ "| GET | `/account/subscriptions/:id` |"
    assert route_inventory =~ "| GET | `/admin/subscriptions` |"
    assert route_inventory =~ "| GET | `/admin/subscriptions/:id` |"
  end
end
