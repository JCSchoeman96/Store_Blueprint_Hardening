defmodule Store.Subscriptions.FacadeTest do
  use Store.DataCase, async: false
  use Oban.Testing, repo: Store.DirectRepo

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
  alias Store.Orders.{InventoryReservation, Order, PaymentApplication}
  alias Store.Payments.{PaymentAttempt, PaymentIntent}
  alias Store.Pricing.TaxRate
  alias Store.Shipping.Facade, as: ShippingFacade
  alias Store.Shipping.Inputs.QuoteRequest
  alias Store.Shipping.{ShippingMethod, ShippingRateRule, ShippingZone}
  alias Store.Subscriptions.ContractChange
  alias Store.Subscriptions.Facade, as: SubscriptionsFacade

  alias Store.Subscriptions.{
    RenewalAttempt,
    RenewalCollectionAttempt,
    RenewalCollectionAttempts,
    Subscription,
    SubscriptionItem
  }

  alias Store.Subscriptions.Inputs.{
    QueueSubscriptionPlanChangeInput,
    QueueSubscriptionVariantChangeInput,
    StartSubscriptionPaymentMethodUpdateInput
  }

  alias Store.SubscriptionsFixtures
  alias Store.TestSupport.StripeAPIStub

  setup context do
    previous = Application.get_env(:store, :payments, [])
    StripeAPIStub.setup_default(context)

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

  test "zero retry allowance suspends an exhausted renewal without ending the contract" do
    customer = SubscriptionsFixtures.create_customer!("jc265_zero_retry")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        max_retry_attempts: 0,
        entitlement_kind: :membership_access,
        entitlement_scope_key: "membership:jc265-zero-retry"
      })

    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    assert {:ok, _grant} =
             EntitlementsFacade.issue_subscription_entitlement_for_system(subscription, plan)

    parent = self()
    handler_id = {__MODULE__, :jc265_dunning_exhaustion, System.unique_integer([:positive])}

    :ok =
      :telemetry.attach(
        handler_id,
        [:store, :subscriptions, :dunning],
        fn event, measurements, metadata, pid ->
          send(pid, {List.to_tuple(event), measurements, metadata})
        end,
        parent
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, %{due_count: 1, failed_count: 1}} =
             SubscriptionsFacade.run_due_renewals_for_system(now: now, limit: 20)

    assert_receive {{:store, :subscriptions, :dunning}, %{count: 1}, dunning_metadata}
    assert dunning_metadata.subscription_id == subscription.id
    assert dunning_metadata.status == :suspended

    suspended = fetch_subscription!(subscription.id)
    assert suspended.status == :suspended
    assert is_nil(suspended.ended_at)
    assert is_nil(suspended.canceled_at)
    assert is_nil(suspended.canceled_reason)
    assert is_nil(suspended.next_retry_at)

    assert {:ok, detail} =
             SubscriptionsFacade.get_subscription_detail_for_user(customer, subscription.id)

    assert detail.action_capabilities.can_cancel_now?
    assert detail.action_capabilities.can_cancel_at_period_end?
    refute detail.action_capabilities.can_queue_plan_change?
    refute detail.action_capabilities.can_queue_variant_change?

    entitlement = fetch_entitlement!(subscription.id)
    assert entitlement.status == :revoked

    assert {:ok, %{due_count: 0, success_count: 0, failed_count: 0}} =
             SubscriptionsFacade.run_due_renewals_for_system(now: now, limit: 20)
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

  test "run_due_renewals_for_system emits tick, renewal attempt, and dunning telemetry" do
    customer = SubscriptionsFixtures.create_customer!("phase29_subs_telemetry")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    parent = self()
    handler_id = {__MODULE__, :phase29_subscriptions, System.unique_integer([:positive])}

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    :telemetry.attach_many(
      handler_id,
      [
        [:store, :subscriptions, :tick],
        [:store, :subscriptions, :renewal_attempt],
        [:store, :subscriptions, :dunning]
      ],
      fn event, measurements, metadata, pid ->
        send(pid, {List.to_tuple(event), measurements, metadata})
      end,
      parent
    )

    try do
      assert {:ok, %{due_count: 1, failed_count: 1}} =
               SubscriptionsFacade.run_due_renewals_for_system(now: now, limit: 20)

      assert_receive {{:store, :subscriptions, :dunning}, %{count: 1}, dunning_metadata}
      assert dunning_metadata.subscription_id == subscription.id
      assert dunning_metadata.status == :past_due

      assert_receive {{:store, :subscriptions, :renewal_attempt}, renewal_measurements,
                      renewal_metadata}

      assert renewal_metadata.subscription_id == subscription.id
      assert renewal_metadata.outcome == :error
      assert renewal_measurements.duration > 0

      assert_receive {{:store, :subscriptions, :tick}, tick_measurements, tick_metadata}
      assert tick_measurements.due_count == 1
      assert tick_measurements.failed_count == 1
      assert tick_measurements.success_count == 0
      assert tick_metadata.due_count == 1
    after
      :telemetry.detach(handler_id)
    end
  end

  test "physical renewal applies certified direct success after reserving inventory and live shipping" do
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
    assert renewal_order.state == :paid
    assert renewal_payment_intent.amount_received_minor == 2_550
    assert renewal_payment_intent.state == :succeeded

    reservation = fetch_reservation!(renewal_order.id, variant.id)
    assert reservation.state == :consumed

    inventory = Repo.get_by!(InventoryItem, variant_id: variant.id)
    assert inventory.reserved_count == 0
    assert inventory.stock_on_hand == 9
  end

  test "renewal provider call sees the committed exact collection claim and key" do
    customer = SubscriptionsFixtures.create_customer!("jc229_dispatch_claim_before_provider")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 2_600})
    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: "pm_jc229_dispatch_claim_before_provider",
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    StripeAPIStub.stub_payment_intent(fn conn, params ->
      collection_id = Map.fetch!(params, "metadata[collection_attempt_id]")
      local_payment_intent_id = Map.fetch!(params, "metadata[local_intent_id]")
      occurrence_key = Map.fetch!(params, "metadata[renewal_key]")
      [provider_idempotency_key] = Plug.Conn.get_req_header(conn, "idempotency-key")

      assert provider_idempotency_key == "renewal-collection:" <> collection_id

      assert {:ok, %{rows: [["may_have_been_reached", ^local_payment_intent_id]]}} =
               Store.Repo.query(
                 "SELECT dispatch_state::text, payment_intent_id::text FROM renewal_collection_attempts WHERE id = $1::uuid",
                 [Ecto.UUID.dump!(collection_id)]
               )

      assert occurrence_key =~ "sub:#{subscription.id}:end:"

      StripeAPIStub.json_response(conn, StripeAPIStub.payment_intent_response(params))
    end)

    assert {:ok, :processed} =
             SubscriptionsFacade.process_due_subscription_renewal_for_system(subscription.id,
               now: now
             )

    attempt = fetch_latest_attempt!(subscription.id)

    collection =
      RenewalCollectionAttempt
      |> Ash.Query.filter(expr(renewal_attempt_id == ^attempt.id))
      |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    payment_intent = fetch_payment_intent!(collection.payment_intent_id)

    assert collection.collection_ordinal == 1
    assert collection.dispatch_state == :may_have_been_reached
    assert collection.financial_outcome == :verified_success
    assert payment_intent.payment_intent_key == "renewal-collection:" <> collection.id
    assert payment_intent.id == attempt.payment_intent_id
  end

  test "unknown provider response replays the same collection PaymentIntent and key" do
    customer = SubscriptionsFixtures.create_customer!("jc229_unknown_provider_replay")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        amount_minor: 2_600,
        max_retry_attempts: 2,
        retry_schedule_hours: [0, 24]
      })

    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: "pm_jc229_unknown_provider_replay",
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    parent = self()
    request_count = :atomics.new(1, [])

    StripeAPIStub.stub_payment_intent(fn conn, params ->
      request_no = :atomics.add_get(request_count, 1, 1)
      [idempotency_key] = Plug.Conn.get_req_header(conn, "idempotency-key")

      send(parent, {
        :renewal_provider_request,
        idempotency_key,
        Map.fetch!(params, "metadata[collection_attempt_id]"),
        Map.fetch!(params, "metadata[local_intent_id]")
      })

      if request_no == 1 do
        conn
        |> Plug.Conn.put_status(500)
        |> StripeAPIStub.json_response(%{"error" => %{"message" => "provider unavailable"}})
      else
        StripeAPIStub.json_response(conn, StripeAPIStub.payment_intent_response(params))
      end
    end)

    assert {:error, %{code: "PAYMENT_PROVIDER_DOWN"}} =
             SubscriptionsFacade.process_due_subscription_renewal_for_system(subscription.id,
               now: now
             )

    assert_receive {:renewal_provider_request, first_key, first_collection_id,
                    first_payment_intent_id},
                   5_000

    assert {:ok, :processed} =
             SubscriptionsFacade.process_due_subscription_renewal_for_system(subscription.id,
               now: now
             )

    assert_receive {:renewal_provider_request, ^first_key, ^first_collection_id,
                    ^first_payment_intent_id},
                   5_000

    refute_receive {:renewal_provider_request, _key, _collection_id, _payment_intent_id}

    attempt = fetch_latest_attempt!(subscription.id)

    collection =
      RenewalCollectionAttempt
      |> Ash.Query.filter(expr(renewal_attempt_id == ^attempt.id))
      |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    assert collection.collection_ordinal == 1
    assert collection.dispatch_state == :may_have_been_reached
    assert collection.financial_outcome == :verified_success
    assert collection.payment_intent_id == first_payment_intent_id
    assert collection.id == first_collection_id
  end

  test "unresolved reached collection with local requires action is not charged again" do
    customer = SubscriptionsFixtures.create_customer!("jc229_requires_action_split_state")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 2_600})
    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: "pm_jc229_requires_action_split_state",
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    StripeAPIStub.stub_payment_intent(fn conn, _params ->
      conn
      |> Plug.Conn.put_status(500)
      |> StripeAPIStub.json_response(%{"error" => %{"message" => "provider unavailable"}})
    end)

    assert {:error, %{code: "PAYMENT_PROVIDER_DOWN"}} =
             SubscriptionsFacade.process_due_subscription_renewal_for_system(subscription.id,
               now: now
             )

    attempt = fetch_latest_attempt!(subscription.id)
    payment_intent = fetch_payment_intent!(attempt.payment_intent_id)
    collection = fetch_collection_for_attempt!(attempt.id)

    assert payment_intent.state == :submitted
    assert payment_intent.provider_payment_id == nil
    assert collection.financial_outcome == :unresolved
    assert collection.dispatch_state == :may_have_been_reached

    assert {:ok, %PaymentIntent{state: :requires_action}} =
             payment_intent
             |> Ash.Changeset.for_update(:mark_requires_action, %{}, context: %{system?: true})
             |> Ash.update(domain: Store.Payments, authorize?: false, context: %{system?: true})

    payment_intent_count = Store.Repo.aggregate(PaymentIntent, :count, :id)
    StripeAPIStub.stub_unexpected!("requires-action PaymentIntent must not be charged again")

    assert {:ok, :processed} =
             SubscriptionsFacade.process_due_subscription_renewal_for_system(subscription.id,
               now: now
             )

    assert fetch_collection_for_attempt!(attempt.id) == collection
    assert fetch_payment_intent!(payment_intent.id).state == :requires_action
    assert Store.Repo.aggregate(PaymentIntent, :count, :id) == payment_intent_count
  end

  test "canceled reached collection with local requires action is not charged again" do
    customer = SubscriptionsFixtures.create_customer!("jc229_canceled_requires_action")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 2_600})
    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: "pm_jc229_canceled_requires_action",
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    StripeAPIStub.stub_payment_intent(fn conn, _params ->
      conn
      |> Plug.Conn.put_status(500)
      |> StripeAPIStub.json_response(%{"error" => %{"message" => "provider unavailable"}})
    end)

    assert {:error, %{code: "PAYMENT_PROVIDER_DOWN"}} =
             SubscriptionsFacade.process_due_subscription_renewal_for_system(subscription.id,
               now: now
             )

    attempt = fetch_latest_attempt!(subscription.id)
    payment_intent = fetch_payment_intent!(attempt.payment_intent_id)
    collection = fetch_collection_for_attempt!(attempt.id)

    assert {:ok, %{status: :canceled}} =
             SubscriptionsFacade.cancel_subscription_for_user(customer, subscription.id, :now)

    assert {:ok, %PaymentIntent{state: :requires_action}} =
             payment_intent
             |> Ash.Changeset.for_update(:mark_requires_action, %{}, context: %{system?: true})
             |> Ash.update(domain: Store.Payments, authorize?: false, context: %{system?: true})

    payment_intent_count = Store.Repo.aggregate(PaymentIntent, :count, :id)

    StripeAPIStub.stub_unexpected!(
      "canceled requires-action collection must not be charged again"
    )

    assert {:ok, :processed} =
             SubscriptionsFacade.process_due_subscription_renewal_for_system(subscription.id,
               now: now
             )

    assert fetch_subscription!(subscription.id).status == :canceled
    assert fetch_collection_for_attempt!(attempt.id) == collection
    assert fetch_payment_intent!(payment_intent.id).state == :requires_action
    assert Store.Repo.aggregate(PaymentIntent, :count, :id) == payment_intent_count
  end

  test "reached collection recovery after cancellation does not submit another charge" do
    customer = SubscriptionsFixtures.create_customer!("jc229_canceled_reached_replay")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 2_600})
    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: "pm_jc229_canceled_reached_replay",
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    parent = self()
    request_count = :atomics.new(1, [])

    StripeAPIStub.stub_payment_intent(fn conn, params ->
      :atomics.add(request_count, 1, 1)
      [idempotency_key] = Plug.Conn.get_req_header(conn, "idempotency-key")

      send(parent, {
        :renewal_provider_request,
        idempotency_key,
        Map.fetch!(params, "metadata[collection_attempt_id]"),
        Map.fetch!(params, "metadata[local_intent_id]")
      })

      conn
      |> Plug.Conn.put_status(500)
      |> StripeAPIStub.json_response(%{"error" => %{"message" => "provider unavailable"}})
    end)

    assert {:error, %{code: "PAYMENT_PROVIDER_DOWN"}} =
             SubscriptionsFacade.process_due_subscription_renewal_for_system(subscription.id,
               now: now
             )

    assert_receive {:renewal_provider_request, _first_key, first_collection_id,
                    first_payment_intent_id},
                   5_000

    assert :atomics.get(request_count, 1) == 1

    assert {:ok, %{status: :canceled}} =
             SubscriptionsFacade.cancel_subscription_for_user(customer, subscription.id, :now)

    StripeAPIStub.stub_unexpected!("canceled reached collection must not submit another charge")

    assert {:error, %{code: "PAYMENT_OUTCOME_UNRESOLVED"}} =
             SubscriptionsFacade.process_due_subscription_renewal_for_system(subscription.id,
               now: now
             )

    refute_receive {:renewal_provider_request, _, _, _}, 100
    assert :atomics.get(request_count, 1) == 1
    assert fetch_subscription!(subscription.id).status == :canceled

    attempt = fetch_latest_attempt!(subscription.id)

    collections =
      RenewalCollectionAttempt
      |> Ash.Query.filter(expr(renewal_attempt_id == ^attempt.id))
      |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    assert [%RenewalCollectionAttempt{} = collection] = collections
    assert collection.dispatch_state == :may_have_been_reached
    assert collection.financial_outcome == :unresolved
    assert collection.id == first_collection_id
    assert collection.payment_intent_id == first_payment_intent_id
    assert collection.collection_ordinal == 1
  end

  test "reached collection recovery after suspension replays its exact PaymentIntent and key" do
    customer = SubscriptionsFixtures.create_customer!("jc229_suspended_reached_replay")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 2_600})
    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: "pm_jc229_suspended_reached_replay",
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    parent = self()
    request_count = :atomics.new(1, [])

    StripeAPIStub.stub_payment_intent(fn conn, params ->
      :atomics.add(request_count, 1, 1)
      [idempotency_key] = Plug.Conn.get_req_header(conn, "idempotency-key")

      send(parent, {
        :renewal_provider_request,
        idempotency_key,
        Map.fetch!(params, "metadata[collection_attempt_id]"),
        Map.fetch!(params, "metadata[local_intent_id]")
      })

      conn
      |> Plug.Conn.put_status(500)
      |> StripeAPIStub.json_response(%{"error" => %{"message" => "provider unavailable"}})
    end)

    assert {:error, %{code: "PAYMENT_PROVIDER_DOWN"}} =
             SubscriptionsFacade.process_due_subscription_renewal_for_system(subscription.id,
               now: now
             )

    assert_receive {:renewal_provider_request, first_key, first_collection_id,
                    first_payment_intent_id},
                   5_000

    suspended =
      fetch_subscription!(subscription.id)
      |> Ash.Changeset.for_update(
        :mark_suspended_transition,
        %{billing_status_reason: "PAYMENT_FAILED"},
        context: %{system?: true}
      )
      |> Ash.update!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    assert suspended.status == :suspended

    assert {:error, %{code: "PAYMENT_PROVIDER_DOWN"}} =
             SubscriptionsFacade.process_due_subscription_renewal_for_system(subscription.id,
               now: now
             )

    assert_receive {:renewal_provider_request, ^first_key, ^first_collection_id,
                    ^first_payment_intent_id},
                   5_000

    assert :atomics.get(request_count, 1) == 2
    assert fetch_subscription!(subscription.id).status == :suspended

    attempt = fetch_latest_attempt!(subscription.id)

    collections =
      RenewalCollectionAttempt
      |> Ash.Query.filter(expr(renewal_attempt_id == ^attempt.id))
      |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    assert [%RenewalCollectionAttempt{} = collection] = collections
    assert collection.dispatch_state == :may_have_been_reached
    assert collection.financial_outcome == :unresolved
    assert collection.id == first_collection_id
    assert collection.payment_intent_id == first_payment_intent_id
    assert collection.collection_ordinal == 1
  end

  test "certified terminal collection failure retries with a new collection on the same renewal order" do
    Application.put_env(:store, :payments,
      enabled_providers: [:stripe],
      stripe: [
        webhook_secret: "whsec_test_only_change_me",
        secret_key: "sk_test_store_blueprint",
        publishable_key: "pk_test_store_blueprint",
        request_options: StripeAPIStub.req_options()
      ]
    )

    customer = SubscriptionsFixtures.create_customer!("jc229_terminal_collection_retry")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        amount_minor: 2_600,
        max_retry_attempts: 2,
        retry_schedule_hours: [0, 24]
      })

    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider: :stripe,
        provider_billing_ref: "pm_jc229_terminal_collection_retry",
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    parent = self()
    request_count = :atomics.new(1, [])

    StripeAPIStub.stub_payment_intent(fn conn, params ->
      request_no = :atomics.add_get(request_count, 1, 1)
      collection_id = Map.fetch!(params, "metadata[collection_attempt_id]")
      local_intent_id = Map.fetch!(params, "metadata[local_intent_id]")
      [idempotency_key] = Plug.Conn.get_req_header(conn, "idempotency-key")

      send(
        parent,
        {:renewal_collection_request, request_no, collection_id, local_intent_id, idempotency_key}
      )

      response =
        if request_no == 1 do
          %{"status" => "canceled"}
        else
          %{"status" => "succeeded"}
        end

      StripeAPIStub.json_response(conn, StripeAPIStub.payment_intent_response(params, response))
    end)

    assert {:error, %{code: "PAYMENT_FAILED"}} =
             SubscriptionsFacade.process_due_subscription_renewal_for_system(subscription.id,
               now: now
             )

    assert_receive {:renewal_collection_request, 1, first_collection_id, first_intent_id,
                    first_idempotency_key},
                   5_000

    attempt = fetch_latest_attempt!(subscription.id)
    first_collection = fetch_collection!(first_collection_id)
    first_intent = fetch_payment_intent!(first_intent_id)
    order = fetch_order!(attempt.order_id)

    assert first_collection.collection_ordinal == 1
    assert first_collection.financial_outcome == :verified_terminal_financial_non_success
    assert first_collection.payment_intent_id == first_intent.id
    assert first_intent.state == :failed
    assert order.state == :pending_payment

    assert {:ok, :processed} =
             SubscriptionsFacade.process_due_subscription_renewal_for_system(subscription.id,
               now: now
             )

    assert_receive {:renewal_collection_request, 2, second_collection_id, second_intent_id,
                    second_idempotency_key},
                   5_000

    second_collection = fetch_collection!(second_collection_id)
    second_intent = fetch_payment_intent!(second_intent_id)
    updated_order = fetch_order!(order.id)

    assert second_collection.collection_ordinal == 2
    assert second_collection.renewal_attempt_id == attempt.id
    assert second_collection.id != first_collection.id
    assert second_collection.payment_intent_id == second_intent.id
    assert second_intent.id != first_intent.id
    assert second_intent.payment_intent_key == "renewal-collection:" <> second_collection.id
    assert first_idempotency_key == "renewal-collection:" <> first_collection.id
    assert second_idempotency_key == "renewal-collection:" <> second_collection.id
    assert second_idempotency_key != first_idempotency_key
    assert updated_order.id == order.id
    assert updated_order.state == :paid
    assert second_intent.state == :succeeded

    assert {:ok, [application]} =
             PaymentApplication
             |> Ash.Query.filter(expr(order_id == ^order.id))
             |> Ash.read(domain: Store.Orders, authorize?: false)

    assert application.payment_intent_id == second_intent.id

    reconciliation_args = %{
      "order_id" => order.id,
      "renewal_attempt_id" => attempt.id,
      "collection_attempt_id" => second_collection.id,
      "payment_intent_id" => second_intent.id
    }

    assert {:ok, handoff} =
             RenewalCollectionAttempts.success_handoff_for_system(second_collection.id)

    assert handoff == %{
             order_id: order.id,
             renewal_attempt_id: attempt.id,
             collection_attempt_id: second_collection.id,
             payment_intent_id: second_intent.id
           }

    refute_enqueued(
      worker: Store.Workers.ReconcilePaidSubscriptionRenewalWorker,
      args: reconciliation_args
    )

    assert {:error, %{code: "PAYMENT_EVENT_UNVERIFIED"}} =
             SubscriptionsFacade.reconcile_paid_subscription_renewal_for_system(order.id,
               renewal_attempt_id: attempt.id
             )

    assert fetch_subscription!(subscription.id).current_period_end_at ==
             subscription.current_period_end_at
  end

  test "a stale legacy PaymentIntent cannot apply against an existing collection identity" do
    Application.put_env(:store, :payments,
      enabled_providers: [:stripe],
      stripe: [
        webhook_secret: "whsec_test_only_change_me",
        secret_key: "sk_test_store_blueprint",
        publishable_key: "pk_test_store_blueprint",
        request_options: StripeAPIStub.req_options()
      ]
    )

    customer = SubscriptionsFixtures.create_customer!("jc229_stale_legacy_pi")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 2_600})
    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: "pm_jc229_stale_legacy_pi",
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    StripeAPIStub.stub_payment_intent(fn conn, params ->
      StripeAPIStub.json_response(
        conn,
        StripeAPIStub.payment_intent_response(params, %{"status" => "processing"})
      )
    end)

    assert {:ok, :processed} =
             SubscriptionsFacade.process_due_subscription_renewal_for_system(subscription.id,
               now: now
             )

    attempt = fetch_latest_attempt!(subscription.id)
    order = fetch_order!(attempt.order_id)

    collection =
      RenewalCollectionAttempt
      |> Ash.Query.filter(expr(renewal_attempt_id == ^attempt.id))
      |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    collection_intent = fetch_payment_intent!(collection.payment_intent_id)

    assert {:ok, _locally_failed} =
             collection_intent
             |> Ash.Changeset.for_update(:mark_failed, %{}, context: %{system?: true})
             |> Ash.update(domain: Store.Payments, authorize?: false, context: %{system?: true})

    assert {:ok, stale_result} =
             Store.Payments.create_or_reuse_payment_intent(
               %{
                 order_id: order.id,
                 amount_received_minor: collection_intent.amount_received_minor,
                 currency: collection_intent.currency,
                 provider: collection_intent.provider,
                 payment_intent_key: "jc229_stale_legacy:#{Ecto.UUID.generate()}"
               },
               context: %{system?: true}
             )

    stale_intent =
      stale_result.payment_intent
      |> Ash.Changeset.for_update(:submit, %{}, context: %{system?: true})
      |> Ash.update!(domain: Store.Payments, authorize?: false, context: %{system?: true})

    assert {:ok, %{num_rows: 1}} =
             Repo.query(
               "UPDATE renewal_attempts SET payment_intent_id = $2::uuid WHERE id = $1::uuid",
               [Ecto.UUID.dump!(attempt.id), Ecto.UUID.dump!(stale_intent.id)]
             )

    assert {:error, %{code: "PAYMENT_EVENT_UNVERIFIED"}} =
             Store.Payments.apply_payment_success_once(stale_intent.id)

    assert fetch_order!(order.id).state == :pending_payment

    assert 0 ==
             PaymentApplication
             |> Ash.Query.filter(expr(order_id == ^order.id))
             |> Ash.count!(domain: Store.Orders, authorize?: false, context: %{system?: true})

    assert fetch_collection!(collection.id).payment_intent_id == collection_intent.id
  end

  test "direct Stripe success applies only when returned money and environment exactly match" do
    Application.put_env(:store, :payments,
      enabled_providers: [:stripe],
      stripe: [
        webhook_secret: "whsec_test_only_change_me",
        secret_key: "sk_test_store_blueprint",
        publishable_key: "pk_test_store_blueprint",
        request_options: StripeAPIStub.req_options()
      ]
    )

    cases = [
      {"amount_mismatch", 2_500, %{"amount_received" => 2_499}, 2_499, "USD", "test"},
      {"currency_mismatch", 2_600, %{"currency" => "zar"}, 2_600, "ZAR", "test"},
      {"environment_mismatch", 2_700, %{"livemode" => true}, 2_700, "USD", "live"},
      {"missing_id", 2_750, %{"id" => nil}, 2_750, "USD", "test"},
      {"missing_evidence", 2_800,
       %{"amount_received" => nil, "amount" => nil, "currency" => nil, "livemode" => nil}, nil,
       nil, nil}
    ]

    for {suffix, amount_minor, overrides, evidence_amount, evidence_currency, evidence_env} <-
          cases do
      StripeAPIStub.stub_payment_intent(fn conn, params ->
        response =
          Map.merge(
            %{"status" => "succeeded"},
            overrides
          )

        StripeAPIStub.json_response(
          conn,
          StripeAPIStub.payment_intent_response(params, response)
        )
      end)

      customer = SubscriptionsFixtures.create_customer!("phase28_#{suffix}")
      %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
      plan = SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: amount_minor})
      _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      %{subscription: subscription} =
        SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
          provider: :stripe,
          provider_billing_ref: "pm_phase28_#{suffix}",
          next_renewal_at: DateTime.add(now, -10, :second)
        })

      assert {:ok, :processed} =
               SubscriptionsFacade.process_due_subscription_renewal_for_system(
                 subscription.id,
                 now: now
               )

      attempt = fetch_latest_attempt!(subscription.id)
      order = fetch_order!(attempt.order_id)
      payment_intent = fetch_payment_intent!(attempt.payment_intent_id)

      assert order.state == :pending_payment
      assert payment_intent.state == :submitted
      assert attempt.status == :processing

      assert 0 ==
               PaymentApplication
               |> Ash.Query.filter(expr(order_id == ^order.id))
               |> Ash.count!(domain: Store.Orders, authorize?: false)

      assert {:ok, [evidence]} =
               PaymentAttempt
               |> Ash.Query.filter(expr(payment_intent_id == ^payment_intent.id))
               |> Ash.read(domain: Store.Payments, authorize?: false)

      assert evidence.observation_source == "direct_response"
      assert evidence.outcome == "authoritative_success"
      assert evidence.amount_minor == evidence_amount
      assert evidence.currency == evidence_currency
      assert evidence.provider_environment == evidence_env

      if suffix == "missing_id" do
        assert evidence.provider_reference == nil
        assert attempt.status == :processing
      end
    end
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

  test "physical renewal retains inventory when Stripe returns a retryable payment failure" do
    Application.put_env(:store, :payments,
      enabled_providers: [:stripe],
      stripe: [
        webhook_secret: "whsec_test_only_change_me",
        secret_key: "sk_test_store_blueprint",
        publishable_key: "pk_test_store_blueprint",
        request_options: StripeAPIStub.req_options()
      ]
    )

    StripeAPIStub.stub_payment_intent(fn conn, params ->
      StripeAPIStub.payment_intent_error(
        conn,
        params,
        "requires_payment_method",
        "card_declined",
        "card was declined"
      )
    end)

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

    assert {:ok, :processed} =
             SubscriptionsFacade.process_due_subscription_renewal_for_system(subscription.id,
               now: now
             )

    attempt = fetch_latest_attempt!(subscription.id)
    assert attempt.status == :processing
    payment_intent = fetch_payment_intent!(attempt.payment_intent_id)
    assert payment_intent.provider_payment_id
    reservation = fetch_reservation!(attempt.order_id, variant.id)
    assert reservation.state == :active

    inventory = Repo.get_by!(InventoryItem, variant_id: variant.id)
    assert inventory.reserved_count == 1
    assert inventory.stock_on_hand == 1

    StripeAPIStub.stub_payment_observation(payment_intent.provider_payment_id, %{
      "amount" => payment_intent.amount_received_minor,
      "amount_received" => 0,
      "currency" => String.downcase(payment_intent.currency),
      "id" => payment_intent.provider_payment_id,
      "livemode" => false,
      "metadata" => %{"local_intent_id" => payment_intent.id},
      "status" => "processing"
    })

    assert {:error, %{code: "PAYMENT_OUTCOME_UNRESOLVED"}} =
             SubscriptionsFacade.process_due_subscription_renewal_for_system(subscription.id,
               now: now
             )

    assert :processing == fetch_latest_attempt!(subscription.id).status
    assert :pending_payment == fetch_order!(attempt.order_id).state
    assert :active == fetch_reservation!(attempt.order_id, variant.id).state
    assert 0 == Repo.aggregate(PaymentApplication, :count, :id)

    StripeAPIStub.stub_payment_observation(payment_intent.provider_payment_id, %{
      "amount" => payment_intent.amount_received_minor,
      "amount_received" => payment_intent.amount_received_minor,
      "currency" => String.downcase(payment_intent.currency),
      "id" => payment_intent.provider_payment_id,
      "livemode" => false,
      "metadata" => %{"local_intent_id" => payment_intent.id},
      "status" => "succeeded"
    })

    assert {:ok, :processed} =
             SubscriptionsFacade.process_due_subscription_renewal_for_system(subscription.id,
               now: now
             )

    assert :paid == fetch_order!(attempt.order_id).state
    assert :succeeded == fetch_payment_intent!(payment_intent.id).state
    assert 1 == Repo.aggregate(PaymentApplication, :count, :id)
    assert :consumed == fetch_reservation!(attempt.order_id, variant.id).state
  end

  test "legacy pending projections cannot select a renewal contract" do
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

    attempts_before = Repo.aggregate(RenewalAttempt, :count, :id)
    orders_before = Repo.aggregate(Order, :count, :id)
    intents_before = Repo.aggregate(PaymentIntent, :count, :id)
    StripeAPIStub.stub_unexpected!("legacy pending projections must fail closed")

    assert {:error, %{code: "VALIDATION_ERROR"}} =
             SubscriptionsFacade.process_due_subscription_renewal_for_system(subscription.id,
               now: now
             )

    assert Repo.aggregate(RenewalAttempt, :count, :id) == attempts_before
    assert Repo.aggregate(Order, :count, :id) == orders_before
    assert Repo.aggregate(PaymentIntent, :count, :id) == intents_before

    unresolved = fetch_subscription!(subscription.id)
    assert unresolved.subscription_plan_id == plan.id
    assert unresolved.variant_id == variant.id
    assert unresolved.pending_subscription_plan_id == upgraded_plan.id
    assert unresolved.pending_variant_id == upgraded_variant.id
    assert unresolved.pending_renewal_amount_minor == upgraded_plan.amount_minor
    assert unresolved.pending_renewal_currency == upgraded_plan.currency
  end

  test "run_due_renewals_for_system suspends subscriptions past grace and revokes entitlements" do
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

    suspended = fetch_subscription!(subscription.id)
    assert suspended.status == :suspended
    assert is_nil(suspended.ended_at)
    assert is_nil(suspended.canceled_at)
    assert is_nil(suspended.canceled_reason)
    assert is_nil(suspended.next_retry_at)

    entitlement = fetch_entitlement!(subscription.id)
    assert entitlement.status == :revoked
    assert entitlement.revoked_reason == "grace_expired"

    assert 1 ==
             EmailOutbox
             |> Ash.Query.filter(
               expr(subscription_id == ^subscription.id and template_kind == :access_ended)
             )
             |> Ash.count!(domain: Store.Comms, authorize?: false, context: %{system?: true})

    assert {:ok, %{due_count: 0, success_count: 0, failed_count: 0}} =
             SubscriptionsFacade.run_due_renewals_for_system(now: now, limit: 20)
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

  test "queue plan and variant changes use the requested dimension and live dimensions" do
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
    target_revision = SubscriptionsFixtures.create_plan_revision!(target_plan)

    target_variant =
      create_variant_target!(product.id, %{
        price_minor: 4_500,
        title: "Boundary Variant"
      })

    _target_variant_attachment =
      SubscriptionsFixtures.attach_variant_plan!(target_variant.id, target_plan.id)

    _target_variant_current_plan_attachment =
      SubscriptionsFixtures.attach_variant_plan!(target_variant.id, current_plan.id)

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

    contract_change =
      ContractChange
      |> Ash.Query.filter(expr(id == ^queued_variant.current_contract_change_id))
      |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    assert contract_change.target_plan_revision_id == target_revision.id
    assert contract_change.target_variant_id == target_variant.id

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
        secret_key: "sk_test_boundary_123",
        publishable_key: "pk_test_boundary_123",
        request_options: StripeAPIStub.req_options()
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
    assert result.client_secret =~ "seti_test_"

    payment_intent = fetch_payment_intent!(result.payment_intent_id)
    assert payment_intent.purpose == :subscription_payment_method_update
    assert payment_intent.subscription_id == subscription.id
    assert payment_intent.provider_customer_ref == "cus_setup_001"
    assert payment_intent.provider_payment_id =~ "seti_test_"
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

  defp fetch_collection!(collection_attempt_id) do
    RenewalCollectionAttempt
    |> Ash.Query.filter(expr(id == ^collection_attempt_id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp fetch_collection_for_attempt!(renewal_attempt_id) do
    RenewalCollectionAttempt
    |> Ash.Query.filter(expr(renewal_attempt_id == ^renewal_attempt_id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
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
