defmodule Store.Subscriptions.FacadeTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Store.Catalog.{
    InventoryItem,
    ProductOption,
    ProductOptionValue,
    Variant,
    VariantOptionSelection
  }

  alias Store.Comms.EmailOutbox
  alias Store.Entitlements.EntitlementGrant
  alias Store.Entitlements.Facade, as: EntitlementsFacade
  alias Store.Orders.{InventoryReservation, Order}
  alias Store.Payments.PaymentIntent
  alias Store.Pricing.TaxRate
  alias Store.Shipping.Facade, as: ShippingFacade
  alias Store.Shipping.Inputs.QuoteRequest
  alias Store.Shipping.{ShippingMethod, ShippingRateRule, ShippingZone}
  alias Store.Subscriptions.Facade, as: SubscriptionsFacade

  alias Store.Subscriptions.{
    RenewalAttempt,
    Subscription,
    SubscriptionItem
  }

  alias Store.Subscriptions.Inputs.{
    QueueSubscriptionPlanChangeInput,
    QueueSubscriptionVariantChangeInput,
    StartSubscriptionPaymentMethodUpdateInput
  }

  alias Store.SubscriptionsFixtures

  setup do
    previous = Application.get_env(:store, :payments, [])

    on_exit(fn ->
      Application.put_env(:store, :payments, previous)
    end)

    :ok
  end

  test "create_subscriptions_from_paid_order_for_system is replay-safe and issues entitlements" do
    customer = SubscriptionsFixtures.create_customer!("phase26_sub_create")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        entitlement_kind: :membership_access,
        entitlement_scope_key: "membership:gold"
      })

    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{order: order} =
      SubscriptionsFixtures.create_paid_order_with_subscription_line!(customer.id, variant, plan)

    assert {:ok, first} =
             SubscriptionsFacade.create_subscriptions_from_paid_order_for_system(order.id)

    assert first.subscription_line_count == 1
    assert first.created_count == 1
    assert first.skipped_count == 0
    assert first.entitlement_issued_count == 1

    assert {:ok, second} =
             SubscriptionsFacade.create_subscriptions_from_paid_order_for_system(order.id)

    assert second.subscription_line_count == 1
    assert second.created_count == 0
    assert second.skipped_count == 1
    assert second.entitlement_issued_count == 0

    assert 1 == count_subscriptions_for_order_line(order.id)
    assert 1 == count_subscription_items_for_order(order.id)
    assert 1 == count_entitlements_for_order(order.id)
  end

  test "run_due_renewals_for_system creates a virtual renewal attempt and waits for paid reconciliation" do
    customer = SubscriptionsFixtures.create_customer!("phase26_sub_renew_success")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        entitlement_kind: :digital_library,
        entitlement_scope_key: "library:all"
      })

    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: "pm_phase26_success",
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    previous_period_end = subscription.current_period_end_at

    assert {:ok, result} = SubscriptionsFacade.run_due_renewals_for_system(now: now, limit: 20)
    assert result.due_count == 1
    assert result.success_count == 1
    assert result.failed_count == 0

    renewed = fetch_subscription!(subscription.id)
    assert renewed.current_period_end_at == previous_period_end
    assert renewed.status == :active

    attempt = fetch_latest_attempt!(renewed.id)
    assert attempt.status == :processing
    assert is_binary(attempt.order_id)
    assert is_binary(attempt.payment_intent_id)
  end

  test "run_due_renewals_for_system marks subscription past_due and attempt failed when chargeability is missing" do
    customer = SubscriptionsFixtures.create_customer!("phase26_sub_renew_fail")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    assert {:ok, result} = SubscriptionsFacade.run_due_renewals_for_system(now: now, limit: 20)
    assert result.due_count == 1
    assert result.success_count == 0
    assert result.failed_count == 1

    updated = fetch_subscription!(subscription.id)
    assert updated.status == :past_due
    assert updated.billing_status_reason == "PAYMENT_METHOD_REQUIRED"

    attempt = fetch_latest_attempt!(updated.id)
    assert attempt.status == :failed
    assert attempt.failure_code == "PAYMENT_METHOD_REQUIRED"
  end

  test "run_due_renewals_for_system requires stored payment method to be active" do
    customer = SubscriptionsFixtures.create_customer!("phase26_sub_inactive_method")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: "pm_phase26_inactive",
        stored_payment_method_status: :inactive,
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    assert {:ok, result} = SubscriptionsFacade.run_due_renewals_for_system(now: now, limit: 20)
    assert result.due_count == 1
    assert result.success_count == 0
    assert result.failed_count == 1

    updated = fetch_subscription!(subscription.id)
    assert updated.status == :past_due
    assert updated.billing_status_reason == "PAYMENT_METHOD_REQUIRED"

    attempt = fetch_latest_attempt!(updated.id)
    assert attempt.status == :failed
    assert attempt.failure_code == "PAYMENT_METHOD_REQUIRED"
  end

  test "run_due_renewals_for_system fails closed when provider is disabled" do
    Application.put_env(:store, :payments,
      enabled_providers: [],
      stripe: [webhook_secret: "whsec_test_only_change_me"]
    )

    customer = SubscriptionsFixtures.create_customer!("phase26_sub_provider_disabled")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider: :stripe,
        provider_billing_ref: "pm_phase26_provider_disabled",
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    assert {:ok, result} = SubscriptionsFacade.run_due_renewals_for_system(now: now, limit: 20)
    assert result.due_count == 1
    assert result.success_count == 0
    assert result.failed_count == 1

    updated = fetch_subscription!(subscription.id)
    assert updated.status == :past_due
    assert updated.billing_status_reason == "PAYMENT_PROVIDER_DISABLED"

    attempt = fetch_latest_attempt!(updated.id)
    assert attempt.status == :failed
    assert attempt.failure_code == "PAYMENT_PROVIDER_DISABLED"
  end

  test "physical renewal reserves inventory, writes live shipping, and leaves reservation active before payment success" do
    customer = SubscriptionsFixtures.create_customer!("phase27_physical_success")

    %{variant: base_variant} =
      SubscriptionsFixtures.create_subscription_sellable!(%{
        base_variant_price_minor: 2_500,
        base_variant_stock_on_hand: 10
      })

    variant = set_variant_weight!(base_variant, 750)

    plan = SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 2_100})
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription, order: source_order} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: "pm_phase27_physical_success",
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    _shipping =
      configure_shipping_profile!(source_order, variant, %{
        baseline_amount_minor: 400,
        live_amount_minor: 450
      })

    assert {:ok, :processed} =
             SubscriptionsFacade.process_due_subscription_renewal_for_system(subscription.id,
               now: now
             )

    attempt = fetch_latest_attempt!(subscription.id)
    renewal_order = fetch_order!(attempt.order_id)
    renewal_payment_intent = fetch_payment_intent!(attempt.payment_intent_id)

    assert renewal_order.shipping_method_code == "GROUND"
    assert renewal_order.shipping_quote_amount_minor == 450
    assert renewal_order.shipping_total_minor == 450
    assert renewal_order.grand_total_minor == 2_550
    assert renewal_payment_intent.amount_received_minor == 2_550

    reservation = fetch_reservation!(renewal_order.id, variant.id)
    assert reservation.state == :active

    inventory = Repo.get_by!(InventoryItem, variant_id: variant.id)
    assert inventory.reserved_count == 1
    assert inventory.stock_on_hand == 10
  end

  test "physical renewal hard blocker suppresses retries when shipping cost surges" do
    customer = SubscriptionsFixtures.create_customer!("phase27_physical_surge")

    %{variant: base_variant} =
      SubscriptionsFixtures.create_subscription_sellable!(%{
        base_variant_stock_on_hand: 10
      })

    variant = set_variant_weight!(base_variant, 500)

    plan = SubscriptionsFixtures.create_subscription_plan!()
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription, order: source_order} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: "pm_phase27_physical_surge",
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    _shipping =
      configure_shipping_profile!(source_order, variant, %{
        baseline_amount_minor: 400,
        live_amount_minor: 1_000
      })

    assert {:error, error} =
             SubscriptionsFacade.process_due_subscription_renewal_for_system(subscription.id,
               now: now
             )

    assert error.code == "SHIPPING_COST_SURGE"

    updated = fetch_subscription!(subscription.id)
    assert updated.status == :past_due
    assert updated.billing_status_reason == "SHIPPING_COST_SURGE"
    assert %DateTime{} = updated.retry_suppressed_at
    assert updated.next_retry_at == nil

    attempt = fetch_latest_attempt!(subscription.id)
    assert attempt.status == :failed
    assert attempt.failure_code == "SHIPPING_COST_SURGE"

    assert {:ok, []} = SubscriptionsFacade.list_due_renewal_jobs_for_system(now: now, limit: 10)
  end

  test "physical renewal out of stock stays retryable without suppression" do
    customer = SubscriptionsFixtures.create_customer!("phase27_physical_oos")

    %{variant: base_variant} =
      SubscriptionsFixtures.create_subscription_sellable!(%{
        base_variant_stock_on_hand: 0
      })

    variant = set_variant_weight!(base_variant, 300)

    plan = SubscriptionsFixtures.create_subscription_plan!()
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription, order: source_order} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: "pm_phase27_physical_oos",
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    _shipping =
      configure_shipping_profile!(source_order, variant, %{
        baseline_amount_minor: 400,
        live_amount_minor: 400
      })

    assert {:error, error} =
             SubscriptionsFacade.process_due_subscription_renewal_for_system(subscription.id,
               now: now
             )

    assert error.code in ["OUT_OF_STOCK", "RESERVATION_CONFLICT"]

    updated = fetch_subscription!(subscription.id)
    assert updated.status == :past_due
    assert updated.retry_suppressed_at == nil
    assert %DateTime{} = updated.next_retry_at
  end

  test "physical renewal releases inventory immediately when Stripe declines synchronously" do
    Application.put_env(:store, :payments,
      enabled_providers: [:stripe],
      stripe: [
        webhook_secret: "whsec_test_only_change_me",
        recurring_charge_status: :failed
      ]
    )

    customer = SubscriptionsFixtures.create_customer!("phase27_physical_release")

    %{variant: base_variant} =
      SubscriptionsFixtures.create_subscription_sellable!(%{
        base_variant_stock_on_hand: 1
      })

    variant = set_variant_weight!(base_variant, 250)

    plan = SubscriptionsFixtures.create_subscription_plan!()
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription, order: source_order} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider: :stripe,
        provider_billing_ref: "pm_phase27_physical_release",
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    _shipping =
      configure_shipping_profile!(source_order, variant, %{
        baseline_amount_minor: 400,
        live_amount_minor: 400
      })

    assert {:error, error} =
             SubscriptionsFacade.process_due_subscription_renewal_for_system(subscription.id,
               now: now
             )

    assert error.code == "PAYMENT_FAILED"

    attempt = fetch_latest_attempt!(subscription.id)
    reservation = fetch_reservation!(attempt.order_id, variant.id)
    assert reservation.state == :cancelled

    inventory = Repo.get_by!(InventoryItem, variant_id: variant.id)
    assert inventory.reserved_count == 0
    assert inventory.stock_on_hand == 1
  end

  test "reconcile_paid_subscription_renewal_for_system promotes pending locked pricing once" do
    customer = SubscriptionsFixtures.create_customer!("phase27_sub_reconcile")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    %{variant: upgraded_variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 1_999})
    upgraded_plan = SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 2_999})
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    _upgrade_attachment =
      SubscriptionsFixtures.attach_variant_plan!(upgraded_variant.id, upgraded_plan.id)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: "pm_phase27_reconcile",
        next_renewal_at: DateTime.add(now, -10, :second),
        pending_variant_id: upgraded_variant.id,
        pending_subscription_plan_id: upgraded_plan.id,
        pending_renewal_amount_minor: upgraded_plan.amount_minor,
        pending_renewal_currency: upgraded_plan.currency,
        change_effective_at: now
      })

    assert {:ok, :processed} =
             SubscriptionsFacade.process_due_subscription_renewal_for_system(subscription.id,
               now: now
             )

    attempt = fetch_latest_attempt!(subscription.id)

    renewal_order =
      Store.Orders.Order
      |> Ash.Query.filter(expr(id == ^attempt.order_id))
      |> Ash.read!(domain: Store.Orders, authorize?: false, context: %{system?: true})
      |> List.first()

    payment_intent =
      Store.Payments.PaymentIntent
      |> Ash.Query.filter(expr(id == ^attempt.payment_intent_id))
      |> Ash.read!(domain: Store.Payments, authorize?: false, context: %{system?: true})
      |> List.first()

    payment_intent
    |> Ash.Changeset.for_update(:mark_succeeded, %{}, context: %{system?: true})
    |> Ash.update!(domain: Store.Payments, authorize?: false, context: %{system?: true})

    renewal_order
    |> Ash.Changeset.for_update(:mark_paid, %{}, context: %{system?: true})
    |> Ash.update!(domain: Store.Orders, authorize?: false, context: %{system?: true})

    assert {:ok, :reconciled} =
             SubscriptionsFacade.reconcile_paid_subscription_renewal_for_system(renewal_order.id,
               renewal_attempt_id: attempt.id
             )

    renewed = fetch_subscription!(subscription.id)
    assert renewed.subscription_plan_id == upgraded_plan.id
    assert renewed.variant_id == upgraded_variant.id
    assert renewed.renewal_amount_minor == upgraded_plan.amount_minor
    assert renewed.renewal_currency == upgraded_plan.currency
    assert renewed.pending_subscription_plan_id == nil
    assert renewed.pending_variant_id == nil
    assert renewed.pending_renewal_amount_minor == nil
    assert renewed.pending_renewal_currency == nil
  end

  test "run_due_renewals_for_system expires subscriptions past grace and revokes entitlements" do
    customer = SubscriptionsFixtures.create_customer!("phase26_sub_grace")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        grace_period_days: 1,
        entitlement_kind: :membership_access,
        entitlement_scope_key: "membership:silver"
      })

    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    old_past_due = DateTime.add(now, -172_800, :second)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: nil,
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    assert {:ok, past_due_subscription} =
             subscription
             |> Ash.Changeset.for_update(
               :mark_past_due_transition,
               %{past_due_since_at: old_past_due, billing_status_reason: "test"},
               context: %{system?: true}
             )
             |> Ash.update(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert {:ok, _grant} =
             EntitlementsFacade.issue_subscription_entitlement_for_system(
               past_due_subscription,
               plan
             )

    assert {:ok, result} = SubscriptionsFacade.run_due_renewals_for_system(now: now, limit: 20)
    assert result.due_count == 1
    assert result.success_count == 1
    assert result.failed_count == 0

    expired = fetch_subscription!(subscription.id)
    assert expired.status == :expired

    entitlement = fetch_entitlement!(subscription.id)
    assert entitlement.status == :revoked
    assert entitlement.revoked_reason == "grace_expired"

    assert 1 ==
             EmailOutbox
             |> Ash.Query.filter(
               expr(subscription_id == ^subscription.id and template_kind == :access_ended)
             )
             |> Ash.count!(domain: Store.Comms, authorize?: false, context: %{system?: true})
  end

  test "create_subscriptions_from_paid_order_for_system fails closed when provider selection is missing" do
    customer = SubscriptionsFixtures.create_customer!("phase26_sub_missing_provider")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{order: order} =
      SubscriptionsFixtures.create_paid_order_with_subscription_line!(
        customer.id,
        variant,
        plan,
        %{
          create_payment_intent?: false
        }
      )

    assert {:error, error} =
             SubscriptionsFacade.create_subscriptions_from_paid_order_for_system(order.id)

    assert error.code == "SUBSCRIPTION_PROVIDER_SELECTION_REQUIRED"
    assert 0 == count_subscriptions_for_order_line(order.id)
  end

  test "create_subscriptions_from_paid_order_for_system fails closed when provider is disabled" do
    Application.put_env(:store, :payments,
      enabled_providers: [],
      stripe: [webhook_secret: "whsec_test_only_change_me"]
    )

    customer = SubscriptionsFixtures.create_customer!("phase26_sub_disabled_provider")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{order: order} =
      SubscriptionsFixtures.create_paid_order_with_subscription_line!(customer.id, variant, plan)

    assert {:error, error} =
             SubscriptionsFacade.create_subscriptions_from_paid_order_for_system(order.id)

    assert error.code == "PAYMENT_PROVIDER_DISABLED"
    assert 0 == count_subscriptions_for_order_line(order.id)
  end

  test "queue plan and variant changes recompute pending snapshots against the effective pair" do
    customer = SubscriptionsFixtures.create_customer!("phase27_boundary_queue")

    %{product: product, variant: variant} =
      SubscriptionsFixtures.create_subscription_sellable!(%{base_variant_price_minor: 1_000})

    current_plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        key: "current-plan",
        amount_minor: 1_000
      })

    target_plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        key: "target-plan",
        amount_minor: 2_500
      })

    invalid_plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        key: "invalid-plan",
        amount_minor: 4_000
      })

    _current_attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, current_plan.id)
    _target_attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, target_plan.id)

    target_variant =
      create_variant_target!(product.id, %{
        price_minor: 4_500,
        title: "Boundary Variant"
      })

    _target_variant_attachment =
      SubscriptionsFixtures.attach_variant_plan!(target_variant.id, target_plan.id)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, current_plan, %{
        provider_customer_ref: "cus_boundary_001",
        provider_billing_ref: "pm_boundary_001"
      })

    {:ok, plan_input} =
      QueueSubscriptionPlanChangeInput.new(%{
        "subscription_id" => subscription.id,
        "subscription_plan_id" => target_plan.id
      })

    assert {:ok, queued_plan} =
             SubscriptionsFacade.queue_subscription_plan_change_for_user(
               customer,
               subscription.id,
               plan_input
             )

    assert queued_plan.pending_subscription_plan_id == target_plan.id
    assert queued_plan.pending_variant_id == nil
    assert queued_plan.pending_renewal_amount_minor == target_plan.amount_minor
    assert queued_plan.pending_renewal_currency == target_plan.currency

    {:ok, variant_input} =
      QueueSubscriptionVariantChangeInput.new(%{
        "subscription_id" => subscription.id,
        "variant_id" => target_variant.id
      })

    assert {:ok, queued_variant} =
             SubscriptionsFacade.queue_subscription_variant_change_for_user(
               customer,
               subscription.id,
               variant_input
             )

    assert queued_variant.pending_variant_id == target_variant.id
    assert queued_variant.pending_subscription_plan_id == target_plan.id
    assert queued_variant.pending_renewal_amount_minor == target_plan.amount_minor
    assert queued_variant.pending_renewal_currency == target_plan.currency

    {:ok, invalid_plan_input} =
      QueueSubscriptionPlanChangeInput.new(%{
        "subscription_id" => subscription.id,
        "subscription_plan_id" => invalid_plan.id
      })

    assert {:error, error} =
             SubscriptionsFacade.queue_subscription_plan_change_for_user(
               customer,
               subscription.id,
               invalid_plan_input
             )

    assert error.code == "VARIANT_PLAN_UNAVAILABLE"
  end

  test "start_subscription_payment_method_update_for_user creates a setup-purpose intent" do
    Application.put_env(:store, :payments,
      enabled_providers: [:stripe],
      stripe: [
        webhook_secret: "whsec_test_only_change_me",
        publishable_key: "pk_test_boundary_123"
      ]
    )

    customer = SubscriptionsFixtures.create_customer!("phase27_payment_method_update")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider: :stripe,
        provider_customer_ref: "cus_setup_001",
        provider_billing_ref: "pm_setup_existing"
      })

    {:ok, input} =
      StartSubscriptionPaymentMethodUpdateInput.new(%{"subscription_id" => subscription.id})

    assert {:ok, result} =
             SubscriptionsFacade.start_subscription_payment_method_update_for_user(
               customer,
               subscription.id,
               input
             )

    assert result.provider == :stripe
    assert result.publishable_key == "pk_test_boundary_123"
    assert result.client_secret =~ "seti_secret_"

    payment_intent = fetch_payment_intent!(result.payment_intent_id)
    assert payment_intent.purpose == :subscription_payment_method_update
    assert payment_intent.subscription_id == subscription.id
    assert payment_intent.provider_customer_ref == "cus_setup_001"
    assert payment_intent.provider_payment_id =~ "seti_store_"
    assert payment_intent.state == :submitted
  end

  defp count_subscriptions_for_order_line(order_id) do
    Subscription
    |> Ash.Query.filter(expr(source_order_id == ^order_id))
    |> Ash.count!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp count_subscription_items_for_order(order_id) do
    subscription_ids =
      Subscription
      |> Ash.Query.filter(expr(source_order_id == ^order_id))
      |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
      |> Enum.map(& &1.id)

    SubscriptionItem
    |> Ash.Query.filter(expr(subscription_id in ^subscription_ids))
    |> Ash.count!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp count_entitlements_for_order(order_id) do
    subscription_ids =
      Subscription
      |> Ash.Query.filter(expr(source_order_id == ^order_id))
      |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
      |> Enum.map(& &1.id)

    EntitlementGrant
    |> Ash.Query.filter(expr(source_kind == :subscription and source_id in ^subscription_ids))
    |> Ash.count!(domain: Store.Entitlements, authorize?: false, context: %{system?: true})
  end

  defp fetch_subscription!(subscription_id) do
    Subscription
    |> Ash.Query.filter(expr(id == ^subscription_id))
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

  defp fetch_entitlement!(subscription_id) do
    EntitlementGrant
    |> Ash.Query.filter(expr(source_kind == :subscription and source_id == ^subscription_id))
    |> Ash.read!(domain: Store.Entitlements, authorize?: false, context: %{system?: true})
    |> List.first()
  end

  defp fetch_payment_intent!(payment_intent_id) do
    PaymentIntent
    |> Ash.Query.filter(expr(id == ^payment_intent_id))
    |> Ash.read!(domain: Store.Payments, authorize?: false, context: %{system?: true})
    |> List.first()
  end

  defp fetch_order!(order_id) do
    Order
    |> Ash.Query.filter(expr(id == ^order_id))
    |> Ash.read!(domain: Store.Orders, authorize?: false, context: %{system?: true})
    |> List.first()
  end

  defp fetch_reservation!(order_id, variant_id) do
    InventoryReservation
    |> Ash.Query.filter(expr(order_id == ^order_id and variant_id == ^variant_id))
    |> Ash.read!(domain: Store.Orders, authorize?: false, context: %{system?: true})
    |> List.first()
  end

  defp configure_shipping_profile!(%Order{} = order, %Variant{} = variant, overrides) do
    zone = create_shipping_zone!("US", "CA")
    method = create_shipping_method!("GROUND")
    _tax_rate = create_tax_rate!("US", "CA")

    _rule =
      create_shipping_rule!(
        zone.id,
        method.id,
        Map.get(overrides, :live_amount_minor, Map.get(overrides, :baseline_amount_minor, 400))
      )

    {:ok, request} =
      QuoteRequest.new(%{
        destination_country_code: "US",
        destination_region_code: "CA",
        destination_postal_code: "94105",
        currency_code: "USD",
        shipping_weight_grams: max(variant.weight_grams || 0, 0)
      })

    {:ok, options} = ShippingFacade.quote_options_for_system(request)
    option = Enum.find(options, &(&1.shipping_method_code == method.code))
    assert option

    addressed_order =
      order
      |> Ash.Changeset.for_update(
        :set_shipping_address,
        %{
          shipping_country_code: "US",
          shipping_region_code: "CA",
          shipping_postal_code: "94105",
          shipping_address_line1: "1 Market St",
          shipping_address_line2: "Suite 100"
        },
        context: %{system?: true}
      )
      |> Ash.update!(domain: Store.Orders, authorize?: false, context: %{system?: true})

    method_order =
      addressed_order
      |> Ash.Changeset.for_update(
        :set_shipping_method,
        %{shipping_rate_code: method.code},
        context: %{system?: true}
      )
      |> Ash.update!(domain: Store.Orders, authorize?: false, context: %{system?: true})

    baseline_amount = Map.get(overrides, :baseline_amount_minor, option.amount_minor)

    method_order
    |> Ash.Changeset.for_update(
      :set_shipping_quote_evidence,
      %{
        shipping_quote_hash: "baseline-#{System.unique_integer([:positive])}",
        shipping_quote_currency_code: option.currency_code,
        shipping_quote_amount_minor: baseline_amount,
        shipping_weight_grams: option.shipping_weight_grams,
        shipping_method_code: method.code,
        shipping_zone_id: option.zone_id
      },
      context: %{system?: true}
    )
    |> Ash.update!(domain: Store.Orders, authorize?: false, context: %{system?: true})
  end

  defp create_shipping_zone!(country_code, region_code) do
    ShippingZone
    |> Ash.Changeset.for_create(
      :create,
      %{
        code: "SUB-ZONE-#{System.unique_integer([:positive])}",
        country_code: country_code,
        region_code: region_code,
        active: true
      },
      context: %{system?: true}
    )
    |> Ash.create!(domain: Store.Shipping, authorize?: false, context: %{system?: true})
  end

  defp create_shipping_method!(code) do
    ShippingMethod
    |> Ash.Changeset.for_create(
      :create,
      %{code: code, name: code, active: true, sort_order: 100},
      context: %{system?: true}
    )
    |> Ash.create!(domain: Store.Shipping, authorize?: false, context: %{system?: true})
  end

  defp create_shipping_rule!(zone_id, method_id, shipping_cost_minor) do
    ShippingRateRule
    |> Ash.Changeset.for_create(
      :create,
      %{
        code: "SUB-RULE-#{System.unique_integer([:positive])}",
        shipping_zone_id: zone_id,
        shipping_method_id: method_id,
        currency: "USD",
        shipping_cost_minor: shipping_cost_minor,
        active: true,
        precedence_rank: 10
      },
      context: %{system?: true}
    )
    |> Ash.create!(domain: Store.Shipping, authorize?: false, context: %{system?: true})
  end

  defp create_tax_rate!(country_code, region_code) do
    TaxRate
    |> Ash.Changeset.for_create(
      :create,
      %{
        code: "SUB-TAX-#{System.unique_integer([:positive])}",
        country_code: country_code,
        region_code: region_code,
        product_tax_category: "STANDARD",
        rate_basis_points: 0,
        shipping_taxable: true,
        active: true,
        precedence_rank: 10
      },
      context: %{system?: true}
    )
    |> Ash.create!(domain: Store.Pricing, authorize?: false, context: %{system?: true})
  end

  defp set_variant_weight!(%Variant{} = variant, weight_grams) do
    variant
    |> Ash.Changeset.for_update(
      :update,
      %{weight_grams: weight_grams},
      context: %{system?: true}
    )
    |> Ash.update!(domain: Store.Catalog, authorize?: false, context: %{system?: true})
  end

  defp create_variant_target!(product_id, overrides) do
    option =
      ProductOption
      |> Ash.Changeset.for_create(
        :create,
        %{
          product_id: product_id,
          name: "Edition #{System.unique_integer([:positive])}",
          slug: "edition-#{System.unique_integer([:positive])}",
          position: 1,
          selection_required: false
        },
        context: %{system?: true}
      )
      |> Ash.create!(domain: Store.Catalog, authorize?: false, context: %{system?: true})

    value =
      ProductOptionValue
      |> Ash.Changeset.for_create(
        :create,
        %{
          product_option_id: option.id,
          name: "Collector #{System.unique_integer([:positive])}",
          slug: "collector-#{System.unique_integer([:positive])}",
          position: 1
        },
        context: %{system?: true}
      )
      |> Ash.create!(domain: Store.Catalog, authorize?: false, context: %{system?: true})

    archived_variant =
      Variant
      |> Ash.Changeset.for_create(
        :create,
        %{
          product_id: product_id,
          sku: "BOUNDARY-#{System.unique_integer([:positive])}",
          title: Map.get(overrides, :title, "Boundary Variant"),
          currency_code: Map.get(overrides, :currency_code, "USD"),
          price_minor: Map.get(overrides, :price_minor, 3_500),
          status: :archived
        },
        context: %{system?: true}
      )
      |> Ash.create!(domain: Store.Catalog, authorize?: false, context: %{system?: true})

    _inventory =
      InventoryItem
      |> Ash.Changeset.for_create(
        :create,
        %{
          variant_id: archived_variant.id,
          stock_on_hand: 20,
          reserved_count: 0,
          allow_oversell: false
        },
        context: %{system?: true}
      )
      |> Ash.create!(domain: Store.Catalog, authorize?: false, context: %{system?: true})

    _selection =
      VariantOptionSelection
      |> Ash.Changeset.for_create(
        :create,
        %{
          variant_id: archived_variant.id,
          product_option_id: option.id,
          product_option_value_id: value.id
        },
        context: %{system?: true}
      )
      |> Ash.create!(domain: Store.Catalog, authorize?: false, context: %{system?: true})

    archived_variant
    |> Ash.Changeset.for_update(
      :update,
      %{status: :active},
      context: %{system?: true}
    )
    |> Ash.update!(domain: Store.Catalog, authorize?: false, context: %{system?: true})
  end
end
