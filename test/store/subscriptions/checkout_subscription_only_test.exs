defmodule Store.Subscriptions.CheckoutSubscriptionOnlyTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Store.Carts.Facade, as: CartsFacade
  alias Store.Carts.Inputs.CartItemInput
  alias Store.Checkout
  alias Store.Checkout.Inputs.{CheckoutFinalizeInput, CheckoutStartInput}
  alias Store.Orders.OrderLineItem
  alias Store.Subscriptions.PlanRevision
  alias Store.SubscriptionsFixtures

  @plan_revision_fields [
    :interval_unit,
    :interval_count,
    :currency,
    :amount_minor,
    :trial_days,
    :anchor_mode,
    :anchor_day_of_month,
    :billing_timezone,
    :term_mode,
    :term_cycles,
    :term_end_at,
    :access_on_past_due,
    :access_on_cancel,
    :grace_period_days,
    :max_retry_attempts,
    :retry_schedule_hours,
    :entitlement_kind,
    :entitlement_scope_key
  ]

  setup do
    previous_flags = Application.get_env(:store, :subscription_features, [])

    on_exit(fn ->
      Application.put_env(:store, :subscription_features, previous_flags)
    end)

    :ok
  end

  test "subscription-only checkout finalizes totals without shipping selection" do
    enable_subscription_purchase!()

    token = Ash.UUIDv7.generate()
    customer = SubscriptionsFixtures.create_customer!("phase26_checkout_sub_only")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    revision = publish_revision!(plan)
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    assert {:ok, add_input} =
             CartItemInput.new(%{
               "variant_id" => variant.id,
               "subscription_plan_id" => plan.id,
               "qty" => 1
             })

    assert {:ok, _cart} = CartsFacade.add_item_for_user(customer, token, add_input)

    assert {:ok, start_input} = CheckoutStartInput.new(%{})
    assert {:ok, started} = Checkout.start_from_cart(customer, token, start_input)
    assert {:ok, finalize_input} = CheckoutFinalizeInput.new(%{})

    assert {:ok, finalized} =
             Checkout.finalize_totals(customer, started.checkout_key, finalize_input)

    assert finalized.totals_finalized?
    assert finalized.shipping_total_minor == 0

    line_item =
      OrderLineItem
      |> Ash.Query.filter(expr(order_id == ^finalized.order_id))
      |> Ash.read!(domain: Store.Orders, authorize?: false)
      |> List.first()

    assert line_item.subscription_plan_id_snapshot == plan.id
    assert line_item.subscription_plan_key_snapshot == plan.key
    assert Map.get(line_item, :subscription_plan_revision_id_snapshot) == revision.id
  end

  test "subscription-only checkout fails closed when no plan revision is effective" do
    enable_subscription_purchase!()

    token = Ash.UUIDv7.generate()
    customer = SubscriptionsFixtures.create_customer!("sbh_10_02_checkout_no_effective")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    assert {:ok, add_input} =
             CartItemInput.new(%{
               "variant_id" => variant.id,
               "subscription_plan_id" => plan.id,
               "qty" => 1
             })

    assert {:ok, _cart} = CartsFacade.add_item_for_user(customer, token, add_input)
    assert {:ok, start_input} = CheckoutStartInput.new(%{})
    assert {:ok, started} = Checkout.start_from_cart(customer, token, start_input)
    assert {:ok, finalize_input} = CheckoutFinalizeInput.new(%{})

    assert {:error, _error} =
             Checkout.finalize_totals(customer, started.checkout_key, finalize_input)

    assert {:ok, []} =
             OrderLineItem
             |> Ash.Query.filter(expr(order_id == ^started.order_id))
             |> Ash.read(domain: Store.Orders, authorize?: false)
  end

  test "subscription add-to-cart is denied when subscription purchase feature flag is off" do
    disable_subscription_purchase!()

    token = Ash.UUIDv7.generate()
    customer = SubscriptionsFixtures.create_customer!("phase26_checkout_sub_flag_off")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    assert {:ok, add_input} =
             CartItemInput.new(%{
               "variant_id" => variant.id,
               "subscription_plan_id" => plan.id,
               "qty" => 1
             })

    assert {:error, error} = CartsFacade.add_item_for_user(customer, token, add_input)
    assert error.code == "SUBSCRIPTION_PURCHASE_DISABLED"
  end

  defp enable_subscription_purchase! do
    update_subscription_feature_flags(expose_purchase?: true)
  end

  defp disable_subscription_purchase! do
    update_subscription_feature_flags(expose_purchase?: false)
  end

  defp update_subscription_feature_flags(overrides) when is_list(overrides) do
    current_flags = Application.get_env(:store, :subscription_features, [])
    Application.put_env(:store, :subscription_features, Keyword.merge(current_flags, overrides))
  end

  defp publish_revision!(plan, overrides \\ %{}) do
    attrs =
      plan
      |> Map.take(@plan_revision_fields)
      |> Map.put(:subscription_plan_id, plan.id)
      |> Map.merge(overrides)

    revision =
      PlanRevision
      |> Ash.Changeset.for_create(:create_draft, attrs, context: %{system?: true})
      |> Ash.create!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    revision
    |> Ash.Changeset.for_update(:publish, %{}, context: %{system?: true})
    |> Ash.update!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end
end
